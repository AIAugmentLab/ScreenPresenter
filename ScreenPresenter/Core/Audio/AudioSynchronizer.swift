//
//  AudioSynchronizer.swift
//  ScreenPresenter
//
//  Created by Sun on 2026/1/07.
//
//  音频同步器
//  基于 PTS 时间戳实现音视频同步
//  参考 scrcpy 的时间戳管理机制
//

import Foundation
import QuartzCore

/// 音频同步器
/// 负责基于 PTS 管理音视频同步，检测延迟漂移
final class AudioSynchronizer {
    // MARK: - 配置常量

    /// 目标延迟（毫秒）
    /// 音频相对于视频的目标延迟
    private static let defaultTargetDelayMs: Double = 50

    /// 漂移补偿阈值（毫秒）
    /// 超过此值时触发播放速度调整
    private static let driftThresholdMs: Double = 30

    /// 最大漂移（毫秒）
    /// 超过此值时触发丢帧或等待
    private static let maxDriftMs: Double = 200

    /// 漂移估算平滑系数
    private static let driftAlpha: Double = 0.1

    /// 播放速度调整步长
    private static let playbackRateStep: Float = 0.02  // 2%

    // MARK: - 属性

    /// 采样率
    private let sampleRate: Double

    /// 目标延迟（微秒）
    private let targetDelayUs: Int64

    // MARK: - 基准时间

    /// 第一个音频 PTS（微秒）
    private var firstAudioPts: UInt64?

    /// 第一个音频到达的系统时间
    private var firstAudioSystemTime: CFAbsoluteTime?

    /// 上一个处理的 PTS
    private var lastPts: UInt64 = 0

    // MARK: - 漂移追踪

    /// 估算的音频延迟（毫秒）
    private var estimatedDelayMs: Double = 0

    /// 累积漂移（毫秒）
    private var accumulatedDriftMs: Double = 0

    /// 漂移历史（用于平滑）
    private var driftHistory: [Double] = []

    /// 当前建议的播放速率
    private(set) var suggestedPlaybackRate: Float = 1.0

    // MARK: - 统计

    /// 丢弃的数据包数量
    private var droppedPackets: Int = 0

    /// 插入的静音数据包数量
    private var insertedSilence: Int = 0

    /// 不连续性检测计数
    private var discontinuityCount: Int = 0

    /// 线程安全锁
    private let lock = NSLock()

    // MARK: - 初始化

    /// 创建音频同步器
    /// - Parameters:
    ///   - sampleRate: 音频采样率
    ///   - targetDelayMs: 目标延迟（毫秒）
    init(sampleRate: Double = 48000, targetDelayMs: Double = defaultTargetDelayMs) {
        self.sampleRate = sampleRate
        self.targetDelayUs = Int64(targetDelayMs * 1000)
        self.estimatedDelayMs = targetDelayMs

        AppLogger.capture.info("""
            [AudioSynchronizer] 已初始化
            - 采样率: \(sampleRate)Hz
            - 目标延迟: \(targetDelayMs)ms
            """)
    }

    // MARK: - PTS 处理

    /// 音频数据包同步决策结果
    struct SyncDecision {
        /// 是否应该播放此数据包
        let shouldPlay: Bool
        /// 是否检测到不连续性
        let isDiscontinuity: Bool
        /// 当前延迟（毫秒）
        let currentDelayMs: Double
        /// 漂移量（毫秒）
        let driftMs: Double
        /// 建议的播放速率
        let suggestedRate: Float
    }

