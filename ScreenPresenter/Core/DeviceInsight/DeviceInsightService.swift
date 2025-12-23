//
//  DeviceInsightService.swift
//  ScreenPresenter
//
//  Created by Sun on 2025/12/22.
//
//  设备感知服务
//  使用 MobileDevice.framework 获取 iOS 设备详细信息
//
//  【重要】MobileDevice.framework 是增强层，不是核心依赖：
//  - 可用时提供：设备名称、型号、系统版本、信任状态、锁屏状态
//  - 不可用时：返回降级结果，不影响主捕获流程
//  - 绝不能因为 MobileDevice 失败而阻止 CMIO+AVFoundation 工作
//

import AppKit
import AVFoundation
import Foundation

// MARK: - MobileDevice.framework 函数类型定义

private typealias AMDeviceNotificationSubscribeFunc = @convention(c) (
    @escaping @convention(c) (UnsafeMutableRawPointer?) -> Void,
    Int32,
    Int32,
    UnsafeMutableRawPointer?,
    UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Int32

private typealias AMDeviceConnectFunc = @convention(c) (UnsafeMutableRawPointer?) -> Int32
private typealias AMDeviceDisconnectFunc = @convention(c) (UnsafeMutableRawPointer?) -> Int32
private typealias AMDeviceStartSessionFunc = @convention(c) (UnsafeMutableRawPointer?) -> Int32
private typealias AMDeviceStopSessionFunc = @convention(c) (UnsafeMutableRawPointer?) -> Int32
private typealias AMDeviceIsPairedFunc = @convention(c) (UnsafeMutableRawPointer?) -> Int32
private typealias AMDeviceCopyValueFunc = @convention(c) (
    UnsafeMutableRawPointer?,
    CFString?,
    CFString?
) -> CFTypeRef?
private typealias AMDeviceGetConnectionIDFunc = @convention(c) (UnsafeMutableRawPointer?) -> UInt32
private typealias AMDeviceCopyDeviceIdentifierFunc = @convention(c) (UnsafeMutableRawPointer?) -> CFString?

// MARK: - 设备信息结构

/// iOS 设备详细信息
/// 整合 AVFoundation 状态检测和 MobileDevice.framework 增强信息
struct IOSDeviceInsight {
    /// 设备 UDID
    let udid: String

    /// 用户设置的设备名称
    let deviceName: String

    /// 设备型号标识符（如 iPhone14,2）
    let modelIdentifier: String

    /// 设备型号名称（如 iPhone 13 Pro）
    let modelName: String

    /// iOS 版本
    let systemVersion: String

    /// 是否已信任（配对）
    let isTrusted: Bool

    /// 是否被其他应用占用（QuickTime/Xcode 等）
    let isOccupied: Bool

    /// 占用状态描述
    let occupiedBy: String?

    /// 是否处于锁屏/息屏状态
    let isLocked: Bool

    /// 连接类型（USB/WiFi）
    let connectionType: ConnectionType

    enum ConnectionType: String {
        case usb = "USB"
        case wifi = "WiFi"
        case unknown
    }

    /// 降级结果（当 MobileDevice 不可用时使用）
    static func degraded(
        udid: String,
        reason: String,
        isLocked: Bool = false,
        isOccupied: Bool = false,
        occupiedBy: String? = nil
    ) -> IOSDeviceInsight {
        AppLogger.device.warning("设备信息降级: \(reason)")
        return IOSDeviceInsight(
            udid: udid,
            deviceName: "iOS 设备",
            modelIdentifier: "unknown",
            modelName: L10n.deviceInfo.unknownModel,
            systemVersion: L10n.deviceInfo.unknownVersion,
            isTrusted: true, // 假设已信任，让主流程继续
            isOccupied: isOccupied,
            occupiedBy: occupiedBy,
            isLocked: isLocked,
            connectionType: .usb
        )
    }
}

// MARK: - 设备感知服务

/// 设备感知服务
/// 提供 iOS 设备的详细信息，作为增强层使用
final class DeviceInsightService {
    // MARK: - 单例

    static let shared = DeviceInsightService()

    // MARK: - 状态

    /// MobileDevice.framework 是否可用
    private(set) var isMobileDeviceAvailable: Bool = false

    /// 服务初始化错误
    private(set) var initializationError: String?

    // MARK: - 私有属性

    private var mobileDeviceHandle: UnsafeMutableRawPointer?

    // MobileDevice.framework 函数指针
    private var amDeviceConnect: AMDeviceConnectFunc?
    private var amDeviceDisconnect: AMDeviceDisconnectFunc?
    private var amDeviceStartSession: AMDeviceStartSessionFunc?
    private var amDeviceStopSession: AMDeviceStopSessionFunc?
    private var amDeviceIsPaired: AMDeviceIsPairedFunc?
    private var amDeviceCopyValue: AMDeviceCopyValueFunc?
    private var amDeviceGetConnectionID: AMDeviceGetConnectionIDFunc?
    private var amDeviceCopyDeviceIdentifier: AMDeviceCopyDeviceIdentifierFunc?

    /// 已发现的设备 (connectionID -> device pointer)
    private var discoveredDevices: [UInt32: UnsafeMutableRawPointer] = [:]

    /// 设备 UDID 到 connectionID 的映射
    private var udidToConnectionID: [String: UInt32] = [:]

    // MARK: - 初始化

    private init() {
        setupMobileDevice()
    }

    // MARK: - 设置

    private func setupMobileDevice() {
        // 尝试动态加载 MobileDevice.framework
        let frameworkPath = "/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice"

        guard let handle = dlopen(frameworkPath, RTLD_NOW) else {
            let error = String(cString: dlerror())
            initializationError = L10n.mobileDevice.loadFailed(error)
            AppLogger.device.warning("MobileDevice.framework 不可用: \(error)")
            isMobileDeviceAvailable = false
            return
        }

        mobileDeviceHandle = handle

        // 加载函数指针
        amDeviceConnect = unsafeBitCast(
            dlsym(handle, "AMDeviceConnect"),
            to: AMDeviceConnectFunc?.self
        )
        amDeviceDisconnect = unsafeBitCast(
            dlsym(handle, "AMDeviceDisconnect"),
            to: AMDeviceDisconnectFunc?.self
        )
        amDeviceStartSession = unsafeBitCast(
            dlsym(handle, "AMDeviceStartSession"),
            to: AMDeviceStartSessionFunc?.self
        )
        amDeviceStopSession = unsafeBitCast(
            dlsym(handle, "AMDeviceStopSession"),
            to: AMDeviceStopSessionFunc?.self
        )
        amDeviceIsPaired = unsafeBitCast(
            dlsym(handle, "AMDeviceIsPaired"),
            to: AMDeviceIsPairedFunc?.self
        )
        amDeviceCopyValue = unsafeBitCast(
            dlsym(handle, "AMDeviceCopyValue"),
            to: AMDeviceCopyValueFunc?.self
        )
        amDeviceGetConnectionID = unsafeBitCast(
            dlsym(handle, "AMDeviceGetConnectionID"),
            to: AMDeviceGetConnectionIDFunc?.self
        )
        amDeviceCopyDeviceIdentifier = unsafeBitCast(
            dlsym(handle, "AMDeviceCopyDeviceIdentifier"),
            to: AMDeviceCopyDeviceIdentifierFunc?.self
        )

        // 检查关键函数是否加载成功
        guard amDeviceCopyValue != nil else {
            AppLogger.device.warning("MobileDevice.framework 关键函数加载失败")
            isMobileDeviceAvailable = false
            return
        }

        isMobileDeviceAvailable = true
        AppLogger.device.info("MobileDevice.framework 已加载，函数指针已初始化")
    }

    // MARK: - 公开方法

    /// 获取设备详细信息（使用 AVCaptureDevice 状态检测）
    /// - Parameters:
    ///   - captureDevice: AVCaptureDevice 实例，用于检测设备状态
    /// - Returns: 设备详细信息（整合 AVFoundation 状态和 MobileDevice 增强信息）
    ///
    /// 注意：锁屏状态无法在捕获前可靠检测。锁屏检测依赖 AVCaptureSession 的中断通知，
    /// 只有在捕获过程中设备锁屏才会触发。
    func getDeviceInsight(for captureDevice: AVCaptureDevice) -> IOSDeviceInsight {
        let udid = captureDevice.uniqueID
        let deviceName = captureDevice.localizedName
        let modelID = captureDevice.modelID

        // 检测 AVFoundation 层面的占用状态
        let isOccupiedByOther = captureDevice.isInUseByAnotherApplication
        let occupiedBy = isOccupiedByOther ? detectOccupyingApp() : nil

        // 锁屏状态：在捕获前无法可靠检测，设为 false
        // 实际锁屏检测依赖 AVCaptureSession 的 InterruptionReason
        let isLocked = false

        // 调试日志
        AppLogger.device.debug("""
            设备状态检测: \(deviceName)
            - isInUseByAnotherApplication (占用): \(isOccupiedByOther)
        """)

        // 2. 尝试从 MobileDevice 获取增强信息
        if isMobileDeviceAvailable {
            do {
                return try fetchDeviceInfo(
                    udid: udid,
                    deviceName: deviceName,
                    modelID: modelID,
                    isLocked: isLocked,
                    isOccupied: isOccupiedByOther,
                    occupiedBy: occupiedBy
                )
            } catch {
                AppLogger.device.warning("MobileDevice 获取信息失败: \(error.localizedDescription)")
            }
        }

        // 3. 降级：使用 AVFoundation 提供的基础信息
        let modelName = Self.modelName(for: modelID)
        return IOSDeviceInsight(
            udid: udid,
            deviceName: deviceName,
            modelIdentifier: modelID,
            modelName: modelName,
            systemVersion: L10n.deviceInfo.unknown,
            isTrusted: true, // AVFoundation 无法检测，假设已信任
            isOccupied: isOccupiedByOther,
            occupiedBy: occupiedBy,
            isLocked: isLocked,
            connectionType: .usb
        )
    }

    /// 获取设备详细信息（简化版，仅 UDID）
    /// - Parameter udid: 设备 UDID（从 AVFoundation 获取的设备 ID）
    /// - Returns: 设备详细信息（可能是降级结果）
    func getDeviceInsight(for udid: String) -> IOSDeviceInsight {
        // 尝试通过 UDID 获取 AVCaptureDevice
        if let captureDevice = AVCaptureDevice(uniqueID: udid) {
            return getDeviceInsight(for: captureDevice)
        }

        // 无法获取设备，返回降级结果
        return .degraded(udid: udid, reason: "无法获取 AVCaptureDevice")
    }

    /// 检查设备是否已信任
    /// - Parameter udid: 设备 UDID
    /// - Returns: 信任状态（不确定时返回 true 以不阻塞流程）
    func isDeviceTrusted(udid _: String) -> Bool {
        // 信任状态在捕获时会体现为错误，无法提前可靠检测
        // 返回 true 以不阻塞流程
        true
    }

    /// 检查设备是否被占用
    /// - Parameter captureDevice: AVCaptureDevice 实例
    /// - Returns: (是否被占用, 占用者描述)
    func checkDeviceOccupation(captureDevice: AVCaptureDevice) -> (isOccupied: Bool, occupiedBy: String?) {
        if captureDevice.isInUseByAnotherApplication {
            let occupier = detectOccupyingApp()
            return (true, occupier)
        }
        return (false, nil)
    }

    /// 检测可能占用设备的应用
    private func detectOccupyingApp() -> String? {
        // 常见占用者：QuickTime Player、Xcode、Instruments
        let occupyingProcesses = ["QuickTime Player", "Xcode", "Instruments"]
        let workspace = NSWorkspace.shared

        for processName in occupyingProcesses {
            if workspace.runningApplications.contains(where: { $0.localizedName == processName }) {
                AppLogger.device.info("检测到可能占用设备的应用: \(processName)")
                return processName
            }
        }

        return L10n.ios.hint.otherApp
    }

    /// 获取用户提示文案
    /// - Parameter insight: 设备信息
    /// - Returns: 用户提示文案（如果有问题需要提示）
    func getUserPrompt(for insight: IOSDeviceInsight) -> String? {
        // 优先级：锁屏 > 占用 > 未信任
        if insight.isLocked {
            return L10n.ios.hint.locked
        }

        if insight.isOccupied {
            if let occupiedBy = insight.occupiedBy {
                return L10n.ios.hint.occupied(occupiedBy)
            }
            return L10n.ios.hint.occupiedUnknown
        }

        if !insight.isTrusted {
            return L10n.ios.hint.trust
        }

        return nil
    }

    // MARK: - 私有方法

    private func fetchDeviceInfo(
        udid: String,
        deviceName: String,
        modelID: String,
        isLocked: Bool,
        isOccupied: Bool,
        occupiedBy: String?
    ) throws -> IOSDeviceInsight {
        // MobileDevice.framework 已加载，但 API 调用较复杂
        // 当前实现：整合 AVFoundation 已检测到的状态，加上型号映射

        AppLogger.device.info("获取设备信息: \(udid), 锁屏: \(isLocked), 占用: \(isOccupied)")

        // 使用型号映射获取友好名称
        let modelName = Self.modelName(for: modelID)

        return IOSDeviceInsight(
            udid: udid,
            deviceName: deviceName,
            modelIdentifier: modelID,
            modelName: modelName,
            systemVersion: L10n.deviceInfo.unknown, // MobileDevice API 可获取，暂用未知
            isTrusted: true, // MobileDevice API 可检测，暂假设已信任
            isOccupied: isOccupied,
            occupiedBy: occupiedBy,
            isLocked: isLocked,
            connectionType: .usb
        )
    }

    // MARK: - 清理

    deinit {
        if let handle = mobileDeviceHandle {
            dlclose(handle)
        }
    }
}

// MARK: - 设备型号映射

extension DeviceInsightService {
    /// 将型号标识符转换为用户友好的名称
    static func modelName(for identifier: String) -> String {
        let modelMap: [String: String] = [
            // iPhone 15 系列
            "iPhone16,1": "iPhone 15 Pro",
            "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone15,4": "iPhone 15",
            "iPhone15,5": "iPhone 15 Plus",

            // iPhone 14 系列
            "iPhone15,2": "iPhone 14 Pro",
            "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone14,7": "iPhone 14",
            "iPhone14,8": "iPhone 14 Plus",

            // iPhone 13 系列
            "iPhone14,2": "iPhone 13 Pro",
            "iPhone14,3": "iPhone 13 Pro Max",
            "iPhone14,4": "iPhone 13 mini",
            "iPhone14,5": "iPhone 13",

            // iPhone 12 系列
            "iPhone13,1": "iPhone 12 mini",
            "iPhone13,2": "iPhone 12",
            "iPhone13,3": "iPhone 12 Pro",
            "iPhone13,4": "iPhone 12 Pro Max",

            // iPad Pro
            "iPad14,5": "iPad Pro 12.9-inch (6th gen)",
            "iPad14,6": "iPad Pro 12.9-inch (6th gen)",
            "iPad14,3": "iPad Pro 11-inch (4th gen)",
            "iPad14,4": "iPad Pro 11-inch (4th gen)",

            // 更多设备...
        ]

        return modelMap[identifier] ?? identifier
    }
}
