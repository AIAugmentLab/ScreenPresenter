//
//  ScrcpyOpusDecoder.swift
//  ScreenPresenter
//
//  Created by Sun on 2026/1/6.
//
//  Scrcpy OPUS 音频解码器
//  使用 alta/swift-opus 库解码 OPUS 音频
//

import AVFoundation
import Foundation
import Opus

// MARK: - Scrcpy OPUS 解码器

/// Scrcpy OPUS 解码器
/// 使用 alta/swift-opus 库解码 OPUS 音频数据
/// 输出为 Float32 PCM 数据供 AudioPlayer 播放
final class ScrcpyOpusDecoder {
    // MARK: - 属性

    /// OPUS 解码器
    private var opusDecoder: Opus.Decoder?

    /// 输出音频格式（供 AudioPlayer 使用）
    private(set) var outputAudioFormat: AVAudioFormat?

    /// 是否已初始化
    private(set) var isInitialized = false

    /// 是否已收到 Config Packet（OPUS 不需要，但保留接口兼容性）
    private(set) var hasReceivedConfig = false

    /// 解码后的 PCM 数据回调
    var onDecodedAudio: ((Data, AVAudioFormat) -> Void)?

    /// 采样率（OPUS 标准为 48000）
    private var sampleRate: Double = 48000

    /// 声道数
    private var channels: UInt32 = 2

    // MARK: - 初始化

    init() {}

    deinit {
        cleanup()
    }

    // MARK: - 公开方法

    /// 初始化解码器
    /// - Parameters:
    ///   - codecId: scrcpy 的 codec_id
    ///   - sampleRate: 采样率（默认 48000）
    ///   - channels: 声道数（默认 2）
    func initialize(codecId: UInt32, sampleRate: Double = 48000, channels: UInt32 = 2) {
        guard codecId == ScrcpyAudioStreamParser.codecIdOpus else {
            AppLogger.capture.error("[OpusDecoder] 不支持的编解码器: 0x\(String(format: "%08x", codecId))")
            return
        }

        self.sampleRate = sampleRate
        self.channels = channels

        // 创建输出格式（interleaved Float32 PCM）
        // 注意：alta/swift-opus 要求特定的格式
        outputAudioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: true
        )

        // 创建 OPUS 解码器
        createOpusDecoder()

        AppLogger.capture.info("[OpusDecoder] 已初始化，采样率: \(sampleRate)Hz, 声道: \(channels)")
    }

    /// 处理 Config Packet
    /// OPUS 不需要 Config Packet（Magic Cookie），但保留接口兼容性
    /// - Parameter data: Config Packet 数据
    func processConfigPacket(_ data: Data) {
        // OPUS 编解码器不需要额外的配置数据
        // scrcpy 发送的 OPUS config packet 通常是空的或包含编解码器信息
        hasReceivedConfig = true

        if data.count > 0 {
            AppLogger.capture.info("[OpusDecoder] 收到 Config Packet，长度: \(data.count) 字节（OPUS 不需要处理）")
        }
    }

    /// 解码 OPUS 数据包
    /// - Parameters:
    ///   - data: OPUS 编码的音频数据
    ///   - pts: 显示时间戳
    ///   - isKeyFrame: 是否为关键帧
    func decode(_ data: Data, pts: UInt64, isKeyFrame: Bool) {
        guard isInitialized, let decoder = opusDecoder, let format = outputAudioFormat else {
            AppLogger.capture.warning("[OpusDecoder] 解码器未初始化")
            return
        }

        do {
            // 使用 alta/swift-opus 解码
            let pcmBuffer = try decoder.decode(data)

            // 将 AVAudioPCMBuffer 转换为 Data
            guard let pcmData = convertPCMBufferToData(pcmBuffer) else {
                AppLogger.capture.error("[OpusDecoder] PCMBuffer 转换失败")
                return
            }

            // 回调解码后的 PCM 数据
            onDecodedAudio?(pcmData, format)

        } catch let error as Opus.Error {
            AppLogger.capture.error("[OpusDecoder] 解码失败: \(error)")
        } catch {
            AppLogger.capture.error("[OpusDecoder] 解码失败: \(error)")
        }
    }

    /// 清理资源
    func cleanup() {
        opusDecoder = nil
        isInitialized = false
        hasReceivedConfig = false
    }

    // MARK: - 私有方法

    /// 创建 OPUS 解码器
    private func createOpusDecoder() {
        do {
            // alta/swift-opus 需要特定的 PCM 格式
            // 支持 Int16 或 Float32，interleaved（单声道）或 非 interleaved（多声道）
            guard let pcmFormat = AVAudioFormat(
                opusPCMFormat: .float32,
                sampleRate: sampleRate,
                channels: AVAudioChannelCount(channels)
            ) else {
                AppLogger.capture.error("[OpusDecoder] 无法创建 PCM 格式")
                return
            }

            // 更新输出格式为 alta/swift-opus 返回的格式
            outputAudioFormat = pcmFormat

            opusDecoder = try Opus.Decoder(format: pcmFormat)
            isInitialized = true
            hasReceivedConfig = true // OPUS 不需要额外配置

            AppLogger.capture.info("[OpusDecoder] OPUS 解码器创建成功")

        } catch let error as Opus.Error {
            AppLogger.capture.error("[OpusDecoder] 创建解码器失败: \(error)")
            isInitialized = false
        } catch {
            AppLogger.capture.error("[OpusDecoder] 创建解码器失败: \(error)")
            isInitialized = false
        }
    }

    /// 将 AVAudioPCMBuffer 转换为 Data
    /// - Parameter buffer: PCM 缓冲区
    /// - Returns: PCM 数据
    private func convertPCMBufferToData(_ buffer: AVAudioPCMBuffer) -> Data? {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return nil }

        let channelCount = Int(buffer.format.channelCount)
        let bytesPerSample = 4 // Float32 = 4 bytes

        // alta/swift-opus 返回的格式：
        // - 单声道：interleaved
        // - 双声道：interleaved（根据创建时的 format）
        if buffer.format.isInterleaved {
            // interleaved 格式：直接复制
            guard let channelData = buffer.floatChannelData?[0] else { return nil }
            let byteCount = frameCount * channelCount * bytesPerSample
            return Data(bytes: channelData, count: byteCount)
        } else {
            // non-interleaved 格式：需要交织
            var interleavedData = Data(capacity: frameCount * channelCount * bytesPerSample)

            for frame in 0..<frameCount {
                for channel in 0..<channelCount {
                    if let channelData = buffer.floatChannelData?[channel] {
                        var sample = channelData[frame]
                        interleavedData.append(Data(bytes: &sample, count: bytesPerSample))
                    }
                }
            }

            return interleavedData
        }
    }
}
