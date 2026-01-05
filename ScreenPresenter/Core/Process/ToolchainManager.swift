//
//  ToolchainManager.swift
//  ScreenPresenter
//
//  Created by Sun on 2025/12/22.
//
//  工具链管理器
//  管理内置的 adb、scrcpy-server 工具
//  优先使用 Bundle 内置版本，回退到系统安装版本
//

import AppKit
import Foundation

// MARK: - 工具链状态

enum ToolchainStatus: Equatable {
    case notInstalled
    case installing
    case installed(version: String)
    case error(String)

    var isReady: Bool {
        if case .installed = self { return true }
        return false
    }
}

// MARK: - 工具链管理器

@MainActor
final class ToolchainManager {
    // MARK: - 常量

    /// Bundle 内置工具目录名
    private static let toolsDirectoryName = "Tools"

    // MARK: - 状态

    private(set) var adbStatus: ToolchainStatus = .notInstalled

    /// adb 是否就绪
    var isReady: Bool {
        adbStatus.isReady
    }

    /// 安装日志
    private(set) var installLog: String = ""

    // MARK: - 路径

    /// 内嵌的 adb 路径（在 App Bundle 中）
    var bundledAdbPath: String? {
        // 尝试多种路径
        if
            let path = Bundle.main.path(
                forResource: "adb",
                ofType: nil,
                inDirectory: "\(Self.toolsDirectoryName)/platform-tools"
            ) {
            return path
        }
        if let path = Bundle.main.path(forResource: "adb", ofType: nil, inDirectory: Self.toolsDirectoryName) {
            return path
        }
        return Bundle.main.path(forResource: "adb", ofType: nil, inDirectory: "tools")
    }

    /// 内嵌的 scrcpy-server 路径
    var bundledScrcpyServerPath: String? {
        if
            let path = Bundle.main
                .path(forResource: "scrcpy-server", ofType: nil, inDirectory: Self.toolsDirectoryName) {
            return path
        }
        return Bundle.main.path(forResource: "scrcpy-server", ofType: nil, inDirectory: "tools")
    }

    /// scrcpy-server 路径（优先级：自定义路径 > 内嵌版本）
    /// 如果路径是目录，会查找其中的 scrcpy-server.jar 文件
    var scrcpyServerPath: String? {
        // 1. 检查自定义路径
        if
            UserPreferences.shared.useCustomScrcpyServerPath,
            let customPath = UserPreferences.shared.customScrcpyServerPath,
            !customPath.isEmpty,
            let validPath = validateServerPath(customPath) {
            AppLogger.app.debug("使用自定义 scrcpy-server: \(validPath)")
            return validPath
        }

        // 2. 检查内嵌版本
        if let bundled = bundledScrcpyServerPath {
            if let validPath = validateServerPath(bundled) {
                return validPath
            }
        }

        AppLogger.app.warning("未找到 scrcpy-server")
        return nil
    }

    /// 验证 scrcpy-server 路径
    /// - Parameter path: 候选路径
    /// - Returns: 有效的服务器文件路径，如果是目录则查找其中的 jar 文件
    private func validateServerPath(_ path: String) -> String? {
        var isDirectory: ObjCBool = false

        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return nil
        }

        if isDirectory.boolValue {
            // 如果是目录，查找其中的 scrcpy-server.jar 或 scrcpy-server
            let jarPath = (path as NSString).appendingPathComponent("scrcpy-server.jar")
            if FileManager.default.fileExists(atPath: jarPath) {
                AppLogger.app.debug("在目录中找到 scrcpy-server.jar: \(jarPath)")
                return jarPath
            }

            let serverFile = (path as NSString).appendingPathComponent("scrcpy-server")
            if FileManager.default.fileExists(atPath: serverFile) {
                AppLogger.app.debug("在目录中找到 scrcpy-server: \(serverFile)")
                return serverFile
            }

            AppLogger.app.warning("scrcpy-server 路径是目录，但未找到有效的服务器文件: \(path)")
            return nil
        }

