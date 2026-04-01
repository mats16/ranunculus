# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Ranunculus は macOS 向けの議事録文字起こしアプリ。マイクから音声をキャプチャし、VOSK（オフライン音声認識）で速報テキストを表示しつつ、kotoba-whisper（whisper.cpp）で高精度な再認識を行う2段階パイプライン構成。Swift Package Manager ベースの SwiftUI アプリ。

## Build & Run

```bash
# 初回セットアップ（libvosk.dylib + VOSK 日本語モデル + kotoba-whisper モデルのダウンロード）
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

2段階パイプライン（VOSK VAD → kotoba-whisper 再認識）:

```
マイク → AudioCaptureManager (16kHz Int16 PCM)
              │
              ├─→ AudioProcessor → VoskWrapper → 速報テキスト → TranscriptStore
              │   (シリアルキュー)    (VAD + 認識)                 (@MainActor)
              │
              └─→ WAVSegmentWriter → WAV ファイル
                                          │
                                          ↓
                                    WhisperService → 高精度テキスト → TranscriptStore
                                    (バックグラウンド Task)
```

- **Sources/CVosk/**: VOSK C API のモジュールマップ（`vosk_api.h` + `module.modulemap`）。Swift から `import CVosk` で利用。
- **Sources/Ranunculus/**: アプリ本体
  - `Audio/AudioCaptureManager` — AVAudioEngine でマイク入力を 16kHz モノラル Int16 PCM に変換
  - `Audio/WAVSegmentWriter` — VOSK VAD 区間ごとに WAV ファイルをストリーミング書き込み
  - `Vosk/VoskWrapper` — VOSK C API の Swift ラッパー。スレッドセーフではないため単一シリアルキューから使用
  - `Vosk/VoskResult` — VOSK の JSON レスポンスのパーサー
  - `Whisper/WhisperService` — kotoba-whisper による高精度再認識（SwiftWhisper 経由）
  - `Whisper/WhisperQueue` — Whisper 処理待ちセグメントの FIFO キュー（Swift actor）
  - `Whisper/WAVFileReader` — WAV ファイルを読み込み Whisper 入力フォーマット（f32）に変換
  - `Models/TranscriptSegment` — 1発話区間のデータモデル（VOSK テキスト、Whisper テキスト、タイムスタンプ）
  - `Models/TranscriptStore` — セグメント一元管理ストア（@MainActor ObservableObject）
  - `ViewModels/CaptionViewModel` — 音声キャプチャ→認識→UI更新を統括。AudioProcessor がシリアルキュー上で VOSK + WAV を駆動
  - `Views/ControlPanelView` — 議事録メインウィンドウ（タイムスタンプ付きスクロールリスト）
  - `Views/TranscriptRowView` — セグメント1行分の表示コンポーネント

## Key Constraints

- **リンカー設定**: `Libraries/libvosk.dylib` を直接リンク。`Package.swift` に `unsafeFlags` で `-L Libraries -lvosk` と rpath を設定。
- **SPM 依存**: SwiftWhisper（whisper.cpp の Swift ラッパー）を master ブランチで参照。
- **モデルパス**: VOSK モデルは `Resources/vosk-model-small-ja-0.22/`、Whisper モデルは `Resources/ggml-kotoba-whisper-v2.0-q5_0.bin` に配置。
- **プラットフォーム**: macOS 13+ 専用（`AVAudioEngine`, SwiftUI）。
- **スレッドモデル**: `VoskWrapper` + `WAVSegmentWriter` は `AudioProcessor` の `processingQueue`（シリアル DispatchQueue）で排他実行。`WhisperService` は `Task.detached` で非同期実行。`TranscriptStore` は `@MainActor`。
- **フォールバック**: Whisper モデルが未設定でも VOSK-only モードで動作する。
