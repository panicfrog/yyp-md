import Foundation
import Metal

/// Metal 函数库加载。
///
/// shader 在构建期由 `Shaders/Shaders.metal` 编译成 `default.metallib`
/// （见 `build-metallib.sh`），作为 SPM 资源打进 bundle —— 运行时不带
/// 编译器、不带源码字符串，也不必在启动时付出 `makeLibrary(source:)`
/// 的编译开销。
///
/// 编译产物与 Swift 侧结构体布局的对应关系见 MetalTypes.swift 的
/// `DrawInstance` / `FrameUniforms`：改任何一个都要重新编译 metallib。
///
/// 找不到 metallib 是构建/打包错误（资源没进 bundle），不是可以静默
/// 降级的运行时状况 —— 返回 nil 让 MetalRenderer 初始化失败。
///
/// ⚠️ 不能用 `Bundle.module`：SPM 生成的 accessor 在 bundle 缺失时
/// `fatalError`（实测报 "could not load resource bundle"）—— 打包漏了
/// 资源就从「初始化失败、给出可读错误」变成「进程直接崩」，二者差别很大。
/// 这里按 accessor 相同的顺序手工探测路径，探测不到只返回 nil。
public enum ShaderLibrary {

    public static let resourceName = "default"
    private static let bundleName = "MarkdownCanvas_MarkdownCanvas.bundle"

    /// bundle 候选路径，顺序与 SPM 生成的 resource_bundle_accessor 一致：
    /// 1) 可执行文件同级的 *.bundle（swift run / swift build 产物布局）
    /// 2) 主 bundle 的 Resource 目录（app 打包布局）
    private static func bundleCandidates() -> [URL] {
        var urls: [URL] = []
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            urls.append(exeDir.appendingPathComponent(bundleName))
        }
        if let res = Bundle.main.resourceURL {
            urls.append(res.appendingPathComponent(bundleName))
        }
        return urls
    }

    public static func make(device: MTLDevice) -> MTLLibrary? {
        for bundleURL in bundleCandidates() {
            guard let bundle = Bundle(url: bundleURL) else { continue }
            if let url = bundle.url(forResource: resourceName, withExtension: "metallib"),
               let library = try? device.makeLibrary(URL: url) {
                return library
            }
            if let library = try? device.makeDefaultLibrary(bundle: bundle) {
                return library
            }
        }
        if Environment.debug {
            print("ShaderLibrary: 未找到 \(resourceName).metallib —— 检查 SPM 资源是否随可执行文件分发")
        }
        return nil
    }
}
