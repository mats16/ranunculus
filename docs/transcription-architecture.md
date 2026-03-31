# Lycoris 文字起こし実装の解説

## 全体アーキテクチャ

Lycorisの文字起こしは**2段階パイプライン**で構成されています。第1段階でVoskがリアルタイム認識と音声区間検出（VAD）を行い、第2段階でWhisperが高精度な再認識を行います。

```
┌─────────────────────────────────────────────────────────┐
│  音声入力（マイク or デスクトップ音声）                      │
│  cpal / screencapturekit                                │
└──────────┬──────────────────────┬───────────────────────┘
           │                      │
           ▼                      ▼
   ┌──────────────┐      ┌──────────────┐
   │ Vosk認識      │      │ WAVファイル   │
   │ (リアルタイム)  │      │  書き込み     │
   └──────┬───────┘      └──────┬───────┘
          │ DecodingState::      │
          │ Finalized            │
          ▼                      ▼
   ┌──────────────────────────────────┐
   │ SQLite に保存                     │
   │ (model="vosk", テキスト, WAVパス)  │
   └──────────────┬───────────────────┘
                  │
                  ▼
   ┌──────────────────────────────────┐
   │ Whisper が SQLite からキュー取得   │
   │ WAVを読み込み → 16kHz変換 → 再認識 │
   └──────────────┬───────────────────┘
                  │
                  ▼
   ┌──────────────────────────────────┐
   │ SQLite 更新 (model="whisper")     │
   │ → フロントエンドへイベント通知      │
   └──────────────────────────────────┘
```

## 第1段階: 音声キャプチャとVosk認識

### 音声入力ソース

2種類の音声入力に対応しており、同時使用も可能です。

| ソース | 実装ファイル | ライブラリ | サンプルレート |
|---|---|---|---|
| マイク | `record.rs` | cpal 0.14.1 | デバイスのデフォルト |
| デスクトップ音声 | `record_desktop.rs` | screencapturekit | 48000Hz |

### cpalコールバック内の処理（`record.rs:78-125`）

cpalの音声入力コールバックが呼ばれるたびに、**同一データに対して2つの処理を同時実行**します:

```rust
move |data: &[f32], _| {
    // 1. Voskに音声データを渡す
    MyRecognizer::recognize(..., data, ...);
    // 2. WAVファイルに書き込む
    Writer::write_input_data::<f32, f32>(&data, &writer_clone);
}
```

cpalのコールバック呼び出し頻度はデバイスとOSに依存し、通常数十ミリ秒ごとです。**アプリ側で固定のバッファサイズや送信間隔は設定していません**。

### WAV書き込み時の無音スキップ（`writer.rs:34-46`）

```rust
let mut silence_passed = false;
for &sample in input.iter() {
    let sample: U = cpal::Sample::from(&sample);
    if Self::to_float(&sample).abs() > 0.01 {
        silence_passed = true;
    }
    if silence_passed {
        writer.0.write_sample(sample).ok();
    }
}
```

各WAVチャンクの**先頭の無音区間（振幅 ≤ 0.01）はカット**されます。ただし、一度音声が検出されると、以降の無音は書き込まれます。

### Voskによる発話区間検出（`recognizer.rs:33-83`）

```rust
let state = recognizer.accept_waveform(&data);
match state {
    DecodingState::Running => {
        // 部分認識結果 → フロントエンドに "partialTextRecognized" イベント
    }
    DecodingState::Finalized => {
        // 発話終了を検知 → チャネル経由で通知
        notify_decoding_state_is_finalized_tx.send(text.to_string())
    }
}
```

**重要**: 音声の区切りタイミングは**Voskの内部VADが自動判定**します。発話中のポーズ（無音区間）を検出すると `Finalized` を返します。固定秒数での区切りではありません。

また、2文字（grapheme）未満のテキスト、および「Xー」のような2文字パターンはノイズとして除外されます（`is_correct_words`）。

### Finalized時のWAVファイル切り替え（`record.rs:140-173`）

`Finalized` を受信すると:

1. 現在のWavWriterを `finalize()` → 1つのWAVファイルが完成
2. SQLiteに保存: `model="vosk"`, Voskの認識テキスト, WAVファイルパス
3. フロントエンドに `finalTextRecognized` イベントを発火
4. **新しいWavWriterを作成**して次の発話区間の録音を開始

```rust
let (w, path) = writer.lock().unwrap().take().unwrap();
w.finalize().expect("Error finalizing writer");
// ... SQLiteに保存 ...
// 新しいWriterで次のチャンク開始
writer.lock().unwrap().replace(Writer::build(&audio_path, spec));
```

**オーバーラップはありません**。前のWriterの `finalize()` 後に新しいWriterが開始されるため、各WAVチャンクは完全に連続・非重複です。

## 第2段階: Whisperによる再認識

### キューの取得（`transcription.rs:70-72`）

```rust
fn convert(&mut self) -> Result<(), rusqlite::Error> {
    let vosk_speech = self.sqlite.select_vosk(self.note_id);
```

SQLiteから `model="vosk"` のレコードを**FIFO順（created_at_unixtime ASC）で1件ずつ**取得します。

