//
//  IOSDeviceSource.swift
//  ScreenPresenter
//
//  Created by Sun on 2025/12/24.
//
//  iOS 设备源
//  使用 CoreMediaIO + AVFoundation 捕获 USB 连接的 iPhone/iPad 屏幕
//  这是 QuickTime 同款路径，稳定可靠
//

@preconcurrency import AVFoundation
import Combine
import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation

// MARK: - iOS 设备源

final class IOSDeviceSource: BaseDeviceSource, @unchecked Sendable {
    // MARK: - 属性

    /// 关联的 iOS 设备
    let iosDevice: IOSDevice

    /// 是否支持音频
    override var supportsAudio: Bool { true }

    /// 最新的 CVPixelBuffer（仅用于获取尺寸信息，不长期持有）
    override var latestPixelBuffer: CVPixelBuffer? { nil }

    // MARK: - 私有属性

    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private let captureQueue = DispatchQueue(label: "com.screenPresenter.ios.capture", qos: .userInteractive)

    /// 视频输出代理
    private var videoDelegate: VideoCaptureDelegate?

    /// 是否正在捕获
    private var isCapturingFlag: Bool = false

    /// 帧回调
    var onFrame: ((CVPixelBuffer) -> Void)?

    /// 会话中断回调（设备锁屏等）
    var onSessionInterrupted: ((String) -> Void)?

    /// 会话恢复回调
    var onSessionResumed: (() -> Void)?

    // MARK: - 初始化

    init(device: IOSDevice) {
        iosDevice = device

        let deviceInfo = GenericDeviceInfo(
            id: device.id,
            name: device.name,
            model: device.modelID,
            platform: .ios
        )

        super.init(
            displayName: device.name,
            sourceType: .quicktime
        )

        self.deviceInfo = deviceInfo

        AppLogger.device.info("创建 iOS 设备源: \(device.name)")
    }

    // MARK: - DeviceSource 实现

    override func connect() async throws {
        guard state == .idle || state == .disconnected else {
            AppLogger.connection.warning("iOS 设备已连接或正在连接中")
            return
        }

        updateState(.connecting)
        AppLogger.connection.info("开始连接 iOS 设备: \(iosDevice.name)")

        do {
            // 1. 确保 CoreMediaIO 已启用屏幕捕获设备
            enableCoreMediaIOScreenCapture()

            // 2. 创建捕获会话
            try await setupCaptureSession()

            updateState(.connected)
            AppLogger.connection.info("iOS 设备已连接: \(iosDevice.name)")
        } catch {
            let deviceError = DeviceSourceError.connectionFailed(error.localizedDescription)
            updateState(.error(deviceError))
            throw deviceError
        }
    }

    override func disconnect() async {
        AppLogger.connection.info("断开 iOS 设备: \(iosDevice.name)")

        await stopCapture()

        // 移除通知监听
        NotificationCenter.default.removeObserver(self)

        captureSession?.stopRunning()
        captureSession = nil
        videoOutput = nil
        videoDelegate = nil
        onFrame = nil
        onSessionInterrupted = nil
        onSessionResumed = nil

        hasReceivedFirstFrame = false

        updateState(.disconnected)
    }

    override func startCapture() async throws {
        guard state == .connected || state == .paused else {
            throw DeviceSourceError.captureStartFailed(L10n.capture.deviceNotConnected)
        }

        guard let session = captureSession else {
            throw DeviceSourceError.captureStartFailed(L10n.capture.sessionNotInitialized)
        }

        AppLogger.capture.info("开始捕获 iOS 设备: \(iosDevice.name)")

        // 在后台线程启动会话
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }

                if !session.isRunning {
                    session.startRunning()
                }

