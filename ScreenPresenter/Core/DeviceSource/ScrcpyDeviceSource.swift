//
//  ScrcpyDeviceSource.swift
//  ScreenPresenter
//
//  Created by Sun on 2025/12/22.
//
//  Scrcpy 设备源
//  通过 scrcpy-server 获取 Android 设备的 H.264/H.265 码流
//  使用 VideoToolbox 进行硬件解码
//

import AppKit
import Combine
import CoreMedia
import CoreVideo
import Foundation
import Network
import VideoToolbox

// MARK: - Scrcpy 配置

/// Scrcpy 启动配置
struct ScrcpyConfiguration {
    /// 设备序列号
    var serial: String

    /// 最大尺寸限制（0 表示不限制）
    var maxSize: Int = 0

    /// 比特率 (bps)
    var bitrate: Int = 8_000_000

    /// 最大帧率
    var maxFps: Int = 60

    /// 是否显示触摸点
    var showTouches: Bool = false

    /// 是否关闭设备屏幕
    var turnScreenOff: Bool = false

    /// 是否保持唤醒
    var stayAwake: Bool = true

    /// 是否禁用音频
    var noAudio: Bool = true

    /// 视频编解码器
    var videoCodec: VideoCodec = .h264

    /// 窗口标题（用于 scrcpy 窗口模式）
    var windowTitle: String?

    /// 窗口置顶
    var alwaysOnTop: Bool = false

    /// 录屏文件路径
    var recordPath: String?

    /// 录制格式
    var recordFormat: RecordFormat = .mp4

    /// 视频编解码器枚举
    enum VideoCodec: String {
        case h264
        case h265

        var fourCC: CMVideoCodecType {
            switch self {
            case .h264: kCMVideoCodecType_H264
            case .h265: kCMVideoCodecType_HEVC
            }
        }
    }

    /// 录制格式枚举
    enum RecordFormat: String {
        case mp4
        case mkv
    }

    /// 构建命令行参数（用于原始流输出）
    func buildRawStreamArguments() -> [String] {
        var args: [String] = []

        args.append("-s")
        args.append(serial)

        if maxSize > 0 {
            args.append("--max-size=\(maxSize)")
        }

        args.append("--video-bit-rate=\(bitrate)")
        args.append("--max-fps=\(maxFps)")
        args.append("--video-codec=\(videoCodec.rawValue)")

        // 关键：不显示窗口，输出原始流
        // 注意: scrcpy 3.x 已移除 --no-display，使用 --no-playback 替代
        args.append("--no-playback")
        args.append("--no-audio")
        args.append("--no-control")

        // 视频源为显示器
        args.append("--video-source=display")

        if stayAwake {
            args.append("--stay-awake")
        }

        return args
    }

    /// 构建命令行参数（用于窗口显示模式）
    func buildWindowArguments() -> [String] {
        var args: [String] = []

        args.append("-s")
        args.append(serial)

        if noAudio {
            args.append("--no-audio")
        }
        if stayAwake {
            args.append("--stay-awake")
        }
        if turnScreenOff {
            args.append("--turn-screen-off")
        }
        if maxSize > 0 {
            args.append("--max-size=\(maxSize)")
        }
        if maxFps > 0 {
            args.append("--max-fps=\(maxFps)")
        }
        if bitrate > 0 {
            args.append("--video-bit-rate=\(bitrate)")
        }
        if let windowTitle {
            args.append("--window-title=\(windowTitle)")
        }
        if alwaysOnTop {
            args.append("--always-on-top")
        }
        if let recordPath {
            args.append("--record=\(recordPath)")
            args.append("--record-format=\(recordFormat.rawValue)")
        }

        return args
    }
}

// MARK: - Scrcpy 设备源

/// Scrcpy 设备源实现
/// 通过直接与 scrcpy-server 通信获取原始 H.264/H.265 码流并使用 VideoToolbox 解码
final class ScrcpyDeviceSource: BaseDeviceSource {
    // MARK: - 常量

    /// 默认端口
    private static let defaultPort = 27183

    // MARK: - 配置

    private let configuration: ScrcpyConfiguration
    private let toolchainManager: ToolchainManager

    // MARK: - 组件

    /// ADB 服务
    private var adbService: AndroidADBService?

    /// 服务器启动器
    private var serverLauncher: ScrcpyServerLauncher?

    /// Socket 接收器
    private var socketAcceptor: ScrcpySocketAcceptor?

    /// 视频流解析器
    private var streamParser: ScrcpyVideoStreamParser?

    /// VideoToolbox 解码器
    private var decoder: VideoToolboxDecoder?

