//
//  ScrcpyAudioDecoder.swift
//  ScreenPresenter
//
//  Created by Sun on 2026/1/6.
//
//  Scrcpy 音频解码器
//  使用 AudioToolbox 解码 AAC 音频
//

import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

// MARK: - Scrcpy 音频解码器

/// Scrcpy 音频解码器
/// 使用 AudioToolbox 的 AudioConverter 解码 AAC 音频
/// 输出为 Float32 PCM 数据供 AudioPlayer 播放
final class ScrcpyAudioDecoder {
    // MARK: - 属性

    /// 音频转换器
    private var audioConverter: AudioConverterRef?

    /// 输入音频格式（AAC）
    /// 使用 fileprivate 以便外部的 C 回调函数可以访问
    fileprivate var inputFormat = AudioStreamBasicDescription()

    /// 输出音频格式（PCM）
    private var outputFormat = AudioStreamBasicDescription()

    /// 输入数据缓冲
    /// 使用 fileprivate 以便外部的 C 回调函数可以访问
    fileprivate var inputBuffer: Data?

    /// 输入数据的持久指针（用于 AudioConverter 回调）
    /// 必须在整个解码过程中保持有效
    fileprivate var inputBufferPointer: UnsafeRawPointer?

    /// 输入数据的大小
    fileprivate var inputBufferSize: UInt32 = 0

    /// 数据包描述（用于 VBR AAC）
    /// 使用 UnsafeMutablePointer 以便在回调中持久有效
    fileprivate var packetDescriptionPtr: UnsafeMutablePointer<AudioStreamPacketDescription>?

    /// AudioSpecificConfig (Magic Cookie)
    private var magicCookie: Data?

    /// 是否已初始化
    private(set) var isInitialized = false

    /// 是否已收到 Config Packet
    private(set) var hasReceivedConfig = false

    /// 解码成功计数（用于日志节流）
    private var decodeSuccessCount = 0

    /// 解码后的 PCM 数据回调
    var onDecodedAudio: ((Data, AVAudioFormat) -> Void)?

    /// 输出的 AVAudioFormat（供 AudioPlayer 使用）
    private(set) var outputAudioFormat: AVAudioFormat?

    /// 采样率
    private var sampleRate: Double = 48000

    /// 声道数
    private var channels: UInt32 = 2

    // MARK: - 初始化

    init() {
        // 分配 packet description 内存
        packetDescriptionPtr = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
        packetDescriptionPtr?.initialize(to: AudioStreamPacketDescription())
    }

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
        guard codecId == ScrcpyAudioStreamParser.codecIdAAC else {
            AppLogger.capture.error("[AudioDecoder] 不支持的编解码器: 0x\(String(format: "%08x", codecId))")
            return
        }

        self.sampleRate = sampleRate
        self.channels = channels

