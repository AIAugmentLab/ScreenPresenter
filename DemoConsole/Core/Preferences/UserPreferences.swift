//
//  UserPreferences.swift
//  DemoConsole
//
//  Created by Sun on 2025/12/22.
//
//  用户偏好设置
//  持久化存储用户的各项配置选项（简化版）
//

import Foundation
import SwiftUI

// MARK: - 布局样式

/// 分屏布局模式
enum SplitLayout: String, CaseIterable, Identifiable, Codable {
    case sideBySide // 左右平分
    case topBottom // 上下平分

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sideBySide: "左右平分"
        case .topBottom: "上下平分"
        }
    }

    var icon: String {
        switch self {
        case .sideBySide: "rectangle.split.2x1"
        case .topBottom: "rectangle.split.1x2"
        }
    }
}

// MARK: - 主题模式

/// 主题模式
enum ThemeMode: String, CaseIterable, Identifiable, Codable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

// MARK: - 背景色模式

/// 预览区域背景色模式
enum BackgroundColorMode: String, CaseIterable, Identifiable, Codable {
    case followTheme // 跟随主题
    case custom // 自定义颜色

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .followTheme: "跟随主题"
        case .custom: "自定义"
        }
    }
}

// MARK: - 用户偏好设置模型

/// 用户偏好设置
final class UserPreferences: ObservableObject {
    // MARK: - Singleton

    static let shared = UserPreferences()

    // MARK: - Keys

    private enum Keys {
        static let defaultLayout = "defaultLayout"
        static let autoReconnect = "autoReconnect"
        static let reconnectDelay = "reconnectDelay"
        static let maxReconnectAttempts = "maxReconnectAttempts"
        static let themeMode = "themeMode"
        static let backgroundColorMode = "backgroundColorMode"
        static let customBackgroundColor = "customBackgroundColor"
        static let captureFrameRate = "captureFrameRate"
        static let scrcpyBitrate = "scrcpyBitrate"
        static let scrcpyMaxSize = "scrcpyMaxSize"
        static let scrcpyShowTouches = "scrcpyShowTouches"
    }

    // MARK: - Layout Settings

    /// 默认布局样式
    @AppStorage(Keys.defaultLayout)
    var defaultLayout: SplitLayout = .sideBySide

    // MARK: - Connection Settings

    /// 是否自动重连
    @AppStorage(Keys.autoReconnect)
    var autoReconnect: Bool = true

    /// 重连延迟（秒）
    @AppStorage(Keys.reconnectDelay)
    var reconnectDelay: Double = 3.0

    /// 最大重连次数
    @AppStorage(Keys.maxReconnectAttempts)
    var maxReconnectAttempts: Int = 5

    // MARK: - Display Settings

    /// 主题模式
    @AppStorage(Keys.themeMode)
    var themeMode: ThemeMode = .system

    /// 背景色模式
    @AppStorage(Keys.backgroundColorMode)
    var backgroundColorMode: BackgroundColorMode = .followTheme

    /// 自定义背景色（十六进制字符串）
    @AppStorage(Keys.customBackgroundColor)
    var customBackgroundColorHex: String = "1C1C1E"

    /// 自定义背景色
    var customBackgroundColor: Color {
        get { Color(hex: customBackgroundColorHex) }
        set { customBackgroundColorHex = newValue.toHex() }
    }

    /// 获取当前有效的背景色
    func effectiveBackgroundColor(for colorScheme: ColorScheme) -> Color {
        switch backgroundColorMode {
        case .followTheme:
            // 跟随主题：亮色用窗口背景色，暗色用深色背景
            colorScheme == .dark
                ? Color(NSColor.windowBackgroundColor)
                : Color(NSColor.windowBackgroundColor)
        case .custom:
            customBackgroundColor
        }
    }

    // MARK: - Capture Settings

    /// 捕获帧率
    @AppStorage(Keys.captureFrameRate)
    var captureFrameRate: Int = 60

    // MARK: - scrcpy Settings

    /// 码率（Mbps）
    @AppStorage(Keys.scrcpyBitrate)
    var scrcpyBitrate: Int = 8

    /// 最大分辨率
    @AppStorage(Keys.scrcpyMaxSize)
    var scrcpyMaxSize: Int = 1920

    /// 显示触摸点
    @AppStorage(Keys.scrcpyShowTouches)
    var scrcpyShowTouches: Bool = true

    // MARK: - Private Init

    private init() {}

    // MARK: - scrcpy 配置生成

    /// 生成 scrcpy 配置
    func generateScrcpyConfig() -> ScrcpyConfig {
        var config = ScrcpyConfig()
        config.bitrate = "\(scrcpyBitrate)M"
        config.maxSize = scrcpyMaxSize
        config.maxFps = captureFrameRate
        config.stayAwake = true
        return config
    }

    /// 为特定设备构建 scrcpy 配置
    func buildScrcpyConfiguration(serial: String) -> ScrcpyConfiguration {
        ScrcpyConfiguration(
            serial: serial,
            maxSize: scrcpyMaxSize,
            bitrate: scrcpyBitrate * 1_000_000,
            maxFps: captureFrameRate,
            showTouches: scrcpyShowTouches,
            stayAwake: true
        )
    }
}

// MARK: - AppStorage Extensions for Custom Types

extension SplitLayout: RawRepresentable {
    init?(rawValue: String) {
        switch rawValue {
        case "sideBySide": self = .sideBySide
        case "topBottom": self = .topBottom
        default: return nil
        }
    }
}

extension ThemeMode: RawRepresentable {
    init?(rawValue: String) {
        switch rawValue {
        case "system": self = .system
        case "light": self = .light
        case "dark": self = .dark
        default: return nil
        }
    }
}

extension BackgroundColorMode: RawRepresentable {
    init?(rawValue: String) {
        switch rawValue {
        case "followTheme": self = .followTheme
        case "custom": self = .custom
        default: return nil
        }
    }
}

// MARK: - Color Hex Extension

extension Color {
    /// 从十六进制字符串创建颜色
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xf) * 17, (int & 0xf) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xff, int & 0xff)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xff, int >> 8 & 0xff, int & 0xff)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }

    /// 将颜色转换为十六进制字符串
    func toHex() -> String {
        guard let components = NSColor(self).usingColorSpace(.sRGB)?.cgColor.components else {
            return "000000"
        }
        let r = components.count > 0 ? components[0] : 0
        let g = components.count > 1 ? components[1] : 0
        let b = components.count > 2 ? components[2] : 0
        return String(format: "%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