    // MARK: - 状态

    /// 服务器进程
    private var serverProcess: Process?

    /// 监控任务
    private var monitorTask: Task<Void, Never>?

    /// 帧管道（参照 scrcpy trait 模式设计）
    /// 实现: 解码线程 → FramePipeline → 主线程渲染
    private let framePipeline = FramePipeline()

    /// 最新的 CVPixelBuffer 存储（兼容旧接口）
    private var _latestPixelBuffer: CVPixelBuffer?

    /// 最新的 CVPixelBuffer（供渲染使用）
    override var latestPixelBuffer: CVPixelBuffer? { _latestPixelBuffer }

    /// 帧回调（通过 FramePipeline 分发，已实现事件合并）
    var onFrame: ((CVPixelBuffer) -> Void)? {
        didSet {
            // 将回调注册到帧管道
            if let callback = onFrame {
                framePipeline.setFrameHandler { [weak self] pixelBuffer in
                    // 更新最新帧引用
                    self?._latestPixelBuffer = pixelBuffer
                    // 调用外部回调
                    callback(pixelBuffer)
                }
            } else {
                framePipeline.setFrameHandler { _ in }
            }
        }
    }

    /// 当前端口
    private var currentPort: Int

    /// 帧管道统计任务
    private var pipelineStatsTask: Task<Void, Never>?

    // MARK: - 初始化

    init(device: AndroidDevice, toolchainManager: ToolchainManager, configuration: ScrcpyConfiguration? = nil) {
        // 使用传入的配置或从用户偏好设置构建配置
        var config = configuration ?? UserPreferences.shared.buildScrcpyConfiguration(serial: device.serial)
        config.serial = device.serial
        self.configuration = config
        self.toolchainManager = toolchainManager

        // 从用户偏好读取端口配置
        currentPort = UserPreferences.shared.scrcpyPort

        super.init(
            displayName: device.displayName,
            sourceType: .scrcpy
        )

        // 设置设备信息
        deviceInfo = GenericDeviceInfo(
            id: device.serial,
            name: device.displayName,
            model: device.model,
            platform: .android
        )

        AppLogger.device.info("创建 Scrcpy 设备源: \(device.displayName)")
    }

    deinit {
        monitorTask?.cancel()
    }

    // MARK: - 连接

    override func connect() async throws {
        AppLogger.connection.info("准备连接 Android 设备: \(configuration.serial), 当前状态: \(state)")

        guard state == .idle || state == .disconnected else {
            AppLogger.connection.warning("设备已连接或正在连接中，当前状态: \(state)")
            return
        }

        updateState(.connecting)
        AppLogger.connection.info("开始连接 Android 设备: \(configuration.serial)")

        // 获取工具链路径
        let (adbPath, scrcpyServerPath, scrcpyReady) = await MainActor.run {
            (
                toolchainManager.adbPath,
                toolchainManager.scrcpyServerPath,
                toolchainManager.scrcpyStatus.isReady
            )
        }

        AppLogger.connection.info("scrcpy 状态: \(scrcpyReady ? "就绪" : "未就绪")")

        guard scrcpyReady else {
            let error = DeviceSourceError.connectionFailed("scrcpy 未安装")
            AppLogger.connection.error("连接失败: scrcpy 未安装")
            updateState(.error(error))
            throw error
        }

        guard let serverPath = scrcpyServerPath else {
            let error = DeviceSourceError.connectionFailed("scrcpy-server 未找到")
            AppLogger.connection.error("连接失败: scrcpy-server 未找到")
            updateState(.error(error))
            throw error
        }

        // 创建 ADB 服务
        adbService = await MainActor.run {
            AndroidADBService(
                adbPath: adbPath,
                deviceSerial: configuration.serial
            )
        }

        // 创建视频流解析器（使用标准协议模式）
        streamParser = ScrcpyVideoStreamParser(codecType: configuration.videoCodec.fourCC, useRawStream: false)

        // 设置 SPS 变化回调（分辨率变化时重建解码器）
        streamParser?.onSPSChanged = { [weak self] _ in
            self?.handleSPSChanged()
        }

        // 创建 VideoToolbox 解码器
        decoder = VideoToolboxDecoder(codecType: configuration.videoCodec.fourCC)
        decoder?.onDecodedFrame = { [weak self] pixelBuffer in
            self?.handleDecodedFrame(pixelBuffer)
        }

        // 获取 scrcpy 版本
        let scrcpyVersion = await getScrcpyVersion()

        // 创建服务器启动器
        guard let adbService else {
            updateState(.disconnected)
            AppLogger.connection.error("❌ 缺少 adbService，无法启动 scrcpy: \(displayName)")
            return
        }

        serverLauncher = ScrcpyServerLauncher(
            adbService: adbService,
            serverLocalPath: serverPath,
            port: currentPort,
            scrcpyVersion: scrcpyVersion
        )

        updateState(.connected)
        AppLogger.connection.info("✅ 设备连接成功: \(displayName), 状态: \(state)")
    }

