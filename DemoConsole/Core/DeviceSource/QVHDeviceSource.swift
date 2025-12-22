//
//  QVHDeviceSource.swift
//  DemoConsole
//
//  Created by Sun on 2025/12/22.
//
//  QVH 设备源
//  使用 quicktime_video_hack (qvh) 工具捕获 iOS 设备屏幕
//  通过启动 qvh gstreamer 进程并捕获其窗口来获取视频流
//

import AppKit
import Combine
import CoreMedia
import Foundation
import ScreenCaptureKit

// MARK: - QVH 设备信息

/// QVH 发现的 iOS 设备
struct QVHDevice: Identifiable, Equatable, Hashable, Codable {
    let deviceName: String
    let udid: String
    let usbDeviceInfo: String
    let screenMirroringEnabled: Bool

    var id: String { udid }

    var displayName: String {
        deviceName.isEmpty ? "iPhone" : deviceName
    }

    enum CodingKeys: String, CodingKey {
        case deviceName
        case udid
        case usbDeviceInfo = "usb_device_info"
        case screenMirroringEnabled = "screen_mirroring_enabled"
    }
}

// MARK: - QVH 设备列表响应

struct QVHDevicesResponse: Codable {
    let devices: [QVHDevice]
}

// MARK: - QVH 设备源

/// 使用 qvh 工具的 iOS 设备源
@MainActor
final class QVHDeviceSource: BaseDeviceSource {
    // MARK: - 属性

    /// 关联的 QVH 设备
    let qvhDevice: QVHDevice

    /// qvh 可执行文件路径
    private let qvhPath: String

    /// qvh 进程
    private var qvhProcess: Process?

    /// 窗口 ID（用于 ScreenCaptureKit 捕获）
    private var windowID: CGWindowID?

    /// ScreenCaptureKit 捕获流
    private var captureStream: SCStream?

    /// 进程监控任务
    private var processMonitorTask: Task<Void, Never>?

    /// 窗口标题（用于查找 qvh 窗口）
    private let windowTitle: String

    // MARK: - 初始化

    init(device: QVHDevice, qvhPath: String? = nil) {
        qvhDevice = device

        // 查找 qvh 路径
        if let path = qvhPath {
            self.qvhPath = path
        } else if
            let bundledPath = Bundle.main.path(forResource: "qvh", ofType: nil, inDirectory: "tools")
            ?? Bundle.main.path(forResource: "qvh", ofType: nil) {
            self.qvhPath = bundledPath
        } else {
            self.qvhPath = "/usr/local/bin/qvh"
        }

        // 窗口标题
        windowTitle = "qvh - \(device.displayName)"

        let deviceInfo = GenericDeviceInfo(
            id: device.udid,
            name: device.displayName,
            model: nil,
            platform: .ios
        )

        super.init(
            displayName: device.displayName,
            sourceType: .quicktime
        )

        self.deviceInfo = deviceInfo

        AppLogger.device.info("创建 QVH 设备源: \(device.displayName), udid: \(device.udid)")
    }

    deinit {
        processMonitorTask?.cancel()
    }

    // MARK: - DeviceSource 实现

    override func connect() async throws {
        guard state == .idle || state == .disconnected else {
            AppLogger.connection.warning("QVH 设备已连接或正在连接中")
            return
        }

        updateState(.connecting)
        AppLogger.connection.info("开始连接 iOS 设备 (QVH): \(qvhDevice.displayName)")

        // 检查 qvh 是否存在
        guard FileManager.default.fileExists(atPath: qvhPath) else {
            let error = DeviceSourceError.connectionFailed("qvh 工具未找到: \(qvhPath)")
            updateState(.error(error))
            throw error
        }

        // 确保可执行权限
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: qvhPath
        )

