import Metal
import MetalKit
import CoreGraphics

/// Metal 渲染器：管线、图集、环形池、每帧调度。
///
/// 帧流程（全部在 draw(in:) 内完成，无多线程争抢）：
///   1. pool.acquire() 取共享槽位（14 深环形，信号量保证 CPU/GPU 读写分离）
///   2. 槽位头部写 FrameUniforms；实例区从两端向中间写：
///      glyph 实例（textureIndex >= 0）自头部向下 bump，
///      solid 实例（textureIndex == -1）自尾部向上 bump —— 一块缓冲服务两条管线
///   3. managed 存储（Intel Mac）didModifyRange 刷新
///   4. 编码：glyph 管线 + 图集纹理 → solid 管线
///   5. addCompletedHandler → pool.signal() 归还槽位
public final class MetalRenderer: NSObject, MTKViewDelegate {

    public let device: MTLDevice
    public let atlas: GlyphAtlas
    public let pool: RingBufferPool

    private let queue: MTLCommandQueue
    private let glyphPipeline: MTLRenderPipelineState
    private let solidPipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState

    /// 滚动偏移（逻辑 pt），由视图层在 contentOffset 变化时更新。
    public var scrollOffset: CGPoint = .zero
    /// 实例数据源：返回当前可视区域的全部实例（文档坐标）。
    public var instancesProvider: (() -> [DrawInstance])?
    /// 图片纹理（ImageStore.allTextures；textureIndex = 槽位 + 1）。
    public var imageTextures: [MTLTexture] = []

    /// 统计：debug overlay / 性能验证用。
    public private(set) var lastGlyphCount = 0
    public private(set) var lastSolidCount = 0
    private var frameCounter = 0
    private var lastGeometrySig = ""

    public init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue(),
              let library = ShaderLibrary.make(device: device)
        else {
            if Environment.debug { print("MetalRenderer: commandQueue/library 创建失败") }
            return nil
        }

        self.device = device
        self.queue = queue
        self.atlas = GlyphAtlas(device: device)
        self.pool = RingBufferPool(device: device, slotBytes: 1 << 20) // 1 MB/槽

        func pipeline(fragment: String) -> MTLRenderPipelineState? {
            guard let vf = library.makeFunction(name: "quad_vertex"),
                  let ff = library.makeFunction(name: fragment) else { return nil }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vf
            desc.fragmentFunction = ff
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            // 直 alpha 混合
            let att = desc.colorAttachments[0]!
            att.isBlendingEnabled = true
            att.sourceRGBBlendFactor = .sourceAlpha
            att.destinationRGBBlendFactor = .oneMinusSourceAlpha
            att.sourceAlphaBlendFactor = .oneMinusSourceAlpha
            att.destinationAlphaBlendFactor = .one
            return try? device.makeRenderPipelineState(descriptor: desc)
        }

        guard let glyphPipeline = pipeline(fragment: "glyph_fragment"),
              let solidPipeline = pipeline(fragment: "solid_fragment") else {
            if Environment.debug { print("MetalRenderer: pipeline 创建失败") }
            return nil
        }
        self.glyphPipeline = glyphPipeline
        self.solidPipeline = solidPipeline

        let smp = MTLSamplerDescriptor()
        smp.minFilter = .linear
        smp.magFilter = .linear
        self.sampler = device.makeSamplerState(descriptor: smp)!

