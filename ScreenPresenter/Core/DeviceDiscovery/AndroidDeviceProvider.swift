//
//  AndroidDeviceProvider.swift
//  ScreenPresenter
//
//  Created by Sun on 2025/12/22.
//
//  Android 设备提供者
//  通过 adb 扫描并管理 Android 设备列表
//

import Combine
import Foundation

// MARK: - Android 设备提供者

@MainActor
final class AndroidDeviceProvider: ObservableObject {
    // MARK: - 状态

    /// 已发现的设备列表
    @Published private(set) var devices: [AndroidDevice] = []

    /// 是否正在监控
    @Published private(set) var isMonitoring = false

    /// 最后一次错误
    @Published private(set) var lastError: String?

    /// adb 服务是否运行中
    @Published private(set) var isAdbServerRunning = false

    // MARK: - 私有属性

    private let processRunner = ProcessRunner()
    private var monitoringTask: Task<Void, Never>?
    private let toolchainManager: ToolchainManager

    /// 轮询间隔（秒）
    private let pollingInterval: TimeInterval = 2.0

    // MARK: - 生命周期

    init(toolchainManager: ToolchainManager) {
        self.toolchainManager = toolchainManager
    }

    deinit {
        monitoringTask?.cancel()
    }

    // MARK: - 公开方法

    /// 开始监控设备
    func startMonitoring() {
        guard !isMonitoring else {
            AppLogger.device.debug("设备监控已在运行中")
            return
        }

        AppLogger.device.info("开始监控 Android 设备")
        isMonitoring = true
        lastError = nil

        monitoringTask = Task {
            await startAdbServer()

            while !Task.isCancelled, isMonitoring {
                await refreshDevices()
                try? await Task.sleep(nanoseconds: UInt64(pollingInterval * 1_000_000_000))
            }

            AppLogger.device.info("设备监控已停止")
        }
    }