        do {
            // 启动 qvh gstreamer 进程
            try await startQVHProcess()

            // 等待窗口出现
            windowID = try await waitForWindow(timeout: 15.0)

            updateState(.connected)
            AppLogger.connection.info("QVH 设备连接成功: \(qvhDevice.displayName)")

            // 启动进程监控
            startProcessMonitoring()

        } catch {
            let deviceError = DeviceSourceError.connectionFailed(error.localizedDescription)
            updateState(.error(deviceError))
            AppLogger.connection.error("QVH 设备连接失败: \(error.localizedDescription)")
            throw deviceError
        }
    }

    override func disconnect() async {
        AppLogger.connection.info("断开 QVH 连接: \(qvhDevice.displayName)")

        processMonitorTask?.cancel()
        processMonitorTask = nil

        await stopCapture()

        // 终止 qvh 进程
        if let process = qvhProcess, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        qvhProcess = nil
        windowID = nil

        updateState(.disconnected)
    }

    override func startCapture() async throws {
        guard state == .connected || state == .paused else {
            throw DeviceSourceError.captureStartFailed("设备未连接")
        }

        guard let windowID else {
            throw DeviceSourceError.windowNotFound
        }

        AppLogger.capture.info("开始捕获 QVH 窗口: \(windowID)")

        do {
            // 获取窗口信息
            guard let window = try await findSCWindow(windowID: windowID) else {
                throw DeviceSourceError.windowNotFound
            }

            // 创建捕获配置
            let filter = SCContentFilter(desktopIndependentWindow: window)

            let streamConfig = SCStreamConfiguration()
            streamConfig.width = Int(window.frame.width) * 2 // Retina
            streamConfig.height = Int(window.frame.height) * 2
            streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
            streamConfig.showsCursor = false
            streamConfig.capturesAudio = false

            // 创建并启动捕获流
            let stream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)

            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
            try await stream.startCapture()

            captureStream = stream

            // 更新捕获尺寸
            let width = CGFloat(streamConfig.width)
            let height = CGFloat(streamConfig.height)
            updateCaptureSize(CGSize(width: width, height: height))

            updateState(.capturing)
            AppLogger.capture.info("QVH 捕获已启动: \(qvhDevice.displayName)")

        } catch {
            let captureError = DeviceSourceError.captureStartFailed(error.localizedDescription)
            updateState(.error(captureError))
            throw captureError
        }
    }

    override func stopCapture() async {
        guard let stream = captureStream else { return }

        do {
            try await stream.stopCapture()
        } catch {
            AppLogger.capture.error("停止 QVH 捕获失败: \(error.localizedDescription)")
        }

        captureStream = nil

        if state == .capturing {
            updateState(.connected)
        }

        AppLogger.capture.info("QVH 捕获已停止: \(qvhDevice.displayName)")
    }

    // MARK: - 私有方法

    /// 启动 qvh 进程
    private func startQVHProcess() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: qvhPath)
        process.arguments = ["gstreamer", "--udid=\(qvhDevice.udid)"]

        // 设置环境变量
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(environment["PATH"] ?? "")"

        // GStreamer 需要的环境变量
        if let gstPluginPath = environment["GST_PLUGIN_PATH"] {
            environment["GST_PLUGIN_PATH"] = gstPluginPath
        } else {
            environment["GST_PLUGIN_PATH"] = "/opt/homebrew/lib/gstreamer-1.0"
        }
        environment["GST_PLUGIN_SCANNER"] = "/opt/homebrew/libexec/gstreamer-1.0/gst-plugin-scanner"

        process.environment = environment

        // 配置输出管道
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        AppLogger.process.info("启动 qvh: \(qvhPath) gstreamer --udid=\(qvhDevice.udid)")

        try process.run()
        qvhProcess = process

        // 异步读取输出（用于调试）
        Task.detached {
            for try await line in outputPipe.fileHandleForReading.bytes.lines {
                AppLogger.process.debug("[qvh stdout] \(line)")
            }
        }

        Task.detached {
            for try await line in errorPipe.fileHandleForReading.bytes.lines {
                // 过滤掉 GStreamer 的常见警告
                if
                    !line.contains("GLib-GIRepository-WARNING"),
                    !line.contains("gst-plugin-scanner"),
                    !line.contains("CRITICAL"),
                    !line.contains("objc[") {
                    AppLogger.process.debug("[qvh stderr] \(line)")
                }
            }
        }

        // 等待进程启动
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5秒

        // 检查进程是否还在运行
        guard process.isRunning else {
            throw DeviceSourceError.connectionFailed("qvh 进程启动失败")
        }
    }

    /// 等待 qvh 窗口出现
    private func waitForWindow(timeout: TimeInterval) async throws -> CGWindowID {
        let startTime = CFAbsoluteTimeGetCurrent()

        AppLogger.capture.info("等待 qvh 窗口出现...")

        while CFAbsoluteTimeGetCurrent() - startTime < timeout {
            // 获取所有窗口
            guard
                let windowList = CGWindowListCopyWindowInfo(
                    [.optionOnScreenOnly, .excludeDesktopElements],
                    kCGNullWindowID
                ) as? [[String: Any]] else {
                try await Task.sleep(nanoseconds: 200_000_000) // 0.2秒
                continue
            }

            // 查找 qvh 窗口
            for windowInfo in windowList {
                guard
                    let name = windowInfo[kCGWindowName as String] as? String,
                    let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID,
                    let ownerName = windowInfo[kCGWindowOwnerName as String] as? String
                else {
                    continue
                }

                // qvh 使用 GStreamer 创建的窗口，可能包含 "qvh" 或设备名称
                // 或者是 "gst-launch" 相关的窗口
                let isQVHWindow = name.lowercased().contains("qvh") ||
                    name.contains(qvhDevice.displayName) ||
                    ownerName.lowercased().contains("qvh") ||
                    ownerName.lowercased().contains("gst") ||
                    ownerName.lowercased().contains("gstreamer")

                if isQVHWindow {
                    AppLogger.capture.info("找到 qvh 窗口: \(name) (ID: \(windowID), Owner: \(ownerName))")
                    return windowID
                }
            }

            try await Task.sleep(nanoseconds: 200_000_000) // 0.2秒
        }

        throw DeviceSourceError.timeout
    }

    /// 查找 SCWindow
    private func findSCWindow(windowID: CGWindowID) async throws -> SCWindow? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.windows.first { $0.windowID == windowID }
    }

    /// 启动进程监控
    private func startProcessMonitoring() {
        processMonitorTask = Task { [weak self] in
            guard let self, let process = qvhProcess else { return }

            // 等待进程退出
            await withCheckedContinuation { continuation in
                process.terminationHandler = { _ in
                    continuation.resume()
                }
            }

            let exitCode = process.terminationStatus

            await MainActor.run { [weak self] in
                guard let self else { return }

                if exitCode != 0, state != .disconnected {
                    AppLogger.connection.error("qvh 进程异常退出，退出码: \(exitCode)")
                    updateState(.error(.processTerminated(exitCode)))
                } else {
                    AppLogger.connection.info("qvh 进程正常退出")
                    updateState(.disconnected)
                }
            }
        }
    }
}

