//
//  SettingsView.swift
//  DemoConsole
//
//  Created by Sun on 2025/12/22.
//
//  设置视图（简化版）
//  提供用户偏好设置的配置界面
//

import SwiftUI

// MARK: - 设置视图

struct SettingsView: View {
    // MARK: - Properties

    @ObservedObject var preferences: UserPreferences = .shared
    @ObservedObject var permissionChecker: PermissionChecker = .init()
    @ObservedObject var toolchainManager: ToolchainManager = .init()

    /// 自定义颜色绑定
    private var customColorBinding: Binding<Color> {
        Binding(
            get: { preferences.customBackgroundColor },
            set: { preferences.customBackgroundColor = $0 }
        )
    }

    // MARK: - Body

    var body: some View {
        TabView {
            generalSettingsTab
                .tabItem {
                    Label("通用", systemImage: "gear")
                }

            captureSettingsTab
                .tabItem {
                    Label("捕获", systemImage: "video")
                }

            scrcpySettingsTab
                .tabItem {
                    Label("Scrcpy", systemImage: "antenna.radiowaves.left.and.right")
                }

            permissionsTab
                .tabItem {
                    Label("权限", systemImage: "lock.shield")
                }
        }
        .frame(width: 450, height: 420)
        .onAppear {
            Task {
                await permissionChecker.checkAll()
            }
        }
    }

    // MARK: - General Settings Tab