    /// 处理接收到的音频 PTS
    /// - Parameters:
    ///   - pts: scrcpy 音频 PTS（微秒）
    ///   - sampleCount: 该数据包的样本数
    /// - Returns: 同步决策
    func processAudioPts(_ pts: UInt64, sampleCount: Int) -> SyncDecision {
        lock.lock()
        defer { lock.unlock() }

        let now = CFAbsoluteTimeGetCurrent()

        // 首次接收，建立基准
        if firstAudioPts == nil {
            firstAudioPts = pts
            firstAudioSystemTime = now
            lastPts = pts

            AppLogger.capture.info("[AudioSynchronizer] 建立基准时间，PTS: \(pts)")
            return SyncDecision(
                shouldPlay: true,
                isDiscontinuity: false,
                currentDelayMs: Self.defaultTargetDelayMs,
                driftMs: 0,
                suggestedRate: 1.0
            )
        }

        // 检测不连续性
        let isDiscontinuity = detectDiscontinuity(currentPts: pts, previousPts: lastPts, sampleCount: sampleCount)
        if isDiscontinuity {
            discontinuityCount += 1
            // 重新建立基准
            firstAudioPts = pts
            firstAudioSystemTime = now
            accumulatedDriftMs = 0
            driftHistory.removeAll()

            AppLogger.capture.warning("[AudioSynchronizer] 检测到不连续性，重新建立基准")
        }

        lastPts = pts

        // 计算预期到达时间
        let ptsUs = Int64(pts)
        let ptsDeltaUs = ptsUs - Int64(firstAudioPts!)
        let expectedArrivalTime = firstAudioSystemTime! + Double(ptsDeltaUs) / 1_000_000.0

        // 计算实际延迟
        let actualDelayS = now - expectedArrivalTime
        let actualDelayMs = actualDelayS * 1000.0

        // 更新估算（指数移动平均）
        estimatedDelayMs = estimatedDelayMs * (1 - Self.driftAlpha) + actualDelayMs * Self.driftAlpha

        // 计算漂移
        let targetDelayMs = Double(targetDelayUs) / 1000.0
        let currentDriftMs = actualDelayMs - targetDelayMs
        accumulatedDriftMs = accumulatedDriftMs * (1 - Self.driftAlpha) + currentDriftMs * Self.driftAlpha

        // 记录漂移历史
        driftHistory.append(currentDriftMs)
        if driftHistory.count > 50 {
            driftHistory.removeFirst()
        }

        // 更新播放速率建议
        updateSuggestedPlaybackRate()

        // 决策：是否应该播放
        var shouldPlay = true
        if accumulatedDriftMs > Self.maxDriftMs {
            // 音频严重落后，丢弃此帧
            shouldPlay = false
            droppedPackets += 1
            AppLogger.capture.debug("[AudioSynchronizer] 丢弃数据包，漂移: \(String(format: "%.1f", accumulatedDriftMs))ms")
        } else if accumulatedDriftMs < -Self.maxDriftMs {
            // 音频严重超前，应该等待（但当前实现无法等待，只能记录）
            insertedSilence += 1
            AppLogger.capture.debug("[AudioSynchronizer] 音频超前，漂移: \(String(format: "%.1f", accumulatedDriftMs))ms")
        }

        return SyncDecision(
            shouldPlay: shouldPlay,
            isDiscontinuity: isDiscontinuity,
            currentDelayMs: actualDelayMs,
            driftMs: accumulatedDriftMs,
            suggestedRate: suggestedPlaybackRate
        )
    }

    // MARK: - 不连续性检测

    /// 检测 PTS 不连续性
    /// - Parameters:
    ///   - currentPts: 当前 PTS
    ///   - previousPts: 前一个 PTS
    ///   - sampleCount: 预期的样本数
    /// - Returns: 是否检测到不连续性
    private func detectDiscontinuity(currentPts: UInt64, previousPts: UInt64, sampleCount: Int) -> Bool {
        // 计算预期的 PTS 增量
        let expectedDurationUs = Int64(Double(sampleCount) / sampleRate * 1_000_000.0)

        // 计算实际 PTS 增量
        let actualDeltaUs: Int64
        if currentPts >= previousPts {
            actualDeltaUs = Int64(currentPts - previousPts)
        } else {
            // PTS 回绕（不太可能，但处理一下）
            return true
        }

        // 允许的误差范围（10%）
        let tolerance = expectedDurationUs / 10

        // 检查是否在预期范围内
        let difference = abs(actualDeltaUs - expectedDurationUs)
        return difference > max(tolerance, 100_000)  // 至少允许 100ms 的误差
    }