    override func disconnect() async {
        AppLogger.connection.info("断开连接: \(displayName), 当前状态: \(state)")

        monitorTask?.cancel()
        monitorTask = nil

        // stopCapture 会处理所有清理工作
        await stopCapture()

        // 清理组件
        adbService = nil
        serverLauncher = nil
        socketAcceptor = nil
        streamParser = nil
        decoder = nil
        _latestPixelBuffer = nil

        updateState(.disconnected)
    }

    // MARK: - 捕获

    override func startCapture() async throws {
        AppLogger.capture.info("开始捕获 Android 设备: \(displayName), 状态: \(state)")

        guard state == .connected || state == .paused else {
            AppLogger.capture.error("无法开始捕获: 设备未连接，当前状态: \(state)")
            throw DeviceSourceError.captureStartFailed(L10n.capture.deviceNotConnected)
        }

        do {
            guard let launcher = serverLauncher else {
                throw DeviceSourceError.captureStartFailed("服务器启动器未初始化")
            }

            // 1. 先推送 scrcpy-server 并设置端口转发
            try await launcher.prepareEnvironment(configuration: configuration)

            // 2. 创建并启动 Socket 监听器/连接器（必须在服务端启动前！）
            socketAcceptor = ScrcpySocketAcceptor(
                port: currentPort,
                connectionMode: launcher.connectionMode
            )

            // 设置数据接收回调
            socketAcceptor?.onDataReceived = { [weak self] data in
                // 使用 autoreleasepool 确保每次数据处理过程中创建的临时对象及时释放
                // NWConnection 回调在后台线程，如果没有 autoreleasepool，
                // autorelease 对象会堆积直到某个时机才释放
                autoreleasepool {
                    self?.handleReceivedData(data)
                }
            }

            // 3. 启动监听/连接
            try await socketAcceptor?.start()

            // 4. 提前设置状态为 capturing，以便接收到数据后立即处理
            // 这样解码后的帧不会因为状态检查而被丢弃
            updateState(.capturing)

            // 5. 现在启动 scrcpy-server（它会连接到我们的监听端口）
            serverProcess = try await launcher.startServer(configuration: configuration)

            // 6. 等待视频连接建立
            try await socketAcceptor?.waitForVideoConnection(timeout: 10)

            AppLogger.capture.info("捕获已启动: \(displayName)")

            // 启动进程监控
            startProcessMonitoring()

            // 启动帧管道（使用初始尺寸，会在收到第一帧时更新）
            framePipeline.start(size: CGSize(width: 1080, height: 1920))

            // 启动帧管道统计任务（每 5 秒输出一次）
            startPipelineStats()

        } catch {
            let captureError = DeviceSourceError.captureStartFailed(error.localizedDescription)
            updateState(.error(captureError))
            throw captureError
        }
    }

    override func stopCapture() async {
        AppLogger.capture.info("停止捕获: \(displayName)")

        // 0. 停止帧管道统计任务
        stopPipelineStats()
        
        // 0.5. 停止帧管道
        framePipeline.stop()

        // 1. 停止 Socket 接收器
        socketAcceptor?.stop()
        socketAcceptor = nil

        // 2. 停止服务器启动器
        await serverLauncher?.stop()

        // 3. 终止服务器进程
        if let process = serverProcess, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        serverProcess = nil

        // 4. 重置解析器
        streamParser?.reset()

        // 5. 重置解码器
        decoder?.reset()

        // 6. 重置帧管道（清空旧帧）
        framePipeline.stop()

        if state == .capturing {
            updateState(.connected)
        }

        AppLogger.capture.info("捕获已停止: \(displayName)")
    }

    // MARK: - 数据处理

    /// 过滤掉的非 VCL NAL 计数（用于诊断）
    private var filteredNonVCLCount = 0
    
    /// 端到端延迟统计
    private var frameReceiveTime: CFAbsoluteTime = 0
    private var frameDecodeCompleteTime: CFAbsoluteTime = 0
    private var totalE2ELatency: Double = 0
    private var maxE2ELatency: Double = 0
    private var e2eLatencyCount: Int = 0
    private var lastE2EStatsTime = CFAbsoluteTimeGetCurrent()

