//
//  SystemSleepBlocker.swift
//  ScreenPresenter
//
//  Created by Sun on 2025/1/4.
//
//  禁止系统自动休眠/锁屏
//  使用 IOKit 的 IOPMAssertion API
//
//  边界说明：
//  - 使用 IOPMAssertionTypePreventUserIdleDisplaySleep：阻止显示器自动休眠
//  - 不修改任何系统设置，仅在 app 运行期间生效
//  - 不阻止用户手动锁屏（⌘+Ctrl+Q）
//  - IOPMAssertion 在进程结束时自动回收
//  - 可在 Activity Monitor → Energy 中观察 "Preventing Sleep" 状态
//

import Foundation
import IOKit.pwr_mgt

// MARK: - 系统休眠阻止器

/// 系统休眠阻止器
/// 用于在捕获期间阻止系统自动休眠/锁屏
final class SystemSleepBlocker {

    // MARK: - Singleton

    static let shared = SystemSleepBlocker()

    // MARK: - Properties

    /// 当前 assertion ID（0 表示未激活）
    private var assertionID: IOPMAssertionID = 0

    /// 是否已启用
    private(set) var isEnabled: Bool = false

    // MARK: - Init

    private init() {}

    // MARK: - Public Methods

    /// 启用休眠阻止
    /// - Parameter reason: 阻止原因（显示在 Activity Monitor 中）
    func enable(reason: String = "ScreenPresenter capturing screen") {
        // 幂等：已启用则不重复操作
        guard !isEnabled else { return }

        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )

        if result == kIOReturnSuccess {
            isEnabled = true
        }
    }

    /// 禁用休眠阻止
    func disable() {
        // 幂等：未启用则不操作
        guard isEnabled, assertionID != 0 else { return }

        let result = IOPMAssertionRelease(assertionID)

        if result == kIOReturnSuccess {
            isEnabled = false
            assertionID = 0
        }
    }
}
