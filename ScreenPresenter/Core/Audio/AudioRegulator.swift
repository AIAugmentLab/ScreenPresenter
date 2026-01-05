//
//  AudioRegulator.swift
//  ScreenPresenter
//
//  Created by Sun on 2026/1/07.
//
//  音频调节器
//  参考 scrcpy 的 audio_regulator.c 实现
//  使用环形缓冲区和自适应策略解决音频抖动问题
//

import AVFoundation
import Foundation

/// 音频调节器
/// 负责音频缓冲管理和流量控制，避免音频卡顿或延迟累积
final class AudioRegulator {
    // MARK: - 配置常量

    /// 目标缓冲时长（毫秒）
    /// scrcpy 默认 50ms
    private static let defaultTargetBufferingMs: Int = 50

    /// 最大缓冲时长（毫秒）
    /// 超过此值会丢弃旧数据
    private static let maxBufferingMs: Int = 200

    /// 重同步阈值（毫秒）
    /// 缓冲偏差超过此值时触发重同步
    private static let resyncThresholdMs: Int = 100

    /// 缓冲估算平滑系数
    private static let bufferingAlpha: Double = 0.05

    /// 补偿检测周期（样本数）
    private static let compensationCheckPeriod: Int = 960 // 20ms @ 48kHz

    // MARK: - 属性

    /// 采样率
    private let sampleRate: Int

    /// 声道数
    private let channels: Int

    /// 每样本字节数
    private let bytesPerSample: Int

    /// 目标缓冲样本数
    private let targetBuffering: Int

    /// 最大缓冲样本数
    private let maxBuffering: Int

    /// 重同步阈值样本数
    private let resyncThreshold: Int

    /// 环形缓冲区
    private var ringBuffer: RingBuffer<Float>

    /// 线程安全锁
    private let lock = NSLock()

    // MARK: - 状态

    /// 是否已接收到数据
    private var hasReceived = false

    /// 是否已开始播放
    private var hasPlayed = false

    /// 下溢样本计数（用于统计）
    private var underflowSamples: Int = 0

    /// 溢出样本计数（用于统计）
    private var overflowSamples: Int = 0

    /// 平均缓冲量（指数移动平均）
    private var avgBuffering: Double = 0

    /// 距上次重同步的样本数
    private var samplesSinceResync: Int = 0

    /// 累积补偿样本数
    private var compensationPending: Int = 0

    /// 上次日志时间
    private var lastLogTime: CFAbsoluteTime = 0

    // MARK: - 初始化

    /// 创建音频调节器
    /// - Parameters:
    ///   - targetBufferingMs: 目标缓冲时长（毫秒）
    ///   - sampleRate: 采样率（Hz）
    ///   - channels: 声道数
    init(
        targetBufferingMs: Int = defaultTargetBufferingMs,
        sampleRate: Int = 48000,
        channels: Int = 2
    ) {
        self.sampleRate = sampleRate
        self.channels = channels
        bytesPerSample = MemoryLayout<Float>.size

        // 计算缓冲样本数
        targetBuffering = targetBufferingMs * sampleRate / 1000
        maxBuffering = Self.maxBufferingMs * sampleRate / 1000
        resyncThreshold = Self.resyncThresholdMs * sampleRate / 1000

        // 创建环形缓冲区（容量 = 最大缓冲 * 2 * 声道数）
        let bufferCapacity = maxBuffering * 2 * channels
        ringBuffer = RingBuffer<Float>(capacity: bufferCapacity + 1) // +1 for ring buffer implementation

        // 初始化平均缓冲估算
        avgBuffering = Double(targetBuffering)

        AppLogger.capture.info("""
        [AudioRegulator] 已初始化
        - 采样率: \(sampleRate)Hz
        - 声道数: \(channels)
        - 目标缓冲: \(targetBuffering) 样本 (\(targetBufferingMs)ms)
        - 最大缓冲: \(maxBuffering) 样本 (\(Self.maxBufferingMs)ms)
        """)
    }

    // MARK: - 推送数据（生产者）

    /// 推送音频数据到缓冲区
    /// - Parameter data: PCM 音频数据（Float32 interleaved 格式）
    func push(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }

        hasReceived = true

        let sampleCount = data.count / bytesPerSample / channels

        // 计算当前缓冲量
        let currentBuffered = ringBuffer.count / channels

        // 检查是否溢出
        if currentBuffered + sampleCount > maxBuffering {
            // 丢弃最旧的数据，为新数据腾出空间
            let overflow = currentBuffered + sampleCount - maxBuffering
            let samplesToDiscard = overflow * channels
            _ = ringBuffer.skip(samplesToDiscard)
            overflowSamples += overflow

            logOccasionally("[AudioRegulator] 缓冲区溢出，丢弃 \(overflow) 样本")
        }

        // 写入数据
        let written = ringBuffer.writeAudioSamples(from: data)

        if written < data.count / bytesPerSample {
            // 仍有数据未能写入（理论上不应该发生）
            AppLogger.capture.warning("[AudioRegulator] 写入不完整: \(written) / \(data.count / bytesPerSample)")
        }

