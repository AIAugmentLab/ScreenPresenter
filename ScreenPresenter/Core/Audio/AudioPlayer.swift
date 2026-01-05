//
//  AudioPlayer.swift
//  ScreenPresenter
//
//  Created by Sun on 2026/1/6.
//
//  音频播放器
//  用于播放从设备捕获的音频流
//  支持音量控制、静音功能和缓冲调节
//

import AVFoundation
import CoreMedia
import Foundation

// MARK: - 音频播放器

/// 音频播放器
/// 使用 AVAudioEngine 播放从设备捕获的音频采样
/// 支持两种模式：
/// 1. 推送模式（直接调度缓冲区）- 简单但可能有抖动
/// 2. 拉取模式（通过 AudioRegulator）- 更平滑的播放体验
final class AudioPlayer {
    // MARK: - 常量

    /// 拉取模式缓冲区大小（帧数）
    /// 10ms @ 48kHz = 480 samples
    private static let pullBufferFrameCount: AVAudioFrameCount = 480

    // MARK: - 属性

    /// 音频引擎
    private var audioEngine: AVAudioEngine?

    /// 播放节点
    private var playerNode: AVAudioPlayerNode?

    /// 混音节点（用于音量控制）
    private var mixerNode: AVAudioMixerNode?

    /// 音频格式
    private var audioFormat: AVAudioFormat?

    /// 是否正在播放
    private(set) var isPlaying = false

    /// 是否已初始化
    private(set) var isInitialized = false

    /// 音量 (0.0 - 1.0)
    var volume: Float = 1.0 {
        didSet {
            mixerNode?.outputVolume = isMuted ? 0 : volume
        }
    }

    /// 是否静音
    var isMuted: Bool = false {
        didSet {
            mixerNode?.outputVolume = isMuted ? 0 : volume
        }
    }

    /// 音频队列（用于缓冲）
    private var audioQueue = DispatchQueue(label: "com.screenPresenter.audioPlayer", qos: .userInteractive)

    /// 缓冲区计数（用于调试）
    private var bufferCount = 0

    // MARK: - 音频调节器

    /// 音频调节器（可选，启用后使用拉取模式）
    private var audioRegulator: AudioRegulator?

    /// 是否使用拉取模式
    private var usePullMode = false

    /// 拉取定时器
    private var pullTimer: DispatchSourceTimer?

    /// 拉取模式的输出格式
    private var pullOutputFormat: AVAudioFormat?

    // MARK: - 初始化

    init() {}

    deinit {
        stop()
    }

    // MARK: - 公开方法

