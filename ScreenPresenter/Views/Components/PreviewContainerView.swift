//
//  PreviewContainerView.swift
//  ScreenPresenter
//
//  Created by Sun on 2025/12/25.
//
//  预览容器视图
//  管理设备面板的布局，支持多种布局模式
//

import AppKit
import SnapKit

// MARK: - 布局模式

enum PreviewLayoutMode: String, CaseIterable {
    /// 双设备并排显示（默认）
    case dual
    /// 仅显示左侧设备
    case leftOnly
    /// 仅显示右侧设备
    case rightOnly

    /// 显示名称
    var displayName: String {
        switch self {
        case .dual: L10n.layout.dual
        case .leftOnly: L10n.layout.leftOnly
        case .rightOnly: L10n.layout.rightOnly
        }
    }

    /// SF Symbol 图标名称
    var iconName: String {
        switch self {
        case .dual: "rectangle.split.2x1"
        case .leftOnly: "rectangle.lefthalf.filled"
        case .rightOnly: "rectangle.righthalf.filled"
        }
    }
}

// MARK: - 预览容器视图

final class PreviewContainerView: NSView {
    // MARK: - UI 组件

    /// 左侧区域容器
    private var leftAreaView: NSView!
    /// 右侧区域容器
    private var rightAreaView: NSView!

    /// iOS 设备面板（默认在左侧）
    private(set) var iosPanelView: DevicePanelView!
    /// Android 设备面板（默认在右侧）
    private(set) var androidPanelView: DevicePanelView!

    /// 交换按钮
    private(set) var swapButton: NSButton!
    private var swapButtonIconLayer: CALayer!

    // MARK: - 状态

    /// 当前布局模式
    private(set) var layoutMode: PreviewLayoutMode = UserPreferences.shared.layoutMode

    /// 是否交换了左右面板
    private(set) var isSwapped: Bool = false

    /// 是否全屏模式
    var isFullScreen: Bool = false {
        didSet {
            if oldValue != isFullScreen {
                updateLayout(animated: false)
            }
        }
    }

    /// 是否首次布局
    private var isInitialLayout: Bool = true
    private var swapButtonAppearWorkItem: DispatchWorkItem?

    // MARK: - 常量

    /// 非全屏时的垂直内边距
    private let verticalPadding: CGFloat = 24

    // MARK: - 回调

    /// 交换按钮点击回调
    var onSwapTapped: (() -> Void)?

    // MARK: - 初始化

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    // MARK: - UI 设置

    private func setupUI() {
        wantsLayer = true

        setupAreaViews()
        setupDevicePanels()
        setupSwapButton()

        // 根据初始 layoutMode 设置 UI 状态
        updateAreaVisibility()
    }

    private func setupAreaViews() {
        // 左侧区域容器
        leftAreaView = NSView()
        addSubview(leftAreaView)
        leftAreaView.snp.makeConstraints { make in
            make.top.bottom.leading.equalToSuperview()
            make.width.equalToSuperview().multipliedBy(0.5)
        }

        // 右侧区域容器
        rightAreaView = NSView()
        addSubview(rightAreaView)
        rightAreaView.snp.makeConstraints { make in
            make.top.bottom.trailing.equalToSuperview()
            make.width.equalToSuperview().multipliedBy(0.5)
        }
    }

    private func setupDevicePanels() {
        // iOS 面板（默认在左侧）
        iosPanelView = DevicePanelView()
        addSubview(iosPanelView)

        // Android 面板（默认在右侧）
        androidPanelView = DevicePanelView()
        addSubview(androidPanelView)
    }

