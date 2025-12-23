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
    private(set) var aspectRatio: CGFloat = 9.0 / 19.0

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

    func configure(deviceName: String?, platform: DevicePlatform, aspectRatio: CGFloat? = nil) {
        deviceModel = DeviceModel.identify(from: deviceName, platform: platform)
        self.aspectRatio = aspectRatio ?? deviceModel.defaultAspectRatio
        updateLayers()
    }

    func configure(model: DeviceModel, aspectRatio: CGFloat? = nil) {
        deviceModel = model
        self.aspectRatio = aspectRatio ?? model.defaultAspectRatio
        updateLayers()
    }

    func updateAspectRatio(_ ratio: CGFloat) {
        guard ratio > 0, ratio != aspectRatio else { return }
        aspectRatio = ratio
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

        let containerAspect = bounds.width / bounds.height
        let deviceWidth: CGFloat
        let deviceHeight: CGFloat
        let sideMargin: CGFloat = 8

        if aspectRatio < containerAspect {
            deviceHeight = bounds.height * 0.92
            deviceWidth = deviceHeight * aspectRatio
        } else {
            deviceWidth = (bounds.width - sideMargin * 2) * 0.92
            deviceHeight = deviceWidth / aspectRatio
        }

        let deviceRect = CGRect(
            x: (bounds.width - deviceWidth) / 2,
            y: (bounds.height - deviceHeight) / 2,
            width: deviceWidth,
            height: deviceHeight
        )

        let bezelWidth = deviceWidth * deviceModel.bezelWidthRatio
        let bezelCornerRadius = deviceWidth * deviceModel.bezelCornerRadiusRatio
        let screenCornerRadius = deviceWidth * deviceModel.screenCornerRadiusRatio

        // 外边缘高光
        let outerRect = deviceRect.insetBy(dx: -0.5, dy: -0.5)
        outerHighlightLayer.strokeColor = deviceModel.bezelHighlightColor.withAlphaComponent(0.3).cgColor
        outerHighlightLayer.path = NSBezierPath(
            roundedRect: outerRect,
            xRadius: bezelCornerRadius + 0.5,
            yRadius: bezelCornerRadius + 0.5
        ).cgPath

        // 主边框
        drawBezelWithGradient(rect: deviceRect, cornerRadius: bezelCornerRadius)

        // 内边缘高光
        let innerHighlightRect = deviceRect.insetBy(dx: bezelWidth - 0.5, dy: bezelWidth - 0.5)
        innerHighlightLayer.strokeColor = deviceModel.bezelHighlightColor.withAlphaComponent(0.15).cgColor
        innerHighlightLayer.path = NSBezierPath(
            roundedRect: innerHighlightRect,
            xRadius: screenCornerRadius + 0.5,
            yRadius: screenCornerRadius + 0.5
        ).cgPath

        // 屏幕区域
        var screenRect = deviceRect.insetBy(dx: bezelWidth, dy: bezelWidth)

        // iPhone SE / Legacy 需要更大的顶部和底部边框
        if case .homeButton = deviceModel.topFeature {
            let extraBezel = deviceWidth * 0.10
            screenRect = CGRect(
                x: screenRect.minX,
                y: screenRect.minY + extraBezel,
                width: screenRect.width,
                height: screenRect.height - extraBezel * 2
            )
        }

        let screenPath = NSBezierPath(roundedRect: screenRect, xRadius: screenCornerRadius, yRadius: screenCornerRadius)
        screenLayer.path = screenPath.cgPath

        screenContentView.frame = screenRect
        screenContentView.layer?.cornerRadius = screenCornerRadius

        updateTopFeature(screenRect: screenRect, deviceWidth: deviceWidth)
        updateSideButtons(deviceRect: deviceRect, deviceWidth: deviceWidth, deviceHeight: deviceHeight)
    }

    private func drawBezelWithGradient(rect: CGRect, cornerRadius: CGFloat) {
        let baseColor = deviceModel.bezelBaseColor
        let highlightColor = deviceModel.bezelHighlightColor

        bezelLayer.fillColor = baseColor.cgColor
        bezelLayer.path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).cgPath
        bezelLayer.strokeColor = highlightColor.withAlphaComponent(0.1).cgColor
        bezelLayer.lineWidth = 0.5
    }

    private func updateTopFeature(screenRect: CGRect, deviceWidth: CGFloat) {
        featureLayer?.removeFromSuperlayer()
        featureLayer = nil
        homeButtonLayer?.removeFromSuperlayer()
        homeButtonLayer = nil

        switch deviceModel.topFeature {
        case .none:
            break

        case let .dynamicIsland(widthRatio, heightRatio):
            let islandWidth = screenRect.width * widthRatio
            let islandHeight = screenRect.width * heightRatio
            let islandCornerRadius = islandHeight / 2

            let islandRect = CGRect(
                x: screenRect.midX - islandWidth / 2,
                y: screenRect.maxY - islandHeight - screenRect.width * 0.028,
                width: islandWidth,
                height: islandHeight
            )

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
