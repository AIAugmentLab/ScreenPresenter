//
//  DeviceBezelView.swift
//  ScreenPresenter
//
//  Created by Sun on 2025/12/23.
//
//  设备边框视图
//  根据连接的真实设备绘制对应的设备外观
//

import AppKit
import SnapKit

// MARK: - 设备边框视图

final class DeviceBezelView: NSView {
    // MARK: - 属性

    private(set) var deviceModel: DeviceModel = .unknown

    /// 屏幕内容区域的宽高比（不是设备整体的宽高比）
    /// 这个值应该与视频的宽高比一致，以避免渲染时产生黑边
    private(set) var screenAspectRatio: CGFloat = 9.0 / 19.5

    /// 设备整体的宽高比（包含边框，用于外部布局参考）
    private(set) var aspectRatio: CGFloat = 9.0 / 19.0

    /// 顶部特征（刘海/灵动岛/摄像头开孔）的底部 Y 坐标
    /// 相对于 screenContentView 的顶部（向下为正），用于 captureBar 定位
    private(set) var topFeatureBottomInset: CGFloat = 0

    // MARK: - UI 组件

    private var bezelLayer: CAShapeLayer!
    private var innerHighlightLayer: CAShapeLayer!
    private var outerHighlightLayer: CAShapeLayer!
    private var screenLayer: CAShapeLayer!
    private var featureLayer: CAShapeLayer?
    private var homeButtonLayer: CAShapeLayer?
    private var sideButtonLayers: [CALayer] = []

    private(set) var screenContentView: NSView!

    // MARK: - 初始化

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    // MARK: - 配置方法

    /// 配置设备外观
    /// - Parameters:
    ///   - deviceName: 设备名称（用于识别设备型号）
    ///   - platform: 设备平台
    ///   - aspectRatio: 屏幕内容区域的宽高比（如视频的宽高比），nil 时使用设备默认值
    func configure(deviceName: String?, platform: DevicePlatform, aspectRatio: CGFloat? = nil) {
        deviceModel = DeviceModel.identify(from: deviceName, platform: platform)
        screenAspectRatio = aspectRatio ?? deviceModel.defaultScreenAspectRatio
        updateLayers()
    }

    /// 配置设备外观
    /// - Parameters:
    ///   - model: 设备型号
    ///   - aspectRatio: 屏幕内容区域的宽高比，nil 时使用设备默认值
    func configure(model: DeviceModel, aspectRatio: CGFloat? = nil) {
        deviceModel = model
        screenAspectRatio = aspectRatio ?? model.defaultScreenAspectRatio
        updateLayers()
    }

    /// 更新屏幕内容区域的宽高比
    func updateAspectRatio(_ ratio: CGFloat) {
        guard ratio > 0, ratio != screenAspectRatio else { return }
        screenAspectRatio = ratio
        updateLayers()
    }

    // MARK: - UI 设置

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        outerHighlightLayer = CAShapeLayer()
        outerHighlightLayer.fillColor = nil
        outerHighlightLayer.lineWidth = 0.5
        layer?.addSublayer(outerHighlightLayer)

        bezelLayer = CAShapeLayer()
        bezelLayer.lineWidth = 0
        layer?.addSublayer(bezelLayer)

        innerHighlightLayer = CAShapeLayer()
        innerHighlightLayer.fillColor = nil
        innerHighlightLayer.lineWidth = 0.5
        layer?.addSublayer(innerHighlightLayer)

        screenLayer = CAShapeLayer()
        screenLayer.fillColor = NSColor.clear.cgColor
        layer?.addSublayer(screenLayer)

        screenContentView = NSView()
        screenContentView.wantsLayer = true
        screenContentView.layer?.backgroundColor = NSColor.clear.cgColor
        screenContentView.layer?.masksToBounds = true
        addSubview(screenContentView)