    // MARK: - 播放速率调整

    private func updateSuggestedPlaybackRate() {
        if accumulatedDriftMs > Self.driftThresholdMs {
            // 音频落后，需要加速
            suggestedPlaybackRate = min(1.0 + Self.playbackRateStep, 1.05)
        } else if accumulatedDriftMs < -Self.driftThresholdMs {
            // 音频超前，需要减速
            suggestedPlaybackRate = max(1.0 - Self.playbackRateStep, 0.95)
        } else {
            // 在可接受范围内，恢复正常速度
            suggestedPlaybackRate = 1.0
        }
    }

    // MARK: - 视频同步支持

    /// 视频帧同步信息
    struct VideoSyncInfo {
        /// 音频相对于视频的偏移（毫秒，正值表示音频落后）
        let audioVideoOffsetMs: Double
        /// 是否需要跳过视频帧
        let shouldSkipVideoFrame: Bool
        /// 是否需要等待音频
        let shouldWaitForAudio: Bool
    }

    /// 获取视频同步信息
    /// - Parameter videoPts: 视频 PTS（微秒）
    /// - Returns: 视频同步信息
    func getVideoSyncInfo(videoPts: UInt64) -> VideoSyncInfo {
        lock.lock()
        defer { lock.unlock() }

        // 计算音视频偏移
        let audioPts = lastPts
        let offsetUs = Int64(audioPts) - Int64(videoPts)
        let offsetMs = Double(offsetUs) / 1000.0

        // 决策
        let shouldSkipVideo = offsetMs < -Self.maxDriftMs  // 视频落后太多
        let shouldWait = offsetMs > Self.maxDriftMs  // 视频超前太多

        return VideoSyncInfo(
            audioVideoOffsetMs: offsetMs,
            shouldSkipVideoFrame: shouldSkipVideo,
            shouldWaitForAudio: shouldWait
        )
    }

    // MARK: - 状态查询

    /// 当前估算延迟（毫秒）
    var currentDelayMs: Double {
        lock.lock()
        defer { lock.unlock() }
        return estimatedDelayMs
    }

    /// 当前漂移（毫秒）
    var currentDriftMs: Double {
        lock.lock()
        defer { lock.unlock() }
        return accumulatedDriftMs
    }

    /// 漂移稳定性（标准差，毫秒）
    var driftStability: Double {
        lock.lock()
        defer { lock.unlock() }

        guard driftHistory.count > 1 else { return 0 }

        let mean = driftHistory.reduce(0, +) / Double(driftHistory.count)
        let squaredDiffs = driftHistory.map { ($0 - mean) * ($0 - mean) }
        let variance = squaredDiffs.reduce(0, +) / Double(driftHistory.count)
        return sqrt(variance)
    }

    // MARK: - 重置

    /// 重置同步器状态
    func reset() {
        lock.lock()
        defer { lock.unlock() }

        firstAudioPts = nil
        firstAudioSystemTime = nil
        lastPts = 0
        estimatedDelayMs = Double(targetDelayUs) / 1000.0
        accumulatedDriftMs = 0
        driftHistory.removeAll()
        suggestedPlaybackRate = 1.0
        droppedPackets = 0
        insertedSilence = 0
        discontinuityCount = 0

        AppLogger.capture.info("[AudioSynchronizer] 已重置")
    }

    /// 打印统计信息
    func logStatistics() {
        lock.lock()
        defer { lock.unlock() }

        AppLogger.capture.info("""
            [AudioSynchronizer] 统计信息
            - 当前延迟: \(String(format: "%.1f", estimatedDelayMs))ms
            - 当前漂移: \(String(format: "%.1f", accumulatedDriftMs))ms
            - 漂移稳定性: \(String(format: "%.1f", driftStability))ms
            - 建议播放速率: \(String(format: "%.2f", suggestedPlaybackRate))
            - 丢弃数据包: \(droppedPackets)
            - 插入静音: \(insertedSilence)
            - 不连续性: \(discontinuityCount)
            """)
    }
}
