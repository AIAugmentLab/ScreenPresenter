//
//  PreferencesWindowController.swift
//  ScreenPresenter
//
//  Created by Sun on 2025/12/22.
//
//  偏好设置窗口控制器
//  包含四个 Tab：
//  - 通用（语言、外观、布局、连接）
//  - 捕获（帧率设置）
//  - Scrcpy（视频、显示、高级）
//  - 权限（系统权限、工具链）
//

import AppKit
import AVFoundation
import SnapKit

// MARK: - 偏好设置窗口控制器

final class PreferencesWindowController: NSWindowController {
    // MARK: - 单例

    static let shared: PreferencesWindowController = {
        let controller = PreferencesWindowController()
        return controller
    }()

    // MARK: - 初始化

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.window.preferences
        window.titlebarSeparatorStyle = .none
        window.titlebarAppearsTransparent = true
        window.center()
        // 禁用初始焦点，避免显示 tab 焦点环
        window.initialFirstResponder = nil
        window.autorecalculatesKeyViewLoop = false

        // 添加空 toolbar 以匹配主窗口风格（影响 titlebar 和圆角）
        let toolbar = NSToolbar(identifier: "PreferencesToolbar")
        toolbar.displayMode = .iconOnly
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar

        self.init(window: window)

        window.contentViewController = PreferencesViewController()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
        // 清除焦点，避免显示焦点环
        window?.makeFirstResponder(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Flipped View（坐标系从上向下）

private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - 偏好设置视图控制器

final class PreferencesViewController: NSViewController {
    // MARK: - UI 组件

    private var segmentedControl: NSSegmentedControl!
    private var contentContainer: NSView!
    private var tabViews: [NSView] = []
    private var currentTabIndex: Int = 0

    // MARK: - 生命周期

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 450))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupLanguageObserver()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupLanguageObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLanguageChange),
            name: LocalizationManager.languageDidChangeNotification,
            object: nil
        )
    }

    @objc private func handleLanguageChange() {
        // 保存当前选中的 tab
        let selectedTab = currentTabIndex

        // 移除所有子视图
        view.subviews.forEach { $0.removeFromSuperview() }
        tabViews.removeAll()

        // 重建 UI
        setupUI()

        // 恢复选中的 tab
        segmentedControl.selectedSegment = selectedTab
        showTab(at: selectedTab)

        // 更新窗口标题
        view.window?.title = L10n.window.preferences
    }

    // MARK: - UI 设置

    private func setupUI() {
        // 创建分段控件
        segmentedControl = NSSegmentedControl(
            labels: [
                L10n.prefs.tab.general,
                L10n.prefs.tab.capture,
                L10n.prefs.tab.scrcpy,
                L10n.prefs.tab.permissions,
            ],
            trackingMode: .selectOne,
            target: self,
            action: #selector(tabChanged(_:))
        )
        segmentedControl.selectedSegment = 0
        segmentedControl.segmentStyle = .automatic
        segmentedControl.focusRingType = .none
        view.addSubview(segmentedControl)
        segmentedControl.snp.makeConstraints { make in
            // 顶部留出 titlebar + toolbar 区域（约 52pt）
            make.top.equalToSuperview().offset(52)
            make.centerX.equalToSuperview()
        }

        // 创建内容容器
        contentContainer = NSView()
        view.addSubview(contentContainer)
        contentContainer.snp.makeConstraints { make in
            make.top.equalTo(segmentedControl.snp.bottom).offset(16)
            make.leading.trailing.bottom.equalToSuperview()
        }

        // 创建各个 tab 的视图
        tabViews = [
            createGeneralView(),
            createCaptureView(),
            createScrcpyView(),
            createPermissionsView(),
        ]

        // 显示第一个 tab
        showTab(at: 0)
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        showTab(at: sender.selectedSegment)
    }

    private func showTab(at index: Int) {
        guard index >= 0, index < tabViews.count else { return }

        // 移除当前显示的视图
        contentContainer.subviews.forEach { $0.removeFromSuperview() }

        // 添加新视图
        let newView = tabViews[index]
        contentContainer.addSubview(newView)
        newView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        currentTabIndex = index
    }

    // MARK: - 通用设置

    private func createGeneralView() -> NSView {
        let scrollView = createScrollView()
        let stackView = createVerticalStack()

        // 语言设置组
        let languageGroup = createSettingsGroup(title: L10n.prefs.section.language, icon: "globe")
        languageGroup.addArrangedSubview(createLabeledRow(label: L10n.prefs.general.language) {
            let popup = NSPopUpButton()
            for language in AppLanguage.allCases {
                popup.addItem(withTitle: language.nativeName)
            }
            let currentIndex = AppLanguage.allCases.firstIndex(of: LocalizationManager.shared.currentLanguage) ?? 0
            popup.selectItem(at: currentIndex)
            popup.target = self
            popup.action = #selector(languageChanged(_:))
            return popup
        })
        addSettingsGroup(languageGroup, to: stackView)

        // 外观设置组
        let appearanceGroup = createSettingsGroup(title: L10n.prefs.section.appearance, icon: "paintbrush")
        appearanceGroup.addArrangedSubview(createLabeledRow(label: L10n.prefs.appearance.backgroundOpacity) {
            let stack = NSStackView()
            stack.orientation = .horizontal
            stack.spacing = 8

            let slider = NSSlider(
                value: UserPreferences.shared.backgroundOpacity,
                minValue: 0,
                maxValue: 1,
                target: self,
                action: #selector(backgroundOpacityChanged(_:))
            )
            slider.snp.makeConstraints { make in
                make.width.equalTo(150).priority(.high)
            }
            slider.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            stack.addArrangedSubview(slider)

            let valueLabel = NSTextField(labelWithString: String(
                format: "%.0f%%",
                UserPreferences.shared.backgroundOpacity * 100
            ))
            valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            valueLabel.tag = 1001 // 用于后续更新
            stack.addArrangedSubview(valueLabel)

            return stack
        })

        // 显示设备边框开关
        let showBezelCheckbox = NSButton(
            checkboxWithTitle: L10n.prefs.appearance.showDeviceBezel,
            target: self,
            action: #selector(showDeviceBezelChanged(_:))
        )
        showBezelCheckbox.state = UserPreferences.shared.showDeviceBezel ? .on : .off
        appearanceGroup.addArrangedSubview(showBezelCheckbox)

        addSettingsGroup(appearanceGroup, to: stackView)

        // 布局设置组
        let layoutGroup = createSettingsGroup(title: L10n.prefs.section.layout, icon: "rectangle.split.2x1")
        layoutGroup.addArrangedSubview(createLabeledRow(label: L10n.prefs.layoutPref.devicePosition) {
            let segmented = NSSegmentedControl(
                labels: [
                    L10n.prefs.layoutPref.iosOnLeft,
                    L10n.prefs.layoutPref.androidOnLeft,
                ],
                trackingMode: .selectOne,
                target: self,
                action: #selector(devicePositionChanged(_:))
            )
            segmented.selectedSegment = UserPreferences.shared.iosOnLeft ? 0 : 1
            return segmented
        })
        addSettingsGroup(layoutGroup, to: stackView)

        // 连接设置组
        let connectionGroup = createSettingsGroup(title: L10n.prefs.section.connection, icon: "cable.connector")
        let autoReconnectCheckbox = NSButton(
            checkboxWithTitle: L10n.prefs.connectionPref.autoReconnect,
            target: self,
            action: #selector(autoReconnectChanged(_:))
        )
        autoReconnectCheckbox.state = UserPreferences.shared.autoReconnect ? .on : .off
        connectionGroup.addArrangedSubview(autoReconnectCheckbox)
        connectionGroup.addArrangedSubview(createLabeledRow(label: L10n.prefs.connectionPref.reconnectDelay) {
            let stack = NSStackView()
            stack.orientation = .horizontal
            stack.spacing = 8
            let stepper = NSStepper()
            stepper.minValue = 1
            stepper.maxValue = 30
            stepper.intValue = Int32(UserPreferences.shared.reconnectDelay)
            stepper.target = self
            stepper.action = #selector(reconnectDelayChanged(_:))
            stepper.tag = 2001 // 用于查找关联的 label
            stack.addArrangedSubview(stepper)
            let label = NSTextField(labelWithString: L10n.prefs.connectionPref
                .seconds(Int(UserPreferences.shared.reconnectDelay)))
            label.tag = 2001
            stack.addArrangedSubview(label)
            return stack
        })
        connectionGroup.addArrangedSubview(createLabeledRow(label: L10n.prefs.connectionPref.maxAttempts) {
            let stack = NSStackView()
            stack.orientation = .horizontal
            stack.spacing = 8
            let stepper = NSStepper()
            stepper.minValue = 1
            stepper.maxValue = 20
            stepper.intValue = Int32(UserPreferences.shared.maxReconnectAttempts)
            stepper.target = self
            stepper.action = #selector(maxAttemptsChanged(_:))
            stepper.tag = 2002 // 用于查找关联的 label
            stack.addArrangedSubview(stepper)
            let label = NSTextField(labelWithString: L10n.prefs.connectionPref
                .times(UserPreferences.shared.maxReconnectAttempts))
            label.tag = 2002
            stack.addArrangedSubview(label)
            return stack
        })
        addSettingsGroup(connectionGroup, to: stackView)

        setupScrollViewConstraints(scrollView: scrollView, contentView: stackView)
        return scrollView
    }

    // MARK: - 捕获设置

    private func createCaptureView() -> NSView {
        let scrollView = createScrollView()
        let stackView = createVerticalStack()

        // 帧率设置组
        let frameRateGroup = createSettingsGroup(title: L10n.prefs.section.frameRate, icon: "speedometer")
        frameRateGroup.addArrangedSubview(createLabeledRow(label: L10n.prefs.capturePref.frameRate) {
            let segmented = NSSegmentedControl(
                labels: ["30 FPS", "60 FPS", "120 FPS"],
                trackingMode: .selectOne,
                target: self,
                action: #selector(frameRateChanged(_:))
            )
            switch UserPreferences.shared.captureFrameRate {
            case 30: segmented.selectedSegment = 0
            case 60: segmented.selectedSegment = 1
            default: segmented.selectedSegment = 2
            }
            return segmented
        })
        let note = NSTextField(labelWithString: L10n.prefs.capturePref.frameRateNote)
        note.font = NSFont.systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        frameRateGroup.addArrangedSubview(note)
        addSettingsGroup(frameRateGroup, to: stackView)

        setupScrollViewConstraints(scrollView: scrollView, contentView: stackView)
        return scrollView
    }

    // MARK: - Scrcpy 设置

    private func createScrcpyView() -> NSView {
        let scrollView = createScrollView()
        let stackView = createVerticalStack()

        // 视频设置组
        let videoGroup = createSettingsGroup(title: L10n.prefs.section.video, icon: "video")
        videoGroup.addArrangedSubview(createLabeledRow(label: L10n.prefs.scrcpyPref.bitrate) {
            let popup = NSPopUpButton()
            popup.addItems(withTitles: [
                L10n.prefs.scrcpyPref.mbps(4),
                L10n.prefs.scrcpyPref.mbps(8),
                L10n.prefs.scrcpyPref.mbps(16),
                L10n.prefs.scrcpyPref.mbps(32),
            ])
            switch UserPreferences.shared.scrcpyBitrate {
            case 4: popup.selectItem(at: 0)
            case 8: popup.selectItem(at: 1)
            case 16: popup.selectItem(at: 2)
            default: popup.selectItem(at: 3)
            }
            popup.target = self
            popup.action = #selector(scrcpyBitrateChanged(_:))
            return popup
        })
        videoGroup.addArrangedSubview(createLabeledRow(label: L10n.prefs.scrcpyPref.maxSize) {
            let popup = NSPopUpButton()
            popup.addItems(withTitles: [
                L10n.prefs.scrcpyPref.noLimit,
                L10n.prefs.scrcpyPref.pixels(1280),
                L10n.prefs.scrcpyPref.pixels(1920),
                L10n.prefs.scrcpyPref.pixels(2560),
            ])
            switch UserPreferences.shared.scrcpyMaxSize {
            case 0: popup.selectItem(at: 0)
            case 1280: popup.selectItem(at: 1)
            case 1920: popup.selectItem(at: 2)
            default: popup.selectItem(at: 3)
            }
            popup.target = self
            popup.action = #selector(scrcpyMaxSizeChanged(_:))
            return popup
        })
        let videoNote = NSTextField(labelWithString: L10n.prefs.scrcpyPref.maxSizeNote)
        videoNote.font = NSFont.systemFont(ofSize: 11)
        videoNote.textColor = .secondaryLabelColor
        videoGroup.addArrangedSubview(videoNote)
        addSettingsGroup(videoGroup, to: stackView)

        // 显示设置组
        let displayGroup = createSettingsGroup(title: L10n.prefs.section.display, icon: "hand.tap")
        let showTouchesCheckbox = NSButton(
            checkboxWithTitle: L10n.prefs.scrcpyPref.showTouches,
            target: self,
            action: #selector(scrcpyShowTouchesChanged(_:))
        )
        showTouchesCheckbox.state = UserPreferences.shared.scrcpyShowTouches ? .on : .off
        displayGroup.addArrangedSubview(showTouchesCheckbox)
        addSettingsGroup(displayGroup, to: stackView)

        // 高级设置组
        let advancedGroup = createSettingsGroup(title: L10n.prefs.section.advanced, icon: "gearshape.2")

        // 使用内置 adb
        let useBundledAdbCheckbox = NSButton(
            checkboxWithTitle: L10n.prefs.scrcpyPref.useBundledAdb,
            target: self,
            action: #selector(useBundledAdbChanged(_:))
        )
        useBundledAdbCheckbox.state = UserPreferences.shared.useBundledAdb ? .on : .off
        advancedGroup.addArrangedSubview(useBundledAdbCheckbox)
        let useBundledAdbNote = NSTextField(labelWithString: L10n.prefs.scrcpyPref.useBundledAdbNote)
        useBundledAdbNote.font = NSFont.systemFont(ofSize: 11)
        useBundledAdbNote.textColor = .secondaryLabelColor
        advancedGroup.addArrangedSubview(useBundledAdbNote)

        // 连接端口
        advancedGroup.addArrangedSubview(createLabeledRow(label: L10n.prefs.scrcpyPref.port) {
            let stack = NSStackView()
            stack.orientation = .horizontal
            stack.spacing = 8
            let textField = NSTextField()
            textField.stringValue = String(UserPreferences.shared.scrcpyPort)
            textField.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            textField.alignment = .center
            textField.snp.makeConstraints { make in
                make.width.equalTo(70)
            }
            textField.target = self
            textField.action = #selector(scrcpyPortChanged(_:))
            textField.tag = 3001
            stack.addArrangedSubview(textField)

            let stepper = NSStepper()
            stepper.minValue = 1024
            stepper.maxValue = 65535
            stepper.intValue = Int32(UserPreferences.shared.scrcpyPort)
            stepper.target = self
            stepper.action = #selector(scrcpyPortStepperChanged(_:))
            stepper.tag = 3001
            stack.addArrangedSubview(stepper)
            return stack
        })

        // 视频编解码器
        advancedGroup.addArrangedSubview(createLabeledRow(label: L10n.prefs.scrcpyPref.codec) {
            let popup = NSPopUpButton()
            for codec in ScrcpyCodecType.allCases {
                popup.addItem(withTitle: codec.displayName)
            }
            let currentIndex = ScrcpyCodecType.allCases.firstIndex(of: UserPreferences.shared.scrcpyCodec) ?? 0
            popup.selectItem(at: currentIndex)
            popup.target = self
            popup.action = #selector(scrcpyCodecChanged(_:))
            return popup
        })

        let advancedNote = NSTextField(labelWithString: L10n.prefs.scrcpyPref.advancedNote)
        advancedNote.font = NSFont.systemFont(ofSize: 11)
        advancedNote.textColor = .secondaryLabelColor
        advancedGroup.addArrangedSubview(advancedNote)
        let linkButton = NSButton(
            title: L10n.prefs.scrcpyPref.github,
            target: self,
            action: #selector(openScrcpyGitHub)
        )
        linkButton.bezelStyle = .inline
        advancedGroup.addArrangedSubview(linkButton)
        addSettingsGroup(advancedGroup, to: stackView)

        setupScrollViewConstraints(scrollView: scrollView, contentView: stackView)
        return scrollView
    }

    // MARK: - 权限设置

    private func createPermissionsView() -> NSView {
        let scrollView = createScrollView()
        let stackView = createVerticalStack()

        // iOS 权限组
        let iosPermGroup = createSettingsGroup(title: L10n.prefs.section.iosPermissions, icon: "apple.logo")
        iosPermGroup.addArrangedSubview(createPermissionRow(
            name: L10n.permission.cameraName,
            description: L10n.permission.cameraDesc,
            permissionType: .camera
        ))
        addSettingsGroup(iosPermGroup, to: stackView)

        // Android 权限组
        let androidPermGroup = createSettingsGroup(title: L10n.prefs.section.androidPermissions, icon: "apps.iphone")
        androidPermGroup.addArrangedSubview(createPermissionRow(
            name: L10n.permission.screenRecordingName,
            description: L10n.permission.screenRecordingDesc,
            permissionType: .screenRecording
        ))
        addSettingsGroup(androidPermGroup, to: stackView)

        // 权限管理说明
        let permNoteLabel = NSTextField(wrappingLabelWithString: L10n.permission.revokeNote)
        permNoteLabel.font = NSFont.systemFont(ofSize: 11)
        permNoteLabel.textColor = .secondaryLabelColor
        stackView.addArrangedSubview(permNoteLabel)
        permNoteLabel.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(16)
            make.trailing.equalToSuperview().offset(-16)
        }

        // Android 工具链组
        let toolchainGroup = createSettingsGroup(
            title: L10n.prefs.section.androidToolchain,
            icon: "wrench.and.screwdriver"
        )

        let adbRow = createToolchainRowWithPath(
            name: "adb",
            description: L10n.prefs.toolchain.adbDesc,
            toolType: .adb
        )
        toolchainGroup.addArrangedSubview(adbRow)
        adbRow.snp.makeConstraints { make in
            make.width.equalToSuperview().offset(-24) // 减去左右 edgeInsets (12 * 2)
        }

        let divider1 = NSBox()
        divider1.boxType = .separator
        toolchainGroup.addArrangedSubview(divider1)

        let scrcpyRow = createToolchainRowWithPath(
            name: "scrcpy",
            description: L10n.prefs.toolchain.scrcpyDesc,
            toolType: .scrcpy
        )
        toolchainGroup.addArrangedSubview(scrcpyRow)
        scrcpyRow.snp.makeConstraints { make in
            make.width.equalToSuperview().offset(-24)
        }

        let divider2 = NSBox()
        divider2.boxType = .separator
        toolchainGroup.addArrangedSubview(divider2)

        let scrcpyServerRow = createToolchainRowWithPath(
            name: "scrcpy-server",
            description: L10n.prefs.toolchain.scrcpyServerDesc,
            toolType: .scrcpyServer
        )
        toolchainGroup.addArrangedSubview(scrcpyServerRow)
        scrcpyServerRow.snp.makeConstraints { make in
            make.width.equalToSuperview().offset(-24)
        }

        addSettingsGroup(toolchainGroup, to: stackView)

        // 刷新按钮
        let refreshButton = NSButton(
            title: L10n.prefs.toolchain.refreshStatus,
            target: self,
            action: #selector(refreshToolchain)
        )
        refreshButton.bezelStyle = .rounded
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        refreshButton.imagePosition = .imageLeading
        let buttonContainer = NSStackView()
        buttonContainer.orientation = .horizontal
        buttonContainer.addArrangedSubview(NSView()) // 占位
        buttonContainer.addArrangedSubview(refreshButton)
        stackView.addArrangedSubview(buttonContainer)

        setupScrollViewConstraints(scrollView: scrollView, contentView: stackView)
        return scrollView
    }

    // MARK: - 辅助方法

    private func createScrollView() -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        // 使用 flipped 的 documentView，让内容从顶部开始排列
        scrollView.documentView = FlippedView()
        return scrollView
    }

    private func createVerticalStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        return stack
    }

    private func setupScrollViewConstraints(scrollView: NSScrollView, contentView: NSStackView) {
        guard let documentView = scrollView.documentView else { return }

        // 将 stackView 添加到 documentView（FlippedView）中
        documentView.addSubview(contentView)

        // 设置 contentView 约束
        contentView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        // 设置 documentView 约束（宽度等于 scrollView）
        documentView.snp.makeConstraints { make in
            make.leading.trailing.top.equalTo(scrollView.contentView)
            make.width.equalTo(scrollView.contentView)
        }
    }

    /// 创建设置分组，返回内容容器（contentBox）
    /// 注意：groupStack 会通过 contentBox.superview 访问
    private func createSettingsGroup(title: String, icon: String) -> NSStackView {
        let groupStack = NSStackView()
        groupStack.orientation = .vertical
        groupStack.alignment = .leading
        groupStack.spacing = 8

        // 标题行
        let titleStack = NSStackView()
        titleStack.orientation = .horizontal
        titleStack.spacing = 6
        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        iconView.contentTintColor = .labelColor
        // 使用 frame 设置固定大小，避免约束冲突
        iconView.setFrameSize(NSSize(width: 16, height: 16))
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentHuggingPriority(.required, for: .vertical)
        titleStack.addArrangedSubview(iconView)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleStack.addArrangedSubview(titleLabel)
        groupStack.addArrangedSubview(titleStack)

        // 内容容器
        let contentBox = NSStackView()
        contentBox.orientation = .vertical
        contentBox.alignment = .leading
        contentBox.spacing = 10
        contentBox.wantsLayer = true
        // 使用半透明的颜色来区分卡片和背景
        contentBox.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        contentBox.layer?.cornerRadius = 8
        contentBox.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        groupStack.addArrangedSubview(contentBox)

        // 让 contentBox 宽度等于 groupStack 宽度
        contentBox.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
        }

        return contentBox
    }

    /// 将设置分组添加到父 stackView，并设置宽度约束
    private func addSettingsGroup(_ contentBox: NSStackView, to parentStack: NSStackView) {
        guard let groupStack = contentBox.superview as? NSStackView else { return }
        parentStack.addArrangedSubview(groupStack)
        // 让 groupStack 宽度填满父视图
        groupStack.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(16)
            make.trailing.equalToSuperview().offset(-16)
        }
    }

    private func createLabeledRow(label: String, controlBuilder: () -> NSView) -> NSStackView {
        let rowStack = NSStackView()
        rowStack.orientation = .horizontal
        rowStack.alignment = .centerY
        rowStack.spacing = 12

        // Title 区域（左边）
        let labelView = NSTextField(labelWithString: label)
        labelView.font = NSFont.systemFont(ofSize: 13)
        labelView.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        labelView.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        rowStack.addArrangedSubview(labelView)

        // 弹性空间（推动 value 到右边）
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rowStack.addArrangedSubview(spacer)

        // Value 区域（右边）
        let control = controlBuilder()
        control.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        rowStack.addArrangedSubview(control)

        return rowStack
    }

    private func createToolchainRow(name: String, description: String) -> NSStackView {
        let rowStack = NSStackView()
        rowStack.orientation = .horizontal
        rowStack.alignment = .centerY
        rowStack.spacing = 8

        // 状态图标
        let statusIcon = NSImageView()
        statusIcon.image = NSImage(systemSymbolName: "circle", accessibilityDescription: nil)
        statusIcon.contentTintColor = .secondaryLabelColor
        statusIcon.snp.makeConstraints { make in
            make.size.equalTo(18)
        }
        rowStack.addArrangedSubview(statusIcon)

        // 名称和描述
        let infoStack = NSStackView()
        infoStack.orientation = .vertical
        infoStack.alignment = .leading
        infoStack.spacing = 2
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = NSFont.systemFont(ofSize: 13)
        infoStack.addArrangedSubview(nameLabel)
        let descLabel = NSTextField(labelWithString: description)
        descLabel.font = NSFont.systemFont(ofSize: 11)
        descLabel.textColor = .secondaryLabelColor
        infoStack.addArrangedSubview(descLabel)
        infoStack.snp.makeConstraints { make in
            make.width.equalTo(200).priority(.high)
        }
        rowStack.addArrangedSubview(infoStack)

        // 占位
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rowStack.addArrangedSubview(spacer)

        // 状态文本
        let statusLabel = NSTextField(labelWithString: L10n.common.checking)
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .right
        rowStack.addArrangedSubview(statusLabel)

        // 更新状态
        Task { @MainActor in
            let toolchain = AppState.shared.toolchainManager
            let status: ToolchainStatus
            let version: String

            if name == "adb" {
                status = toolchain.adbStatus
                version = toolchain.adbVersionDescription
            } else {
                status = toolchain.scrcpyStatus
                version = toolchain.scrcpyVersionDescription
            }

            switch status {
            case .installed:
                statusIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
                statusIcon.contentTintColor = .systemGreen
                statusLabel.stringValue = version
                statusLabel.textColor = .systemGreen
            case .notInstalled:
                statusIcon.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
                statusIcon.contentTintColor = .systemOrange
                statusLabel.stringValue = L10n.prefs.toolchain.notInstalled
                statusLabel.textColor = .systemOrange
            case .installing:
                statusIcon.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
                statusIcon.contentTintColor = .appAccent
                statusLabel.stringValue = L10n.common.checking
            case let .error(message):
                statusIcon.image = NSImage(
                    systemSymbolName: "exclamationmark.circle.fill",
                    accessibilityDescription: nil
                )
                statusIcon.contentTintColor = .systemRed
                statusLabel.stringValue = message
                statusLabel.textColor = .systemRed
            }
        }

        return rowStack
    }

    private func createToolchainRowWithPath(name: String, description: String, toolType: ToolType) -> NSStackView {
        let containerStack = NSStackView()
        containerStack.orientation = .vertical
        containerStack.alignment = .leading
        containerStack.spacing = 8

        // 第一行：状态显示
        let statusRow = NSStackView()
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8

        // 状态图标
        let statusIcon = NSImageView()
        statusIcon.image = NSImage(systemSymbolName: "circle", accessibilityDescription: nil)
        statusIcon.contentTintColor = .secondaryLabelColor
        statusIcon.snp.makeConstraints { make in
            make.size.equalTo(18)
        }
        statusIcon.setContentHuggingPriority(.required, for: .horizontal)
        statusIcon.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusRow.addArrangedSubview(statusIcon)

        // 名称和描述
        let infoStack = NSStackView()
        infoStack.orientation = .vertical
        infoStack.alignment = .leading
        infoStack.spacing = 2
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = NSFont.systemFont(ofSize: 13)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        infoStack.addArrangedSubview(nameLabel)
        let descLabel = NSTextField(labelWithString: description)
        descLabel.font = NSFont.systemFont(ofSize: 11)
        descLabel.textColor = .secondaryLabelColor
        descLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        infoStack.addArrangedSubview(descLabel)
        infoStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        infoStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusRow.addArrangedSubview(infoStack)

        // 弹性空间（推动状态文本到右边）
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusRow.addArrangedSubview(spacer)

        // 状态文本（右对齐）
        let statusLabel = NSTextField(labelWithString: L10n.common.checking)
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .right
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusRow.addArrangedSubview(statusLabel)

        containerStack.addArrangedSubview(statusRow)
        statusRow.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
        }

        // 第二行：自定义路径
        let pathRow = NSStackView()
        pathRow.orientation = .horizontal
        pathRow.alignment = .centerY
        pathRow.spacing = 8

        // 使用自定义路径复选框
        let useCustomCheckbox = NSButton(
            checkboxWithTitle: L10n.prefs.toolchain.useCustomPath,
            target: self,
            action: #selector(useCustomPathChanged(_:))
        )
        useCustomCheckbox.tag = tagForToolType(toolType, base: 4001)
        useCustomCheckbox.state = useCustomPathForToolType(toolType) ? .on : .off
        pathRow.addArrangedSubview(useCustomCheckbox)

        containerStack.addArrangedSubview(pathRow)

        // 第三行：路径输入（仅在启用自定义路径时显示）
        let pathInputRow = NSStackView()
        pathInputRow.orientation = .horizontal
        pathInputRow.alignment = .centerY
        pathInputRow.spacing = 8
        pathInputRow.isHidden = !useCustomPathForToolType(toolType)

        let pathTextField = NSTextField()
        pathTextField.placeholderString = L10n.prefs.toolchain.pathPlaceholder
        pathTextField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        pathTextField.tag = tagForToolType(toolType, base: 4011)
        pathTextField.stringValue = customPathForToolType(toolType) ?? ""
        pathTextField.target = self
        pathTextField.action = #selector(customPathChanged(_:))
        pathInputRow.addArrangedSubview(pathTextField)
        pathTextField.snp.makeConstraints { make in
            make.width.greaterThanOrEqualTo(200)
        }

        // 浏览按钮
        let browseButton = NSButton(
            title: L10n.prefs.toolchain.browse,
            target: self,
            action: #selector(browseToolPath(_:))
        )
        browseButton.bezelStyle = .rounded
        browseButton.controlSize = .small
        browseButton.tag = tagForToolType(toolType, base: 4021)
        pathInputRow.addArrangedSubview(browseButton)

        // 验证图标
        let validationIcon = NSImageView()
        validationIcon.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
        validationIcon.contentTintColor = .secondaryLabelColor
        validationIcon.tag = tagForToolType(toolType, base: 4031)
        validationIcon.snp.makeConstraints { make in
            make.size.equalTo(16)
        }
        pathInputRow.addArrangedSubview(validationIcon)

        containerStack.addArrangedSubview(pathInputRow)
        pathInputRow.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
        }

        // 更新状态
        Task { @MainActor in
            let toolchain = AppState.shared.toolchainManager
            let status: ToolchainStatus
            let version: String

            switch toolType {
            case .adb:
                status = toolchain.adbStatus
                version = toolchain.adbVersionDescription
            case .scrcpy:
                status = toolchain.scrcpyStatus
                version = toolchain.scrcpyVersionDescription
            case .scrcpyServer:
                // scrcpy-server 使用 scrcpy 的状态，但显示路径信息
                if let serverPath = toolchain.scrcpyServerPath {
                    statusIcon.image = NSImage(
                        systemSymbolName: "checkmark.circle.fill",
                        accessibilityDescription: nil
                    )
                    statusIcon.contentTintColor = .systemGreen
                    let fileName = (serverPath as NSString).lastPathComponent
                    statusLabel.stringValue = fileName
                    statusLabel.textColor = .systemGreen
                } else {
                    statusIcon.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
                    statusIcon.contentTintColor = .systemOrange
                    statusLabel.stringValue = L10n.prefs.toolchain.notInstalled
                    statusLabel.textColor = .systemOrange
                }
                updatePathValidation(toolType: toolType, validationIcon: validationIcon)
                return
            }

            switch status {
            case .installed:
                statusIcon.image = NSImage(
                    systemSymbolName: "checkmark.circle.fill",
                    accessibilityDescription: nil
                )
                statusIcon.contentTintColor = .systemGreen
                statusLabel.stringValue = version
                statusLabel.textColor = .systemGreen
            case .notInstalled:
                statusIcon.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
                statusIcon.contentTintColor = .systemOrange
                statusLabel.stringValue = L10n.prefs.toolchain.notInstalled
                statusLabel.textColor = .systemOrange
            case .installing:
                statusIcon.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
                statusIcon.contentTintColor = .appAccent
                statusLabel.stringValue = L10n.common.checking
            case let .error(message):
                statusIcon.image = NSImage(
                    systemSymbolName: "exclamationmark.circle.fill",
                    accessibilityDescription: nil
                )
                statusIcon.contentTintColor = .systemRed
                statusLabel.stringValue = message
                statusLabel.textColor = .systemRed
            }

            // 验证自定义路径
            updatePathValidation(toolType: toolType, validationIcon: validationIcon)
        }

        return containerStack
    }

    // MARK: - ToolType 辅助方法

    private func tagForToolType(_ toolType: ToolType, base: Int) -> Int {
        switch toolType {
        case .adb: base
        case .scrcpy: base + 1
        case .scrcpyServer: base + 2
        }
    }

    private func useCustomPathForToolType(_ toolType: ToolType) -> Bool {
        switch toolType {
        case .adb: UserPreferences.shared.useCustomAdbPath
        case .scrcpy: UserPreferences.shared.useCustomScrcpyPath
        case .scrcpyServer: UserPreferences.shared.useCustomScrcpyServerPath
        }
    }

    private func customPathForToolType(_ toolType: ToolType) -> String? {
        switch toolType {
        case .adb: UserPreferences.shared.customAdbPath
        case .scrcpy: UserPreferences.shared.customScrcpyPath
        case .scrcpyServer: UserPreferences.shared.customScrcpyServerPath
        }
    }

    private func toolTypeFromTag(_ tag: Int) -> ToolType? {
        let offset = tag % 10
        switch offset {
        case 1: return .adb
        case 2: return .scrcpy
        case 3: return .scrcpyServer
        default: return nil
        }
    }

    private func updatePathValidation(toolType: ToolType, validationIcon: NSImageView) {
        let useCustom = useCustomPathForToolType(toolType)
        let customPath = customPathForToolType(toolType)

        guard useCustom, let path = customPath, !path.isEmpty else {
            validationIcon.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
            validationIcon.contentTintColor = .secondaryLabelColor
            validationIcon.toolTip = nil
            return
        }

        // 检查文件是否存在
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)

        // scrcpy-server 不需要检查可执行权限，它是 DEX 文件
        if toolType == .scrcpyServer {
            if exists, !isDirectory.boolValue {
                validationIcon.image = NSImage(
                    systemSymbolName: "checkmark.circle.fill",
                    accessibilityDescription: nil
                )
                validationIcon.contentTintColor = .systemGreen
                validationIcon.toolTip = L10n.prefs.toolchain.pathValid
            } else if !exists {
                validationIcon.image = NSImage(
                    systemSymbolName: "xmark.circle.fill",
                    accessibilityDescription: nil
                )
                validationIcon.contentTintColor = .systemRed
                validationIcon.toolTip = L10n.prefs.toolchain.pathNotFound
            } else {
                validationIcon.image = NSImage(
                    systemSymbolName: "xmark.circle.fill",
                    accessibilityDescription: nil
                )
                validationIcon.contentTintColor = .systemRed
                validationIcon.toolTip = L10n.prefs.toolchain.pathIsDirectory
            }
            return
        }

        // adb 和 scrcpy 需要检查可执行权限
        let isExecutable = fileManager.isExecutableFile(atPath: path)

        if exists, !isDirectory.boolValue, isExecutable {
            validationIcon.image = NSImage(
                systemSymbolName: "checkmark.circle.fill",
                accessibilityDescription: nil
            )
            validationIcon.contentTintColor = .systemGreen
            validationIcon.toolTip = L10n.prefs.toolchain.pathValid
        } else if !exists {
            validationIcon.image = NSImage(
                systemSymbolName: "xmark.circle.fill",
                accessibilityDescription: nil
            )
            validationIcon.contentTintColor = .systemRed
            validationIcon.toolTip = L10n.prefs.toolchain.pathNotFound
        } else if isDirectory.boolValue {
            validationIcon.image = NSImage(
                systemSymbolName: "xmark.circle.fill",
                accessibilityDescription: nil
            )
            validationIcon.contentTintColor = .systemRed
            validationIcon.toolTip = L10n.prefs.toolchain.pathIsDirectory
        } else {
            validationIcon.image = NSImage(
                systemSymbolName: "exclamationmark.circle.fill",
                accessibilityDescription: nil
            )
            validationIcon.contentTintColor = .systemOrange
            validationIcon.toolTip = L10n.prefs.toolchain.pathNotExecutable
        }
    }

    private enum PermissionType {
        case screenRecording
        case camera
    }

    private enum ToolType {
        case adb
        case scrcpy
        case scrcpyServer
    }

    private func createPermissionRow(name: String, description: String, permissionType: PermissionType) -> NSStackView {
        let containerStack = NSStackView()
        containerStack.orientation = .vertical
        containerStack.alignment = .leading
        containerStack.spacing = 8

        let rowStack = NSStackView()
        rowStack.orientation = .horizontal
        rowStack.alignment = .top
        rowStack.spacing = 8

        // 状态图标
        let statusIcon = NSImageView()
        statusIcon.image = NSImage(systemSymbolName: "circle", accessibilityDescription: nil)
        statusIcon.contentTintColor = .secondaryLabelColor
        statusIcon.snp.makeConstraints { make in
            make.size.equalTo(18)
        }
        statusIcon.setContentHuggingPriority(.required, for: .horizontal)
        statusIcon.setContentCompressionResistancePriority(.required, for: .horizontal)
        rowStack.addArrangedSubview(statusIcon)

        // 名称和描述
        let infoStack = NSStackView()
        infoStack.orientation = .vertical
        infoStack.alignment = .leading
        infoStack.spacing = 2
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = NSFont.systemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byWordWrapping
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        infoStack.addArrangedSubview(nameLabel)
        let descLabel = NSTextField(wrappingLabelWithString: description)
        descLabel.font = NSFont.systemFont(ofSize: 11)
        descLabel.textColor = .secondaryLabelColor
        descLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        infoStack.addArrangedSubview(descLabel)
        infoStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        infoStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rowStack.addArrangedSubview(infoStack)

        // 弹性空间（推动右侧内容到右边）
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rowStack.addArrangedSubview(spacer)

        // 右侧容器（状态 + 按钮）
        let rightStack = NSStackView()
        rightStack.orientation = .horizontal
        rightStack.alignment = .centerY
        rightStack.spacing = 8
        rightStack.setContentHuggingPriority(.required, for: .horizontal)
        rightStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        // 状态文本
        let statusLabel = NSTextField(labelWithString: L10n.common.checking)
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .right
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        rightStack.addArrangedSubview(statusLabel)

        // 打开设置按钮
        let openButton = NSButton(
            title: L10n.permission.openSystemPrefs,
            target: self,
            action: #selector(openSystemPreferences(_:))
        )
        openButton.bezelStyle = .rounded
        openButton.controlSize = .small
        openButton.setContentHuggingPriority(.required, for: .horizontal)
        switch permissionType {
        case .screenRecording:
            openButton.tag = 0
        case .camera:
            openButton.tag = 1
        }
        rightStack.addArrangedSubview(openButton)

        // 撤销按钮（已授权时显示）
        let revokeButton = NSButton(
            title: L10n.permission.revoke,
            target: self,
            action: #selector(revokePermission(_:))
        )
        revokeButton.bezelStyle = .rounded
        revokeButton.controlSize = .small
        revokeButton.setContentHuggingPriority(.required, for: .horizontal)
        revokeButton.isHidden = true
        switch permissionType {
        case .screenRecording:
            revokeButton.tag = 10
        case .camera:
            revokeButton.tag = 11
        }
        rightStack.addArrangedSubview(revokeButton)

        rowStack.addArrangedSubview(rightStack)
        containerStack.addArrangedSubview(rowStack)
        rowStack.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
        }

        // 检查权限状态
        Task { @MainActor in
            let granted: Bool = switch permissionType {
            case .screenRecording:
                checkScreenRecordingPermission()
            case .camera:
                checkCameraPermission()
            }

            if granted {
                statusIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
                statusIcon.contentTintColor = .systemGreen
                statusLabel.stringValue = L10n.permission.granted
                statusLabel.textColor = .systemGreen
                openButton.isHidden = true
                revokeButton.isHidden = false
            } else {
                statusIcon.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
                statusIcon.contentTintColor = .systemOrange
                statusLabel.stringValue = L10n.permission.denied
                statusLabel.textColor = .systemOrange
                openButton.isHidden = false
                revokeButton.isHidden = true
            }
        }

        return containerStack
    }

    private func checkScreenRecordingPermission() -> Bool {
        // 检查屏幕录制权限
        // macOS 10.15+ 使用 CGPreflightScreenCaptureAccess 准确检查权限状态
        CGPreflightScreenCaptureAccess()
    }

    private func checkCameraPermission() -> Bool {
        // 检查摄像头权限
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        return status == .authorized
    }

    // MARK: - 操作

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard index >= 0, index < AppLanguage.allCases.count else { return }
        let language = AppLanguage.allCases[index]
        LocalizationManager.shared.setLanguage(language)
    }

    @objc private func backgroundOpacityChanged(_ sender: NSSlider) {
        UserPreferences.shared.backgroundOpacity = CGFloat(sender.doubleValue)

        // 更新标签显示
        if let valueLabel = sender.superview?.subviews.first(where: { $0.tag == 1001 }) as? NSTextField {
            valueLabel.stringValue = String(format: "%.0f%%", sender.doubleValue * 100)
        }

        // 发送通知更新背景色
        NotificationCenter.default.post(name: .backgroundColorDidChange, object: nil)
    }

    @objc private func showDeviceBezelChanged(_ sender: NSButton) {
        UserPreferences.shared.showDeviceBezel = sender.state == .on
    }

    @objc private func devicePositionChanged(_ sender: NSSegmentedControl) {
        UserPreferences.shared.iosOnLeft = sender.selectedSegment == 0
    }

    @objc private func autoReconnectChanged(_ sender: NSButton) {
        UserPreferences.shared.autoReconnect = sender.state == .on
    }

    @objc private func reconnectDelayChanged(_ sender: NSStepper) {
        UserPreferences.shared.reconnectDelay = sender.doubleValue
        // 更新关联的标签
        if
            let label = sender.superview?.subviews
                .first(where: { $0.tag == 2001 && $0 is NSTextField }) as? NSTextField {
            label.stringValue = L10n.prefs.connectionPref.seconds(Int(sender.intValue))
        }
    }

    @objc private func maxAttemptsChanged(_ sender: NSStepper) {
        UserPreferences.shared.maxReconnectAttempts = Int(sender.intValue)
        // 更新关联的标签
        if
            let label = sender.superview?.subviews
                .first(where: { $0.tag == 2002 && $0 is NSTextField }) as? NSTextField {
            label.stringValue = L10n.prefs.connectionPref.times(Int(sender.intValue))
        }
    }

    @objc private func frameRateChanged(_ sender: NSSegmentedControl) {
        let frameRates = [30, 60, 120]
        UserPreferences.shared.captureFrameRate = frameRates[sender.selectedSegment]
    }

    @objc private func scrcpyBitrateChanged(_ sender: NSPopUpButton) {
        let bitrates = [4, 8, 16, 32]
        let index = sender.indexOfSelectedItem
        if index >= 0, index < bitrates.count {
            UserPreferences.shared.scrcpyBitrate = bitrates[index]
        }
    }

    @objc private func scrcpyMaxSizeChanged(_ sender: NSPopUpButton) {
        let sizes = [0, 1280, 1920, 2560]
        let index = sender.indexOfSelectedItem
        if index >= 0, index < sizes.count {
            UserPreferences.shared.scrcpyMaxSize = sizes[index]
        }
    }

    @objc private func scrcpyShowTouchesChanged(_ sender: NSButton) {
        UserPreferences.shared.scrcpyShowTouches = sender.state == .on
    }

    @objc private func useBundledAdbChanged(_ sender: NSButton) {
        UserPreferences.shared.useBundledAdb = sender.state == .on
        // 刷新工具链状态
        Task {
            await AppState.shared.toolchainManager.refresh()
        }
    }

    @objc private func scrcpyPortChanged(_ sender: NSTextField) {
        guard let port = Int(sender.stringValue), port >= 1024, port <= 65535 else {
            // 恢复为当前值
            sender.stringValue = String(UserPreferences.shared.scrcpyPort)
            return
        }
        UserPreferences.shared.scrcpyPort = port
        // 同步更新 stepper
        if let stepper = sender.superview?.subviews.first(where: { $0.tag == 3001 && $0 is NSStepper }) as? NSStepper {
            stepper.intValue = Int32(port)
        }
    }

    @objc private func scrcpyPortStepperChanged(_ sender: NSStepper) {
        let port = Int(sender.intValue)
        UserPreferences.shared.scrcpyPort = port
        // 同步更新文本框
        if
            let textField = sender.superview?.subviews
                .first(where: { $0.tag == 3001 && $0 is NSTextField }) as? NSTextField {
            textField.stringValue = String(port)
        }
    }

    @objc private func scrcpyCodecChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard index >= 0, index < ScrcpyCodecType.allCases.count else { return }
        UserPreferences.shared.scrcpyCodec = ScrcpyCodecType.allCases[index]
    }

    @objc private func refreshToolchain() {
        Task {
            await AppState.shared.toolchainManager.refresh()
        }
    }

    @objc private func openScrcpyGitHub() {
        if let url = URL(string: "https://github.com/Genymobile/scrcpy") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openSystemPreferences(_ sender: NSButton) {
        let urlString: String
        switch sender.tag {
        case 0:
            // 打开系统偏好设置 - 隐私 - 屏幕录制
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case 1:
            // 打开系统偏好设置 - 隐私 - 摄像头
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
        default:
            return
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func revokePermission(_ sender: NSButton) {
        let urlString: String
        let alertMessage: String

        switch sender.tag {
        case 10:
            // 屏幕录制权限
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            alertMessage = L10n.permission.revokeScreenRecordingHint
        case 11:
            // 摄像头权限
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
            alertMessage = L10n.permission.revokeCameraHint
        default:
            return
        }

        // 显示提示
        let alert = NSAlert()
        alert.messageText = L10n.permission.revokeTitle
        alert.informativeText = alertMessage
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.permission.openSystemPrefs)
        alert.addButton(withTitle: L10n.common.cancel)

        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - 工具链路径设置

    @objc private func useCustomPathChanged(_ sender: NSButton) {
        guard let toolType = toolTypeFromTag(sender.tag) else { return }
        let useCustom = sender.state == .on

        switch toolType {
        case .adb:
            UserPreferences.shared.useCustomAdbPath = useCustom
        case .scrcpy:
            UserPreferences.shared.useCustomScrcpyPath = useCustom
        case .scrcpyServer:
            UserPreferences.shared.useCustomScrcpyServerPath = useCustom
        }

        // 查找对应的路径输入行并更新显示
        let pathInputTag = tagForToolType(toolType, base: 4011)
        if let containerStack = sender.superview?.superview as? NSStackView {
            for arrangedSubview in containerStack.arrangedSubviews {
                if let pathRow = arrangedSubview as? NSStackView {
                    for subview in pathRow.arrangedSubviews {
                        if let textField = subview as? NSTextField, textField.tag == pathInputTag {
                            pathRow.isHidden = !useCustom
                            break
                        }
                    }
                }
            }
        }

        // 刷新工具链状态
        Task {
            await AppState.shared.toolchainManager.refresh()
        }
    }

    @objc private func customPathChanged(_ sender: NSTextField) {
        guard let toolType = toolTypeFromTag(sender.tag) else { return }
        let path = sender.stringValue

        switch toolType {
        case .adb:
            UserPreferences.shared.customAdbPath = path.isEmpty ? nil : path
        case .scrcpy:
            UserPreferences.shared.customScrcpyPath = path.isEmpty ? nil : path
        case .scrcpyServer:
            UserPreferences.shared.customScrcpyServerPath = path.isEmpty ? nil : path
        }

        // 更新验证图标
        let validationTag = tagForToolType(toolType, base: 4031)
        if let parentStack = sender.superview as? NSStackView {
            for subview in parentStack.arrangedSubviews {
                if let icon = subview as? NSImageView, icon.tag == validationTag {
                    updatePathValidation(toolType: toolType, validationIcon: icon)
                    break
                }
            }
        }

        // 刷新工具链状态
        Task {
            await AppState.shared.toolchainManager.refresh()
        }
    }

    @objc private func browseToolPath(_ sender: NSButton) {
        guard let toolType = toolTypeFromTag(sender.tag) else { return }
        let toolName = switch toolType {
        case .adb: "adb"
        case .scrcpy: "scrcpy"
        case .scrcpyServer: "scrcpy-server"
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = L10n.prefs.toolchain.selectTool(toolName)
        panel.prompt = L10n.common.ok

        // 设置初始目录
        if let currentPath = customPathForToolType(toolType), !currentPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: currentPath).deletingLastPathComponent()
        } else {
            panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
        }

        if panel.runModal() == .OK, let url = panel.url {
            let path = url.path

            // 更新 UserPreferences
            switch toolType {
            case .adb:
                UserPreferences.shared.customAdbPath = path
            case .scrcpy:
                UserPreferences.shared.customScrcpyPath = path
            case .scrcpyServer:
                UserPreferences.shared.customScrcpyServerPath = path
            }

            // 更新文本框
            let textFieldTag = tagForToolType(toolType, base: 4011)
            if let parentStack = sender.superview as? NSStackView {
                for subview in parentStack.arrangedSubviews {
                    if let textField = subview as? NSTextField, textField.tag == textFieldTag {
                        textField.stringValue = path
                        break
                    }
                }
            }

            // 更新验证图标
            let validationTag = tagForToolType(toolType, base: 4031)
            if let parentStack = sender.superview as? NSStackView {
                for subview in parentStack.arrangedSubviews {
                    if let icon = subview as? NSImageView, icon.tag == validationTag {
                        updatePathValidation(toolType: toolType, validationIcon: icon)
                        break
                    }
                }
            }

            // 刷新工具链状态
            Task {
                await AppState.shared.toolchainManager.refresh()
            }
        }
    }
}

// MARK: - 通知名称

extension Notification.Name {
    static let backgroundColorDidChange = Notification.Name("backgroundColorDidChange")
    static let deviceBezelVisibilityDidChange = Notification.Name("deviceBezelVisibilityDidChange")
}
