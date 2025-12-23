//
//  IOSDeviceProvider.swift
//  ScreenPresenter
//
//  Created by Sun on 2025/12/24.
//
//  iOS 设备提供者
//  使用 AVFoundation 发现和管理 USB 连接的 iOS 设备
//
//  设备事件监听策略：
//  - 主要：AVFoundation 通知（连接/断开）— 稳定的公开 API
//  - 增强：定期刷新 DeviceInsight（状态变化检测）— 轻量级补充
//  - 不使用 MobileDevice 原生事件，避免私有 API 不稳定性
//

import AVFoundation
import Combine
import Foundation

// MARK: - iOS 设备提供者

@MainActor
final class IOSDeviceProvider: NSObject, ObservableObject {
    // MARK: - 状态

    /// 已发现的 iOS 设备列表
    @Published private(set) var devices: [IOSDevice] = []

    /// 是否正在监控
    @Published private(set) var isMonitoring = false

    /// 最后一次错误
    @Published private(set) var lastError: String?

    // MARK: - 配置

    /// 状态刷新间隔（秒）— 用于检测信任/占用状态变化
    private let insightRefreshInterval: TimeInterval = 5.0

    // MARK: - 私有属性

    private var discoverySession: AVCaptureDevice.DiscoverySession?
    private var deviceObservation: NSKeyValueObservation?
    private var insightRefreshTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - 初始化

    override init() {
        super.init()
        setupNotifications()
    }

    deinit {
        deviceObservation?.invalidate()
        insightRefreshTask?.cancel()
    }

    // MARK: - 公开方法

    /// 开始监控设备
    func startMonitoring() {
        guard !isMonitoring else { return }

        isMonitoring = true
        lastError = nil
        setupDiscoverySession()
        startInsightRefresh()
    }

    /// 设置设备发现会话
    private func setupDiscoverySession() {
        // 检查相机权限
        let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
        AppLogger.device.info("相机权限状态: \(authStatus.rawValue) (0=未确定, 1=受限, 2=拒绝, 3=已授权)")

        if authStatus == .notDetermined {
            // 请求权限
            AppLogger.device.info("请求相机权限...")
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                AppLogger.device.info("相机权限请求结果: \(granted ? "已授权" : "已拒绝")")
                if granted {
                    Task { @MainActor in
                        self?.refreshDevices()
                    }
                }
            }
        } else if authStatus == .denied || authStatus == .restricted {
            AppLogger.device.error("相机权限被拒绝，无法发现 iOS 设备。请在系统偏好设置中授权。")
            lastError = "相机权限被拒绝"
        }

