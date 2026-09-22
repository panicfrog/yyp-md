#!/bin/bash
# 把 Sources/MarkdownCanvas/Shaders.metal 编译成 default.metallib。
#
# SwiftPM 不编译 .metal 文件，所以这一步在 swift build 之前单独跑；
# 产物 `Sources/MarkdownCanvas/Resources/default.metallib` 被 Package.swift
# 声明为 copy 资源，随 bundle 分发。
#
# ⚠️ Shaders.metal 里的 Instance/Uniforms 布局必须与 MetalTypes.swift 的
#    DrawInstance / FrameUniforms 一致 —— 改了 Swift 结构体就要重跑本脚本。
#
# 前置：Metal 工具链。Xcode 26 起它是独立组件，缺失时执行
#   xcodebuild -downloadComponent MetalToolchain
set -euo pipefail
cd "$(dirname "$0")"

SRC=Sources/MarkdownCanvas/Shaders.metal
OUT=Sources/MarkdownCanvas/Resources/default.metallib
AIR=$(mktemp -d)/Shaders.air

for sdk in macosx iphonesimulator iphoneos; do
  xcrun -sdk "$sdk" metal -c "$SRC" -o "$AIR"
done
# 上面只验证三个 SDK 都能编译；实际产物用 macosx（iOS 与 macOS 的
# metallib 是同一个 ABI，现场用 macosx 编一份即可跑通两端）
xcrun -sdk macosx metal -c "$SRC" -o "$AIR"
xcrun -sdk macosx metallib "$AIR" -o "$OUT"

echo "→ $OUT ($(stat -f%z "$OUT") bytes)"
