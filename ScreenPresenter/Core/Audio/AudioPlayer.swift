//
//  AudioPlayer.swift
//  ScreenPresenter
//
//  Created by Sun on 2026/1/6.
//
//  音频播放器
//  用于播放从设备捕获的音频流
//  支持音量控制和静音功能
//

import AVFoundation
import CoreMedia
import Foundation

// MARK: - 音频播放器

/// 音频播放器
/// 使用 AVAudioEngine 播放从设备捕获的音频采样
final class AudioPlayer {
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
            mixerNode?.outputVolume = volume
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
            AppLogger.capture.info("[AudioPlayer] 开始播放")
        } catch {
            AppLogger.capture.error("[AudioPlayer] 启动失败: \(error.localizedDescription)")
        }
    }

    /// 停止播放
    func stop() {
        guard isPlaying else { return }

        playerNode?.stop()
        audioEngine?.stop()
        isPlaying = false
        bufferCount = 0
        AppLogger.capture.info("[AudioPlayer] 停止播放")
    }

    /// 重置播放器
    func reset() {
        stop()

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

    // MARK: - 私有方法

    private func setupAudioEngine(format: AVAudioFormat) {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let mixer = AVAudioMixerNode()

        engine.attach(player)
        engine.attach(mixer)

        // 连接节点：player -> mixer -> output
        engine.connect(player, to: mixer, format: format)
        engine.connect(mixer, to: engine.outputNode, format: format)

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
}
