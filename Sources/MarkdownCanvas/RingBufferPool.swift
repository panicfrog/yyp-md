import Metal

/// CPU/GPU 共享缓冲环形池 —— 本架构的核心。
///
/// 滚动事件（尤其 iOS ProMotion / 触控板）一秒可产生上百次偏移更新，
/// CPU 生成实例数据的速率可能短期超过 GPU 消化速率。环形深度 14 允许
/// 最多 14 帧的实例数据同时在飞：
///
///   CPU 写第 N+14 帧时，GPU 才可能还在读第 N 帧 —— 读写完全分离，
///   CPU 仅在「已提交 14 帧、GPU 一帧未完成」时才阻塞（健康状态下不会发生）。
///
/// 存储模式：
/// - Apple Silicon（统一内存）→ .storageModeShared
/// - Intel Mac → .storageModeManaged，写完必须 didModifyRange
public final class RingBufferPool {

    /// 滚动期在飞帧深度的经验值：两倍 ProMotion 帧率的滚动事件洪峰余量。
    public static let defaultDepth = 14

    public let depth: Int
    public let slotBytes: Int

    private let buffers: [MTLBuffer]
    private let semaphore: DispatchSemaphore
    private var cursor = 0
    /// Intel Mac 专用（iOS / Apple Silicon 恒 false）。
    private let managed: Bool

    /// 槽位头部的 uniform 区大小（Metal uniform buffer offset 需要 256 对齐）。
    public static let uniformStride = 256

    public init(device: MTLDevice, slotBytes: Int, depth: Int = RingBufferPool.defaultDepth) {
        precondition(slotBytes > RingBufferPool.uniformStride, "槽位太小")
        self.depth = depth
        self.slotBytes = slotBytes

        // iOS 全线统一内存恒为 shared；Intel Mac 需要 managed
        #if os(macOS)
        let managed = !device.hasUnifiedMemory
        self.managed = managed
        let storage: MTLResourceOptions =
            managed ? .storageModeManaged : .storageModeShared
        #else
        self.managed = false
        let storage: MTLResourceOptions = .storageModeShared
        #endif
        self.buffers = (0..<depth).map { _ in
            device.makeBuffer(length: slotBytes, options: storage)!
        }
        self.semaphore = DispatchSemaphore(value: depth)
    }

    /// 取下一个可写槽位（必要时阻塞等待 GPU 归还）。
    /// 返回的 buffer 在对应命令缓冲完成前不可复写 —— 由 signal() 保证。
    public func acquire() -> MTLBuffer {
        semaphore.wait()
        let buffer = buffers[cursor]
        cursor = (cursor + 1) % depth
        return buffer
    }

    /// GPU 完成回调里调用，归还槽位。
    public func signal() {
        semaphore.signal()
    }

    /// Intel Mac（managed 存储）写完数据后必须调用，否则 GPU 读到旧缓存。
    public func flush(_ buffer: MTLBuffer, range: Range<Int>) {
        #if os(macOS)
        if managed {
            buffer.didModifyRange(range)
        }
        #endif
    }

    /// 实例区起始偏移（uniform 之后）。
    public var instanceOffset: Int { RingBufferPool.uniformStride }
}