```sql
SELECT ... FROM speeches
WHERE model = "vosk" AND note_id = ?1
ORDER BY created_at_unixtime ASC LIMIT 1
```

### 音声データの前処理（`transcription.rs:73-131`）

1. **最小長チェック**: WAVの長さが1秒未満の場合はスキップ（Voskの結果をそのまま採用）
   ```rust
   if (reader.duration() / spec.sample_rate as u32) < 1 {
       println!("input is too short, so skipping...");
   }
   ```

2. **フォーマット変換**: 16/24/32bit int/floatをすべてf32に正規化

3. **モノラル変換**: ステレオの場合は `whisper_rs::convert_stereo_to_mono_audio` で変換

4. **リサンプリング**: 入力サンプルレート → **16000Hz** に変換（SincBestQuality）
   ```rust
   let audio_data = convert(
       spec.sample_rate, 16000, 1,
       ConverterType::SincBestQuality, &data,
   ).unwrap();
   ```

### Whisperの推論パラメータ（`transcriber.rs`）

| パラメータ | 値 |
|---|---|
| サンプリング戦略 | `BeamSearch { beam_size: 2, patience: 1.0 }` |
| スレッド数 | `min(8, CPUコア数)` |
| Flash Attention | 有効 |
| 入力サンプルレート | 16000Hz |
| モデル | 設定に応じてsmall/medium/large/large-turbo/large-distil等 |
| initial_prompt | 言語別に設定（例: 日本語なら「これは日本語の音声です。適切な句読点を用いて正確に書き起こしてください。」） |

### 結果の保存

- Whisper結果が**空でない場合**: SQLiteの `model` を `"vosk"` → `"whisper"` に更新し、`content` をWhisperの結果で上書き
- Whisper結果が**空の場合**: `model` は `"whisper"` に更新するが、**Voskの元テキストをフォールバックとして使用**
- いずれの場合も `finalTextConverted` イベントでフロントエンドに通知

## バイリンガルモード（`transcriber.rs:102-110`）

`large-distil.bilingual` モデル選択時は、Whisperを**翻訳タスク**として動作させます。パイプラインの構造（Vosk → SQLite → Whisper）やオーディオの前処理は通常モードと同一で、違いはWhisperの推論パラメータのみです。

```rust
if transcription_accuracy.starts_with("large-distil.bilingual") {
    params.set_translate(true);          // 翻訳モードON
    if language == "en" {
        params.set_initial_prompt("これは日本語の音声です。...");
        params.set_language(Some("ja")); // 出力言語を日本語に
    } else if language == "ja" {
        params.set_initial_prompt("This is an audio in English...");
        params.set_language(Some("en")); // 出力言語を英語に
    }
}
```

通常モードとの差分:

| 項目 | 通常モード | バイリンガルモード |
|---|---|---|
| モデルファイル | `ggml-{small,medium,large,...}.bin` | `ggml-large-distil.bilingual.bin` |
| `set_translate` | `false`（文字起こしのみ） | **`true`**（翻訳を有効化） |
| `set_language` | 入力音声の言語をそのまま設定 | **入力と逆の言語を設定**（ja→en, en→ja） |
| `initial_prompt` | 入力言語のプロンプト | **出力言語のプロンプト** |

ポイントとして、`set_language` にはWhisperに**出力させたい言語**を指定し、`initial_prompt` も出力言語で書くことで翻訳結果を誘導しています。入力音声の言語はモデルが自動認識します。

## Hybridモード（`transcription_hybrid.rs`）

Hybridモードでは、Whisperに加えてReazonSpeechも**別スレッドで並列実行**します:

```rust
pub fn start(&mut self, ...) {
    // ReazonSpeechスレッド
    thread::spawn(move || {
        singleton.start(stop_convert_rx_clone_for_reazonspeech, ...);
    });
    // Whisperスレッド
    thread::spawn(move || {
        singleton.start(stop_convert_rx_clone_for_whisper, ...);
    });
}
```

Hybrid Whisperは通常モードとは別のフラグ（`is_done_with_hybrid_whisper`）で処理済み判定を行い、さらにその後 `transcription_hybrid_online` に渡すパイプラインも持っています。

## start_trace_command（録音済み音声の後処理）

`start_trace_command`（`main.rs:340`）は、録音が完了した後に未処理のVoskレコードを一括で再認識するためのコマンドです。`use_no_vosk_queue_terminate_mode = true` で呼び出され、キューが空になったら自動終了します。

## まとめ

| 項目 | 値 |
|---|---|
| 送信間隔 | 固定値なし。**VoskのVADが発話終了を検知するたびに**1チャンク生成 |
| オーバーラップ | **なし**。WAVチャンクは完全に連続・非重複 |
| 最小チャンク長 | 1秒未満はWhisperスキップ（Vosk結果を採用） |
| 先頭無音カット | あり（振幅 ≤ 0.01） |
| Whisper入力サンプルレート | 16000Hz（SincBestQualityでリサンプリング） |
| Whisperデコード戦略 | BeamSearch (beam_size=2) |
| 並行性 | Vosk認識とWAV書き込みは同期、Whisper再認識は別スレッドで非同期 |
