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
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 800, minHeight: 600)
                .preferredColorScheme(preferences.themeMode.colorScheme)
        }
        .windowStyle(.hiddenTitleBar)
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

    /// iOS 设备提供者
    @Published private(set) var iosDeviceProvider = IOSDeviceProvider()

    /// 权限检查器
    @Published var permissionChecker = PermissionChecker()

    /// 当前选中的设备 ID
    @Published var selectedDeviceID: String?

    /// 是否显示首次启动检查清单
    @Published var showPermissionChecklist = false

    /// 是否正在初始化
    @Published var isInitializing = true

    // MARK: - 设备连接状态

    /// Android 是否已连接
    var androidConnected: Bool {
        !androidDeviceProvider.devices.isEmpty
    }

    /// Android 设备名称
    var androidDeviceName: String? {
        androidDeviceProvider.devices.first?.displayName
    }

    /// iOS 是否已连接
    var iosConnected: Bool {
        !iosDeviceProvider.devices.isEmpty
    }

    /// iOS 设备名称
    var iosDeviceName: String? {
        iosDeviceProvider.devices.first?.name
    }

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

        // 如果首次启动或权限不完整，显示检查清单
        if !hasCompletedSetup || !permissionChecker.allPermissionsGranted {
            showPermissionChecklist = true
        }

        isInitializing = false

        // 开始监控设备
        androidDeviceProvider.startMonitoring()
        iosDeviceProvider.startMonitoring()
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
        }
        iosDeviceProvider.refreshDevices()
    }
}