        // 是文件，直接返回
        return path
    }

    /// 系统安装的 adb 路径
    private var systemAdbPath: String?

    /// adb 路径（优先级：自定义路径 > 内嵌版本 > 系统版本）
    var adbPath: String {
        // 1. 检查自定义路径
        if
            UserPreferences.shared.useCustomAdbPath,
            let customPath = UserPreferences.shared.customAdbPath,
            !customPath.isEmpty,
            FileManager.default.isExecutableFile(atPath: customPath) {
            return customPath
        }

        // 2. 检查内嵌版本
        if let bundled = bundledAdbPath, FileManager.default.fileExists(atPath: bundled) {
            return bundled
        }

        // 3. 系统版本
        return systemAdbPath ?? "/usr/local/bin/adb"
    }

    // MARK: - 私有属性

    private let processRunner = ProcessRunner()

    // MARK: - 公开方法

    /// 设置工具链
    func setup() async {
        AppLogger.app.info("开始设置工具链")

        // 检查 adb
        await setupAdb()

        AppLogger.app.info("工具链设置完成 - adb: \(adbVersionDescription)")
    }

    /// 重新检查工具链
    func refresh() async {
        await setupAdb()
    }

    // MARK: - adb 设置

    private func setupAdb() async {
        adbStatus = .installing

        // 1. 首先检查内嵌的 adb
        if let bundledPath = bundledAdbPath, FileManager.default.fileExists(atPath: bundledPath) {
            // 确保可执行权限
            await ensureExecutable(bundledPath)

            if let version = await getToolVersion(bundledPath, versionArgs: ["version"]) {
                adbStatus = .installed(version: L10n.prefs.toolchain.bundled(version))
                return
            }
        }

        // 2. 查找系统安装的 adb
        if let systemPath = await findSystemTool("adb") {
            systemAdbPath = systemPath
            if let version = await getToolVersion(systemPath, versionArgs: ["version"]) {
                adbStatus = .installed(version: version)
                AppLogger.app.info("使用系统 adb: \(systemPath)")
                return
            }
        }

        // 3. 未找到 adb
        adbStatus = .error(L10n.prefs.toolchain.notFoundAdb)
        AppLogger.app.warning("未找到 adb")
    }

    // MARK: - 辅助方法

    /// 在系统路径中查找工具
    private func findSystemTool(_ name: String) async -> String? {
        let commonPaths = [
            "/opt/homebrew/bin/\(name)", // Homebrew (Apple Silicon)
            "/usr/local/bin/\(name)", // Homebrew (Intel)
            "/usr/bin/\(name)", // System
            "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/\(name)", // Android SDK
        ]

        for path in commonPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // 使用 which 命令查找
        do {
            let result = try await processRunner.shell("/bin/zsh -l -c 'which \(name)'")
            if result.isSuccess {
                let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty, !path.contains("not found"), FileManager.default.fileExists(atPath: path) {
                    return path
                }
            }
        } catch {
            // 忽略
        }

        return nil
    }

    /// 确保文件可执行
    private func ensureExecutable(_ path: String) async {
        do {
            _ = try await processRunner.shell("chmod +x '\(path)'")
        } catch {
            // 忽略
        }
    }

    /// 获取工具版本
    private func getToolVersion(_ path: String, versionArgs: [String]) async -> String? {
        do {
            let result = try await processRunner.run(path, arguments: versionArgs)
            let output = result.stdout + result.stderr

            // 提取版本号
            if let match = output.firstMatch(of: /(\d+\.\d+(\.\d+)?)/) {
                return String(match.1)
            }

            // 如果没有匹配到版本号但命令成功，返回 unknown
            if result.isSuccess {
                return "unknown"
            }
        } catch {
            // 忽略
        }
        return nil
    }
}

// MARK: - 便捷扩展

extension ToolchainManager {
    /// 获取 adb 版本描述
    var adbVersionDescription: String {
        switch adbStatus {
        case .notInstalled:
            L10n.prefs.toolchain.notInstalled
        case .installing:
            L10n.common.checking
        case let .installed(version):
            version
        case let .error(message):
            message
        }
    }
}
