//
//  ScrcpyRAWDecoder.swift
//  ScreenPresenter
//
//  Created by Sun on 2026/1/7.
//
//  Scrcpy RAW PCM 音频解码器
//  处理 scrcpy-server 发送的原始 PCM 数据（PCM_S16LE）
//

import AVFoundation
import Foundation

// MARK: - Scrcpy RAW PCM 解码器

/// Scrcpy RAW PCM 解码器
/// 处理 scrcpy-server 发送的原始 PCM 数据
/// 输入格式：PCM_S16LE（16-bit Little-Endian Signed Integer）
/// 输出格式：Float32 PCM 数据供 AudioPlayer 播放
final class ScrcpyRAWDecoder {
    // MARK: - 属性

    /// 输出音频格式（供 AudioPlayer 使用）
    private(set) var outputAudioFormat: AVAudioFormat?

    /// 是否已初始化
    private(set) var isInitialized = false

    /// 是否已收到 Config Packet（RAW 不需要，但保留接口兼容性）
    private(set) var hasReceivedConfig = false

    /// 解码后的 PCM 数据回调
    var onDecodedAudio: ((Data, AVAudioFormat) -> Void)?

    /// 采样率（scrcpy 固定为 48000）
    private var sampleRate: Double = 48000

    /// 声道数（scrcpy 固定为 2 立体声）
    private var channels: UInt32 = 2

    /// 解码成功计数（用于日志节流）
    private var decodeSuccessCount = 0

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
        guard codecId == ScrcpyAudioStreamParser.codecIdRAW else {
            AppLogger.capture.error("[RAWDecoder] 不支持的编解码器: 0x\(String(format: "%08x", codecId))")
            return
        }

        self.sampleRate = sampleRate
        self.channels = channels

        // 创建输出格式（interleaved Float32 PCM）
        outputAudioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: true
        )

        isInitialized = true

        AppLogger.capture.info("[RAWDecoder] 已初始化，采样率: \(sampleRate)Hz, 声道: \(channels)")
    }

    /// 处理 Config Packet
    /// RAW PCM 不需要 Config Packet，但保留接口兼容性
    /// - Parameter data: Config Packet 数据
    func processConfigPacket(_ data: Data) {
        // RAW PCM 编解码器不需要配置数据
        hasReceivedConfig = true

        if data.count > 0 {
            AppLogger.capture.info("[RAWDecoder] 收到 Config Packet，长度: \(data.count) 字节（RAW 不需要处理）")
        }
    }

    /// 解码 RAW PCM 数据包
    /// 将 Int16 Little-Endian 转换为 Float32
    /// - Parameters:
    ///   - data: RAW PCM 数据（PCM_S16LE 格式）
    ///   - pts: 显示时间戳
    ///   - isKeyFrame: 是否为关键帧（RAW 无此概念，忽略）
    func decode(_ data: Data, pts: UInt64, isKeyFrame: Bool) {
        guard isInitialized, let format = outputAudioFormat else {
            AppLogger.capture.warning("[RAWDecoder] 解码器未初始化")
            return
        }

        // 输入数据大小校验（每个样本 2 字节，立体声则为 4 字节每帧）
        let bytesPerSample = 2  // Int16
        let bytesPerFrame = Int(channels) * bytesPerSample
        
        guard data.count > 0, data.count % bytesPerFrame == 0 else {
            AppLogger.capture.warning("[RAWDecoder] 数据大小不正确: \(data.count) 字节，应为 \(bytesPerFrame) 的倍数")
            return
        }

        // 计算样本数
        let sampleCount = data.count / bytesPerSample

        // 转换 Int16 LE → Float32
        let float32Data = convertInt16LEToFloat32(data: data, sampleCount: sampleCount)

        // 回调解码后的 PCM 数据
        onDecodedAudio?(float32Data, format)

        // 日志节流
        decodeSuccessCount += 1
        if decodeSuccessCount == 1 || decodeSuccessCount % 100 == 0 {
            AppLogger.capture.debug("[RAWDecoder] 已解码 \(decodeSuccessCount) 个数据包，当前包: \(data.count) 字节 → \(float32Data.count) 字节")
        }
    }

    /// 清理资源
    func cleanup() {
        isInitialized = false
        hasReceivedConfig = false
        decodeSuccessCount = 0
    }

    // MARK: - 私有方法

    /// 将 Int16 Little-Endian 数据转换为 Float32
    /// - Parameters:
    ///   - data: 原始 Int16 LE 数据
    ///   - sampleCount: 样本数量
    /// - Returns: Float32 PCM 数据
    private func convertInt16LEToFloat32(data: Data, sampleCount: Int) -> Data {
        // 创建 Float32 输出缓冲区
        var float32Buffer = [Float](repeating: 0, count: sampleCount)

        // 读取 Int16 Little-Endian 并转换为 Float32
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            let int16Pointer = baseAddress.assumingMemoryBound(to: Int16.self)

            for i in 0..<sampleCount {
                // Int16 范围: -32768 ~ 32767
                // 归一化到 Float32 范围: -1.0 ~ 1.0
                // 使用 32768.0 作为除数，使 -32768 映射到 -1.0
                let int16Value = Int16(littleEndian: int16Pointer[i])
                float32Buffer[i] = Float(int16Value) / 32768.0
            }
        }

        // 转换为 Data
        return float32Buffer.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }
}
