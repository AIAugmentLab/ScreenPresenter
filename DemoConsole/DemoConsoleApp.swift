//
//  DemoConsoleApp.swift
//  DemoConsole
//
//  Created by Sun on 2025/12/22.
//
//  应用程序入口
//  配置主窗口和应用状态
//

import SwiftUI

@main
struct DemoConsoleApp: App {
    @StateObject private var appState = AppState()
    @ObservedObject private var preferences = UserPreferences.shared

    var body: some Scene {
        WindowGroup("DemoConsole") {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 800, minHeight: 600)
                .preferredColorScheme(preferences.themeMode.colorScheme)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        // 偏好设置独立窗口
        Settings {
            SettingsView()
                .preferredColorScheme(preferences.themeMode.colorScheme)
        }
    }
}

// MARK: - 全局应用状态

@MainActor
final class AppState: ObservableObject {
    /// 工具链管理器
    @Published var toolchainManager = ToolchainManager()

    /// Android 设备提供者
    @Published private(set) var androidDeviceProvider: AndroidDeviceProvider!

    /// Android 连接器
    @Published private(set) var androidConnector: AndroidConnector!

    /// QVH 设备管理器（iOS 设备，使用 quicktime_video_hack）
    @Published private(set) var qvhDeviceManager = QVHDeviceManager.shared

    /// 权限检查器
    @Published var permissionChecker = PermissionChecker()

    /// 当前选中的设备 ID
    @Published var selectedDeviceID: String?

    /// 是否显示首次启动检查清单
    @Published var showPermissionChecklist = false

    /// 是否正在初始化
    @Published var isInitializing = true

    // MARK: - 设备源（捕获）

    /// iOS 设备源（使用 QVH）
    @Published private(set) var iosDeviceSource: QVHDeviceSource?

    /// Android 设备源
    @Published private(set) var androidDeviceSource: ScrcpyDeviceSource?

    /// iOS 最新捕获帧
    @Published private(set) var iosLatestFrame: CapturedFrame?

    /// Android 最新捕获帧
    @Published private(set) var androidLatestFrame: CapturedFrame?

    // MARK: - 设备连接状态

    /// Android 是否已连接（设备列表不为空，且设备源处于有效状态）
    var androidConnected: Bool {
        guard !androidDeviceProvider.devices.isEmpty else { return false }
        // 如果设备源存在，检查其状态
        if let source = androidDeviceSource {
            switch source.state {
            case .idle, .disconnected:
                return false
            default:
                return true
            }
        }
        // 设备列表有设备但源未创建，也视为连接中
        return true
    }

    /// Android 设备名称
    var androidDeviceName: String? {
        androidDeviceProvider.devices.first?.displayName
    }

    /// iOS 是否已连接（QVH 设备列表不为空，且设备源处于有效状态）
    var iosConnected: Bool {
        guard !qvhDeviceManager.devices.isEmpty else { return false }
        // 如果设备源存在，检查其状态
        if let source = iosDeviceSource {
            switch source.state {
            case .idle, .disconnected:
                return false
            default:
                return true
            }
        }
        // 设备列表有设备但源未创建，也视为连接中
        return true
    }

    /// iOS 设备名称
    var iosDeviceName: String? {
        qvhDeviceManager.devices.first?.displayName
    }

    /// iOS 捕获中
    var iosCapturing: Bool {
        iosDeviceSource?.state == .capturing
    }

    /// Android 捕获中
    var androidCapturing: Bool {
        androidDeviceSource?.state == .capturing
    }

    // MARK: - 私有属性

    private var deviceObservationTask: Task<Void, Never>?

    init() {
        // 使用共享的 toolchainManager 初始化 androidDeviceProvider
        androidDeviceProvider = AndroidDeviceProvider(toolchainManager: toolchainManager)
        // 使用共享的 toolchainManager 和 androidDeviceProvider 初始化 androidConnector
        androidConnector = AndroidConnector(
            deviceProvider: androidDeviceProvider,
            toolchainManager: toolchainManager
        )

        Task {
            await initialize()
        }
    }

    /// 初始化应用
    private func initialize() async {
        // 检查是否首次启动
        let hasCompletedSetup = UserDefaults.standard.bool(forKey: "hasCompletedSetup")

        // 初始化工具链
        await toolchainManager.setup()

        // 检查权限
        await permissionChecker.checkAll()

        // 只在首次启动时显示检查清单
        if !hasCompletedSetup {
            showPermissionChecklist = true
        }

        isInitializing = false

        // 开始监控设备
        androidDeviceProvider.startMonitoring()
        qvhDeviceManager.startMonitoring() // 使用 QVH 监控 iOS 设备

        // 启动设备观察
        startDeviceObservation()
    }

    /// 标记设置完成
    func markSetupComplete() {
        UserDefaults.standard.set(true, forKey: "hasCompletedSetup")
        showPermissionChecklist = false
    }

    /// 刷新设备列表
    func refreshDevices() {
        Task {
            await androidDeviceProvider.refreshDevices()
            await qvhDeviceManager.refreshDevices() // 使用 QVH 刷新 iOS 设备
        }
    }

    // MARK: - 设备观察

    /// 启动设备观察，自动处理连接/断开
    private func startDeviceObservation() {
        deviceObservationTask?.cancel()
        deviceObservationTask = Task { [weak self] in
            guard let self else { return }

            // 定期检查设备状态变化
            while !Task.isCancelled {
                await checkAndUpdateDeviceSources()
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
            }
        }
    }