        updateLayers()
    }

    // MARK: - 布局

    override func layout() {
        super.layout()
        updateLayers()
    }

    private func updateLayers() {
        guard bounds.width > 0, bounds.height > 0 else { return }

        // 核心思路：以屏幕内容区域的宽高比 (screenAspectRatio) 为基准，反推设备整体尺寸
        // 这样确保 screenRect 的宽高比与视频一致，避免渲染时产生黑边
        //
        // 数学推导：
        // 设 r = screenAspectRatio, b = bezelRatio, e = extraBezelRatio
        // 由于 bezelWidth = deviceWidth * b，边框是按设备宽度计算的：
        //   screenWidth = deviceWidth * (1 - 2*b)
        //   screenHeight = deviceHeight - 2*bezelWidth - 2*extraBezel
        //                = deviceHeight - 2*deviceWidth*(b + e)
        // 设 da = deviceWidth/deviceHeight，则：
        //   r = screenWidth/screenHeight
        //     = [da * (1 - 2*b)] / [1 - 2*da*(b + e)]
        // 解出 da：
        //   da = r / [(1 - 2*b) + 2*r*(b + e)]

        let containerAspect = bounds.width / bounds.height

        // 边框相关比例
        let bezelRatio = deviceModel.bezelWidthRatio
        let hasHomeButton = if case .homeButton = deviceModel.topFeature {
            true
        } else {
            false
        }
        let extraBezelRatio: CGFloat = hasHomeButton ? 0.10 : 0

        // 计算设备整体的宽高比（根据屏幕宽高比和边框推算）
        let r = screenAspectRatio
        let b = bezelRatio
        let e = extraBezelRatio
        let deviceAspect = r / ((1 - 2 * b) + 2 * r * (b + e))

        let deviceWidth: CGFloat
        let deviceHeight: CGFloat

        // 设备尽可能填满容器，保持设备整体宽高比
        if deviceAspect < containerAspect {
            // 容器更宽，以高度为基准
            deviceHeight = bounds.height
            deviceWidth = deviceHeight * deviceAspect
        } else {
            // 容器更高，以宽度为基准
            deviceWidth = bounds.width
            deviceHeight = deviceWidth / deviceAspect
        }

        let deviceRect = CGRect(
            x: (bounds.width - deviceWidth) / 2,
            y: (bounds.height - deviceHeight) / 2,
            width: deviceWidth,
            height: deviceHeight
        )

        // 更新设备整体宽高比（供外部布局使用）
        aspectRatio = deviceAspect

        let bezelWidth = deviceWidth * bezelRatio

        // 屏幕圆角（内圆角）
        let screenCornerRadius = deviceWidth * deviceModel.screenCornerRadiusRatio

        // 外圆角 = 内圆角 + 边框宽度（物理正确的圆角关系）
        let bezelCornerRadius = screenCornerRadius + bezelWidth

        // 计算屏幕区域
        var screenRect = deviceRect.insetBy(dx: bezelWidth, dy: bezelWidth)

        // iPhone SE / Legacy 需要更大的顶部和底部边框
        if case .homeButton = deviceModel.topFeature {
            let extraBezel = deviceWidth * extraBezelRatio
            screenRect = CGRect(
                x: screenRect.minX,
                y: screenRect.minY + extraBezel,
                width: screenRect.width,
                height: screenRect.height - extraBezel * 2
            )
        }

        // 像素对齐：确保 screenRect 对齐到整像素
        let scale = window?.backingScaleFactor ?? 2.0
        screenRect = CGRect(
            x: round(screenRect.minX * scale) / scale,
            y: round(screenRect.minY * scale) / scale,
            width: round(screenRect.width * scale) / scale,
            height: round(screenRect.height * scale) / scale
        )

        // 外边缘高光
        let outerRect = deviceRect.insetBy(dx: -0.5, dy: -0.5)
        outerHighlightLayer.strokeColor = deviceModel.bezelHighlightColor.withAlphaComponent(0.3).cgColor
        outerHighlightLayer.path = NSBezierPath(
            roundedRect: outerRect,
            xRadius: bezelCornerRadius + 0.5,
            yRadius: bezelCornerRadius + 0.5
        ).cgPath

        // 主边框（中间镂空）- 使用 screenRect 确保完全匹配
        drawBezelWithGradient(
            rect: deviceRect,
            cornerRadius: bezelCornerRadius,
            screenRect: screenRect,
            screenCornerRadius: screenCornerRadius
        )

        // 内边缘高光（紧贴屏幕边缘）
        innerHighlightLayer.strokeColor = deviceModel.bezelHighlightColor.withAlphaComponent(0.15).cgColor
        innerHighlightLayer.path = NSBezierPath(
            roundedRect: screenRect,
            xRadius: screenCornerRadius,
            yRadius: screenCornerRadius
        ).cgPath

        // 屏幕区域路径
        let screenPath = NSBezierPath(roundedRect: screenRect, xRadius: screenCornerRadius, yRadius: screenCornerRadius)
        screenLayer.path = screenPath.cgPath

        // screenContentView 完全匹配 screenRect
        screenContentView.frame = screenRect
        screenContentView.layer?.cornerRadius = screenCornerRadius

        updateTopFeature(screenRect: screenRect, deviceWidth: deviceWidth)
        updateSideButtons(deviceRect: deviceRect, deviceWidth: deviceWidth, deviceHeight: deviceHeight)
    }

    private func drawBezelWithGradient(
        rect: CGRect,
        cornerRadius: CGFloat,
        screenRect: CGRect,
        screenCornerRadius: CGFloat
    ) {
        let baseColor = deviceModel.bezelBaseColor
        let highlightColor = deviceModel.bezelHighlightColor

        // 创建镂空路径：外边框 - 内部屏幕区域
        let outerPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        let innerPath = NSBezierPath(roundedRect: screenRect, xRadius: screenCornerRadius, yRadius: screenCornerRadius)

        // 使用 even-odd 填充规则创建镂空效果
        outerPath.append(innerPath)
        outerPath.windingRule = .evenOdd

        bezelLayer.fillColor = baseColor.cgColor
        bezelLayer.path = outerPath.cgPath
        bezelLayer.fillRule = .evenOdd
        bezelLayer.strokeColor = highlightColor.withAlphaComponent(0.1).cgColor
        bezelLayer.lineWidth = 0.5
    }

    private func updateTopFeature(screenRect: CGRect, deviceWidth: CGFloat) {
        featureLayer?.removeFromSuperlayer()
        featureLayer = nil
        homeButtonLayer?.removeFromSuperlayer()
        homeButtonLayer = nil

        // 重置顶部特征的底部位置
        topFeatureBottomInset = 0

        switch deviceModel.topFeature {
        case .none:
            break

        case let .dynamicIsland(widthRatio, heightRatio):
            let islandWidth = screenRect.width * widthRatio
            let islandHeight = screenRect.width * heightRatio
            let islandCornerRadius = islandHeight / 2
            let islandTopMargin = screenRect.width * 0.028

            let islandRect = CGRect(
                x: screenRect.midX - islandWidth / 2,
                y: screenRect.maxY - islandHeight - islandTopMargin,
                width: islandWidth,
                height: islandHeight
            )

            // 计算顶部特征底部距离屏幕顶部的偏移
            topFeatureBottomInset = islandTopMargin + islandHeight

            let layer = CAShapeLayer()
            layer.fillColor = NSColor.black.cgColor
            layer.shadowColor = NSColor.white.cgColor
            layer.shadowOffset = CGSize(width: 0, height: -0.5)
            layer.shadowRadius = 0.5
            layer.shadowOpacity = 0.1
            layer.path = NSBezierPath(roundedRect: islandRect, xRadius: islandCornerRadius, yRadius: islandCornerRadius)
                .cgPath
            self.layer?.addSublayer(layer)
            featureLayer = layer

        case let .notch(widthRatio, heightRatio):
            let notchWidth = screenRect.width * widthRatio
            let notchHeight = screenRect.width * heightRatio
            let notchCornerRadius = notchHeight * 0.45

            // 刘海从屏幕顶部开始向下延伸
            topFeatureBottomInset = notchHeight

            let notchPath = createNotchPath(
                centerX: screenRect.midX,
                topY: screenRect.maxY,
                width: notchWidth,
                height: notchHeight,
                cornerRadius: notchCornerRadius
            )

            let layer = CAShapeLayer()
            layer.fillColor = NSColor.black.cgColor
            layer.path = notchPath
            self.layer?.addSublayer(layer)
            featureLayer = layer

        case let .punchHole(position, sizeRatio):
            let holeSize = screenRect.width * sizeRatio
            let margin = screenRect.width * 0.045

            // 计算顶部特征底部距离屏幕顶部的偏移
            topFeatureBottomInset = margin + holeSize

            let holeX: CGFloat = switch position {
            case .center:
                screenRect.midX - holeSize / 2
            case .topLeft:
                screenRect.minX + margin
            case .topRight:
                screenRect.maxX - margin - holeSize
            }

            let holeRect = CGRect(
                x: holeX,
                y: screenRect.maxY - margin - holeSize,
                width: holeSize,
                height: holeSize
            )

            let layer = CAShapeLayer()
            layer.fillColor = NSColor.black.cgColor
            layer.strokeColor = NSColor(white: 0.15, alpha: 1.0).cgColor
            layer.lineWidth = 0.5
            layer.path = NSBezierPath(ovalIn: holeRect).cgPath
            self.layer?.addSublayer(layer)
            featureLayer = layer

        case .homeButton:
            let buttonSize = deviceWidth * 0.14
            let buttonY = screenContentView.frame.minY - (deviceWidth * 0.10 + buttonSize) / 2 - buttonSize * 0.15

            let buttonRect = CGRect(
                x: screenContentView.frame.midX - buttonSize / 2,
                y: buttonY,
                width: buttonSize,
                height: buttonSize
            )

            let outerLayer = CAShapeLayer()
            outerLayer.fillColor = NSColor(white: 0.06, alpha: 1.0).cgColor
            outerLayer.strokeColor = NSColor(white: 0.22, alpha: 1.0).cgColor
            outerLayer.lineWidth = 1.0
            outerLayer.path = NSBezierPath(ovalIn: buttonRect).cgPath

            let innerSize = buttonSize * 0.35
            let innerRect = CGRect(
                x: buttonRect.midX - innerSize / 2,
                y: buttonRect.midY - innerSize / 2,
                width: innerSize,
                height: innerSize
            )
            let innerLayer = CAShapeLayer()
            innerLayer.fillColor = nil
            innerLayer.strokeColor = NSColor(white: 0.25, alpha: 1.0).cgColor
            innerLayer.lineWidth = 1.0
            innerLayer.path = NSBezierPath(roundedRect: innerRect, xRadius: innerSize * 0.2, yRadius: innerSize * 0.2)
                .cgPath

            layer?.addSublayer(outerLayer)
            layer?.addSublayer(innerLayer)
            homeButtonLayer = outerLayer
        }
    }

    private func createNotchPath(
        centerX: CGFloat,
        topY: CGFloat,
        width: CGFloat,
        height: CGFloat,
        cornerRadius: CGFloat
    ) -> CGPath {
        let path = CGMutablePath()

        let leftX = centerX - width / 2
        let rightX = centerX + width / 2
        let bottomY = topY - height

        path.move(to: CGPoint(x: leftX - cornerRadius, y: topY))

        path.addQuadCurve(
            to: CGPoint(x: leftX, y: topY - cornerRadius * 0.5),
            control: CGPoint(x: leftX, y: topY)
        )

        path.addLine(to: CGPoint(x: leftX, y: bottomY + cornerRadius))

        path.addQuadCurve(
            to: CGPoint(x: leftX + cornerRadius, y: bottomY),
            control: CGPoint(x: leftX, y: bottomY)
        )

        path.addLine(to: CGPoint(x: rightX - cornerRadius, y: bottomY))

        path.addQuadCurve(
            to: CGPoint(x: rightX, y: bottomY + cornerRadius),
            control: CGPoint(x: rightX, y: bottomY)
        )

        path.addLine(to: CGPoint(x: rightX, y: topY - cornerRadius * 0.5))

        path.addQuadCurve(
            to: CGPoint(x: rightX + cornerRadius, y: topY),
            control: CGPoint(x: rightX, y: topY)
        )

        path.closeSubpath()

        return path
    }

    private func updateSideButtons(deviceRect: CGRect, deviceWidth _: CGFloat, deviceHeight: CGFloat) {
        sideButtonLayers.forEach { $0.removeFromSuperlayer() }
        sideButtonLayers.removeAll()

        let buttons = deviceModel.sideButtons

        for spec in buttons.left {
            let buttonLayer = createButtonLayer(
                spec: spec,
                deviceRect: deviceRect,
                deviceHeight: deviceHeight,
                isLeft: true
            )
            layer?.addSublayer(buttonLayer)
            sideButtonLayers.append(buttonLayer)
        }

        for spec in buttons.right {
            let buttonLayer = createButtonLayer(
                spec: spec,
                deviceRect: deviceRect,
                deviceHeight: deviceHeight,
                isLeft: false
            )
            layer?.addSublayer(buttonLayer)
            sideButtonLayers.append(buttonLayer)
        }
    }

    private func createButtonLayer(
        spec: DeviceModel.SideButtons.ButtonSpec,
        deviceRect: CGRect,
        deviceHeight: CGFloat,
        isLeft: Bool
    ) -> CALayer {
        let buttonHeight = deviceHeight * spec.heightRatio
        let buttonY = deviceRect.maxY - deviceHeight * spec.topRatio - buttonHeight

        let buttonRect = if isLeft {
            CGRect(
                x: deviceRect.minX - spec.width,
                y: buttonY,
                width: spec.width,
                height: buttonHeight
            )
        } else {
            CGRect(
                x: deviceRect.maxX,
                y: buttonY,
                width: spec.width,
                height: buttonHeight
            )
        }

        let layer = CAShapeLayer()
        let cornerRadius: CGFloat = switch spec.type {
        case .silentSwitch, .actionButton:
            buttonHeight / 2
        case .cameraControl:
            buttonHeight / 2
        default:
            1.5
        }

        let path = NSBezierPath(roundedRect: buttonRect, xRadius: cornerRadius, yRadius: cornerRadius)
        layer.path = path.cgPath
        layer.fillColor = deviceModel.buttonColor.cgColor
        layer.strokeColor = deviceModel.buttonHighlightColor.withAlphaComponent(0.3).cgColor
        layer.lineWidth = 0.5

        return layer
    }

    // MARK: - 屏幕区域

    var screenFrame: CGRect {
        screenContentView.frame
    }

    /// 屏幕圆角半径（用于 Metal 渲染遮罩）
    var screenCornerRadius: CGFloat {
        screenContentView.layer?.cornerRadius ?? 0
    }
}

// MARK: - NSBezierPath CGPath 扩展

extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)

        for i in 0..<elementCount {
            let type = element(at: i, associatedPoints: &points)
            switch type {
            case .moveTo:
                path.move(to: points[0])
            case .lineTo:
                path.addLine(to: points[0])
            case .curveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closePath:
                path.closeSubpath()
            case .cubicCurveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo:
                path.addQuadCurve(to: points[1], control: points[0])
            @unknown default:
                break
            }
        }

        return path
    }
}
