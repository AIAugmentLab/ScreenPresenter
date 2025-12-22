//
//  ContentView.swift
//  DemoConsole
//
//  Created by Sun on 2025/12/22.
//
//  主内容视图（简化版）
//  单窗口布局：顶部工具栏、中间预览区、底部状态栏
//

import SwiftUI

// MARK: - 蓝色主题色

extension Color {
    /// 主题蓝色 - 与 AppIcon 一致
    static let themeBlue = Color(hex: "007AFF")
    static let themeBlueDark = Color(hex: "005FB8")
}

// MARK: - 主内容视图

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var preferences = UserPreferences.shared
    @Environment(\.colorScheme) private var colorScheme

    // 窗口设置
    @State private var splitLayout: SplitLayout = .sideBySide
    @State private var isSwapped: Bool = false // 是否交换设备位置

    /// 当前有效的背景色
    private var effectiveBackgroundColor: Color {
        preferences.effectiveBackgroundColor(for: colorScheme)
    }

    /// 自定义颜色绑定（用于 ColorPicker）
    private var customColorBinding: Binding<Color> {
        Binding(
            get: { preferences.customBackgroundColor },
            set: { preferences.customBackgroundColor = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部工具栏
            topToolbar

            Divider()

            // 中间预览区域
            previewArea

            Divider()

            // 底部状态栏
            bottomStatusBar
        }
        .background(Color(NSColor.windowBackgroundColor))
        .overlay {
            // 首次启动权限检查
            if appState.showPermissionChecklist {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()

                PermissionChecklistView()
                    .environmentObject(appState)
            }

            // 初始化加载
            if appState.isInitializing {
                Color(NSColor.windowBackgroundColor)
                    .ignoresSafeArea()

                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("正在初始化...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - 顶部工具栏

    private var topToolbar: some View {
        HStack(spacing: 16) {
            // 设备窗口设置
            HStack(spacing: 12) {
                // 背景色选择
                HStack(spacing: 6) {
                    Text("背景色")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if preferences.backgroundColorMode == .custom {
                        ColorPicker("", selection: customColorBinding)
                            .labelsHidden()
                            .fixedSize()
                    } else {
                        // 跟随主题时显示当前主题颜色预览
                        RoundedRectangle(cornerRadius: 4)
                            .fill(effectiveBackgroundColor)
                            .frame(width: 20, height: 20)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                            )
                    }
                }
                .help(preferences.backgroundColorMode == .custom ? "点击选择自定义背景色" : "跟随主题（可在偏好设置中修改）")

                Divider().frame(height: 20)

                // 分屏布局选择
                HStack(spacing: 6) {
                    Text("布局")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // 使用自定义按钮组实现带 icon 的 segmented 效果
                    HStack(spacing: 0) {
                        ForEach(SplitLayout.allCases) { layout in
                            Button {
                                splitLayout = layout
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: layout.icon)
                                    Text(layout.displayName)
                                }
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                            .background(
                                splitLayout == layout
                                    ? Color.accentColor
                                    : Color(NSColor.controlBackgroundColor)
                            )
                            .foregroundStyle(splitLayout == layout ? .white : .primary)
                            .clipShape(
                                layout == .sideBySide
                                    ? AnyShape(UnevenRoundedRectangle(cornerRadii: .init(
                                        topLeading: 5,
                                        bottomLeading: 5
                                    )))
                                    : AnyShape(UnevenRoundedRectangle(cornerRadii: .init(
                                        bottomTrailing: 5,
                                        topTrailing: 5
                                    )))
                            )
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
                    )
                }
                .help("切换布局方式")

                Divider().frame(height: 20)

                // 交换位置按钮
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                        isSwapped.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.left.arrow.right")
                            .rotationEffect(.degrees(isSwapped ? 180 : 0))
                        Text("交换")
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help("交换设备位置")
            }

            Spacer()

            // 刷新按钮
            Button {
                appState.refreshDevices()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                    Text("刷新")
                }
                .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help("刷新设备列表")

            // 设置按钮（打开独立偏好设置窗口）
            SettingsLink {
                HStack(spacing: 4) {
                    Image(systemName: "gear")
                    Text("偏好设置")
                }
                .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help("偏好设置")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - 预览区域

    private var previewArea: some View {
        GeometryReader { geometry in
            ZStack {
                // 背景色
                effectiveBackgroundColor

                // 根据布局显示设备（使用 ZStack + offset 实现真正的卡片交换动画）
                let isHorizontal = splitLayout == .sideBySide
                let panelWidth = isHorizontal ? geometry.size.width / 2 : geometry.size.width
                let panelHeight = isHorizontal ? geometry.size.height : geometry.size.height / 2

                // Android 面板
                androidDevicePanel
                    .frame(width: panelWidth - 1, height: panelHeight - 1)
                    .offset(
                        x: isHorizontal ? (isSwapped ? panelWidth / 2 : -panelWidth / 2) : 0,
                        y: isHorizontal ? 0 : (isSwapped ? panelHeight / 2 : -panelHeight / 2)
                    )

                // iOS 面板
                iosDevicePanel
                    .frame(width: panelWidth - 1, height: panelHeight - 1)
                    .offset(
                        x: isHorizontal ? (isSwapped ? -panelWidth / 2 : panelWidth / 2) : 0,
                        y: isHorizontal ? 0 : (isSwapped ? -panelHeight / 2 : panelHeight / 2)
                    )
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: splitLayout)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: isSwapped)
    }

    // MARK: - 设备面板

    /// Android 设备面板
    private var androidDevicePanel: some View {
        devicePreviewPanel(
            title: "Android",
            isConnected: appState.androidConnected,
            deviceName: appState.androidDeviceName,
            connectionGuide: "使用 USB 数据线连接 Android 设备"
        )
    }

    /// iOS 设备面板
    private var iosDevicePanel: some View {
        devicePreviewPanel(
            title: "iPhone",
            isConnected: appState.iosConnected,
            deviceName: appState.iosDeviceName,
            connectionGuide: "使用 USB 数据线连接 iPhone 并信任此电脑"
        )
    }

    // MARK: - 设备预览面板

    private func devicePreviewPanel(
        title: String,
        isConnected: Bool,
        deviceName: String?,
        connectionGuide: String
    ) -> some View {
        // 根据主题决定文字颜色
        let textColor = colorScheme == .dark ? Color.white : Color.black
        let secondaryTextOpacity = colorScheme == .dark ? 0.5 : 0.4
        let tertiaryTextOpacity = colorScheme == .dark ? 0.4 : 0.3

        return ZStack {
            // 设备内容区
            if isConnected {
                // 已连接：显示设备画面占位符
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                Text("设备画面")
                    .foregroundStyle(textColor.opacity(secondaryTextOpacity))
            } else {
                // 未连接：显示设备类型和大图标
                VStack(spacing: 20) {
                    // 大设备图标（使用 AppIcon 上的设备 icon）
                    Image(title == "Android" ? "AndroidIcon" : "IOSIcon")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 120)
                        .opacity(secondaryTextOpacity)

                    // 设备类型名称
                    Text(title)
                        .font(.title.bold())
                        .foregroundStyle(textColor.opacity(secondaryTextOpacity))

                    // 连接指引
                    VStack(spacing: 8) {
                        Image(systemName: "cable.connector")
                            .font(.system(size: 24))
                            .foregroundStyle(textColor.opacity(tertiaryTextOpacity))

                        Text(connectionGuide)
                            .font(.caption)
                            .foregroundStyle(textColor.opacity(tertiaryTextOpacity))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
            }

            // 顶部状态栏（悬浮在内容上方）
            VStack {
                HStack {
                    if isConnected {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        if let name = deviceName {
                            Text(name)
                                .font(.caption)
                                .foregroundStyle(textColor.opacity(0.8))
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isConnected ? (colorScheme == .dark ? Color.black : Color.white).opacity(0.3) : Color.clear)

                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background((colorScheme == .dark ? Color.black : Color.white).opacity(0.1))
    }

    // MARK: - 底部状态栏

    private var bottomStatusBar: some View {
        HStack(spacing: 16) {
            // 工具链状态
            HStack(spacing: 12) {
                // adb 状态
                HStack(spacing: 6) {
                    StatusDot(isReady: appState.toolchainManager.adbStatus.isReady)
                    Text("adb")
                        .font(.caption)
                    if appState.toolchainManager.adbStatus.isReady {
                        Text(appState.toolchainManager.adbVersionDescription)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider().frame(height: 12)

                // scrcpy 状态
                HStack(spacing: 6) {
                    StatusDot(isReady: appState.toolchainManager.scrcpyStatus.isReady)
                    Text("scrcpy")
                        .font(.caption)
                    if appState.toolchainManager.scrcpyStatus.isReady {
                        Text(appState.toolchainManager.scrcpyVersionDescription)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("安装") {
                            // TODO: 安装 scrcpy
                        }
                        .font(.caption2)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
            }

            Spacer()

            // 设备连接状态
            HStack(spacing: 8) {
                if appState.androidConnected {
                    Label("Android 已连接", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if appState.iosConnected {
                    Label("iPhone 已连接", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if !appState.androidConnected, !appState.iosConnected {
                    Text("等待设备连接...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

// MARK: - 状态指示点

struct StatusDot: View {
    let isReady: Bool

    var body: some View {
        Circle()
            .fill(isReady ? Color.green : Color.orange)
            .frame(width: 8, height: 8)
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(AppState())
        .frame(width: 900, height: 600)
}
