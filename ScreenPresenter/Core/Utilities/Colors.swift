//
//  Colors.swift
//  ScreenPresenter
//
//  Created by Sun on 2025/12/23.
//
//  应用颜色定义
//  统一管理应用中使用的颜色
//

import AppKit

// MARK: - 应用颜色

extension NSColor {
    /// 应用主题色（从 Assets.xcassets 中获取）
    static var appAccent: NSColor {
        NSColor(named: "AccentColor") ?? .controlAccentColor
    }
}