    private var generalSettingsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 外观设置组
                SettingsGroup(title: "外观", icon: "paintbrush") {
                    LabeledContent("主题模式") {
                        Picker("", selection: $preferences.themeMode) {
                            ForEach(ThemeMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 200)
                    }

                    LabeledContent("预览背景") {
                        HStack(spacing: 8) {
                            Picker("", selection: $preferences.backgroundColorMode) {
                                ForEach(BackgroundColorMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 140)

                            if preferences.backgroundColorMode == .custom {
                                ColorPicker("", selection: customColorBinding)
                                    .labelsHidden()
                                    .fixedSize()
                            }
                        }
                    }

                    if preferences.backgroundColorMode == .followTheme {
                        Text("预览区域背景色将跟随系统主题自动切换")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // 布局设置组
                SettingsGroup(title: "布局", icon: "rectangle.split.2x1") {
                    LabeledContent("默认布局") {
                        Picker("", selection: $preferences.defaultLayout) {
                            ForEach(SplitLayout.allCases) { layout in
                                Label(layout.displayName, systemImage: layout.icon)
                                    .tag(layout)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 200)
                    }
                }

                // 连接设置组
                SettingsGroup(title: "连接", icon: "cable.connector") {
                    Toggle("自动重连", isOn: $preferences.autoReconnect)

                    if preferences.autoReconnect {
                        LabeledContent("重连延迟") {
                            Stepper(
                                "\(Int(preferences.reconnectDelay)) 秒",
                                value: $preferences.reconnectDelay,
                                in: 1...30,
                                step: 1
                            )
                            .frame(width: 120)
                        }

                        LabeledContent("最大重连次数") {
                            Stepper(
                                "\(preferences.maxReconnectAttempts) 次",
                                value: $preferences.maxReconnectAttempts,
                                in: 1...20
                            )
                            .frame(width: 120)
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - Capture Settings Tab

    private var captureSettingsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 帧率设置组
                SettingsGroup(title: "帧率", icon: "speedometer") {
                    LabeledContent("捕获帧率") {
                        Picker("", selection: $preferences.captureFrameRate) {
                            Text("30 FPS").tag(30)
                            Text("60 FPS").tag(60)
                            Text("120 FPS").tag(120)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 200)
                    }

                    Text("更高的帧率会增加 CPU 和 GPU 负载")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(20)
        }
    }

    // MARK: - Scrcpy Settings Tab

    private var scrcpySettingsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 视频设置组
                SettingsGroup(title: "视频", icon: "video") {
                    LabeledContent("比特率") {
                        Picker("", selection: $preferences.scrcpyBitrate) {
                            Text("4 Mbps").tag(4)
                            Text("8 Mbps").tag(8)
                            Text("16 Mbps").tag(16)
                            Text("32 Mbps").tag(32)
                        }
                        .frame(width: 150)
                    }

                    LabeledContent("最大尺寸") {
                        Picker("", selection: $preferences.scrcpyMaxSize) {
                            Text("不限制").tag(0)
                            Text("1280 像素").tag(1280)
                            Text("1920 像素").tag(1920)
                            Text("2560 像素").tag(2560)
                        }
                        .frame(width: 150)
                    }

                    Text("限制尺寸可以降低 CPU 负载")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // 显示设置组
                SettingsGroup(title: "显示", icon: "hand.tap") {
                    Toggle("显示触摸点", isOn: $preferences.scrcpyShowTouches)
                }

                // 高级设置组
                SettingsGroup(title: "高级", icon: "gearshape.2") {
                    Text("更多 scrcpy 配置请参考官方文档")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Link(destination: URL(string: "https://github.com/Genymobile/scrcpy")!) {
                        Label("scrcpy GitHub", systemImage: "link")
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - Permissions Tab

    private var permissionsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 系统权限组
                SettingsGroup(title: "系统权限", icon: "lock.shield") {
                    ForEach(permissionChecker.permissions) { permission in
                        PermissionRow(
                            permission: permission,
                            onRequest: {
                                Task {
                                    if permission.id == "screenRecording" {
                                        _ = await permissionChecker.requestScreenRecordingPermission()
                                    }
                                }
                            },
                            onOpenSettings: {
                                permissionChecker.openSystemPreferences(for: permission.id)
                            }
                        )

                        if permission.id != permissionChecker.permissions.last?.id {
                            Divider()
                        }
                    }
                }

                // Android 工具链组
                SettingsGroup(title: "Android 工具链", icon: "apps.iphone") {
                    // adb
                    ToolchainRow(
                        name: "adb",
                        description: "Android 调试工具",
                        status: toolchainManager.adbStatus,
                        version: toolchainManager.adbVersionDescription
                    )

                    Divider()

                    // scrcpy
                    ToolchainRow(
                        name: "scrcpy",
                        description: "Android 投屏工具",
                        status: toolchainManager.scrcpyStatus,
                        version: toolchainManager.scrcpyVersionDescription,
                        installURL: URL(string: "https://github.com/Genymobile/scrcpy")
                    )
                }

                // iOS 工具链组
                SettingsGroup(title: "iOS 工具链", icon: "iphone") {
                    // qvh (iOS 投屏工具)
                    ToolchainRow(
                        name: "qvh",
                        description: "iOS 投屏工具 (quicktime_video_hack)",
                        status: toolchainManager.qvhStatus,
                        version: toolchainManager.qvhVersionDescription,
                        installURL: URL(string: "https://github.com/danielpaulus/quicktime_video_hack")
                    )
                }

                // 刷新按钮
                HStack {
                    Spacer()
                    Button {
                        Task {
                            await permissionChecker.checkAll()
                            await toolchainManager.refresh()
                        }
                    } label: {
                        Label("刷新状态", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(20)
        }
        .onAppear {
            Task {
                await toolchainManager.setup()
            }
        }
    }
}

// MARK: - 权限行组件

private struct PermissionRow: View {
    let permission: PermissionItem
    let onRequest: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // 状态图标
            Image(systemName: permission.status.icon)
                .font(.system(size: 18))
                .foregroundColor(statusColor)
                .frame(width: 24)

            // 权限信息
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(permission.name)
                        .font(.body)

                    if permission.isRequired {
                        Text("必需")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.red.opacity(0.1))
                            .foregroundColor(.red)
                            .cornerRadius(3)
                    } else {
                        Text("可选")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.1))
                            .foregroundColor(.secondary)
                            .cornerRadius(3)
                    }
                }

                Text(permission.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // 操作按钮
            if permission.status == .granted {
                Text("已授权")
                    .font(.caption)
                    .foregroundColor(.green)
            } else {
                HStack(spacing: 8) {
                    Button("授权") {
                        onRequest()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        onOpenSettings()
                    } label: {
                        Image(systemName: "gear")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("打开系统设置")
                }
            }
        }
    }

    private var statusColor: Color {
        switch permission.status {
        case .granted:
            .green
        case .denied:
            .red
        case .notDetermined:
            .orange
        default:
            .gray
        }
    }
}

// MARK: - 工具链行组件

private struct ToolchainRow: View {
    let name: String
    let description: String
    let status: ToolchainStatus
    var version: String = ""
    var installURL: URL?

    var body: some View {
        HStack(spacing: 12) {
            // 状态图标
            Image(systemName: statusIcon)
                .font(.system(size: 18))
                .foregroundColor(statusColor)
                .frame(width: 24)

            // 工具信息
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.body)

                    Text("可选")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .foregroundColor(.secondary)
                        .cornerRadius(3)
                }

                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // 状态/操作
            switch status {
            case let .installed(ver):
                Text(ver.isEmpty ? "已安装" : ver)
                    .font(.caption)
                    .foregroundColor(.green)

            case .installing:
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("检查中...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

            case .notInstalled:
                if let url = installURL {
                    Link(destination: url) {
                        Text("安装指南")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Text("未安装")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

            case let .error(message):
                Text(message)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(1)
            }
        }
    }

    private var statusIcon: String {
        switch status {
        case .installed:
            "checkmark.circle.fill"
        case .installing:
            "arrow.down.circle"
        case .notInstalled:
            "xmark.circle"
        case .error:
            "exclamationmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch status {
        case .installed:
            .green
        case .installing:
            .blue
        case .notInstalled:
            .orange
        case .error:
            .red
        }
    }
}

// MARK: - 设置分组组件

struct SettingsGroup<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 分组标题
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(.primary)

            // 分组内容
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
}