// MARK: - SCStreamOutput

extension QVHDeviceSource: SCStreamOutput {
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen else { return }

        Task { @MainActor [weak self] in
            guard let self, state == .capturing else { return }

            // 创建 CapturedFrame
            let frame = CapturedFrame(sourceID: id, sampleBuffer: sampleBuffer)
            emitFrame(frame)
        }
    }
}

// MARK: - QVH 设备管理器

/// QVH 设备管理器 - 负责发现和管理 iOS 设备
@MainActor
final class QVHDeviceManager: ObservableObject {
    // MARK: - 单例

    static let shared = QVHDeviceManager()

    // MARK: - 状态

    @Published private(set) var devices: [QVHDevice] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastError: String?

    // MARK: - 私有属性

    private let processRunner = ProcessRunner()
    private var monitoringTask: Task<Void, Never>?

    /// qvh 路径
    var qvhPath: String {
        // 先尝试 tools 子目录，再尝试 Resources 根目录
        if
            let bundledPath = Bundle.main.path(forResource: "qvh", ofType: nil, inDirectory: "tools")
            ?? Bundle.main.path(forResource: "qvh", ofType: nil) {
            return bundledPath
        }
        return "/usr/local/bin/qvh"
    }

    /// 是否已安装 qvh
    var isQVHInstalled: Bool {
        FileManager.default.fileExists(atPath: qvhPath)
    }