        // 设置输入格式（AAC LC）
        inputFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024, // AAC 每帧 1024 样本
            mBytesPerFrame: 0,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 0,
            mReserved: 0
        )

        // 设置输出格式（Float32 PCM，interleaved）
        // 使用 interleaved 格式，因为 AudioConverterFillComplexBuffer 使用单个 buffer
        outputFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels) * 4,  // 每帧所有通道
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channels) * 4,   // 每帧所有通道
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        // 创建 AVAudioFormat（interleaved）
        outputAudioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: true
        )

        // 先创建一个基础的音频转换器
        // 收到 Config Packet 后会重新创建并设置 Magic Cookie
        createAudioConverter()

        AppLogger.capture.info("[AudioDecoder] 已初始化，采样率: \(sampleRate)Hz, 声道: \(channels)")
    }

    /// 处理 Config Packet (AudioSpecificConfig / Magic Cookie)
    /// - Parameter data: Config Packet 数据
    func processConfigPacket(_ data: Data) {
        guard data.count >= 2 else {
            AppLogger.capture.error("[AudioDecoder] Config packet 太短: \(data.count) 字节")
            return
        }

        // 保存 Magic Cookie
        magicCookie = data
        hasReceivedConfig = true

        // 解析 AudioSpecificConfig
        let startIndex = data.startIndex
        let firstByte = data[startIndex]
        let secondByte = data[startIndex + 1]

        let audioObjectType = (firstByte >> 3) & 0x1F
        let sampleRateIndex = ((firstByte & 0x07) << 1) | ((secondByte >> 7) & 0x01)
        let channelConfig = (secondByte >> 3) & 0x0F

        let sampleRateTable: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        let actualSampleRate = sampleRateIndex < sampleRateTable.count ? sampleRateTable[Int(sampleRateIndex)] : 48000.0

        AppLogger.capture.info("[AudioDecoder] AudioSpecificConfig - AOT: \(audioObjectType), 采样率: \(actualSampleRate)Hz, 声道: \(channelConfig)")

        // 使用 Config Packet 中解析的实际参数更新格式
        self.sampleRate = actualSampleRate
        self.channels = UInt32(channelConfig)

        // 更新输入格式
        inputFormat.mSampleRate = actualSampleRate
        inputFormat.mChannelsPerFrame = UInt32(channelConfig)

        // 更新输出格式（interleaved）
        outputFormat.mSampleRate = actualSampleRate
        outputFormat.mChannelsPerFrame = UInt32(channelConfig)
        outputFormat.mBytesPerPacket = UInt32(channelConfig) * 4
        outputFormat.mBytesPerFrame = UInt32(channelConfig) * 4

        // 更新 AVAudioFormat（interleaved）
        outputAudioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: actualSampleRate,
            channels: AVAudioChannelCount(channelConfig),
            interleaved: true
        )

        // 重新创建 AudioConverter（不使用 Magic Cookie，依靠正确的格式描述）
        recreateAudioConverter()
    }

    /// 创建音频转换器
    private func createAudioConverter() {
        // 如果已有转换器，先释放
        if let converter = audioConverter {
            AudioConverterDispose(converter)
            audioConverter = nil
        }

        var converter: AudioConverterRef?
        let status = AudioConverterNew(&inputFormat, &outputFormat, &converter)

        if status != noErr {
            AppLogger.capture.error("[AudioDecoder] 创建 AudioConverter 失败: \(status)")
            return
        }

        audioConverter = converter
        isInitialized = true
    }

    /// 重新创建音频转换器（使用更新的格式信息）
    private func recreateAudioConverter() {
        // 释放旧转换器
        if let converter = audioConverter {
            AudioConverterDispose(converter)
            audioConverter = nil
        }

        var converter: AudioConverterRef?
        let status = AudioConverterNew(&inputFormat, &outputFormat, &converter)

        guard status == noErr, let conv = converter else {
            AppLogger.capture.error("[AudioDecoder] 重新创建 AudioConverter 失败: \(status)")
            isInitialized = false
            return
        }

        audioConverter = conv
        isInitialized = true
    }

    /// 使用 Magic Cookie 重新创建音频转换器（备用方法）
    private func recreateAudioConverterWithMagicCookie() {
        guard let cookie = magicCookie else { return }

        // 释放旧转换器
        if let converter = audioConverter {
            AudioConverterDispose(converter)
            audioConverter = nil
        }

        var converter: AudioConverterRef?
        let status = AudioConverterNew(&inputFormat, &outputFormat, &converter)

        guard status == noErr, let conv = converter else {
            AppLogger.capture.error("[AudioDecoder] 创建 AudioConverter 失败: \(status)")
            isInitialized = false
            return
        }

        // 设置 Magic Cookie（关键！）
        let cookieStatus = cookie.withUnsafeBytes { ptr -> OSStatus in
            guard let baseAddress = ptr.baseAddress else { return kAudioConverterErr_UnspecifiedError }
            let size = UInt32(cookie.count)
            return AudioConverterSetProperty(
                conv,
                kAudioConverterDecompressionMagicCookie,
                size,
                baseAddress
            )
        }

        if cookieStatus != noErr {
            AppLogger.capture.warning("[AudioDecoder] 设置 Magic Cookie 失败: \(cookieStatus)")
        }

        audioConverter = conv
        isInitialized = true
    }

    /// 解码 AAC 数据包
    /// - Parameters:
    ///   - data: AAC 编码的音频数据
    ///   - pts: 显示时间戳（用于保持接口一致性，AAC 解码器内部不使用）
    ///   - isKeyFrame: 是否为关键帧（用于保持接口一致性，AAC 解码器内部不使用）
    func decode(_ data: Data, pts: UInt64 = 0, isKeyFrame: Bool = false) {
        guard isInitialized, let converter = audioConverter else {
            return
        }

        // 计算输出缓冲区大小（每帧 1024 样本）
        let outputFrames: UInt32 = 1024
        let outputByteSize = outputFrames * outputFormat.mBytesPerFrame
        var outputBuffer = Data(count: Int(outputByteSize))

        // 使用 withUnsafeBytes 确保输入数据在整个解码过程中保持有效
        data.withUnsafeBytes { inputPtr in
            guard let inputBaseAddress = inputPtr.baseAddress else {
                AppLogger.capture.error("[AudioDecoder] 无法获取输入数据指针")
                return
            }

            // 设置持久指针供回调使用
            inputBufferPointer = inputBaseAddress
            inputBufferSize = UInt32(data.count)

            // 设置输出 buffer list
            var outputBufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: outputFormat.mChannelsPerFrame,
                    mDataByteSize: outputByteSize,
                    mData: nil
                )
            )

            outputBuffer.withUnsafeMutableBytes { outputPtr in
                outputBufferList.mBuffers.mData = outputPtr.baseAddress
                outputBufferList.mBuffers.mDataByteSize = outputByteSize

                var outputPacketCount = outputFrames

                // 执行转换
                let status = AudioConverterFillComplexBuffer(
                    converter,
                    inputDataProc,
                    Unmanaged.passUnretained(self).toOpaque(),
                    &outputPacketCount,
                    &outputBufferList,
                    nil
                )

                if status == noErr, outputPacketCount > 0 {
                    let actualSize = Int(outputPacketCount * outputFormat.mBytesPerFrame)
                    let pcmData = Data(bytes: outputPtr.baseAddress!, count: actualSize)
                    decodeSuccessCount += 1

                    if let format = outputAudioFormat {
                        onDecodedAudio?(pcmData, format)
                    }
                }
                // 静默忽略解码错误，避免日志洪泛
            }

            // 清空指针
            inputBufferPointer = nil
            inputBufferSize = 0
        }

        inputBuffer = nil
    }

    /// 重置解码器
    func reset() {
        if let converter = audioConverter {
            AudioConverterReset(converter)
        }
        inputBuffer = nil
        inputBufferPointer = nil
        inputBufferSize = 0
    }

    /// 清理资源
    func cleanup() {
        if let converter = audioConverter {
            AudioConverterDispose(converter)
            audioConverter = nil
        }
        inputBuffer = nil
        inputBufferPointer = nil
        inputBufferSize = 0
        isInitialized = false

        // 释放 packet description 内存
        if let ptr = packetDescriptionPtr {
            ptr.deinitialize(count: 1)
            ptr.deallocate()
            packetDescriptionPtr = nil
        }
    }
}