        updateBufferingEstimate()
    }

    // MARK: - 拉取数据（消费者）

    /// 从缓冲区拉取音频数据
    /// - Parameter sampleCount: 需要的样本数（单声道）
    /// - Returns: Float 数组（interleaved 格式，长度 = sampleCount * channels）
    func pull(sampleCount: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        let frameCount = sampleCount * channels

        // 首次播放：检查是否有足够的缓冲
        if !hasPlayed {
            let bufferedSamples = ringBuffer.count / channels
            if bufferedSamples < targetBuffering {
                // 缓冲不足，返回静音
                return [Float](repeating: 0, count: frameCount)
            }
            hasPlayed = true
            // 避免在持有锁时访问 bufferedMs 属性（它也会获取锁，导致死锁）
            let bufferedMsValue = Double(bufferedSamples) * 1000.0 / Double(sampleRate)
            AppLogger.capture.info("[AudioRegulator] 开始播放，缓冲: \(bufferedSamples) 样本 (\(bufferedMsValue)ms)")
        }

        // 读取数据
        var output = ringBuffer.readAudioSamples(count: frameCount)

        // 处理下溢
        if output.count < frameCount {
            let silenceCount = frameCount - output.count
            output.append(contentsOf: [Float](repeating: 0, count: silenceCount))
            underflowSamples += silenceCount / channels

            if hasReceived {
                logOccasionally("[AudioRegulator] 下溢，插入 \(silenceCount / channels) 样本静音")
            }
        }

        // 更新重同步计数
        samplesSinceResync += sampleCount

        // 定期检查是否需要补偿
        if samplesSinceResync >= Self.compensationCheckPeriod {
            checkAndApplyCompensation()
            samplesSinceResync = 0
        }

        return output
    }

    // MARK: - 缓冲估算与补偿

    private func updateBufferingEstimate() {
        let currentBuffering = Double(ringBuffer.count / channels)

        // 指数移动平均
        avgBuffering = avgBuffering * (1 - Self.bufferingAlpha) + currentBuffering * Self.bufferingAlpha
    }

    private func checkAndApplyCompensation() {
        let deviation = avgBuffering - Double(targetBuffering)
        let deviationSamples = Int(deviation)

        // 累积补偿
        compensationPending += deviationSamples

        // 检查是否需要重同步
        if abs(compensationPending) > resyncThreshold {
            if compensationPending > 0 {
                // 缓冲过多：跳过一些样本
                let samplesToSkip = min(compensationPending, resyncThreshold / 2)
                _ = ringBuffer.skip(samplesToSkip * channels)
                compensationPending -= samplesToSkip

                logOccasionally("[AudioRegulator] 重同步：跳过 \(samplesToSkip) 样本")
            } else {
                // 缓冲不足：会在 pull 时自动插入静音
                compensationPending = 0
            }
        }
    }

    private func logOccasionally(_ message: String) {
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastLogTime > 1.0 { // 每秒最多记录一次
            AppLogger.capture.debug("\(message)")
            lastLogTime = now
        }
    }

    // MARK: - 状态查询

    /// 当前缓冲的样本数（单声道）
    var bufferedSamples: Int {
        lock.lock()
        defer { lock.unlock() }
        return ringBuffer.count / channels
    }

    /// 当前缓冲时长（毫秒）
    var bufferedMs: Double {
        Double(bufferedSamples) * 1000.0 / Double(sampleRate)
    }

    /// 目标缓冲时长（毫秒）
    var targetBufferingMs: Double {
        Double(targetBuffering) * 1000.0 / Double(sampleRate)
    }

    /// 平均缓冲量（样本数）
    var averageBufferedSamples: Double {
        lock.lock()
        defer { lock.unlock() }
        return avgBuffering
    }

    /// 下溢统计（样本数）
    var totalUnderflowSamples: Int {
        lock.lock()
        defer { lock.unlock() }
        return underflowSamples
    }

    /// 溢出统计（样本数）
    var totalOverflowSamples: Int {
        lock.lock()
        defer { lock.unlock() }
        return overflowSamples
    }

    // MARK: - 重置

    /// 重置调节器状态
    func reset() {
        lock.lock()
        defer { lock.unlock() }

        ringBuffer.clear()
        hasReceived = false
        hasPlayed = false
        underflowSamples = 0
        overflowSamples = 0
        avgBuffering = Double(targetBuffering)
        samplesSinceResync = 0
        compensationPending = 0

        AppLogger.capture.info("[AudioRegulator] 已重置")
    }

    /// 打印统计信息
    func logStatistics() {
        lock.lock()
        defer { lock.unlock() }

        AppLogger.capture.info("""
        [AudioRegulator] 统计信息
        - 当前缓冲: \(ringBuffer.count / channels) 样本 (\(String(format: "%.1f", bufferedMs))ms)
        - 平均缓冲: \(String(format: "%.1f", avgBuffering)) 样本
        - 下溢总计: \(underflowSamples) 样本
        - 溢出总计: \(overflowSamples) 样本
        """)
    }
}