    // MARK: - 初始化

    private init() {}

    // MARK: - 公开方法

    /// 开始监控设备
    func startMonitoring() {
        guard monitoringTask == nil else { return }

        monitoringTask = Task {
            while !Task.isCancelled {
                await refreshDevices()
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2秒
            }
        }

        AppLogger.device.info("QVH 设备监控已启动")
    }

    /// 停止监控
    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
        AppLogger.device.info("QVH 设备监控已停止")
    }

    /// 刷新设备列表
    func refreshDevices() async {
        guard isQVHInstalled else {
            lastError = "qvh 工具未安装"
            return
        }

        isScanning = true
        defer { isScanning = false }

        do {
            let result = try await processRunner.run(qvhPath, arguments: ["devices"], timeout: 10)

            if result.isSuccess {
                // qvh 可能会在 JSON 前输出 GStreamer 警告，需要提取有效的 JSON 部分
                let output = result.stdout

                // 查找 JSON 开始位置（以 { 开头）
                guard let jsonStartIndex = output.firstIndex(of: "{") else {
                    lastError = "qvh 输出中未找到 JSON 数据"
                    AppLogger.device.error("QVH 输出无效: \(output)")
                    return
                }

                // 提取从 { 开始到结尾的 JSON 字符串
                let jsonString = String(output[jsonStartIndex...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                guard let jsonData = jsonString.data(using: .utf8) else {
                    lastError = "无法编码 JSON 数据"
                    return
                }

                let response = try JSONDecoder().decode(QVHDevicesResponse.self, from: jsonData)

                // 更新设备列表
                if response.devices != devices {
                    devices = response.devices
                    AppLogger.device.info("QVH 发现 \(devices.count) 台 iOS 设备")
                    for device in devices {
                        AppLogger.device.info("  - \(device.displayName) (\(device.udid))")
                    }
                }

                lastError = nil
            } else {
                lastError = "qvh 命令执行失败: \(result.stderr)"
            }
        } catch {
            // 尝试解析错误信息
            if let decodingError = error as? DecodingError {
                lastError = "解析设备列表失败: \(decodingError.localizedDescription)"
            } else {
                lastError = error.localizedDescription
            }
            AppLogger.device.error("QVH 刷新设备失败: \(lastError ?? "未知错误")")
        }
    }

    /// 获取特定设备
    func device(for udid: String) -> QVHDevice? {
        devices.first { $0.udid == udid }
    }

    /// 激活设备的屏幕镜像
    func activateDevice(_ device: QVHDevice) async throws {
        guard isQVHInstalled else {
            throw DeviceSourceError.connectionFailed("qvh 工具未安装")
        }

        let result = try await processRunner.run(
            qvhPath,
            arguments: ["activate", "--udid=\(device.udid)"],
            timeout: 30
        )

        if !result.isSuccess {
            throw DeviceSourceError.connectionFailed("激活设备失败: \(result.stderr)")
        }

        // 刷新设备列表
        await refreshDevices()
    }

    /// 停用设备的屏幕镜像
    func deactivateDevice(_ device: QVHDevice) async throws {
        guard isQVHInstalled else {
            throw DeviceSourceError.connectionFailed("qvh 工具未安装")
        }

        let result = try await processRunner.run(
            qvhPath,
            arguments: ["deactivate", "--udid=\(device.udid)"],
            timeout: 30
        )

        if !result.isSuccess {
            throw DeviceSourceError.connectionFailed("停用设备失败: \(result.stderr)")
        }

        // 刷新设备列表
        await refreshDevices()
    }
}