                DispatchQueue.main.async {
                    self.isCapturingFlag = true
                    self.updateState(.capturing)
                    continuation.resume()
                }
            }
        }

        AppLogger.capture.info("iOS 捕获已启动: \(iosDevice.name)")
    }

    override func stopCapture() async {
        guard isCapturingFlag else { return }

        isCapturingFlag = false

        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                self?.captureSession?.stopRunning()

                DispatchQueue.main.async {
                    if self?.state == .capturing {
                        self?.updateState(.connected)
                    }
                    continuation.resume()
                }
            }
        }

        AppLogger.capture.info("iOS 捕获已停止: \(iosDevice.name)")
    }

    // MARK: - CoreMediaIO 设置

    /// 启用 CoreMediaIO 屏幕捕获设备（关键步骤）
    private func enableCoreMediaIOScreenCapture() {
        var prop = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )

        var allow: UInt32 = 1
        let result = CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &prop,
            0, nil,
            UInt32(MemoryLayout<UInt32>.size),
            &allow
        )

        if result == kCMIOHardwareNoError {
            AppLogger.device.info("已启用 CoreMediaIO 屏幕捕获设备")
        } else {
            AppLogger.device.warning("启用 CoreMediaIO 屏幕捕获设备失败: \(result)")
        }
    }

    // MARK: - 捕获会话设置

    private func setupCaptureSession() async throws {
        AppLogger.capture.info("开始配置捕获会话，设备ID: \(iosDevice.id), avUniqueID: \(iosDevice.avUniqueID)")

        // 获取 AVCaptureDevice（使用 avUniqueID）
        guard let captureDevice = iosDevice.getAVCaptureDevice() else {
            AppLogger.capture.error("无法获取捕获设备: \(iosDevice.avUniqueID)")
            throw DeviceSourceError.connectionFailed(L10n.capture.cannotGetDevice(iosDevice.id))
        }

        AppLogger.capture.info("找到捕获设备: \(captureDevice.localizedName), 模型: \(captureDevice.modelID)")

        // 检测设备是否被其他应用占用（如 QuickTime）
        if captureDevice.isInUseByAnotherApplication {
            AppLogger.capture.warning("设备被其他应用占用: \(captureDevice.localizedName)")
            throw DeviceSourceError.deviceInUse("QuickTime")
        }

        let session = AVCaptureSession()
        session.sessionPreset = .high

        // 添加视频输入
        do {
            let videoInput = try AVCaptureDeviceInput(device: captureDevice)
            guard session.canAddInput(videoInput) else {
                AppLogger.capture.error("无法添加视频输入到会话")
                throw DeviceSourceError.connectionFailed(L10n.capture.cannotAddInput)
            }
            session.addInput(videoInput)
            AppLogger.capture.info("视频输入已添加")
        } catch {
            AppLogger.capture.error("创建视频输入失败: \(error.localizedDescription)")

            // 检测常见错误并提供更有用的提示
            let errorMessage = error.localizedDescription
            if errorMessage.contains("无法使用") || errorMessage.contains("Cannot use") {
                // "无法使用 XXX" 通常是因为 iPhone 未解锁或未信任
                throw DeviceSourceError.connectionFailed(L10n.capture.deviceNotReady(iosDevice.name))
            } else {
                throw DeviceSourceError.connectionFailed(L10n.capture.inputFailed(errorMessage))
            }
        }

        // 添加视频输出
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true

        // 创建视频代理
        let delegate = VideoCaptureDelegate { [weak self] sampleBuffer in
            self?.handleVideoSampleBuffer(sampleBuffer)
        }
        videoOutput.setSampleBufferDelegate(delegate, queue: captureQueue)

        guard session.canAddOutput(videoOutput) else {
            throw DeviceSourceError.connectionFailed(L10n.capture.cannotAddOutput)
        }
        session.addOutput(videoOutput)

        captureSession = session
        self.videoOutput = videoOutput
        videoDelegate = delegate

        // 监听会话中断和恢复通知
        setupSessionNotifications(for: session)

        AppLogger.capture.info("iOS 捕获会话已配置: \(iosDevice.name)")
    }

    // MARK: - 会话通知

    private func setupSessionNotifications(for session: AVCaptureSession) {
        // 会话开始运行
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionDidStartRunning),
            name: .AVCaptureSessionDidStartRunning,
            object: session
        )

        // 会话停止运行
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionDidStopRunning),
            name: .AVCaptureSessionDidStopRunning,
            object: session
        )

        // 会话运行时错误
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionRuntimeError),
            name: .AVCaptureSessionRuntimeError,
            object: session
        )
    }

    @objc private func sessionDidStartRunning(_: Notification) {
        AppLogger.capture.info("🎬 捕获会话开始运行")
        DispatchQueue.main.async { [weak self] in
            self?.onSessionResumed?()
        }
    }

    @objc private func sessionDidStopRunning(_: Notification) {
        // 如果不是主动停止，则是中断
        guard isCapturingFlag else { return }

        AppLogger.capture.warning("⚠️ 捕获会话意外停止")
        DispatchQueue.main.async { [weak self] in
            self?.onSessionInterrupted?(L10n.ios.hint.sessionStopped)
        }
    }

    @objc private func sessionRuntimeError(_ notification: Notification) {
        guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError else {
            AppLogger.capture.error("会话运行时错误（未知）")
            return
        }

        AppLogger.capture.error("会话运行时错误: \(error.localizedDescription)")

        // 通知 UI 显示错误
        DispatchQueue.main.async { [weak self] in
            self?.onSessionInterrupted?(error.localizedDescription)
        }

        // 尝试恢复会话
        captureQueue.async { [weak self] in
            guard let self, isCapturingFlag else { return }
            if let session = captureSession, !session.isRunning {
                session.startRunning()
            }
        }
    }

    // MARK: - 帧处理

    /// 是否已获取视频尺寸
    private var hasReceivedFirstFrame = false

    private func handleVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isCapturingFlag else { return }

        // 获取 CVPixelBuffer
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // 从第一帧获取视频尺寸
        if !hasReceivedFirstFrame {
            hasReceivedFirstFrame = true
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let size = CGSize(width: CGFloat(width), height: CGFloat(height))
            updateCaptureSize(size)
            AppLogger.capture.info("iOS 捕获分辨率: \(width)x\(height)")
        }

        // 创建 CapturedFrame 并发送
        let frame = CapturedFrame(sourceID: id, sampleBuffer: sampleBuffer)
        emitFrame(frame)

        // 直接回调通知渲染视图（不持有 pixelBuffer）
        onFrame?(pixelBuffer)
    }
}

// MARK: - 视频捕获代理

private final class VideoCaptureDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let handler: (CMSampleBuffer) -> Void

    init(handler: @escaping (CMSampleBuffer) -> Void) {
        self.handler = handler
        super.init()
    }

    func captureOutput(
        _: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from _: AVCaptureConnection
    ) {
        handler(sampleBuffer)
    }
}
