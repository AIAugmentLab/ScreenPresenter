//
//  RingBuffer.swift
//  ScreenPresenter
//
//  Created by Sun on 2026/1/07.
//
//  通用环形缓冲区实现
//  用于音频数据的无锁缓冲，支持生产者-消费者模式
//

import Foundation

/// 通用环形缓冲区
/// 支持高效的 FIFO 读写操作
final class RingBuffer<T> {
    // MARK: - 属性

    /// 内部存储
    private var buffer: [T?]
    
    /// 读取位置索引
    private var readIndex = 0
    
    /// 写入位置索引
    private var writeIndex = 0
    
    /// 缓冲区容量
    let capacity: Int

    /// 当前缓冲的元素数量
    var count: Int {
        let write = writeIndex
        let read = readIndex
        if write >= read {
            return write - read
        } else {
            return capacity - read + write
        }
    }
    
    /// 缓冲区是否为空
    var isEmpty: Bool {
        return readIndex == writeIndex
    }
    
    /// 缓冲区是否已满
    var isFull: Bool {
        return count == capacity - 1
    }
    
    /// 可用写入空间
    var availableSpace: Int {
        return capacity - 1 - count
    }

    // MARK: - 初始化

    /// 创建指定容量的环形缓冲区
    /// - Parameter capacity: 缓冲区容量
    init(capacity: Int) {
        precondition(capacity > 1, "环形缓冲区容量必须大于 1")
        self.capacity = capacity
        self.buffer = [T?](repeating: nil, count: capacity)
    }

    // MARK: - 写入操作

    /// 写入单个元素
    /// - Parameter element: 要写入的元素
    /// - Returns: 是否成功写入
    @discardableResult
    func write(_ element: T) -> Bool {
        let nextWrite = (writeIndex + 1) % capacity
        if nextWrite == readIndex {
            // 缓冲区已满
            return false
        }
        buffer[writeIndex] = element
        writeIndex = nextWrite
        return true
    }

    /// 批量写入元素
    /// - Parameter elements: 要写入的元素数组
    /// - Returns: 实际写入的元素数量
    @discardableResult
    func write(_ elements: [T]) -> Int {
        var written = 0
        for element in elements {
            if !write(element) {
                break
            }
            written += 1
        }
        return written
    }
    
    /// 批量写入元素（从 UnsafeBufferPointer）
    /// - Parameter buffer: 要写入的数据缓冲区
    /// - Returns: 实际写入的元素数量
    @discardableResult
    func write(from sourceBuffer: UnsafeBufferPointer<T>) -> Int {
        var written = 0
        for i in 0..<sourceBuffer.count {
            if !write(sourceBuffer[i]) {
                break
            }
            written += 1
        }
        return written
    }

    // MARK: - 读取操作

    /// 读取单个元素
    /// - Returns: 读取的元素，如果缓冲区为空则返回 nil
    func read() -> T? {
        guard readIndex != writeIndex else {
            return nil
        }
        let element = buffer[readIndex]
        buffer[readIndex] = nil  // 释放引用
        readIndex = (readIndex + 1) % capacity
        return element
    }

    /// 批量读取元素
    /// - Parameter count: 要读取的元素数量
    /// - Returns: 读取的元素数组
    func read(count: Int) -> [T] {
        var result = [T]()
        result.reserveCapacity(min(count, self.count))
        
        for _ in 0..<count {
            guard let element = read() else {
                break
            }
            result.append(element)
        }
        
        return result
    }
    
    /// 批量读取到数组（填充 0 如果不足）
    /// - Parameters:
    ///   - count: 要读取的元素数量
    ///   - defaultValue: 不足时填充的默认值
    /// - Returns: 固定长度的数组
    func read(count: Int, defaultValue: T) -> [T] {
        var result = [T]()
        result.reserveCapacity(count)
        
        for _ in 0..<count {
            if let element = read() {
                result.append(element)
            } else {
                result.append(defaultValue)
            }
        }
        
        return result
    }

    /// 查看下一个元素但不移除
    /// - Returns: 下一个元素，如果缓冲区为空则返回 nil
    func peek() -> T? {
        guard readIndex != writeIndex else {
            return nil
        }
        return buffer[readIndex]
    }

    // MARK: - 其他操作

    /// 清空缓冲区
    func clear() {
        while read() != nil {}
        readIndex = 0
        writeIndex = 0
    }
    
    /// 跳过指定数量的元素
    /// - Parameter count: 要跳过的元素数量
    /// - Returns: 实际跳过的元素数量
    @discardableResult
    func skip(_ count: Int) -> Int {
        var skipped = 0
        for _ in 0..<count {
            guard readIndex != writeIndex else {
                break
            }
            buffer[readIndex] = nil
            readIndex = (readIndex + 1) % capacity
            skipped += 1
        }
        return skipped
    }
}

// MARK: - 专门为 Float 音频数据优化的扩展

extension RingBuffer where T == Float {
    /// 批量写入 Float 音频数据
    /// - Parameter data: 音频数据 (Float32 格式)
    /// - Returns: 实际写入的样本数
    @discardableResult
    func writeAudioSamples(from data: Data) -> Int {
        return data.withUnsafeBytes { ptr -> Int in
            guard let baseAddress = ptr.baseAddress else { return 0 }
            let floatPtr = baseAddress.assumingMemoryBound(to: Float.self)
            let floatCount = data.count / MemoryLayout<Float>.size
            let bufferPtr = UnsafeBufferPointer(start: floatPtr, count: floatCount)
            return write(from: bufferPtr)
        }
    }
    
    /// 读取音频样本到缓冲区（用于 AVAudioPlayerNode）
    /// - Parameters:
    ///   - count: 要读取的样本数
    /// - Returns: Float 数组
    func readAudioSamples(count: Int) -> [Float] {
        return read(count: count, defaultValue: 0.0)
    }
}
