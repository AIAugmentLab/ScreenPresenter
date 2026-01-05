//
//  ScrcpyErrorHelper.swift
//  ScreenPresenter
//
//  Created by Sun on 2026/1/5.
//
//  Scrcpy 错误处理辅助类
//  提供友好的错误消息和恢复建议
//

import Foundation
import Network

// MARK: - Scrcpy 错误类型

/// Scrcpy 错误类型（用户友好）
enum ScrcpyError: LocalizedError {
    /// 端口被占用（可能是其他 scrcpy 正在运行）
    case portInUse(port: Int)
    /// 设备未连接或 USB 调试未启用
    case deviceNotReady(reason: String)
    /// ADB 端口转发失败
    case portForwardingFailed(reason: String)
    /// scrcpy-server 启动失败
    case serverStartFailed(reason: String)
    /// 连接超时
    case connectionTimeout
    /// 设备被其他程序占用（如另一个 scrcpy）
    case deviceBusy
    /// 设备被其他 scrcpy 进程占用
    case deviceOccupied
    /// 未知错误
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case let .portInUse(port):
            "端口 \(port) 被占用"
        case let .deviceNotReady(reason):
            "设备未就绪：\(reason)"
        case let .portForwardingFailed(reason):
            "端口转发失败：\(reason)"
        case let .serverStartFailed(reason):
            "服务启动失败：\(reason)"
        case .connectionTimeout:
            "连接超时"
        case .deviceBusy:
            "设备正被其他程序占用"
        case .deviceOccupied:
            "设备已被其他 scrcpy 占用"
        case let .unknown(message):
            message
        }
    }

    /// 用户友好的错误描述
    var userFriendlyDescription: String {
        switch self {
        case let .portInUse(port):
            "端口 \(port) 已被占用，可能有其他 scrcpy 正在运行"
        case let .deviceNotReady(reason):
            "设备未就绪：\(reason)"
        case .portForwardingFailed:
            "无法建立与设备的连接通道"
        case .serverStartFailed:
            "无法在设备上启动投屏服务"
        case .connectionTimeout:
            "连接设备超时"
        case .deviceBusy:
            "设备正被其他程序占用"
        case .deviceOccupied:
            "设备已被另一个 scrcpy 程序占用\n\n请先关闭命令行中运行的 scrcpy 或其他投屏软件"
        case let .unknown(message):
            message
        }
    }

    /// 恢复建议
    var recoverySuggestion: String? {
        switch self {
        case .portInUse:
            "请关闭其他 scrcpy 程序后重试，或点击「重置连接」"
        case .deviceNotReady:
            "请确保设备已连接并启用 USB 调试"
        case .portForwardingFailed:
            "请尝试重新插拔 USB 线或点击「重置连接」"
        case .serverStartFailed:
            "请尝试重新插拔 USB 线或重启\(L10n.app.name)"
        case .connectionTimeout:
            "请检查 USB 连接或点击「重置连接」"
        case .deviceBusy:
            "请关闭占用设备的程序后重试"
        case .deviceOccupied:
            "关闭其他 scrcpy 后，点击「重置连接」清理残留进程"
        case .unknown:
            "请点击「重置连接」后重试"
        }
    }

    /// 完整的错误消息（包含建议）
    var fullDescription: String {
        if let suggestion = recoverySuggestion {
            return "\(userFriendlyDescription)\n\n建议：\(suggestion)"
        }
        return userFriendlyDescription
    }
}

// MARK: - Scrcpy 错误辅助类

/// Scrcpy 错误辅助类
enum ScrcpyErrorHelper {
    /// 将底层错误转换为用户友好的 ScrcpyError
    static func mapError(_ error: Error, port: Int) -> ScrcpyError {
        let errorString = error.localizedDescription.lowercased()

        // 检查是否是端口占用错误
        if isPortInUseError(error) {
            return .portInUse(port: port)
        }

        // 检查是否是设备被其他 scrcpy 占用（常见情况：已经有一个 scrcpy 在连接设备）
        if isDeviceOccupiedError(error) {
            return .deviceOccupied
        }

        // 检查是否是连接超时
        if errorString.contains("timeout") || errorString.contains("超时") {
            return .connectionTimeout
        }

        // 检查是否是设备问题
        if errorString.contains("device") && (errorString.contains("not found") || errorString.contains("offline")) {
            return .deviceNotReady(reason: "设备未找到或已离线")
        }

        // 检查是否是 ADB 错误
        if errorString.contains("adb") || errorString.contains("forward") || errorString.contains("reverse") {
            return .portForwardingFailed(reason: extractReason(from: error))
        }

        // 检查是否是服务器启动错误
        if errorString.contains("server") || errorString.contains("scrcpy") {
            return .serverStartFailed(reason: extractReason(from: error))
        }

        // 默认返回未知错误
        return .unknown(extractReason(from: error))
    }

