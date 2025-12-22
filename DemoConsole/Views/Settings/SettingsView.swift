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
        }
        .frame(width: 450, height: 380)
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