    private func setupSwapButton() {
        swapButton = NSButton(title: "", target: self, action: #selector(swapTapped))
        swapButton.bezelStyle = .circular
        swapButton.isBordered = false
        swapButton.wantsLayer = true
        swapButton.layer?.cornerRadius = 16
        swapButton.toolTip = L10n.toolbar.swapTooltip
        swapButton.focusRingType = .none
        swapButton.refusesFirstResponder = true
        addSubview(swapButton)

        // 添加图标图层
        swapButtonIconLayer = CALayer()
        swapButtonIconLayer.contentsGravity = .resizeAspect
        swapButton.layer?.addSublayer(swapButtonIconLayer)

        // 设置图标大小和位置
        let iconSize: CGFloat = 16
        let buttonSize: CGFloat = 32
        let iconOffset = (buttonSize - iconSize) / 2
        swapButtonIconLayer.frame = CGRect(x: iconOffset, y: iconOffset, width: iconSize, height: iconSize)

        // 设置初始样式
        updateSwapButtonStyle()

        // 交换按钮约束
        swapButton.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.centerY.equalToSuperview()
            make.width.height.equalTo(32)
        }
    }

    private func updateSwapButtonStyle() {
        guard let layer = swapButton.layer else { return }

        // 根据全屏状态确定图标颜色
        let iconColor: NSColor = isFullScreen ? .white : NSColor(white: 0.3, alpha: 1.0)
        let swapIconConfig = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            .applying(.init(paletteColors: [iconColor]))

        if isFullScreen {
            // 全屏时使用暗色样式
            layer.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
            layer.borderColor = NSColor.white.withAlphaComponent(0.4).cgColor
            layer.borderWidth = 1
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.5
            layer.shadowOffset = CGSize(width: 0, height: -1)
            layer.shadowRadius = 4
        } else {
            // 非全屏时使用浅色样式
            layer.backgroundColor = NSColor(white: 0.95, alpha: 1.0).cgColor
            layer.borderColor = NSColor(white: 0.8, alpha: 1.0).cgColor
            layer.borderWidth = 1
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.1
            layer.shadowOffset = CGSize(width: 0, height: -1)
            layer.shadowRadius = 2
        }

        swapButtonIconLayer.contents = NSImage(
            systemSymbolName: "arrow.left.arrow.right",
            accessibilityDescription: L10n.toolbar.swapTooltip
        )?.withSymbolConfiguration(swapIconConfig)
    }

    // MARK: - 公开方法

    /// 设置布局模式
    func setLayoutMode(_ mode: PreviewLayoutMode, animated: Bool = true) {
        guard layoutMode != mode else { return }
        let oldMode = layoutMode
        layoutMode = mode
        updateLayoutWithModeTransition(from: oldMode, to: mode, animated: animated)
    }

    /// 交换左右面板
    func swapPanels(animated: Bool = true) {
        isSwapped.toggle()
        swapButton.alphaValue = 0
        updateLayout(animated: animated)
    }

