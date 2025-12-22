//
//  ContentView.swift
//  DemoConsole
//
//  Created by Sun on 2025/12/22.
//
//  主内容视图（简化版）
//  单窗口布局：顶部工具栏、中间预览区、底部状态栏
//

import AppKit
import CoreImage
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

    // 刷新状态
    @State private var isRefreshing: Bool = false
    @State private var showRefreshResult: Bool = false
    @State private var refreshResultMessage: String = ""

    // 捕获错误提示
    @State private var captureError: String?
    @State private var showCaptureError: Bool = false

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

            // 刷新结果提示
            if showRefreshResult {
                VStack {
                    Spacer()

                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(refreshResultMessage)
                            .font(.caption)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .shadow(radius: 4)
                    .padding(.bottom, 20)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // 捕获错误提示
            if showCaptureError, let error = captureError {
                VStack {
                    Spacer()

                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("捕获失败: \(error)")
                            .font(.caption)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .shadow(radius: 4)
                    .padding(.bottom, 20)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - 刷新设备

    private func performRefresh() {
        guard !isRefreshing else { return }

        isRefreshing = true

        // 执行刷新
        appState.refreshDevices()

        // 延迟检查结果（给设备发现一些时间）
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5秒

            await MainActor.run {
                isRefreshing = false

                // 获取刷新后的设备数量
                let iosCount = appState.qvhDeviceManager.devices.count
                let androidCount = appState.androidDeviceProvider.devices.count
                let totalCount = iosCount + androidCount

                // 构建结果消息
                if totalCount == 0 {
                    refreshResultMessage = "未发现设备"
                } else {
                    var parts: [String] = []
                    if iosCount > 0 {
                        parts.append("\(iosCount) 台 iOS")
                    }
                    if androidCount > 0 {
                        parts.append("\(androidCount) 台 Android")
                    }
                    refreshResultMessage = "发现 \(parts.joined(separator: "、")) 设备"
                }

                // 显示结果提示
                withAnimation(.easeInOut(duration: 0.3)) {
                    showRefreshResult = true
                }

                // 2秒后自动隐藏
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await MainActor.run {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            showRefreshResult = false
                        }
                    }
                }
            }
        }
    }

    // MARK: - 顶部工具栏

    private var topToolbar: some View {
        ZStack {
            // 背景层
            Color(NSColor.controlBackgroundColor)

            // 工具栏内容
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
                                        : (colorScheme == .dark
                                            ? Color.white.opacity(0.1)
                                            : Color(NSColor.controlBackgroundColor))
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
                    performRefresh()
                } label: {
                    HStack(spacing: 4) {
                        if isRefreshing {
                            ProgressView()
                                .scaleEffect(0.35)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(isRefreshing ? "刷新中..." : "刷新")
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(isRefreshing)
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
        }
        .frame(height: 44) // 固定高度
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

                // 中间分割线
                if isHorizontal {
                    // 左右布局：垂直分割线
                    Rectangle()
                        .fill(Color(NSColor.separatorColor))
                        .frame(width: 1)
                } else {
                    // 上下布局：水平分割线
                    Rectangle()
                        .fill(Color(NSColor.separatorColor))
                        .frame(height: 1)
                }
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
            deviceName: appState.androidDeviceName,
            deviceSource: appState.androidDeviceSource,
            connectionGuide: "使用 USB 数据线连接 Android 设备"
        )
    }

    /// iOS 设备面板（使用 QVH）
    private var iosDevicePanel: some View {
        qvhDevicePreviewPanel()
    }

    // MARK: - QVH 设备预览面板

    /// QVH (iOS) 设备预览面板
    private func qvhDevicePreviewPanel() -> some View {
        // 根据主题决定文字颜色
        let textColor = colorScheme == .dark ? Color.white : Color.black
        let secondaryTextOpacity = colorScheme == .dark ? 0.5 : 0.4
        let tertiaryTextOpacity = colorScheme == .dark ? 0.4 : 0.3

        let deviceSource = appState.iosDeviceSource
        let isCapturing = deviceSource?.state == .capturing
        let hasDevice = !appState.qvhDeviceManager.devices.isEmpty
        let deviceName = appState.iosDeviceName

        return ZStack {
            // 设备内容区
            if isCapturing, let source = deviceSource {
                // 捕获中：使用 TimelineView 定期刷新画面
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
                    if let frame = source.latestFrame, let cgImage = createCGImage(from: frame) {
                        GeometryReader { geometry in
                            Image(nsImage: NSImage(
                                cgImage: cgImage,
                                size: NSSize(width: cgImage.width, height: cgImage.height)
                            ))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: geometry.size.width, maxHeight: geometry.size.height)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                        }
                    } else {
                        // 等待第一帧
                        VStack(spacing: 16) {
                            ProgressView()
                                .scaleEffect(1.2)
                            Text("等待画面...")
                                .font(.caption)
                                .foregroundStyle(textColor.opacity(secondaryTextOpacity))
                        }
                    }
                }
            } else if let source = deviceSource, source.state == .connecting {
                // 连接中
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("正在启动投屏...")
                        .font(.headline)
                        .foregroundStyle(textColor.opacity(secondaryTextOpacity))
                    Text("qvh 进程启动中")
                        .font(.caption)
                        .foregroundStyle(textColor.opacity(tertiaryTextOpacity))
                }
            } else if let source = deviceSource, case let .error(error) = source.state {
                // 错误状态
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(textColor.opacity(secondaryTextOpacity))
                        .multilineTextAlignment(.center)

                    // 重试按钮
                    Button {
                        Task {
                            await appState.startIOSCapture()
                        }
                    } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
            } else if hasDevice {
                // 设备已发现，等待用户启动捕获
                VStack(spacing: 20) {
                    // 设备图标
                    Image("IOSIcon")
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 80)
                        .foregroundStyle(textColor.opacity(secondaryTextOpacity))

                    // 设备名称
                    if let name = deviceName {
                        Text(name)
                            .font(.title2.bold())
                            .foregroundStyle(textColor.opacity(0.8))
                    }

                    // QVH 状态指示
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Text("已检测到设备")
                            .font(.caption)
                            .foregroundStyle(textColor.opacity(secondaryTextOpacity))
                    }

                    // 捕获按钮
                    Button {
                        Task {
                            await appState.startIOSCapture()
                        }
                    } label: {
                        Label("开始投屏", systemImage: "play.fill")
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Text("使用 quicktime_video_hack 直接捕获屏幕")
                        .font(.caption2)
                        .foregroundStyle(textColor.opacity(tertiaryTextOpacity))
                }
            } else {
                // 未连接：显示设备类型和大图标
                VStack(spacing: 20) {
                    // 大设备图标
                    Image("IOSIcon")
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 120)
                        .foregroundStyle(textColor.opacity(secondaryTextOpacity))

                    // 设备类型名称
                    Text("iPhone")
                        .font(.title.bold())
                        .foregroundStyle(textColor.opacity(secondaryTextOpacity))

                    // 连接指引
                    VStack(spacing: 8) {
                        Image(systemName: "cable.connector")
                            .font(.system(size: 24))
                            .foregroundStyle(textColor.opacity(tertiaryTextOpacity))

                        Text("使用 USB 数据线连接 iPhone")
                            .font(.caption)
                            .foregroundStyle(textColor.opacity(tertiaryTextOpacity))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    // 检查 qvh 状态
                    if !appState.qvhDeviceManager.isQVHInstalled {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("qvh 工具未安装")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        .padding(.top, 8)
                    }
                }
            }

            // 顶部状态栏（仅捕获时悬浮在内容上方）
            VStack {
                if isCapturing, let source = deviceSource {
                    HStack {
                        // 状态指示灯
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)

                        Text("捕获中 (QVH)")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.9))

                        Spacer()

                        // 捕获尺寸信息
                        if source.captureSize != .zero {
                            Text("\(Int(source.captureSize.width))×\(Int(source.captureSize.height))")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.6))
                        }

                        if source.frameRate > 0 {
                            Text("\(Int(source.frameRate)) fps")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.6))
                        }

                        // 停止捕获按钮
                        Button {
                            Task {
                                await appState.stopIOSCapture()
                            }
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.8))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.5))
                }

                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background((colorScheme == .dark ? Color.black : Color.white).opacity(0.1))
    }

    // MARK: - 设备预览面板

    private func devicePreviewPanel(
        title: String,
        deviceName: String?,
        deviceSource: BaseDeviceSource?,
        connectionGuide: String
    ) -> some View {
        // 根据主题决定文字颜色
        let textColor = colorScheme == .dark ? Color.white : Color.black
        let secondaryTextOpacity = colorScheme == .dark ? 0.5 : 0.4
        let tertiaryTextOpacity = colorScheme == .dark ? 0.4 : 0.3

        // 根据 deviceSource 状态判断连接和捕获状态
        let isCapturing = deviceSource?.state == .capturing
        let isConnected: Bool = {
            guard let source = deviceSource else { return false }
            switch source.state {
            case .idle, .disconnected:
                return false
            default:
                return true
            }
        }()

        return ZStack {
            // 设备内容区
            if isCapturing, let source = deviceSource {
                // 捕获中：使用 TimelineView 定期刷新画面
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
                    if let frame = source.latestFrame, let cgImage = createCGImage(from: frame) {
                        GeometryReader { geometry in
                            Image(nsImage: NSImage(
                                cgImage: cgImage,
                                size: NSSize(width: cgImage.width, height: cgImage.height)
                            ))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: geometry.size.width, maxHeight: geometry.size.height)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                        }
                    } else {
                        // 等待第一帧
                        VStack(spacing: 16) {
                            ProgressView()
                                .scaleEffect(1.2)
                            Text("等待画面...")
                                .font(.caption)
                                .foregroundStyle(textColor.opacity(secondaryTextOpacity))
                        }
                    }
                }
            } else if let source = deviceSource, isConnected {
                // 已连接：根据状态显示不同内容
                VStack(spacing: 20) {
                    switch source.state {
                    case .connecting:
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("正在连接...")
                            .font(.headline)
                            .foregroundStyle(textColor.opacity(secondaryTextOpacity))

                    case .connected:
                        // 设备图标
                        Image(title == "Android" ? "AndroidIcon" : "IOSIcon")
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 80)
                            .foregroundStyle(textColor.opacity(secondaryTextOpacity))

                        // 设备名称
                        if let name = deviceName {
                            Text("\(name)")
                                .font(.title2.bold())
                                .foregroundStyle(textColor.opacity(0.8))
                        }

                        // 捕获按钮
                        Button {
                            Task {
                                do {
                                    try await source.startCapture()
                                } catch {
                                    await MainActor.run {
                                        captureError = error.localizedDescription
                                        withAnimation {
                                            showCaptureError = true
                                        }
                                        // 3秒后自动隐藏
                                        Task {
                                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                                            await MainActor.run {
                                                withAnimation {
                                                    showCaptureError = false
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        } label: {
                            Label("开始捕获", systemImage: "play.fill")
                                .font(.headline)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                    case .capturing:
                        ProgressView()
                            .scaleEffect(1.2)
                        if let name = deviceName {
                            Text("正在捕获 \"\(name)\"...")
                                .font(.caption)
                                .foregroundStyle(textColor.opacity(secondaryTextOpacity))
                        } else {
                            Text("等待画面...")
                                .font(.caption)
                                .foregroundStyle(textColor.opacity(secondaryTextOpacity))
                        }

                    case .paused:
                        Image(systemName: "pause.circle")
                            .font(.system(size: 48))
                            .foregroundStyle(textColor.opacity(secondaryTextOpacity))
                        Text("已暂停")
                            .font(.headline)
                            .foregroundStyle(textColor.opacity(secondaryTextOpacity))

                        // 恢复按钮
                        Button {
                            Task {
                                try? await source.startCapture()
                            }
                        } label: {
                            Label("继续捕获", systemImage: "play.fill")
                        }
                        .buttonStyle(.bordered)

                    case let .error(error):
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 48))
                            .foregroundStyle(.orange)
                        Text(error.localizedDescription)
                            .font(.caption)
                            .foregroundStyle(textColor.opacity(secondaryTextOpacity))
                            .multilineTextAlignment(.center)

                        // 重试按钮
                        Button {
                            Task {
                                try? await source.reconnect()
                            }
                        } label: {
                            Label("重试", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)

                    default:
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("初始化中...")
                            .font(.caption)
                            .foregroundStyle(textColor.opacity(secondaryTextOpacity))
                    }
                }
            } else {
                // 未连接：显示设备类型和大图标
                VStack(spacing: 20) {
                    // 大设备图标（使用 AppIcon 上的设备 icon）
                    Image(title == "Android" ? "AndroidIcon" : "IOSIcon")
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 120)
                        .foregroundStyle(textColor.opacity(secondaryTextOpacity))

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

            // 顶部状态栏（仅捕获时悬浮在内容上方）
            VStack {
                if isCapturing, let source = deviceSource {
                    HStack {
                        // 状态指示灯
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)

                        Text("捕获中")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.9))

                        Spacer()

                        // 捕获尺寸信息
                        if source.captureSize != .zero {
                            Text("\(Int(source.captureSize.width))×\(Int(source.captureSize.height))")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.6))
                        }

                        if source.frameRate > 0 {
                            Text("\(Int(source.frameRate)) fps")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.6))
                        }

                        // 停止捕获按钮
                        Button {
                            Task {
                                await source.stopCapture()
                            }
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.8))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.5))
                }

                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background((colorScheme == .dark ? Color.black : Color.white).opacity(0.1))
    }

    // MARK: - 帧转换

    /// 将 CapturedFrame 转换为 CGImage
    private func createCGImage(from frame: CapturedFrame) -> CGImage? {
        guard let pixelBuffer = frame.pixelBuffer else { return nil }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        return context.createCGImage(ciImage, from: ciImage.extent)
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(AppState())
        .frame(width: 900, height: 600)
}
