// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MarkdownCanvas",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    targets: [
        // md4c C 源码：直接指向 vendored 的上游仓库 md4c/src，不复制文件。
        // entity.h 是 md4c.c 的私有头；publicHeadersPath "." 让 md4c.h 对 Swift 可见。
        .target(
            name: "CMD4C",
            path: "md4c/src",
            exclude: [
                "md4c-html.c",
                "md4c-html.h",
                "CMakeLists.txt",
                "JoinPaths.cmake",
                "md4c.pc.in",
                "md4c-html.pc.in",
            ],
            publicHeadersPath: "."
        ),
        // 核心渲染库：无 UIKit/AppKit 依赖，macOS/iOS 共用。
        // default.metallib 由 build-metallib.sh 从 Shaders/Shaders.metal 编译而来，
        // 作为资源打进 bundle —— 运行时不带 shader 源码，也不需要 Metal 编译器。
        // Shaders.metal 是 build-metallib.sh 的输入，不参与 SwiftPM 编译
        // （SwiftPM 不编译 .metal），显式 exclude 掉以免 "unhandled file" 警告
        .target(
            name: "MarkdownCanvas",
            dependencies: ["CMD4C"],
            exclude: ["Shaders.metal"],
            resources: [.copy("Resources/default.metallib")]
        ),
        // 控制台检查工具：打印 md4c 解析出的文档树（M0 验证手段）
        .executableTarget(
            name: "mdprint",
            dependencies: ["MarkdownCanvas"]
        ),
        // macOS app 入口（M1 接入 Metal 后启用）
        .executableTarget(
            name: "yyp-md",
            dependencies: ["MarkdownCanvas"]
        ),
        // iOS app 入口：与 macOS 同构（UIScrollView 虚拟滚动 + 覆盖画布）。
        // 代码用 #if canImport(UIKit) 包裹，macOS 构建时为空 target。
        .executableTarget(
            name: "MarkdownCanvasIOS",
            dependencies: ["MarkdownCanvas"]
        ),
        .testTarget(
            name: "MarkdownCanvasTests",
            dependencies: ["MarkdownCanvas"],
            path: "Tests"
        ),
    ]
)
