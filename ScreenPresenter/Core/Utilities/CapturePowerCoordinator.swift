//
//  CapturePowerCoordinator.swift
//  ScreenPresenter
//
//  Created by Sun on 2025/1/4.
//
//  协调捕获状态与休眠阻止
//  监听设置变化与捕获状态，自动管理 SystemSleepBlocker
//

import Combine
import Foundation

// MARK: - 捕获电源协调器

/// 捕获电源协调器
/// 监听设置与捕获状态，自动管理 SystemSleepBlocker
@MainActor
final class CapturePowerCoordinator {

    // MARK: - Singleton

    static let shared = CapturePowerCoordinator()

    // MARK: - Properties

    private var cancellables = Set<AnyCancellable>()
    private let blocker = SystemSleepBlocker.shared
    private let preferences = UserPreferences.shared

    // MARK: - Init

    private init() {
        setupObservers()
    }

    // MARK: - Setup

    private func setupObservers() {
        // 监听设置变化
        NotificationCenter.default.publisher(for: .preventAutoLockSettingDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.evaluateAndUpdate()
            }
            .store(in: &cancellables)

        // 监听 AppState 状态变化（包含捕获状态变化）
        AppState.shared.stateChangedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.evaluateAndUpdate()
            }
            .store(in: &cancellables)
    }

    // MARK: - Core Logic

    /// 评估当前状态并更新 blocker
    func evaluateAndUpdate() {
        let shouldBlock = preferences.preventAutoLockDuringCapture && isAnyDeviceCapturing

        AppLogger.app.debug(
            "CapturePowerCoordinator 评估: shouldBlock=\(shouldBlock), " +
            "设置=\(preferences.preventAutoLockDuringCapture), " +
            "iOS捕获=\(AppState.shared.iosCapturing), " +
            "Android捕获=\(AppState.shared.androidCapturing)"
        )

        if shouldBlock {
            blocker.enable(reason: "ScreenPresenter 正在捕获画面")
        } else {
            blocker.disable()
        }
    }

    /// 是否有任一设备正在捕获
    private var isAnyDeviceCapturing: Bool {
        AppState.shared.iosCapturing || AppState.shared.androidCapturing
    }

    // MARK: - Lifecycle

    /// 应用启动时调用
    func start() {
        evaluateAndUpdate()
        AppLogger.app.info("CapturePowerCoordinator 已启动")
    }

    /// 应用退出时调用
    func stop() {
        blocker.disable()
        AppLogger.app.info("CapturePowerCoordinator 已停止")
    }
}