// MARK: - 输入数据回调

/// AudioConverter 输入数据回调
private func inputDataProc(
    _ inAudioConverter: AudioConverterRef,
    _ ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
    _ ioData: UnsafeMutablePointer<AudioBufferList>,
    _ outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    _ inUserData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData = inUserData else {
        ioNumberDataPackets.pointee = 0
        return kAudioConverterErr_UnspecifiedError
    }

    let decoder = Unmanaged<ScrcpyAudioDecoder>.fromOpaque(userData).takeUnretainedValue()

    // 使用持久指针（在 decode 方法的 withUnsafeBytes 作用域内有效）
    guard let inputPtr = decoder.inputBufferPointer, decoder.inputBufferSize > 0 else {
        ioNumberDataPackets.pointee = 0
        return kAudioConverterErr_InvalidInputSize
    }

    // 设置输入数据
    ioData.pointee.mNumberBuffers = 1
    ioData.pointee.mBuffers.mNumberChannels = decoder.inputFormat.mChannelsPerFrame
    ioData.pointee.mBuffers.mDataByteSize = decoder.inputBufferSize
    ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: inputPtr)

    // 对于 VBR 格式（AAC），必须提供数据包描述
    if let packetDescPtr = decoder.packetDescriptionPtr {
        packetDescPtr.pointee.mStartOffset = 0
        packetDescPtr.pointee.mVariableFramesInPacket = 0
        packetDescPtr.pointee.mDataByteSize = decoder.inputBufferSize

        // 返回 packet description 指针
        if let outDesc = outDataPacketDescription {
            outDesc.pointee = packetDescPtr
        }
    }

    ioNumberDataPackets.pointee = 1

    // 清空指针，避免重复使用（只提供一次数据）
    decoder.inputBufferPointer = nil
    decoder.inputBufferSize = 0

    return noErr
}