    /// 检查是否是设备被占用的错误
    static func isDeviceOccupiedError(_ error: Error) -> Bool {
        let errorString = error.localizedDescription.lowercased()

        // scrcpy-server 启动失败时的常见错误
        // 当另一个 scrcpy 已经连接时，服务端无法再次启动
        if
            errorString.contains("could not inject input event") ||
            errorString.contains("failed to start server") ||
            errorString.contains("device is already in use") ||
            errorString.contains("server connection failed") {
            return true
        }

        // 检查常见的视频编码器错误（设备资源被占用）
        if
            errorString.contains("encoder") || errorString.contains("codec"),
            errorString.contains("failed") || errorString.contains("error") || errorString.contains("unavailable") {
            return true
        }

        return false
    }

    /// 检查是否是端口占用错误
    static func isPortInUseError(_ error: Error) -> Bool {
        let errorString = error.localizedDescription.lowercased()

        // Network.framework 的端口占用错误
        if
            errorString.contains("address already in use") ||
            errorString.contains("错误48") ||
            errorString.contains("error 48") {
            return true
        }

        // NSError 检查
        let nsError = error as NSError
        if nsError.domain == "Network.NWError" && nsError.code == 48 {
            return true
        }

        // POSIX 错误码 48 = EADDRINUSE
        if nsError.code == 48 || nsError.code == Int(EADDRINUSE) {
            return true
        }

        return false
    }

    /// 提取错误的根本原因
    static func extractReason(from error: Error) -> String {
        // 尝试获取最内层的错误描述
        var currentError: Error = error
        var depth = 0
        let maxDepth = 5

        while depth < maxDepth {
            let nsError = currentError as NSError
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
                currentError = underlying
                depth += 1
            } else {
                break
            }
        }

        return currentError.localizedDescription
    }

    /// 检查端口是否可用
    /// 使用 lsof 检查端口是否被占用，这是最可靠的方法
    static func isPortAvailable(_ port: Int) -> Bool {
        // 方法1: 使用 lsof 检查任何使用该端口的连接（包括 LISTEN 和 ESTABLISHED）
        let lsofProcess = Process()
        lsofProcess.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        // 不使用 -sTCP:LISTEN，因为 scrcpy 接受连接后会关闭监听器
        // 直接检查所有使用该端口的连接
        lsofProcess.arguments = ["-i", ":\(port)", "-nP"]

        let pipe = Pipe()
        lsofProcess.standardOutput = pipe
        lsofProcess.standardError = FileHandle.nullDevice

        do {
            try lsofProcess.run()
            lsofProcess.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if
                let output = String(data: data, encoding: .utf8),
                !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // 检查输出是否包含该端口作为本地端口的 LISTEN 或使用
                // 格式通常是: localhost:27183 (LISTEN) 或 localhost:27183->... (ESTABLISHED)
                let lines = output.components(separatedBy: "\n")
                for line in lines {
                    // 跳过标题行
                    if line.hasPrefix("COMMAND") { continue }
                    // 检查是否有进程正在使用这个端口作为本地监听端口
                    // 格式: localhost:27183-> 或 *:27183
                    if line.contains(":\(port)->") || line.contains(":\(port) (LISTEN)") || line.contains("*:\(port)") {
                        return false
                    }
                }
            }
        } catch {
            // lsof 执行失败，使用备用方法
        }

        // 方法2: 使用 socket bind 测试（不使用 SO_REUSEADDR）
        let socketFD = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        // 注意：不设置 SO_REUSEADDR，这样才能正确检测端口是否被占用

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        return result == 0
    }

    /// 尝试释放占用的端口（通过 lsof + kill）
    /// 注意：这是一个激进的操作，可能会终止其他 scrcpy 进程
    static func tryReleasePort(_ port: Int) async -> Bool {
        // 使用 lsof 查找占用端口的进程
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-i", ":\(port)", "-t"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !output.isEmpty else {
                return true // 没有进程占用
            }

            // 解析 PID 并尝试终止（只终止 scrcpy 相关进程）
            let pids = output.components(separatedBy: .newlines).compactMap { Int($0) }
            for pid in pids {
                // 检查是否是 scrcpy 进程
                if await isScrcpyProcess(pid) {
                    AppLogger.process.info("[ScrcpyErrorHelper] 终止占用端口的 scrcpy 进程: \(pid)")
                    kill(Int32(pid), SIGTERM)
                }
            }

            // 等待一小段时间让进程退出
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5秒

            return isPortAvailable(port)
        } catch {
            AppLogger.process.warning("[ScrcpyErrorHelper] 无法检查端口占用: \(error.localizedDescription)")
            return false
        }
    }

    /// 检查进程是否是 scrcpy 相关进程
    private static func isScrcpyProcess(_ pid: Int) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "comm="]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.lowercased() {
                return output.contains("scrcpy") || output.contains("adb")
            }
        } catch {
            // 忽略错误
        }

        return false
    }
}