    /// 停止监控
    func stopMonitoring() {
        AppLogger.device.info("停止监控 Android 设备")
        isMonitoring = false
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    /// 手动刷新设备列表
    func refreshDevices() async {

        do {
            let result = try await processRunner.run(
                toolchainManager.adbPath,
                arguments: ["devices", "-l"]
            )

            if result.isSuccess {
                var newDevices = parseDevices(from: result.stdout)

                // 为已授权设备获取详细信息
                for i in newDevices.indices {
                    if newDevices[i].state == .device {
                        newDevices[i] = await enrichDeviceInfo(newDevices[i])
                    }
                }

                // 只在设备列表真正变化时更新
                if newDevices != devices {
                    AppLogger.device.info("Android 设备列表已更新: \(newDevices.count) 个设备")
                    for device in newDevices {
                        AppLogger.device
                            .info(
                                "  - \(device.serial): \(device.state.rawValue), 名称: \(device.displayName), Android \(device.androidVersion ?? "?")"
                            )
                    }
                    devices = newDevices
                }

                isAdbServerRunning = true
                lastError = nil
            } else {
                AppLogger.device.error("adb devices 命令失败: \(result.stderr)")
                lastError = "adb 命令执行失败: \(result.stderr)"
            }
        } catch {
            AppLogger.device.error("刷新设备列表失败: \(error.localizedDescription)")
            lastError = error.localizedDescription
            isAdbServerRunning = false
        }
    }

    /// 获取设备详细信息
    private func enrichDeviceInfo(_ device: AndroidDevice) async -> AndroidDevice {
        var enriched = device

        // 并行获取所有属性以提高效率
        async let brand = getDeviceProperty(device.serial, property: "ro.product.brand")
        async let marketName = getDeviceProperty(device.serial, property: "ro.product.marketname")
        async let androidVersion = getDeviceProperty(device.serial, property: "ro.build.version.release")
        async let sdkVersion = getDeviceProperty(device.serial, property: "ro.build.version.sdk")

        enriched.brand = await brand
        enriched.marketName = await marketName
        enriched.androidVersion = await androidVersion
        enriched.sdkVersion = await sdkVersion

        // 获取定制系统信息
        await enrichCustomOsInfo(&enriched)

        // 某些设备没有 marketname，尝试其他属性
        // 注意：只有当值看起来像有效的市场名称时才使用（包含空格或长度超过型号）
        if !isValidMarketName(enriched.marketName) {
            let vendorMarketName = await getDeviceProperty(device.serial, property: "ro.product.vendor.marketname")
            if isValidMarketName(vendorMarketName) {
                enriched.marketName = vendorMarketName
            }
        }
        if !isValidMarketName(enriched.marketName) {
            let configMarketingName = await getDeviceProperty(device.serial, property: "ro.config.marketing_name")
            if isValidMarketName(configMarketingName) {
                enriched.marketName = configMarketingName
            }
        }
        // OnePlus 等设备使用 ro.product.odm.marketname
        if !isValidMarketName(enriched.marketName) {
            let odmMarketName = await getDeviceProperty(device.serial, property: "ro.product.odm.marketname")
            if isValidMarketName(odmMarketName) {
                enriched.marketName = odmMarketName
            }
        }
        // 尝试 ro.display.series（某些 OnePlus 设备使用）
        if !isValidMarketName(enriched.marketName) {
            let displaySeries = await getDeviceProperty(device.serial, property: "ro.display.series")
            if isValidMarketName(displaySeries) {
                enriched.marketName = displaySeries
            }
        }
        // 尝试 ro.vendor.oplus.market.name（OPLUS/OnePlus 设备）
        if !isValidMarketName(enriched.marketName) {
            let oplusMarketName = await getDeviceProperty(device.serial, property: "ro.vendor.oplus.market.name")
            if isValidMarketName(oplusMarketName) {
                enriched.marketName = oplusMarketName
            }
        }
        // 尝试 ro.oplus.market.name
        if !isValidMarketName(enriched.marketName) {
            let oplusMarketName2 = await getDeviceProperty(device.serial, property: "ro.oplus.market.name")
            if isValidMarketName(oplusMarketName2) {
                enriched.marketName = oplusMarketName2
            }
        }

        // 如果还是没有有效的市场名称，清空它让 displayName 使用 brand + model
        if !isValidMarketName(enriched.marketName) {
            enriched.marketName = nil
        }

        return enriched
    }

    /// 检查是否是有效的市场名称
    /// 有效的市场名称通常包含空格（如 "OnePlus 13T"）或者长度大于典型型号
    private func isValidMarketName(_ name: String?) -> Bool {
        guard let name = name, !name.isEmpty else { return false }
        // 包含空格的名称通常是有效的市场名称
        if name.contains(" ") { return true }
        // 纯数字或型号代码通常不是有效的市场名称
        let alphanumericOnly = name.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "", options: .regularExpression)
        // 如果全是大写字母和数字的组合（如 PKX110, SM_G998B），可能是型号
        let isLikelyModelCode = alphanumericOnly.uppercased() == alphanumericOnly && alphanumericOnly.count <= 10
        return !isLikelyModelCode
    }

    /// 启动 adb 服务
    func startAdbServer() async {
        AppLogger.device.info("启动 adb 服务...")

        do {
            let result = try await processRunner.run(
                toolchainManager.adbPath,
                arguments: ["start-server"]
            )
            isAdbServerRunning = result.isSuccess

            if result.isSuccess {
                AppLogger.device.info("adb 服务已启动")
            } else {
                AppLogger.device.error("adb 服务启动失败: \(result.stderr)")
            }
        } catch {
            isAdbServerRunning = false
            lastError = L10n.adb.startFailed(error.localizedDescription)
            AppLogger.device.error("adb 服务启动异常: \(error.localizedDescription)")
        }
    }

    /// 停止 adb 服务
    func stopAdbServer() async {
        AppLogger.device.info("停止 adb 服务...")

        do {
            _ = try await processRunner.run(
                toolchainManager.adbPath,
                arguments: ["kill-server"]
            )
            isAdbServerRunning = false
            devices = []
            AppLogger.device.info("adb 服务已停止")
        } catch {
            lastError = L10n.adb.stopFailed(error.localizedDescription)
            AppLogger.device.error("停止 adb 服务失败: \(error.localizedDescription)")
        }
    }

    /// 获取特定设备
    func device(for serial: String) -> AndroidDevice? {
        devices.first { $0.serial == serial }
    }

    // MARK: - 私有方法

    /// 解析 adb devices -l 输出
    private func parseDevices(from output: String) -> [AndroidDevice] {
        output
            .components(separatedBy: .newlines)
            .compactMap { AndroidDevice.parse(from: $0) }
    }
}

// MARK: - 设备操作扩展