    /// 检查并更新设备源
    private func checkAndUpdateDeviceSources() async {
        // 处理 iOS 设备
        await handleIOSDeviceChange()

        // 处理 Android 设备
        await handleAndroidDeviceChange()
    }

    /// 处理 iOS 设备变化（使用 QVH）
    private func handleIOSDeviceChange() async {
        let currentDevice = qvhDeviceManager.devices.first

        if let device = currentDevice {
            // 设备已连接
            if iosDeviceSource == nil || iosDeviceSource?.qvhDevice.udid != device.udid {
                // 创建新的设备源
                await disconnectIOSDevice()
                await connectIOSDevice(device)
            }
        } else {
            // 设备已断开
            if iosDeviceSource != nil {
                await disconnectIOSDevice()
            }
        }
    }

    /// 处理 Android 设备变化
    private func handleAndroidDeviceChange() async {
        let currentDevice = androidDeviceProvider.devices.first

        if let device = currentDevice {
            // 设备已连接
            if androidDeviceSource == nil || androidDeviceSource?.deviceInfo?.id != device.serial {
                // 创建新的设备源
                await disconnectAndroidDevice()
                await connectAndroidDevice(device)
            }
        } else {
            // 设备已断开
            if androidDeviceSource != nil {
                await disconnectAndroidDevice()
            }
        }
    }

    // MARK: - iOS 设备管理（使用 QVH）

    /// 准备 iOS 设备源（使用 QVH，不自动连接，由用户手动点击捕获时才启动）
    private func connectIOSDevice(_ device: QVHDevice) async {
        AppLogger.device.info("准备 iOS 设备 (QVH): \(device.displayName), UDID: \(device.udid)")

        // 检查 qvh 是否可用
        guard qvhDeviceManager.isQVHInstalled else {
            AppLogger.device.warning("qvh 未安装，无法捕获 iOS 设备")
            return
        }

        let source = QVHDeviceSource(device: device, qvhPath: qvhDeviceManager.qvhPath)
        iosDeviceSource = source

        // QVH 设备源的 connect() 会启动 qvh 进程，所以不在这里调用
        // 等待用户点击"开始捕获"按钮时再调用 startIOSCapture()
        AppLogger.device.info("iOS 设备已准备就绪 (QVH): \(device.displayName)")

        // 订阅帧流（用户点击捕获后会收到帧）
        subscribeToIOSFrames(source)
    }

    /// 断开 iOS 设备
    private func disconnectIOSDevice() async {
        guard let source = iosDeviceSource else { return }

        AppLogger.device.info("断开 iOS 设备 (QVH): \(source.displayName)")

        await source.stopCapture()
        await source.disconnect()

        iosDeviceSource = nil
        iosLatestFrame = nil
    }

    /// 订阅 iOS 帧流
    private func subscribeToIOSFrames(_ source: QVHDeviceSource) {
        Task { [weak self] in
            for await frame in source.frameStream {
                await MainActor.run {
                    self?.iosLatestFrame = frame
                }
            }
        }
    }

    // MARK: - Android 设备管理

    /// 连接 Android 设备（不自动启动捕获，由用户手动点击开始）
    private func connectAndroidDevice(_ device: AndroidDevice) async {
        AppLogger.device.info("开始连接 Android 设备: \(device.displayName)")

        // 检查 scrcpy 是否可用
        guard toolchainManager.scrcpyStatus.isReady else {
            AppLogger.device.warning("scrcpy 未安装，无法捕获 Android 设备")
            return
        }

        let source = ScrcpyDeviceSource(device: device)
        androidDeviceSource = source

        do {
            try await source.connect()
            AppLogger.device.info("Android 设备已连接: \(device.displayName)")

            // 订阅帧流（用户点击捕获后会收到帧）
            subscribeToAndroidFrames(source)
        } catch {
            AppLogger.device.error("Android 设备连接失败: \(error.localizedDescription)")
        }
    }

    /// 断开 Android 设备
    private func disconnectAndroidDevice() async {
        guard let source = androidDeviceSource else { return }

        AppLogger.device.info("断开 Android 设备: \(source.displayName)")

        await source.stopCapture()
        await source.disconnect()

        androidDeviceSource = nil
        androidLatestFrame = nil
    }

    /// 订阅 Android 帧流
    private func subscribeToAndroidFrames(_ source: ScrcpyDeviceSource) {
        Task { [weak self] in
            for await frame in source.frameStream {
                await MainActor.run {
                    self?.androidLatestFrame = frame
                }
            }
        }
    }

    // MARK: - 公开方法

    /// 手动启动 iOS 捕获（QVH）
    func startIOSCapture() async {
        guard let source = iosDeviceSource else { return }
        do {
            // QVH 设备源需要先连接（启动 qvh 进程）
            if source.state == .idle || source.state == .disconnected {
                try await source.connect()
            }
            // 然后开始捕获
            try await source.startCapture()
        } catch {
            AppLogger.capture.error("启动 iOS 捕获失败: \(error.localizedDescription)")
        }
    }

    /// 手动停止 iOS 捕获
    func stopIOSCapture() async {
        guard let source = iosDeviceSource else { return }
        await source.stopCapture()
    }

    /// 手动启动 Android 捕获
    func startAndroidCapture() async {
        guard let source = androidDeviceSource else { return }
        do {
            try await source.startCapture()
        } catch {
            AppLogger.capture.error("启动 Android 捕获失败: \(error.localizedDescription)")
        }
    }

    /// 手动停止 Android 捕获
    func stopAndroidCapture() async {
        guard let source = androidDeviceSource else { return }
        await source.stopCapture()
    }
}