    /// 从 CMSampleBuffer 初始化音频格式
    /// - Parameter sampleBuffer: 包含音频格式信息的采样缓冲
    /// - Returns: 是否成功初始化
    @discardableResult
    func initializeFromSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard !isInitialized else { return true }

        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            AppLogger.capture.error("[AudioPlayer] 无法获取格式描述")
            return false
        }

        // 获取 AudioStreamBasicDescription
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            AppLogger.capture.error("[AudioPlayer] 无法获取 AudioStreamBasicDescription")
            return false
        }

        // 创建 AVAudioFormat
        guard let format = AVAudioFormat(streamDescription: asbd) else {
            AppLogger.capture.error("[AudioPlayer] 无法创建 AVAudioFormat")
            return false
        }

        audioFormat = format

        // 设置音频引擎
        setupAudioEngine(format: format)

        isInitialized = true
        AppLogger.capture.info("[AudioPlayer] 已初始化，格式: \(format.sampleRate)Hz, \(format.channelCount)ch")

        return true
    }

    /// 启动播放
    func start() {
        guard isInitialized, !isPlaying else { return }

        do {
            try audioEngine?.start()
            playerNode?.play()
            isPlaying = true

            // 如果启用了调节器，启动拉取模式
            if usePullMode {
                startPullMode()
            }

            AppLogger.capture.info("[AudioPlayer] 开始播放 (模式: \(usePullMode ? "拉取" : "推送"))")
        } catch {
            AppLogger.capture.error("[AudioPlayer] 启动失败: \(error.localizedDescription)")
        }
    }

    /// 停止播放
    func stop() {
        guard isPlaying else { return }

        // 停止拉取定时器
        stopPullTimer()

        playerNode?.stop()
        audioEngine?.stop()
        isPlaying = false
        bufferCount = 0
        AppLogger.capture.info("[AudioPlayer] 停止播放")
    }

    /// 重置播放器
    func reset() {
        stop()

        // 重置调节器
        audioRegulator?.reset()

        audioEngine = nil
        playerNode = nil
        mixerNode = nil
        audioFormat = nil
        isInitialized = false

        AppLogger.capture.info("[AudioPlayer] 已重置")
    }

    /// 处理音频采样缓冲
    /// - Parameter sampleBuffer: 从设备捕获的音频采样
    func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        // 确保已初始化
        if !isInitialized {
            if !initializeFromSampleBuffer(sampleBuffer) {
                return
            }
            start()
        }

        guard isPlaying, let playerNode, let audioFormat else { return }

        // 使用 autoreleasepool 避免内存累积
        autoreleasepool {
            // 将 CMSampleBuffer 转换为 AVAudioPCMBuffer
            guard let pcmBuffer = createPCMBuffer(from: sampleBuffer, format: audioFormat) else {
                return
            }

            // 调度缓冲区播放
            playerNode.scheduleBuffer(pcmBuffer, completionHandler: nil)

            bufferCount += 1
        }
    }

    /// 从 AVAudioFormat 初始化播放器
    /// - Parameter format: 音频格式
    /// - Returns: 是否成功初始化
    @discardableResult
    func initializeFromFormat(_ format: AVAudioFormat) -> Bool {
        guard !isInitialized else { return true }

        // 保存原始格式（可能是 interleaved）
        audioFormat = format

        // 创建 AVAudioEngine 使用的 non-interleaved 格式
        // AVAudioEngine 默认需要 non-interleaved 格式
        let engineFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: format.channelCount,
            interleaved: false
        )

        guard let engineFormat else {
            AppLogger.capture.error("[AudioPlayer] 无法创建 non-interleaved 格式")
            return false
        }

        // 设置音频引擎（使用 non-interleaved 格式）
        setupAudioEngine(format: engineFormat)

        isInitialized = true
        AppLogger.capture.info("[AudioPlayer] 已初始化，采样率: \(format.sampleRate)Hz, 声道: \(format.channelCount)")

        return true
    }

    /// 处理 PCM 数据
    /// - Parameters:
    ///   - data: PCM 音频数据（Float32 格式，interleaved）
    ///   - format: 音频格式
    func processPCMData(_ data: Data, format: AVAudioFormat) {
        // 确保已初始化
        if !isInitialized {
            if !initializeFromFormat(format) {
                return
            }
            start()
        }

        guard isPlaying, let playerNode else {
            return
        }

        // 如果使用拉取模式，将数据推送到调节器
        if usePullMode, let regulator = audioRegulator {
            regulator.push(data)
            return
        }

        // 推送模式：直接调度缓冲区
        autoreleasepool {
            // 将 interleaved Data 转换为 non-interleaved AVAudioPCMBuffer
            guard let pcmBuffer = createPCMBuffer(from: data, inputFormat: format) else {
                return
            }

            // 调度缓冲区播放
            playerNode.scheduleBuffer(pcmBuffer, completionHandler: nil)
            bufferCount += 1
        }
    }

    // MARK: - 拉取模式（AudioRegulator 集成）

    /// 启用音频调节器（拉取模式）
    /// - Parameters:
    ///   - sampleRate: 采样率
    ///   - channels: 声道数
    ///   - targetBufferingMs: 目标缓冲时长（毫秒）
    func enableRegulator(sampleRate: Int = 48000, channels: Int = 2, targetBufferingMs: Int = 50) {
        audioRegulator = AudioRegulator(
            targetBufferingMs: targetBufferingMs,
            sampleRate: sampleRate,
            channels: channels
        )
        usePullMode = true

        // 创建拉取模式的输出格式
        pullOutputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channels),
            interleaved: false
        )

        AppLogger.capture.info("[AudioPlayer] 已启用音频调节器，目标缓冲: \(targetBufferingMs)ms")
    }

    /// 禁用音频调节器
    func disableRegulator() {
        stopPullTimer()
        audioRegulator?.reset()
        audioRegulator = nil
        usePullMode = false
        pullOutputFormat = nil

        AppLogger.capture.info("[AudioPlayer] 已禁用音频调节器")
    }

    /// 启动拉取模式播放
    private func startPullMode() {
        guard usePullMode, let regulator = audioRegulator, let format = pullOutputFormat else {
            return
        }

        // 停止现有的定时器
        stopPullTimer()

        // 创建定时器，周期性拉取数据
        // 10ms 周期 @ 48kHz = 480 samples
        let sampleRate = Int(format.sampleRate)
        let channels = Int(format.channelCount)
        let samplesPerPeriod = sampleRate / 100 // 10ms
        let intervalMs = 10

        let timer = DispatchSource.makeTimerSource(queue: audioQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(intervalMs))

        timer.setEventHandler { [weak self] in
            self?.pullAndScheduleAudio(
                regulator: regulator,
                format: format,
                sampleCount: samplesPerPeriod,
                channels: channels
            )
        }

        timer.resume()
        pullTimer = timer

        AppLogger.capture.info("[AudioPlayer] 拉取模式已启动，周期: \(intervalMs)ms, 每次 \(samplesPerPeriod) 样本")
    }

    /// 停止拉取定时器
    private func stopPullTimer() {
        pullTimer?.cancel()
        pullTimer = nil
    }

    /// 拉取音频数据并调度播放
    private func pullAndScheduleAudio(
        regulator: AudioRegulator,
        format: AVAudioFormat,
        sampleCount: Int,
        channels: Int
    ) {
        guard isPlaying, let playerNode else { return }

        // 从调节器拉取数据
        let samples = regulator.pull(sampleCount: sampleCount)

        // 如果没有数据，跳过（静音）
        if samples.isEmpty {
            return
        }

        // 转换为 AVAudioPCMBuffer
        guard
            let pcmBuffer = createPCMBuffer(
                fromInterleavedSamples: samples,
                format: format,
                channels: channels
            ) else {
            return
        }

        // 调度播放
        playerNode.scheduleBuffer(pcmBuffer, completionHandler: nil)
    }

    /// 从 interleaved Float 样本创建 non-interleaved PCM 缓冲区
    private func createPCMBuffer(
        fromInterleavedSamples samples: [Float],
        format: AVAudioFormat,
        channels: Int
    ) -> AVAudioPCMBuffer? {
        let frameCount = samples.count / channels
        guard frameCount > 0 else { return nil }

        guard
            let pcmBuffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
            ) else {
            return nil
        }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        // 分离声道：interleaved -> non-interleaved
        for channel in 0..<channels {
            guard let channelData = pcmBuffer.floatChannelData?[channel] else { continue }
            for frame in 0..<frameCount {
                channelData[frame] = samples[frame * channels + channel]
            }
        }

        return pcmBuffer
    }

    // MARK: - 私有方法

    private func setupAudioEngine(format: AVAudioFormat) {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let mixer = AVAudioMixerNode()

        engine.attach(player)
        engine.attach(mixer)

        // 连接节点：player -> mixer -> output
        // 使用指定的格式连接 player 到 mixer
        engine.connect(player, to: mixer, format: format)

        // 连接 mixer 到 output 时使用 nil 格式，让 AVAudioEngine 自动处理格式转换
        // 这可以避免格式不兼容的问题
        engine.connect(mixer, to: engine.outputNode, format: nil)

        // 设置音量
        mixer.outputVolume = isMuted ? 0 : volume

        audioEngine = engine
        playerNode = player
        mixerNode = mixer
    }

    private func createPCMBuffer(from sampleBuffer: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        // 获取采样数量
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0 else { return nil }

        // 创建 PCM 缓冲区
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(numSamples)) else {
            return nil
        }
        pcmBuffer.frameLength = AVAudioFrameCount(numSamples)

        // 获取音频数据
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )

        guard status == kCMBlockBufferNoErr, let data = dataPointer else {
            return nil
        }

        // 根据格式复制数据
        if format.isInterleaved {
            // 交错格式：直接复制
            if let channelData = pcmBuffer.floatChannelData?[0] {
                memcpy(channelData, data, length)
            } else if let channelData = pcmBuffer.int16ChannelData?[0] {
                memcpy(channelData, data, length)
            } else if let channelData = pcmBuffer.int32ChannelData?[0] {
                memcpy(channelData, data, length)
            }
        } else {
            // 非交错格式：分别复制每个声道
            let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
            let channelCount = Int(format.channelCount)
            let framesPerChannel = length / bytesPerFrame / channelCount

            for channel in 0..<channelCount {
                if let channelData = pcmBuffer.floatChannelData?[channel] {
                    let sourceOffset = channel * framesPerChannel * MemoryLayout<Float>.size
                    memcpy(channelData, data.advanced(by: sourceOffset), framesPerChannel * MemoryLayout<Float>.size)
                }
            }
        }

        return pcmBuffer
    }

    /// 从 Data 创建 PCM 缓冲区
    /// 输入是 interleaved Float32 数据，输出是 non-interleaved AVAudioPCMBuffer
    private func createPCMBuffer(from data: Data, inputFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let channelCount = Int(inputFormat.channelCount)
        let bytesPerSample = 4 // Float32 = 4 bytes
        let bytesPerFrame = bytesPerSample * channelCount

        let frameCount = data.count / bytesPerFrame
        guard frameCount > 0 else {
            return nil
        }

        // 创建 non-interleaved 格式的 PCM 缓冲区
        guard
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: inputFormat.sampleRate,
                channels: AVAudioChannelCount(channelCount),
                interleaved: false
            ) else {
            return nil
        }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(frameCount))
        else {
            return nil
        }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        // 从 interleaved 转换为 non-interleaved
        data.withUnsafeBytes { ptr in
            guard let srcBase = ptr.baseAddress else { return }
            let srcPtr = srcBase.assumingMemoryBound(to: Float.self)

            // 分离声道数据
            // 输入：[L0 R0 L1 R1 L2 R2 ...]
            // 输出：channel[0] = [L0 L1 L2 ...], channel[1] = [R0 R1 R2 ...]
            for channel in 0..<channelCount {
                guard let channelData = pcmBuffer.floatChannelData?[channel] else { continue }
                for frame in 0..<frameCount {
                    channelData[frame] = srcPtr[frame * channelCount + channel]
                }
            }
        }

        return pcmBuffer
    }
}