extension AndroidDeviceProvider {
    /// 获取设备属性
    func getDeviceProperty(_ serial: String, property: String) async -> String? {
        do {
            let result = try await processRunner.run(
                toolchainManager.adbPath,
                arguments: ["-s", serial, "shell", "getprop", property]
            )
            if result.isSuccess {
                return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            // 忽略
        }
        return nil
    }

    /// 获取设备品牌
    func getDeviceBrand(_ serial: String) async -> String? {
        await getDeviceProperty(serial, property: "ro.product.brand")
    }

    /// 获取 Android 版本
    func getAndroidVersion(_ serial: String) async -> String? {
        await getDeviceProperty(serial, property: "ro.build.version.release")
    }

    /// 获取定制系统信息
    /// 支持：ColorOS, MIUI, HyperOS, One UI, OxygenOS, Flyme, EMUI, MagicOS 等
    private func enrichCustomOsInfo(_ device: inout AndroidDevice) async {
        let serial = device.serial

        // ColorOS (OnePlus/OPPO/Realme)
        if let colorOsVersion = await getDeviceProperty(serial, property: "ro.oplus.version") {
            device.customOsName = "ColorOS"
            device.customOsVersion = colorOsVersion
            return
        }
        if let colorOsVersion = await getDeviceProperty(serial, property: "ro.build.version.opporom") {
            device.customOsName = "ColorOS"
            device.customOsVersion = colorOsVersion
            return
        }

        // MIUI/HyperOS (Xiaomi/Redmi/POCO)
        if let miuiVersion = await getDeviceProperty(serial, property: "ro.miui.ui.version.name") {
            // 检查是否是 HyperOS
            if let hyperOsVersion = await getDeviceProperty(serial, property: "ro.mi.os.version.name"),
               !hyperOsVersion.isEmpty
            {
                device.customOsName = "HyperOS"
                device.customOsVersion = hyperOsVersion
            } else {
                device.customOsName = "MIUI"
                device.customOsVersion = miuiVersion
            }
            return
        }

        // One UI (Samsung)
        if let oneUiVersion = await getDeviceProperty(serial, property: "ro.build.version.oneui") {
            // One UI 版本通常是数字格式，如 50100 表示 5.1
            let formatted = formatOneUiVersion(oneUiVersion)
            device.customOsName = "One UI"
            device.customOsVersion = formatted
            return
        }

        // OxygenOS (OnePlus 海外版)
        if let oxygenVersion = await getDeviceProperty(serial, property: "ro.oxygen.version") {
            device.customOsName = "OxygenOS"
            device.customOsVersion = oxygenVersion
            return
        }

        // Flyme (Meizu)
        if let flymeVersion = await getDeviceProperty(serial, property: "ro.build.display.id") {
            if flymeVersion.lowercased().contains("flyme") {
                device.customOsName = "Flyme"
                // 提取版本号
                if let match = flymeVersion.range(of: #"\d+(\.\d+)*"#, options: .regularExpression) {
                    device.customOsVersion = String(flymeVersion[match])
                }
                return
            }
        }

        // EMUI/HarmonyOS (Huawei)
        if let emuiVersion = await getDeviceProperty(serial, property: "ro.build.version.emui") {
            // 检查是否是 HarmonyOS
            if let harmonyVersion = await getDeviceProperty(serial, property: "hw_sc.build.os.version"),
               !harmonyVersion.isEmpty
            {
                device.customOsName = "HarmonyOS"
                device.customOsVersion = harmonyVersion
            } else {
                device.customOsName = "EMUI"
                // EMUI 版本格式通常是 EmotionUI_X.X.X
                if let match = emuiVersion.range(of: #"\d+(\.\d+)*"#, options: .regularExpression) {
                    device.customOsVersion = String(emuiVersion[match])
                }
            }
            return
        }

        // MagicOS (Honor)
        if let magicVersion = await getDeviceProperty(serial, property: "ro.build.version.magic") {
            device.customOsName = "MagicOS"
            device.customOsVersion = magicVersion
            return
        }

        // Vivo OriginOS
        if let originVersion = await getDeviceProperty(serial, property: "ro.vivo.os.version") {
            device.customOsName = "OriginOS"
            device.customOsVersion = originVersion
            return
        }
    }

    /// 格式化 One UI 版本号
    /// 例如：50100 -> 5.1, 40000 -> 4.0
    private func formatOneUiVersion(_ version: String) -> String {
        guard let versionNum = Int(version) else { return version }
        let major = versionNum / 10000
        let minor = (versionNum % 10000) / 100
        if minor == 0 {
            return "\(major)"
        }
        return "\(major).\(minor)"
    }
}
