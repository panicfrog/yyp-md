#!/bin/bash
# 打包 yyp-md 为 .app → 签名 → 压成 dmg（本机自用）。
#
# 产物：dist/MarkdownCanvas-<version>.dmg
#
# 用法：
#   ./make-dmg.sh                 # 仅 arm64（本机架构，体积最小）
#   ./make-dmg.sh --universal     # arm64 + x86_64
#
# 前置：先跑过 ./build-metallib.sh（需要 Sources/MarkdownCanvas/Resources/default.metallib）
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME=yyp-md
VERSION=1.0.0
BUNDLE_ID=com.yyp.yyp-md
SIGN_ID="${MC_SIGN_ID:--}"          # 默认 ad-hoc 签名；要正式签名设环境变量
UNIVERSAL=0
[[ "${1:-}" == "--universal" ]] && UNIVERSAL=1

DIST=dist
APP="$DIST/$APP_NAME.app"
rm -rf "$APP"; mkdir -p "$DIST"

# --- 1. 构建 ---
SWIFT_FLAGS=(-Xswiftc -Osize -Xswiftc -whole-module-optimization
             -Xswiftc -Xfrontend -Xswiftc -disable-reflection-metadata
             -Xcc -Os -Xlinker -dead_strip)

# 先编译 shader。必须在 swift build 之前 —— 否则 SwiftPM 会把
# .build 里【上一次】的缓存产物拷进 bundle，改过 Shaders.metal 也
# 不会生效，而且源码缺失时它照拷不误（实测：删掉源文件后 swift build
# 依然"成功"，打出来的 dmg 里是旧 shader）。
METALLIB=Sources/MarkdownCanvas/Resources/default.metallib
echo "==> 编译 shader → $METALLIB"
if ! ./build-metallib.sh; then
  echo "  ✗ metallib 编译失败 —— shader 改坏了或 Metal 工具链缺失" >&2
  echo "    （Xcode 26 起工具链是独立组件：xcodebuild -downloadComponent MetalToolchain）" >&2
  exit 1
fi

echo "==> 构建 (arm64)"
swift build -c release --product yyp-md "${SWIFT_FLAGS[@]}"

if [[ $UNIVERSAL == 1 ]]; then
  echo "==> 构建 (x86_64)"
  swift build -c release --product yyp-md --arch x86_64 "${SWIFT_FLAGS[@]}"
  BIN_UNI=$(mktemp -d)/yyp-md
  lipo -create \
    .build/arm64-apple-macosx/release/yyp-md \
    .build/x86_64-apple-macosx/release/yyp-md \
    -output "$BIN_UNI"
else
  BIN_UNI=.build/release/yyp-md
fi

# --- 2. 组装 .app ---
echo "==> 组装 $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_UNI" "$APP/Contents/MacOS/$APP_NAME"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

# ⚠️ strip 必须在签名【之前】—— 签完再 strip 会让签名失效
# （strip 会改写 __LINKEDIT，签名覆盖的正是这段）。
# 不 strip 的话 __LINKEDIT 会带着完整符号表（实测 ~344 KB，
# 占总文件一半以上），包体积直接翻倍。
BIN="$APP/Contents/MacOS/$APP_NAME"
BEFORE=$(stat -f%z "$BIN")
strip -x "$BIN"
AFTER=$(stat -f%z "$BIN")
printf "  strip: %.1f KB → %.1f KB (省 %.1f KB)\n" \
  "$(echo "$BEFORE/1024" | bc -l)" "$(echo "$AFTER/1024" | bc -l)" \
  "$(echo "($BEFORE-$AFTER)/1024" | bc -l)"

# SPM 资源 bundle：ShaderLibrary 会在 Bundle.main.executableURL 同级
# 与 Bundle.main.resourceURL 两处找它 —— 这里放进 Contents/Resources/
# （由第二个候选路径命中）。漏了它程序会报「未找到 default.metallib」并退出。
cp -R .build/release/MarkdownCanvas_MarkdownCanvas.bundle "$APP/Contents/Resources/"

# 校验 metallib 真的进了 bundle。缺了它 app 启动就报「无法初始化 Metal」
# 退出，但在那之前 swift build 不会报任何错 —— 必须在这里拦。
if [[ ! -f "$APP/Contents/Resources/MarkdownCanvas_MarkdownCanvas.bundle/default.metallib" ]]; then
  echo "  ✗ bundle 里没有 default.metallib —— 打出来的 dmg 无法运行" >&2
  exit 1
fi

# 图标 / dmg 背景图在仓库根目录（版本控制内）—— dist/ 被 gitignore，
# 放那边曾导致重装环境后图标丢失
[[ -f AppIcon.icns ]] && cp AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>       <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>        <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <!-- 打开 md 文件：把 MarkdownCanvas 关联为 .md 的可选打开方式 -->
    <key>CFBundleDocumentTypes</key>
    <array><dict>
        <key>CFBundleTypeName</key>      <string>Markdown Document</string>
        <key>CFBundleTypeRole</key>      <string>Viewer</string>
        <key>LSHandlerRank</key>         <string>Alternate</string>
        <key>LSItemContentTypes</key>
        <array><string>net.daringfireball.markdown</string><string>public.plain-text</string></array>
    </dict></array>
    <!-- 声明 Markdown UTI（系统已认识也无害）：.md/.markdown/.mdown/.mkd -->
    <key>UTImportedTypeDeclarations</key>
    <array><dict>
        <key>UTTypeIdentifier</key>      <string>net.daringfireball.markdown</string>
        <key>UTTypeDescription</key>     <string>Markdown Document</string>
        <key>UTTypeConformsTo</key>
        <array><string>public.plain-text</string></array>
        <key>UTTypeTagSpecification</key>
        <dict>
            <key>public.filename-extension</key>
            <array><string>md</string><string>markdown</string><string>mdown</string><string>mkd</string></array>
        </dict>
    </dict></array>