        // 创建发现会话，监听外部 muxed 设备（USB 屏幕镜像）
        // 注意：USB 屏幕镜像设备使用 .muxed 媒体类型，而不是 .video
        discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .muxed,
            position: .unspecified
        )

        AppLogger.device.info("已创建 DiscoverySession，当前设备数: \(discoverySession?.devices.count ?? 0)")

        // 监听设备列表变化
        deviceObservation = discoverySession?.observe(\.devices, options: [.new, .initial]) { [weak self] session, _ in
            AppLogger.device.debug("KVO: 设备列表变化，当前设备数: \(session.devices.count)")
            Task { @MainActor in
                self?.refreshDevices()
            }
        }

        // 诊断：列出所有视频捕获设备
        logAllCaptureDevices()

        // 立即刷新一次
        refreshDevices()

        AppLogger.device.info("iOS 设备监控已启动")
    }

    /// 诊断：列出所有视频捕获设备（用于调试）
    private func logAllCaptureDevices() {
        AppLogger.device.info("=== 诊断：捕获设备检测 ===")

        // 1. 检查 video 媒体类型的外部设备
        let videoExternalDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified
        ).devices
        AppLogger.device.info("外部视频设备数: \(videoExternalDevices.count)")

        // 2. 检查 muxed 媒体类型的外部设备（USB 屏幕镜像特征）
        let muxedExternalDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .muxed,
            position: .unspecified
        ).devices
        AppLogger.device.info("外部 muxed 设备数: \(muxedExternalDevices.count)")

        // 3. 列出所有视频设备（不限类型）
        let allVideoDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video,
            position: .unspecified
        ).devices

        if allVideoDevices.isEmpty {
            AppLogger.device.info("未发现任何视频捕获设备")
        } else {
            AppLogger.device.info("所有视频设备列表:")
            for device in allVideoDevices {
                let suspended = device.isSuspended ? " [SUSPENDED]" : ""
                let muxed = device.hasMediaType(.muxed) ? " [MUXED]" : ""
                AppLogger.device.info("""
                    - \(device.localizedName)\(suspended)\(muxed)
                      类型: \(device.deviceType.rawValue)
                      型号: \(device.modelID)
                """)
            }
        }

        // 4. 检查 muxed 外部设备中的 iOS 设备
        let iosDevices = muxedExternalDevices.filter {
            $0.modelID.hasPrefix("iPhone") ||
                $0.modelID.hasPrefix("iPad") ||
                $0.modelID == "iOS Device"
        }
        if !iosDevices.isEmpty {
            AppLogger.device.info("发现的 iOS muxed 设备:")
            for device in iosDevices {
                let suspended = device.isSuspended ? " [SUSPENDED]" : ""
                AppLogger.device.info("""
                    - \(device.localizedName)\(suspended) [MUXED]
                      类型: \(device.deviceType.rawValue)
                      型号: \(device.modelID)
                """)
            }
        }

        AppLogger.device.info("=== 诊断结束 ===")
    }

    /// 停止监控
    func stopMonitoring() {
        isMonitoring = false
        deviceObservation?.invalidate()
        deviceObservation = nil
        discoverySession = nil
        insightRefreshTask?.cancel()
        insightRefreshTask = nil

        AppLogger.device.info("iOS 设备监控已停止")
    }

    /// 手动刷新设备列表
    func refreshDevices() {
        guard let session = discoverySession else {
            // 如果没有会话，创建临时查询（使用 muxed 媒体类型）
            let tempSession = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.external],
                mediaType: .muxed,
                position: .unspecified
            )
            updateDeviceList(from: tempSession.devices)
            return
        }

        updateDeviceList(from: session.devices)
    }

    /// 获取特定设备
    func device(for id: String) -> IOSDevice? {
        devices.first { $0.id == id }
    }

    /// 获取 AVCaptureDevice
    func captureDevice(for deviceID: String) -> AVCaptureDevice? {
        AVCaptureDevice(uniqueID: deviceID)
    }

    // MARK: - 私有方法

    private func updateDeviceList(from captureDevices: [AVCaptureDevice]) {
        // 记录原始捕获设备数量（用于调试）
        AppLogger.device.debug("发现 \(captureDevices.count) 个外部视频捕获设备")

        let iosDevices = captureDevices.compactMap { device -> IOSDevice? in
            IOSDevice.from(captureDevice: device)
        }

        // 只在设备列表真正变化时更新
        if iosDevices.map(\.id) != devices.map(\.id) {
            devices = iosDevices

            if iosDevices.isEmpty {
                if captureDevices.isEmpty {
                    AppLogger.device.info("未发现任何外部视频设备")
                } else {
                    AppLogger.device.info("发现 \(captureDevices.count) 个外部设备，但没有可用的 iOS 屏幕镜像设备")
                }
            } else {
                for device in iosDevices {
                    // 使用增强的设备信息显示
                    let displayInfo = buildDeviceDisplayInfo(device)
                    AppLogger.device.info("iOS 设备已更新: \(displayInfo)")
                }
            }
        }
    }

    /// 构建设备显示信息（用于日志和诊断）
    private func buildDeviceDisplayInfo(_ device: IOSDevice) -> String {
        var info = device.displayName

        if let modelName = device.displayModelName {
            info += " (\(modelName))"
        }

        if let version = device.systemVersion, version != L10n.deviceInfo.unknown {
            info += " iOS \(version)"
        }

        if let prompt = device.userPrompt {
            info += " ⚠️ \(prompt)"
        }

        return info
    }

    /// 获取设备的用户提示信息（用于 UI 显示）
    func getUserPrompt(for deviceID: String) -> String? {
        devices.first { $0.id == deviceID }?.userPrompt
    }

    // MARK: - Insight 状态刷新（轻量级增强）

    /// 启动定期状态刷新
    /// 用于检测设备状态变化（信任、占用等），补充 AVFoundation 的连接/断开事件
    private func startInsightRefresh() {
        insightRefreshTask?.cancel()
        insightRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self?.insightRefreshInterval ?? 5.0) * 1_000_000_000)

                guard !Task.isCancelled, let self else { break }

                // 只在有设备时刷新 insight
                if !devices.isEmpty {
                    await refreshDeviceInsights()
                }
            }
        }

        AppLogger.device.debug("设备状态刷新已启动，间隔: \(insightRefreshInterval)s")
    }

    /// 刷新所有设备的 insight 信息
    /// 检测状态变化（信任、占用等）并更新 UI
    private func refreshDeviceInsights() async {
        guard let session = discoverySession else { return }

        var hasChanges = false

        for captureDevice in session.devices {
            guard let existingDevice = devices.first(where: { $0.id == captureDevice.uniqueID }) else {
                continue
            }

            // 重新获取 insight
            let insightService = DeviceInsightService.shared
            let newInsight = insightService.getDeviceInsight(for: captureDevice.uniqueID)
            let newPrompt = insightService.getUserPrompt(for: newInsight)

            // 检测状态变化
            let oldPrompt = existingDevice.userPrompt
            if newPrompt != oldPrompt {
                hasChanges = true

                if let prompt = newPrompt {
                    AppLogger.device.warning("设备状态变化: \(existingDevice.displayName) - \(prompt)")
                } else if oldPrompt != nil {
                    AppLogger.device.info("设备状态恢复正常: \(existingDevice.displayName)")
                }
            }
        }

        // 如果有变化，完整刷新设备列表（会触发 UI 更新）
        if hasChanges {
            refreshDevices()
        }
    }

    private func setupNotifications() {
        // 监听设备连接/断开通知
        NotificationCenter.default.publisher(for: .AVCaptureDeviceWasConnected)
            .sink { [weak self] notification in
                Task { @MainActor in
                    if let device = notification.object as? AVCaptureDevice {
                        AppLogger.device.info("设备已连接: \(device.localizedName)")
                    }
                    self?.refreshDevices()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .AVCaptureDeviceWasDisconnected)
            .sink { [weak self] notification in
                Task { @MainActor in
                    if let device = notification.object as? AVCaptureDevice {
                        AppLogger.device.info("设备已断开: \(device.localizedName)")
                    }
                    self?.refreshDevices()
                }
            }
            .store(in: &cancellables)
    }
}