    /// 处理接收到的数据
    private func handleReceivedData(_ data: Data) {
        // 记录数据接收时间
        frameReceiveTime = CFAbsoluteTimeGetCurrent()
        
        guard let parser = streamParser, let decoder else { return }

        // 解析 NAL 单元
        let nalUnits = parser.append(data)

        for nalUnit in nalUnits {
            // 如果是参数集且解码器未初始化，尝试初始化
            if nalUnit.isParameterSet, !decoder.isReady {
                if parser.hasCompleteParameterSets {
                    initializeDecoderIfNeeded()
                }
                continue
            }

            // 过滤非 VCL NAL 单元（SEI/AUD/filler 等）
            // 这些单元不包含实际视频数据，不应送入解码器
            guard nalUnit.isVCL else {
                filteredNonVCLCount += 1
                // 每 100 个非 VCL NAL 记录一次日志（避免日志过多）
                if filteredNonVCLCount % 100 == 1 {
                    AppLogger.capture.debug("[Scrcpy] 过滤非 VCL NAL (type=\(nalUnit.type))，累计过滤: \(filteredNonVCLCount)")
                }
                continue
            }

            // 解码 VCL NAL 单元（实际视频帧数据）
            if decoder.isReady {
                decoder.decode(nalUnit: nalUnit)
            }
        }
    }

    /// 初始化解码器（如果需要）
    private func initializeDecoderIfNeeded() {
        guard let parser = streamParser, let decoder else { return }
        guard !decoder.isReady else { return }
        guard parser.hasCompleteParameterSets else { return }

        initializeDecoder()
    }

    /// 初始化解码器
    private func initializeDecoder() {
        guard let parser = streamParser, let decoder else { return }
        guard parser.hasCompleteParameterSets else { return }

        // 获取实际的编解码类型（可能从协议元数据更新）
        let codecType = parser.currentCodecType

        do {
            if codecType == kCMVideoCodecType_H264 {
                guard let sps = parser.sps, let pps = parser.pps else { return }
                try decoder.initializeH264(sps: sps, pps: pps)
            } else {
                guard let vps = parser.vps, let sps = parser.sps, let pps = parser.pps else { return }
                try decoder.initializeH265(vps: vps, sps: sps, pps: pps)
            }
            AppLogger.capture.info("✅ 解码器初始化成功（可能是旋转后重建）")
        } catch {
            AppLogger.capture.error("解码器初始化失败: \(error.localizedDescription)")
        }
    }

    /// 处理 SPS 变化（分辨率变化）
    /// 注意：只标记需要重建解码器，不立即重建
    /// 因为新的 PPS 可能还没到达，需要等待完整参数集
    private func handleSPSChanged() {
        AppLogger.capture.info("⚠️ 检测到 SPS 变化（设备旋转），标记解码器需要重建...")

        // 重置解码器（这会导致 isReady = false）
        decoder?.reset()

        // 重置帧管道（清空旧帧，避免显示旧的旋转前内容）
        framePipeline.stop()
        // 立即重新启动（使用当前尺寸或默认尺寸）
        framePipeline.start(size: captureSize != .zero ? captureSize : CGSize(width: 1080, height: 1920))

        AppLogger.capture.info("[旋转] 解码器已重置，等待新的完整参数集...")

        // 不在这里调用 initializeDecoder()
        // 等待 handleReceivedData 中收到新的参数集后自动重新初始化
        // 因为设备旋转时，scrcpy 会重新发送完整的 config packet (SPS + PPS)
    }