</dict>
</plist>
PLIST

# --- 3. 签名（含资源，--deep 不用于签名，逐层签） ---
echo "==> 签名 ($SIGN_ID)"
if [[ "$SIGN_ID" == "-" ]]; then
  # ad-hoc：本机自用足够；首次打开可能仍需右键→打开
  codesign --force --sign - "$APP/Contents/Resources/MarkdownCanvas_MarkdownCanvas.bundle" 2>/dev/null || true
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" \
    "$APP/Contents/Resources/MarkdownCanvas_MarkdownCanvas.bundle"
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
fi
codesign --verify --verbose=1 "$APP" 2>&1 | tail -3

# --- 4. 压 dmg（含「拖到 Applications」引导） ---
#
# 裸 dmg（只有 .app）打开就是个文件夹，没有拖拽提示 —— 标准做法是放一个
# 指向 /Applications 的符号链接 + 背景图，再用 .DS_Store 记住图标位置。
# 流程：可写 dmg → 挂载 → 布置 → 卸载 → 转成压缩只读 dmg。
DMG="$DIST/$APP_NAME-$VERSION.dmg"
RW="$DIST/$APP_NAME-rw.dmg"
rm -f "$DMG" "$RW"

# 背景图：浅色，中间留出两个图标位。
# 优先用仓库根目录的版本控制副本；否则用 dist/mkdmgbg.swift 现编一个。
BG_SRC="dmg-background.png"
BG_BIN="$DIST/.mkdmgbg"
if [[ ! -f "$BG_SRC" && -f "$DIST/mkdmgbg.swift" ]]; then
  [[ -x "$BG_BIN" ]] || swiftc -O "$DIST/mkdmgbg.swift" -o "$BG_BIN" 2>/dev/null || true
  [[ -x "$BG_BIN" ]] && "$BG_BIN" "$DIST/dmg-background.png" >/dev/null 2>&1 || true
  [[ -f "$DIST/dmg-background.png" ]] && BG_SRC="$DIST/dmg-background.png"
fi

echo "==> 生成 $DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$APP" -ov -format UDRW -quiet "$RW"

MNT="/Volumes/$APP_NAME"
# 同名卷可能残留 —— 先卸干净，否则挂载点会变成 "yyp-md 1"
hdiutil detach "$MNT" -force -quiet 2>/dev/null || true
hdiutil attach "$RW" -nobrowse -quiet
# 等待挂载点就绪（attach 返回 ≠ 卷已可用）
for _ in $(seq 1 20); do [[ -d "$MNT" ]] && break; sleep 0.5; done

ln -sf /Applications "$MNT/Applications"
if [[ -f "$BG_SRC" ]]; then
  mkdir -p "$MNT/.background"
  cp "$BG_SRC" "$MNT/.background/background.png"
fi

# .DS_Store：窗口尺寸 + 图标位置 + 背景引用。
#
# 背景图用【卷内相对路径】（".background:background.png"，HFS 冒号分隔），
# 不能用 alias —— `file "..."` 会把相对路径解析成 alias 并记下当时所在
# 的磁盘路径（即临时 $RW），而 $RW 在打包末尾就被删了。实测那样背景仍
# 能显示（Finder 回退到卷内路径），但记录是脏的，换机器可能失效。
osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$APP_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 200, 800, 620}
    set vopts to the icon view options of container window
    set arrangement of vopts to not arranged
    set icon size of vopts to 110
    try
      set background picture of vopts to file ".background:background.png"
    end try
    set position of item "$APP_NAME.app" of container window to {160, 200}
    set position of item "Applications" of container window to {440, 200}
    close
  end tell
end tell
APPLESCRIPT

# 校验 .DS_Store 真的写出来了 —— Finder 脚本偶尔静默失败，
# 不校验的话会得到一个「看起来正常但没布局」的裸 dmg。
if [[ ! -f "$MNT/.DS_Store" ]]; then
  echo "  ⚠️  Finder 未生成 .DS_Store —— dmg 将没有拖拽引导布局" >&2
fi

sync
hdiutil detach "$MNT" -quiet || hdiutil detach "$MNT" -force -quiet
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -ov -quiet -o "$DMG"
rm -f "$RW"

echo
echo "==> 完成"
printf "  %s  %.1f KB\n" "$DMG" "$(echo "$(stat -f%z "$DMG")/1024" | bc -l)"
echo "  .app 体积: $(du -sh "$APP" | awk '{print $1}')"
lipo -info "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null | sed 's/^/  /'