        super.init()
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // 视口尺寸由每帧 uniform 携带，无需处理
    }

    public func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let instances = instancesProvider?(),
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        let slot = pool.acquire()

        // 1. uniform（macOS MTKView 无 contentScaleFactor，用 drawable/bounds 比值）
        let scaleY = view.bounds.height > 0 ? view.drawableSize.height / view.bounds.height : 1
        if Environment.debug {
            let sig = "\(view.drawableSize.width)x\(view.drawableSize.height)|\(view.bounds.width)x\(view.bounds.height)|\(scaleY)"
            if sig != lastGeometrySig {
                lastGeometrySig = sig
                print("[geometry] drawable=\(view.drawableSize) bounds=\(view.bounds.size) scaleY=\(scaleY) frame=\(view.frame)")
                fflush(stdout)
            }
        }
        let uniforms = FrameUniforms(
            viewportSize: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            scrollOffset: SIMD2(Float(scrollOffset.x), Float(scrollOffset.y)),
            scale: Float(scaleY),
            atlasSize: SIMD2(Float(atlas.texture.width), Float(atlas.texture.height)))
        let slotPtr = slot.contents()
        slotPtr.storeBytes(of: uniforms, as: FrameUniforms.self)

        // 2. 实例分桶：glyph(atlas) / 每张图片一个桶 / solid。
        //    先按桶分组（保证桶内连续，一次 draw），再顺序写入共享槽位：
        //    glyph + images 自头部向下，solid 自尾部向上。
        let stride = MemoryLayout<DrawInstance>.stride
        var glyphList: [DrawInstance] = []
        var imageLists: [Int16: [DrawInstance]] = [:]
        var solidList: [DrawInstance] = []
        for instance in instances {
            switch instance.textureIndex {
            case 0: glyphList.append(instance)
            case 1...: imageLists[instance.textureIndex, default: []].append(instance)
            default: solidList.append(instance)
            }
        }

        var writeCursor = pool.instanceOffset
        var solidStart = pool.slotBytes
        var imageBuckets: [(textureIndex: Int16, offset: Int, count: Int)] = []

        func write(_ list: [DrawInstance]) -> Int {
            var n = 0
            for instance in list {
                guard writeCursor + stride <= solidStart else { break }
                (slotPtr + writeCursor).assumingMemoryBound(to: DrawInstance.self).pointee = instance
                writeCursor += stride
                n += 1
            }
            return n
        }

        let glyphOffset = pool.instanceOffset
        _ = write(glyphList)
        for (texIdx, list) in imageLists.sorted(by: { $0.key < $1.key }) {
            let offset = writeCursor
            let n = write(list)
            if n > 0 { imageBuckets.append((texIdx, offset, n)) }
        }
        for instance in solidList.reversed() {
            guard solidStart - stride >= writeCursor else { break }
            solidStart -= stride
            (slotPtr + solidStart).assumingMemoryBound(to: DrawInstance.self).pointee = instance
        }
        lastGlyphCount = glyphList.count
        lastSolidCount = solidList.count

        if Environment.debug {
            frameCounter += 1
            if frameCounter <= 3 || frameCounter % 120 == 0 {
                fflush(stdout); print("[frame \(frameCounter)] glyphs=\(lastGlyphCount) solids=\(lastSolidCount) provider=\(instances.count) drawable=\(view.drawableSize)")
            }
        }

        // 3. managed 存储刷新
        pool.flush(slot, range: 0..<writeCursor)
        if lastSolidCount > 0 {
            pool.flush(slot, range: solidStart..<pool.slotBytes)
        }

        // 4. 编码。顺序：solid（背景/划线）→ glyph → 图片 —— 保证底色垫在
        //    字形之下，图片纹理用同一个 quad shader 换纹理绑定
        encoder.setRenderPipelineState(solidPipeline)
        if lastSolidCount > 0 {
            encoder.setVertexBuffer(slot, offset: 0, index: 0)
            encoder.setVertexBuffer(slot, offset: solidStart, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: lastSolidCount)
        }

        encoder.setRenderPipelineState(glyphPipeline)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setVertexBuffer(slot, offset: 0, index: 0)              // uniforms
        if lastGlyphCount > 0 {
            encoder.setFragmentTexture(atlas.texture, index: 0)
            encoder.setVertexBuffer(slot, offset: glyphOffset, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: lastGlyphCount)
        }
        for bucket in imageBuckets {
            guard let tex = imageTextures.indices.contains(Int(bucket.textureIndex) - 1)
                ? imageTextures[Int(bucket.textureIndex) - 1] : nil else { continue }
            encoder.setFragmentTexture(tex, index: 0)
            encoder.setVertexBuffer(slot, offset: bucket.offset, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: bucket.count)
        }

        // 5. 提交：endEncoding 必须在 commit 之前（defer 会在 commit 之后才执行，
        //    曾因此触发 `commit command buffer with uncommitted encoder` 断言崩溃）
        encoder.endEncoding()
        commandBuffer.addCompletedHandler { [pool] _ in pool.signal() }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