    /// 处理解码后的帧
    /// 使用双帧缓冲设计（与 scrcpy frame_buffer.c 一致）
    private func handleDecodedFrame(_ pixelBuffer: CVPixelBuffer) {
        guard state == .capturing else { return }
        
        // 计算端到端延迟（从数据接收到解码完成）
        let decodeCompleteTime = CFAbsoluteTimeGetCurrent()
        let e2eLatency = (decodeCompleteTime - frameReceiveTime) * 1000 // 转换为毫秒
        
        totalE2ELatency += e2eLatency
        maxE2ELatency = max(maxE2ELatency, e2eLatency)
        e2eLatencyCount += 1
        
        // 每 5 秒重置统计（保留内部统计逻辑，移除日志输出）
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastE2EStatsTime
        if elapsed >= 5.0 {
            // 重置统计
            lastE2EStatsTime = now
            totalE2ELatency = 0
            maxE2ELatency = 0
            e2eLatencyCount = 0
        }

        // 更新最新帧（兼容旧接口）
        _latestPixelBuffer = pixelBuffer

        // 更新捕获尺寸（这会触发 UI 刷新，包括 bezel 更新）
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let newSize = CGSize(width: width, height: height)

        // 检测尺寸变化（可能是旋转导致）
        if captureSize != newSize {
            let wasLandscape = captureSize.width > captureSize.height
            let isLandscape = width > height
            if wasLandscape != isLandscape {
                AppLogger.capture.info("[旋转] 检测到方向变化: \(wasLandscape ? "横屏" : "竖屏") → \(isLandscape ? "横屏" : "竖屏")")
                AppLogger.capture.info("[旋转] 新尺寸: \(width) x \(height)")
            }
        }

        updateCaptureSize(newSize)

        // 创建 CapturedFrame
        let frame = CapturedFrame(
            pixelBuffer: pixelBuffer,
            presentationTime: CMTime(value: Int64(CACurrentMediaTime() * 1_000_000), timescale: 1_000_000),
            size: newSize
        )
        emitFrame(frame)

        // 使用 FramePipeline 分发帧到主线程
        // FramePipeline 实现了 scrcpy 的事件合并机制：
        // - 如果上一帧还未被渲染，不发送新的主线程事件
        // - 主线程消费时总是获取最新帧
        // 这避免了主线程任务堆积的问题
        framePipeline.pushFrame(pixelBuffer)
    }

    // MARK: - 辅助方法

    /// 获取 scrcpy 版本
    /// 优先从 scrcpy 可执行文件获取，失败时使用默认版本
    private func getScrcpyVersion() async -> String {
        let scrcpyPath = await MainActor.run { toolchainManager.scrcpyPath }

        AppLogger.process.info("获取 scrcpy 版本，路径: \(scrcpyPath)")

        do {
            let runner = await MainActor.run { ProcessRunner() }
            let result = try await runner.run(scrcpyPath, arguments: ["--version"])

            AppLogger.process.debug("scrcpy --version 输出: \(result.stdout.prefix(100))")

            // 解析版本号，格式如: "scrcpy 3.3.4 <https://...>"
            // 必须匹配完整的三段式版本号 (x.y.z)
            if let match = result.stdout.firstMatch(of: /scrcpy\s+(\d+\.\d+\.\d+)/) {
                let version = String(match.1)
                AppLogger.process.info("✅ 获取到 scrcpy 版本: \(version)")
                return version
            }

            // 尝试匹配两段式版本号 (x.y)
            if let match = result.stdout.firstMatch(of: /scrcpy\s+(\d+\.\d+)/) {
                let version = String(match.1)
                AppLogger.process.info("✅ 获取到 scrcpy 版本 (两段式): \(version)")
                return version
            }

            AppLogger.process.warning("无法从输出中解析版本号: \(result.stdout.prefix(200))")
        } catch {
            AppLogger.process.error("获取 scrcpy 版本失败: \(error.localizedDescription)")
        }

        // 默认返回与内置 scrcpy-server 匹配的版本号
        // 内置的 scrcpy-server 版本是 3.3.4
        let defaultVersion = "3.3.4"
        AppLogger.process.warning("⚠️ 使用默认版本号: \(defaultVersion)")
        return defaultVersion
    }

    /// 启动进程监控
    private func startProcessMonitoring() {
        monitorTask = Task { [weak self] in
            guard let self, let serverProcess else { return }

            // 等待进程退出
            await withCheckedContinuation { continuation in
                serverProcess.terminationHandler = { _ in
                    continuation.resume()
                }
            }

            let exitCode = serverProcess.terminationStatus

            await MainActor.run { [weak self] in
                guard let self else { return }

                // 退出码 0 表示正常退出，15 (SIGTERM) 表示被主动终止（也是正常情况）
                let isNormalExit = exitCode == 0 || exitCode == 15 // SIGTERM

                if !isNormalExit, state != .disconnected {
                    AppLogger.connection.error("scrcpy-server 进程异常退出，退出码: \(exitCode)")
                    updateState(.error(.processTerminated(exitCode)))
                } else {
                    AppLogger.connection.info("scrcpy-server 进程正常退出")
                    if state == .capturing {
                        updateState(.connected)
                    }
                }
            }
        }
    }

    // MARK: - 帧缓冲统计

    /// 启动帧管道统计任务（生产环境已禁用日志输出）
    private func startPipelineStats() {
        // 保留任务结构以便后续调试使用，但不再输出日志
        pipelineStatsTask = nil
    }

    /// 停止帧管道统计任务
    private func stopPipelineStats() {
        pipelineStatsTask?.cancel()
        pipelineStatsTask = nil
    }
}