    /// 更新布局
    func updateLayout(animated: Bool = true) {
        // 更新按钮样式
        updateSwapButtonStyle()

        // 更新区域可见性
        updateAreaVisibility()

        // 根据交换状态决定哪个面板在哪个区域
        // 默认 (isSwapped=false): iOS 在左侧，Android 在右侧
        // 交换后 (isSwapped=true): Android 在左侧，iOS 在右侧
        let currentLeftPanel = isSwapped ? androidPanelView! : iosPanelView!
        let currentRightPanel = isSwapped ? iosPanelView! : androidPanelView!

        // 计算垂直内边距
        let vPadding: CGFloat = isFullScreen ? 0 : verticalPadding
        let showBezel = UserPreferences.shared.showDeviceBezel
        let shouldFillHeight = isFullScreen && !showBezel

        // 获取设备的 aspectRatio（宽/高）
        let leftAspectRatio = currentLeftPanel.deviceAspectRatio
        let rightAspectRatio = currentRightPanel.deviceAspectRatio

        // 重置面板约束（不移动视图层级，只更新约束）
        currentLeftPanel.snp.remakeConstraints { make in
            if shouldFillHeight {
                make.top.bottom.equalTo(leftAreaView)
            } else {
                make.top.equalTo(leftAreaView).offset(vPadding)
                make.bottom.equalTo(leftAreaView).offset(-vPadding)
            }
            // 宽度 = 高度 * aspectRatio
            make.width.equalTo(currentLeftPanel.snp.height).multipliedBy(leftAspectRatio)
            // 在区域内水平居中，右侧留出 gap/2 的间隔
            make.centerX.equalTo(leftAreaView)
            // 确保不超出区域边界
            make.leading.greaterThanOrEqualTo(leftAreaView)
            make.trailing.lessThanOrEqualTo(leftAreaView)
        }

        currentRightPanel.snp.remakeConstraints { make in
            if shouldFillHeight {
                make.top.bottom.equalTo(rightAreaView)
            } else {
                make.top.equalTo(rightAreaView).offset(vPadding)
                make.bottom.equalTo(rightAreaView).offset(-vPadding)
            }
            // 宽度 = 高度 * aspectRatio
            make.width.equalTo(currentRightPanel.snp.height).multipliedBy(rightAspectRatio)
            // 在区域内水平居中，左侧留出 gap/2 的间隔
            make.centerX.equalTo(rightAreaView)
            // 确保不超出区域边界
            make.leading.greaterThanOrEqualTo(rightAreaView)
            make.trailing.lessThanOrEqualTo(rightAreaView)
        }

        // 执行布局更新
        if isInitialLayout || !animated {
            isInitialLayout = false
            swapButton.alphaValue = 1
            layoutSubtreeIfNeeded()
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                context.completionHandler = { [weak self] in
                    NSAnimationContext.runAnimationGroup { swapContext in
                        swapContext.duration = 0.3
                        swapContext.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        swapContext.allowsImplicitAnimation = true
                        self?.swapButton.alphaValue = 1
                    }
                }
                layoutSubtreeIfNeeded()
            }
        }
    }

    /// 更新 bezel 可见性
    func updateBezelVisibility() {
        let showBezel = UserPreferences.shared.showDeviceBezel
        iosPanelView.setBezelVisible(showBezel)
        androidPanelView.setBezelVisible(showBezel)
        updateLayout(animated: false)
    }

    /// 更新本地化文本
    func updateLocalizedTexts() {
        swapButton.toolTip = L10n.toolbar.swapTooltip

        // 根据全屏状态确定图标颜色
        let iconColor: NSColor = isFullScreen ? .white : NSColor(white: 0.3, alpha: 1.0)
        let swapIconConfig = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            .applying(.init(paletteColors: [iconColor]))

        swapButtonIconLayer.contents = NSImage(
            systemSymbolName: "arrow.left.arrow.right",
            accessibilityDescription: L10n.toolbar.swapTooltip
        )?.withSymbolConfiguration(swapIconConfig)

        iosPanelView.updateLocalizedTexts()
        androidPanelView.updateLocalizedTexts()
    }

    // MARK: - 私有方法

    /// 更新区域可见性和约束（无动画时使用）
    private func updateAreaVisibility() {
        updateAreaConstraints()
        updatePanelVisibility()
    }

    /// 仅更新区域约束（动画时使用，不修改 isHidden）
    private func updateAreaConstraints() {
        if layoutMode != .dual {
            cancelSwapButtonAppearance()
        }
        switch layoutMode {
        case .dual:
            leftAreaView.isHidden = false
            rightAreaView.isHidden = false
            swapButton.isHidden = false
            // 恢复左右各占一半的布局
            leftAreaView.snp.remakeConstraints { make in
                make.top.bottom.leading.equalToSuperview()
                make.width.equalToSuperview().multipliedBy(0.5)
            }
            rightAreaView.snp.remakeConstraints { make in
                make.top.bottom.trailing.equalToSuperview()
                make.width.equalToSuperview().multipliedBy(0.5)
            }

        case .leftOnly:
            leftAreaView.isHidden = false
            rightAreaView.isHidden = true
            swapButton.isHidden = true
            // 左侧区域占满整个容器
            leftAreaView.snp.remakeConstraints { make in
                make.edges.equalToSuperview()
            }

        case .rightOnly:
            leftAreaView.isHidden = true
            rightAreaView.isHidden = false
            swapButton.isHidden = true
            // 右侧区域占满整个容器
            rightAreaView.snp.remakeConstraints { make in
                make.edges.equalToSuperview()
            }
        }
    }

    /// 仅更新面板可见性（根据当前 layoutMode）
    private func updatePanelVisibility() {
        let leftPanel = isSwapped ? androidPanelView! : iosPanelView!
        let rightPanel = isSwapped ? iosPanelView! : androidPanelView!

        switch layoutMode {
        case .dual:
            leftPanel.isHidden = false
            rightPanel.isHidden = false
        case .leftOnly:
            leftPanel.isHidden = false
            rightPanel.isHidden = true
        case .rightOnly:
            leftPanel.isHidden = true
            rightPanel.isHidden = false
        }
    }

    @objc private func swapTapped() {
        swapPanels()
        onSwapTapped?()
    }

    /// 处理布局模式切换的动画
    private func updateLayoutWithModeTransition(
        from oldMode: PreviewLayoutMode,
        to newMode: PreviewLayoutMode,
        animated: Bool
    ) {
        // 根据交换状态确定哪个面板在左侧/右侧
        let leftPanel = isSwapped ? androidPanelView! : iosPanelView!
        let rightPanel = isSwapped ? iosPanelView! : androidPanelView!

        if !animated {
            updateLayout(animated: false)
            return
        }

        // 动画参数
        let duration: TimeInterval = 0.3
        let offsetDistance: CGFloat = 60

        switch (oldMode, newMode) {
        case (.dual, .leftOnly):
            // 双设备 -> 仅左侧：右侧面板滑出淡出，左侧面板移动到居中
            animateDualToSingle(
                hidingPanel: rightPanel,
                stayingPanel: leftPanel,
                hideToRight: true,
                duration: duration,
                offsetDistance: offsetDistance
            )

        case (.dual, .rightOnly):
            // 双设备 -> 仅右侧：左侧面板滑出淡出，右侧面板移动到居中
            animateDualToSingle(
                hidingPanel: leftPanel,
                stayingPanel: rightPanel,
                hideToRight: false,
                duration: duration,
                offsetDistance: offsetDistance
            )

        case (.leftOnly, .dual):
            // 仅左侧 -> 双设备：左侧面板移动到半边，右侧面板滑入淡入
            animateSingleToDual(
                stayingPanel: leftPanel,
                enteringPanel: rightPanel,
                enterFromRight: true,
                duration: duration,
                offsetDistance: offsetDistance,
                swapButtonDelay: 0.12
            )

        case (.rightOnly, .dual):
            // 仅右侧 -> 双设备：右侧面板移动到半边，左侧面板滑入淡入
            animateSingleToDual(
                stayingPanel: rightPanel,
                enteringPanel: leftPanel,
                enterFromRight: false,
                duration: duration,
                offsetDistance: offsetDistance,
                swapButtonDelay: 0.12
            )

        case (.leftOnly, .rightOnly):
            // 仅左侧 -> 仅右侧：左侧滑出淡出，右侧滑入淡入（同时）
            animateSingleToSingle(
                hidingPanel: leftPanel,
                showingPanel: rightPanel,
                hideToRight: oldMode == .rightOnly,
                showFromRight: newMode == .rightOnly,
                duration: duration,
                offsetDistance: offsetDistance
            )

        case (.rightOnly, .leftOnly):
            // 仅右侧 -> 仅左侧：右侧滑出淡出，左侧滑入淡入（同时）
            animateSingleToSingle(
                hidingPanel: rightPanel,
                showingPanel: leftPanel,
                hideToRight: oldMode == .rightOnly,
                showFromRight: newMode == .rightOnly,
                duration: duration,
                offsetDistance: offsetDistance
            )

        default:
            updateLayout(animated: animated)
        }
    }

    // MARK: - 手动计算面板 Frame

    /// 计算面板在指定区域内居中的 frame
    /// - Parameters:
    ///   - panel: 面板视图
    ///   - areaRect: 区域矩形
    /// - Returns: 计算后的 frame
    private func calculatePanelFrame(for panel: DevicePanelView, in areaRect: CGRect) -> CGRect {
        let vPadding: CGFloat = isFullScreen ? 0 : verticalPadding
        let showBezel = UserPreferences.shared.showDeviceBezel
        let shouldFillHeight = isFullScreen && !showBezel

        // 计算可用高度
        let availableHeight = shouldFillHeight ? areaRect.height : (areaRect.height - vPadding * 2)

        // 计算面板尺寸（基于高度和宽高比）
        let aspectRatio = panel.deviceAspectRatio
        let panelHeight = availableHeight
        let panelWidth = panelHeight * aspectRatio

        // 确保不超出区域宽度
        let finalWidth = min(panelWidth, areaRect.width)
        let finalHeight = finalWidth / aspectRatio

        // 计算居中位置
        let x = areaRect.origin.x + (areaRect.width - finalWidth) / 2
        let y = areaRect.origin.y + (areaRect.height - finalHeight) / 2

        return CGRect(x: x, y: y, width: finalWidth, height: finalHeight)
    }

    /// 计算双设备模式下左侧区域的矩形
    private func leftAreaRectForDualMode() -> CGRect {
        CGRect(x: 0, y: 0, width: bounds.width / 2, height: bounds.height)
    }

    /// 计算双设备模式下右侧区域的矩形
    private func rightAreaRectForDualMode() -> CGRect {
        CGRect(x: bounds.width / 2, y: 0, width: bounds.width / 2, height: bounds.height)
    }

    /// 计算单设备模式下的区域矩形（占满整个容器）
    private func areaRectForSingleMode() -> CGRect {
        bounds
    }

    // MARK: - 动画方法

    /// 双设备 -> 单设备的动画
    /// - hidingPanel: 要隐藏的面板（位移+淡出）
    /// - stayingPanel: 保留的面板（位移）
    private func animateDualToSingle(
        hidingPanel: DevicePanelView,
        stayingPanel: DevicePanelView,
        hideToRight: Bool,
        duration: TimeInterval,
        offsetDistance: CGFloat
    ) {
        cancelSwapButtonAppearance()
        swapButton.isHidden = true
        swapButton.alphaValue = 0

        preparePanelsForManualAnimation()

        // 1. 记录初始位置
        let hidingPanelStartFrame = hidingPanel.frame
        let stayingPanelStartFrame = stayingPanel.frame

        // 2. 手动计算目标位置
        // 保留面板的目标位置：在整个容器内居中
        let stayingPanelEndFrame = calculatePanelFrame(for: stayingPanel, in: areaRectForSingleMode())

        // 隐藏面板的目标位置：从初始位置向外滑出
        let hideOffset = hideToRight ? offsetDistance : -offsetDistance
        let hidingPanelEndFrame = hidingPanelStartFrame.offsetBy(dx: hideOffset, dy: 0)

        // 3. 更新 swapButton 样式
        updateSwapButtonStyle()

        // 4. 使用 CATransaction 确保 frame 立即生效
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hidingPanel.frame = hidingPanelStartFrame
        stayingPanel.frame = stayingPanelStartFrame
        CATransaction.commit()

        // 5. 执行动画
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true

            // 隐藏面板：位移 + 淡出
            hidingPanel.animator().frame = hidingPanelEndFrame
            hidingPanel.animator().alphaValue = 0

            // 保留面板：位移
            stayingPanel.animator().frame = stayingPanelEndFrame
        } completionHandler: {
            hidingPanel.isHidden = true
            hidingPanel.alphaValue = 1
            // 动画完成后更新约束
            self.updateAreaConstraints()
            self.updatePanelConstraints()
            self.layoutSubtreeIfNeeded()
        }
    }

    /// 单设备 -> 双设备的动画
    /// - stayingPanel: 当前显示的面板（位移）
    /// - enteringPanel: 要进入的面板（位移+淡入）
    private func animateSingleToDual(
        stayingPanel: DevicePanelView,
        enteringPanel: DevicePanelView,
        enterFromRight: Bool,
        duration: TimeInterval,
        offsetDistance: CGFloat,
        swapButtonDelay: TimeInterval
    ) {
        preparePanelsForManualAnimation()
        elevatePanel(enteringPanel, above: stayingPanel)

        // 1. 记录保留面板的初始位置
        let stayingPanelStartFrame = stayingPanel.frame

        // 2. 手动计算目标位置
        let leftAreaRect = leftAreaRectForDualMode()
        let rightAreaRect = rightAreaRectForDualMode()

        // 根据 enterFromRight 决定哪个面板在哪个区域
        let stayingPanelEndFrame: CGRect
        let enteringPanelEndFrame: CGRect

        if enterFromRight {
            // 进入面板从右侧进入，保留面板在左侧
            stayingPanelEndFrame = calculatePanelFrame(for: stayingPanel, in: leftAreaRect)
            enteringPanelEndFrame = calculatePanelFrame(for: enteringPanel, in: rightAreaRect)
        } else {
            // 进入面板从左侧进入，保留面板在右侧
            stayingPanelEndFrame = calculatePanelFrame(for: stayingPanel, in: rightAreaRect)
            enteringPanelEndFrame = calculatePanelFrame(for: enteringPanel, in: leftAreaRect)
        }

        // 3. 计算进入面板的初始位置（从外部滑入）
        let enterOffset = enterFromRight ? offsetDistance : -offsetDistance
        let enteringPanelStartFrame = enteringPanelEndFrame.offsetBy(dx: enterOffset, dy: 0)

        // 4. 更新 swapButton 样式
        updateSwapButtonStyle()

        // 5. 先显示进入面板（透明状态），设置初始位置
        enteringPanel.isHidden = false
        enteringPanel.alphaValue = 0

        // 6. 使用 CATransaction 确保 frame 立即生效
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        enteringPanel.frame = enteringPanelStartFrame
        stayingPanel.frame = stayingPanelStartFrame
        CATransaction.commit()

        // 7. 执行动画
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true

            // 存在的面板：位移
            stayingPanel.animator().frame = stayingPanelEndFrame

            // 出现的面板：位移 + 淡入
            enteringPanel.animator().frame = enteringPanelEndFrame
            enteringPanel.animator().alphaValue = 1
        } completionHandler: {
            // 动画完成后更新约束
            self.updateAreaConstraints()
            self.updatePanelConstraints()
            self.layoutSubtreeIfNeeded()
            self.scheduleSwapButtonAppearance(after: swapButtonDelay)
        }
    }

    /// 单设备 -> 另一个单设备的动画
    /// - hidingPanel: 消失的面板（位移+淡出）
    /// - showingPanel: 出现的面板（位移+淡入）
    private func animateSingleToSingle(
        hidingPanel: DevicePanelView,
        showingPanel: DevicePanelView,
        hideToRight: Bool,
        showFromRight: Bool,
        duration: TimeInterval,
        offsetDistance: CGFloat
    ) {
        preparePanelsForManualAnimation()
        elevatePanel(showingPanel, above: hidingPanel)

        // 1. 记录隐藏面板的初始位置
        let hidingPanelStartFrame = hidingPanel.frame

        // 2. 手动计算目标位置
        // 显示面板的目标位置：在整个容器内居中
        let showingPanelEndFrame = calculatePanelFrame(for: showingPanel, in: areaRectForSingleMode())

        // 隐藏面板的目标位置：从初始位置向外滑出
        let hideOffset = hideToRight ? offsetDistance : -offsetDistance
        let hidingPanelEndFrame = hidingPanelStartFrame.offsetBy(dx: hideOffset, dy: 0)

        // 显示面板的初始位置：从外部滑入
        let showOffset = showFromRight ? offsetDistance : -offsetDistance
        let showingPanelStartFrame = showingPanelEndFrame.offsetBy(dx: showOffset, dy: 0)

        // 3. 更新 swapButton 样式
        updateSwapButtonStyle()

        // 4. 先显示面板（透明状态）
        showingPanel.isHidden = false
        showingPanel.alphaValue = 0

        // 5. 使用 CATransaction 确保 frame 立即生效
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        showingPanel.frame = showingPanelStartFrame
        hidingPanel.frame = hidingPanelStartFrame
        CATransaction.commit()

        // 6. 执行动画
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true

            // 消失的面板：位移 + 淡出
            hidingPanel.animator().frame = hidingPanelEndFrame
            hidingPanel.animator().alphaValue = 0

            // 出现的面板：位移 + 淡入
            showingPanel.animator().frame = showingPanelEndFrame
            showingPanel.animator().alphaValue = 1
        } completionHandler: {
            hidingPanel.isHidden = true
            hidingPanel.alphaValue = 1
            // 动画完成后更新约束
            self.updateAreaConstraints()
            self.updatePanelConstraints()
            self.layoutSubtreeIfNeeded()
        }
    }

    /// 更新面板约束（不执行布局）
    private func updatePanelConstraints() {
        let currentLeftPanel = isSwapped ? androidPanelView! : iosPanelView!
        let currentRightPanel = isSwapped ? iosPanelView! : androidPanelView!

        let vPadding: CGFloat = isFullScreen ? 0 : verticalPadding
        let showBezel = UserPreferences.shared.showDeviceBezel
        let shouldFillHeight = isFullScreen && !showBezel

        let leftAspectRatio = currentLeftPanel.deviceAspectRatio
        let rightAspectRatio = currentRightPanel.deviceAspectRatio

        currentLeftPanel.snp.remakeConstraints { make in
            if shouldFillHeight {
                make.top.bottom.equalTo(leftAreaView)
            } else {
                make.top.equalTo(leftAreaView).offset(vPadding)
                make.bottom.equalTo(leftAreaView).offset(-vPadding)
            }
            make.width.equalTo(currentLeftPanel.snp.height).multipliedBy(leftAspectRatio)
            make.centerX.equalTo(leftAreaView)
            make.leading.greaterThanOrEqualTo(leftAreaView)
            make.trailing.lessThanOrEqualTo(leftAreaView)
        }

        currentRightPanel.snp.remakeConstraints { make in
            if shouldFillHeight {
                make.top.bottom.equalTo(rightAreaView)
            } else {
                make.top.equalTo(rightAreaView).offset(vPadding)
                make.bottom.equalTo(rightAreaView).offset(-vPadding)
            }
            make.width.equalTo(currentRightPanel.snp.height).multipliedBy(rightAspectRatio)
            make.centerX.equalTo(rightAreaView)
            make.leading.greaterThanOrEqualTo(rightAreaView)
            make.trailing.lessThanOrEqualTo(rightAreaView)
        }
    }

    private func preparePanelsForManualAnimation() {
        iosPanelView.snp.removeConstraints()
        androidPanelView.snp.removeConstraints()
        layoutSubtreeIfNeeded()
    }

    private func elevatePanel(_ panel: DevicePanelView, above sibling: DevicePanelView) {
        guard let superview = panel.superview, panel !== sibling else { return }
        superview.addSubview(panel, positioned: .above, relativeTo: sibling)
    }

    private func scheduleSwapButtonAppearance(after delay: TimeInterval) {
        cancelSwapButtonAppearance()
        guard layoutMode == .dual else { return }
        swapButton.isHidden = false
        swapButton.alphaValue = 0

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.layoutMode == .dual else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                self.swapButton.animator().alphaValue = 1
            }
        }
        swapButtonAppearWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelSwapButtonAppearance() {
        swapButtonAppearWorkItem?.cancel()
        swapButtonAppearWorkItem = nil
    }
}
