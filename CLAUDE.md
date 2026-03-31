# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Ranunculus は macOS 向けのリアルタイム音声字幕アプリ。マイクから音声をキャプチャし、VOSK（オフライン音声認識エンジン）で日本語テキストに変換し、フローティングオーバーレイとして画面上に字幕を表示する。Swift Package Manager ベースの SwiftUI アプリ。

## Build & Run

```bash
# 初回セットアップ（libvosk.dylib + 日本語モデルのダウンロード）
bash scripts/setup.sh

# ビルド
swift build

# .app バンドル作成（リリースビルド → 署名 → バンドル生成）
bash scripts/build-app.sh

# 実行
open Ranunculus.app
# または直接: .build/debug/Ranunculus
```

## Architecture

MVVM + コールバックベースのオーディオパイプライン:

```
マイク → AudioCaptureManager → AudioProcessor → VoskWrapper → CaptionViewModel → UI
       (AVAudioEngine,          (シリアルキュー     (C API        (@MainActor,
        16kHz Int16 PCM変換)      でスレッド安全)     ラッパー)      Published状態)
```

- **Sources/CVosk/**: VOSK C API のモジュールマップ（`vosk_api.h` + `module.modulemap`）。Swift から `import CVosk` で利用。
- **Sources/Ranunculus/**: アプリ本体
  - `Audio/AudioCaptureManager` — AVAudioEngine でマイク入力を 16kHz モノラル Int16 PCM に変換
  - `Vosk/VoskWrapper` — VOSK C API の Swift ラッパー。スレッドセーフではないため単一シリアルキューから使用
  - `Vosk/VoskResult` — VOSK の JSON レスポンスのパーサー
  - `ViewModels/CaptionViewModel` — 音声キャプチャ→認識→UI更新を統括。`AudioProcessor`（private クラス）がシリアルキュー上で VOSK を駆動
  - `Views/OverlayPanelController` — `NSPanel` による常に最前面のフローティング字幕パネル（全 Space 対応）

## Key Constraints

- **リンカー設定**: `Libraries/libvosk.dylib` を直接リンク。`Package.swift` に `unsafeFlags` で `-L Libraries -lvosk` と rpath を設定。
- **モデルパス**: VOSK モデルは `Resources/vosk-model-small-ja-0.22/` に配置。`CaptionViewModel.loadBundledModel()` がプロジェクトルートからの相対パス・Bundle.main 内の両方を探索する。
- **プラットフォーム**: macOS 13+ 専用（`AVAudioEngine`, `NSPanel`, SwiftUI）。
- **スレッドモデル**: `VoskWrapper` はスレッドセーフでない。`AudioProcessor` 内の `processingQueue`（シリアル `DispatchQueue`）で排他実行。UI 更新は `DispatchQueue.main.async` でメインスレッドに戻す。
