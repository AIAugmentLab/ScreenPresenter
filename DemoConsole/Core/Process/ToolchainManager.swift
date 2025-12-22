//
//  ToolchainManager.swift
//  DemoConsole
//
//  Created by Sun on 2025/12/22.
//
//  工具链管理器
//  管理 Homebrew、adb、scrcpy 等工具的安装状态
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
final class ToolchainManager: ObservableObject {
    // MARK: - 常量

    /// 工具链安装目录（用于 scrcpy 检测）
    static let toolsDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("DemoConsole/tools", isDirectory: true)
    }()

    /// 内嵌的 adb 路径（在 App Bundle 中）
    var bundledAdbPath: String? {
        // 先尝试 tools 子目录，再尝试 Resources 根目录
        Bundle.main.path(forResource: "adb", ofType: nil, inDirectory: "tools")
            ?? Bundle.main.path(forResource: "adb", ofType: nil)
    }

    /// adb 路径（优先使用内嵌版本）
    var adbPath: String {
        if let bundled = bundledAdbPath, FileManager.default.fileExists(atPath: bundled) {
            return bundled
        }
        // 回退到系统安装的 adb
        return systemAdbPath ?? "/usr/local/bin/adb"
    }

    /// 系统安装的 adb 路径
    private var systemAdbPath: String?

    /// 系统安装的 scrcpy 路径
    private var systemScrcpyPath: String?

    /// scrcpy 路径
    var scrcpyPath: String {
        systemScrcpyPath ?? "/opt/homebrew/bin/scrcpy"
    }

    // MARK: - 状态

    @Published private(set) var adbStatus: ToolchainStatus = .notInstalled
    @Published private(set) var scrcpyStatus: ToolchainStatus = .notInstalled
    @Published private(set) var qvhStatus: ToolchainStatus = .notInstalled

    /// 是否全部就绪（Android 工具链）
    var isReady: Bool {
        adbStatus.isReady && scrcpyStatus.isReady
    }

    /// iOS 工具链是否就绪
    var isIOSReady: Bool {
        qvhStatus.isReady
    }

    /// 是否正在安装 scrcpy
    @Published private(set) var isInstallingScrcpy = false

    /// 安装日志
    @Published private(set) var installLog: String = ""

    // MARK: - 初始化

    private let processRunner = ProcessRunner()

    // MARK: - 公开方法

    /// 设置工具链
    func setup() async {
        // 创建工具目录
        try? FileManager.default.createDirectory(
            at: Self.toolsDirectory,
            withIntermediateDirectories: true
        )

        // 检查 adb（优先使用内嵌版本）
        await setupAdb()

        // 检查 scrcpy（需要用户安装）
        await checkScrcpy()

        // 检查 qvh（iOS 投屏工具）
        await checkQVH()
    }

    /// 重新检查工具链
    func refresh() async {
        await setupAdb()
        await checkScrcpy()
        await checkQVH()
    }

    // MARK: - qvh 检查

    /// 内嵌的 qvh 路径
    var bundledQVHPath: String? {
        // 先尝试 tools 子目录，再尝试 Resources 根目录
        Bundle.main.path(forResource: "qvh", ofType: nil, inDirectory: "tools")
            ?? Bundle.main.path(forResource: "qvh", ofType: nil)
    }

    /// qvh 路径
    var qvhPath: String {
        if let bundled = bundledQVHPath, FileManager.default.fileExists(atPath: bundled) {
            return bundled
        }
        return "/usr/local/bin/qvh"
    }

    /// 检查 qvh 是否已安装
    private func checkQVH() async {
        qvhStatus = .installing

        // 1. 首先检查内嵌的 qvh
        if let bundledPath = bundledQVHPath, FileManager.default.fileExists(atPath: bundledPath) {
            // 确保可执行权限
            await ensureExecutable(bundledPath)

            if let version = await getQVHVersion(bundledPath) {
                qvhStatus = .installed(version: "内嵌 \(version)")
                return
            }
        }

        // 2. 回退到系统安装的 qvh
        if let systemPath = await findSystemTool("qvh") {
            if let version = await getQVHVersion(systemPath) {
                qvhStatus = .installed(version: version)
                return
            }
        }

        // 3. 未找到 qvh
        qvhStatus = .notInstalled
    }

    /// 获取 qvh 版本
    private func getQVHVersion(_ path: String) async -> String? {
        do {
            let result = try await processRunner.run(path, arguments: ["--version"], timeout: 5)
            let output = result.stdout + result.stderr

            // qvh 输出 JSON 格式: {"version":"v0.6-beta"}
            // 但可能在 JSON 前有 GStreamer 警告，需要提取有效的 JSON 部分
            if let jsonStartIndex = output.firstIndex(of: "{") {
                let jsonString = String(output[jsonStartIndex...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if
                    let jsonData = jsonString.data(using: .utf8),
                    let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                    let version = json["version"] as? String {
                    return version
                }
            }

            // 如果解析失败但命令成功，返回 unknown
            if result.isSuccess {
                return "unknown"
            }
        } catch {
            // 忽略
        }
        return nil
    }

    // MARK: - adb 设置（内嵌 + 系统回退）

    private func setupAdb() async {
        adbStatus = .installing

        // 1. 首先检查内嵌的 adb
        if let bundledPath = bundledAdbPath {
            // 确保可执行权限
            await ensureExecutable(bundledPath)

            if let version = await getToolVersion(bundledPath, versionArgs: ["version"]) {
                adbStatus = .installed(version: "内嵌 v\(version)")
                return
            }
        }

        // 2. 回退到系统安装的 adb
        if let systemPath = await findSystemTool("adb") {
            systemAdbPath = systemPath
            if let version = await getToolVersion(systemPath, versionArgs: ["version"]) {
                adbStatus = .installed(version: version)
                return
            }
        }

        // 3. 未找到 adb
        adbStatus = .error("未找到 adb（内嵌版本可能损坏）")
    }

    // MARK: - scrcpy 检查和安装引导

    /// 检查 scrcpy 是否已安装
    private func checkScrcpy() async {
        scrcpyStatus = .installing

        // 检查系统中是否安装了 scrcpy
        if let systemPath = await findSystemTool("scrcpy") {
            systemScrcpyPath = systemPath
            if let version = await getToolVersion(systemPath, versionArgs: ["--version"]) {
                scrcpyStatus = .installed(version: version)
                return
            }
        }

        // 未安装
        scrcpyStatus = .notInstalled
    }

    /// 检查 Homebrew 是否已安装，返回 brew 路径
    func checkHomebrew() async -> Bool {
        if await findBrewPath() != nil {
            return true
        }
        return false
    }

    /// 查找 Homebrew 路径
    private func findBrewPath() async -> String? {
        // Homebrew 常见安装路径
        let brewPaths = [
            "/opt/homebrew/bin/brew", // Apple Silicon
            "/usr/local/bin/brew", // Intel Mac
            "/home/linuxbrew/.linuxbrew/bin/brew", // Linux
        ]

        for path in brewPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // 尝试用 shell 查找
        do {
            let result = try await processRunner.shell("/bin/zsh -l -c 'which brew'")
            if result.isSuccess {
                let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty, FileManager.default.fileExists(atPath: path) {
                    return path
                }
            }
        } catch {
            // 忽略
        }

        return nil
    }

    /// 一键安装 scrcpy（通过 Homebrew）
    func installScrcpy() async {
        guard !isInstallingScrcpy else { return }

        isInstallingScrcpy = true
        installLog = "🔍 正在检查 Homebrew...\n"
        scrcpyStatus = .installing

        // 直接检查常见的 Homebrew 路径
        let brewPaths = [
            "/opt/homebrew/bin/brew", // Apple Silicon
            "/usr/local/bin/brew", // Intel Mac
        ]

        var brewPath: String?
        for path in brewPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                brewPath = path
                break
            }
        }

        guard let foundBrewPath = brewPath else {
            installLog += "❌ 未检测到 Homebrew\n\n"
            installLog += "检查的路径:\n"
            for path in brewPaths {
                let exists = FileManager.default.fileExists(atPath: path)
                installLog += "  \(path): \(exists ? "存在" : "不存在")\n"
            }
            installLog += "\n请先安装 Homebrew:\n/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
            scrcpyStatus = .error("请先安装 Homebrew")
            isInstallingScrcpy = false
            return
        }

        // 获取版本信息
        do {
            let versionResult = try await processRunner.run(foundBrewPath, arguments: ["--version"])
            installLog += "✅ 找到 Homebrew: \(versionResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines))\n"
            installLog += "路径: \(foundBrewPath)\n\n"
        } catch {
            installLog += "✅ 找到 Homebrew: \(foundBrewPath)\n\n"
        }

        installLog += "🍺 正在通过 Homebrew 安装 scrcpy...\n\n"

        // 使用找到的 brew 路径直接执行安装
        do {
            _ = try await processRunner.startBackground(
                foundBrewPath,
                arguments: ["install", "scrcpy"],
                onOutput: { [weak self] output in
                    Task { @MainActor in
                        self?.installLog += output
                    }
                },
                onTermination: { [weak self] exitCode in
                    Task { @MainActor in
                        if exitCode == 0 {
                            self?.installLog += "\n\n✅ scrcpy 安装成功！"
                            await self?.refresh()
                        } else {
                            self?.installLog += "\n\n❌ 安装失败 (退出码: \(exitCode))"
                            self?.scrcpyStatus = .error("安装失败")
                        }
                        self?.isInstallingScrcpy = false
                    }
                }
            )
        } catch {
            installLog += "\n\n❌ 错误: \(error.localizedDescription)"
            scrcpyStatus = .error(error.localizedDescription)
            isInstallingScrcpy = false
        }
    }

    /// 打开终端手动安装
    func openTerminalForInstall() {
        let command = "brew install scrcpy"

        // 检测并使用用户安装的终端应用
        // 优先级: Warp > iTerm2 > Hyper > Terminal (系统自带)
        let terminalApps: [(bundleId: String, name: String)] = [
            ("dev.warp.Warp-Stable", "Warp"),
            ("com.googlecode.iterm2", "iTerm"),
            ("co.zeit.hyper", "Hyper"),
            ("com.apple.Terminal", "Terminal"),
        ]

        var selectedTerminal: (bundleId: String, name: String)?

        for app in terminalApps {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleId) != nil {
                selectedTerminal = app
                break
            }
        }

        guard let terminal = selectedTerminal else {
            // 回退到系统终端
            openInSystemTerminal(command)
            return
        }

        switch terminal.name {
        case "iTerm":
            openInITerm(command)
        case "Warp":
            openInWarp(command)
        case "Hyper":
            openInHyper(command)
        default:
            openInSystemTerminal(command)
        }
    }

    /// 在 iTerm2 中打开命令
    private func openInITerm(_ command: String) {
        let script = """
        tell application "iTerm"
            activate
            try
                set newWindow to (create window with default profile)
                tell current session of newWindow
                    write text "\(command)"
                end tell
            on error
                tell current window
                    create tab with default profile
                    tell current session
                        write text "\(command)"
                    end tell
                end tell
            end try
        end tell
        """
        runAppleScript(script)
    }

    /// 在 Warp 中打开命令
    private func openInWarp(_ command: String) {
        let script = """
        tell application "Warp"
            activate
        end tell
        delay 0.5
        tell application "System Events"
            keystroke "\(command)"
            keystroke return
        end tell
        """
        runAppleScript(script)
    }

    /// 在 Hyper 中打开命令
    private func openInHyper(_ command: String) {
        let script = """
        tell application "Hyper"
            activate
        end tell
        delay 0.5
        tell application "System Events"
            keystroke "\(command)"
            keystroke return
        end tell
        """
        runAppleScript(script)
    }

    /// 在系统终端中打开命令
    private func openInSystemTerminal(_ command: String) {
        let script = """
        tell application "Terminal"
            activate
            do script "\(command)"
        end tell
        """
        runAppleScript(script)
    }

    /// 执行 AppleScript
    private func runAppleScript(_ script: String) {
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }

    // MARK: - 辅助方法

    /// 在系统路径中查找工具
    private func findSystemTool(_ name: String) async -> String? {
        // 常见路径（按优先级排序）
        let commonPaths = [
            // Homebrew (Apple Silicon)
            "/opt/homebrew/bin/\(name)",
            // Homebrew (Intel)
            "/usr/local/bin/\(name)",
            // System
            "/usr/bin/\(name)",
            // MacPorts
            "/opt/local/bin/\(name)",
            // Android SDK 常见位置
            "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/\(name)",
        ]

        for path in commonPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // 使用 zsh 的登录 shell 来获取完整的 PATH
        do {
            // 使用 -l 参数让 zsh 加载配置文件（.zshrc 等）
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
            // 忽略权限设置错误
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
            "未安装"
        case .installing:
            "检查中..."
        case let .installed(version):
            version
        case let .error(message):
            message
        }
    }

    /// 获取 scrcpy 版本描述
    var scrcpyVersionDescription: String {
        switch scrcpyStatus {
        case .notInstalled:
            "未安装 - 点击安装"
        case .installing:
            "安装中..."
        case let .installed(version):
            "v\(version)"
        case let .error(message):
            message
        }
    }

    /// 获取 qvh 版本描述
    var qvhVersionDescription: String {
        switch qvhStatus {
        case .notInstalled:
            "未安装"
        case .installing:
            "检查中..."
        case let .installed(version):
            version
        case let .error(message):
            message
        }
    }

    /// scrcpy 是否需要安装
    var needsScrcpyInstall: Bool {
        if case .notInstalled = scrcpyStatus { return true }
        if case .error = scrcpyStatus { return true }
        return false
    }

    /// qvh 是否需要安装
    var needsQVHInstall: Bool {
        if case .notInstalled = qvhStatus { return true }
        if case .error = qvhStatus { return true }
        return false
    }
}
