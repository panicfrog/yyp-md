# yyp-md

A Markdown viewer for macOS.

It is tiny — the whole `.app` is about **400 KB**, and the packaged dmg about **240 KB**.

> ⚠️ This project is at an early stage and still has quite a few bugs. Fine for a quick look, not recommended for important documents.

## Requirements

- macOS 13 or later
- Xcode (with the Swift toolchain)
- The Metal toolchain. As of Xcode 26 it ships as a separate component; if it's missing, run:

  ```sh
  xcodebuild -downloadComponent MetalToolchain
  ```

## Building

A fresh clone needs its submodule (md4c):

```sh
git clone <repo-url>
cd yyp-md
git submodule update --init --recursive
```

Compile the shaders — this must happen **before** `swift build`:

```sh
./build-metallib.sh
```

Then build:

```sh
swift build -c release --product yyp-md
```

Run it directly:

```sh
.build/release/yyp-md Samples/test.md
```

Run the tests:

```sh
swift test
```

## Making a dmg

One command does everything — it compiles the shaders, builds, signs, and packages:

```sh
./make-dmg.sh              # arm64 only, smallest size
./make-dmg.sh --universal  # arm64 + x86_64
```

The result lands in `dist/yyp-md-1.0.0.dmg`. Open it and drag the app into Applications.

The build uses an ad-hoc signature by default, which is enough for local use; if macOS blocks the first launch, right-click → Open. For a real signature:

```sh
MC_SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./make-dmg.sh
```
