<p align="center"><img src="branding/siftr-icon-1024.png" width="128" alt="Siftr icon"></p>

# Siftr

Siftr is an iMessage app that cleans up voice messages before you send them. It removes ums, uhs, repeated words, background talk and long pauses, and it suppresses background noise. Everything runs on the iPhone, so recordings stay on the device.

## How it works

1. The extension records the raw microphone inside Messages.
2. Apple's on-device voice isolation (`AUSoundIsolation`) removes background noise.
3. Apple's `SpeechAnalyzer` writes down every word, fillers included, with a confidence score for each.
4. A wav2vec2 model converted to Core ML re-times each word to within about a tenth of a second, because Apple's own timings can drift by half a second.
5. The trimmer removes fillers, repeats, comma-separated filler phrases such as "like" and "you know", quiet background speech and unclear mumbling. It shortens pauses to 0.3 s and never cuts into a word it keeps.
6. The result goes into the message field as an Opus `.caf` audio message with a matching transcript. A slider lets the sender pick the original recording instead.

## Repository

| Path | Contents |
|---|---|
| `ios/` | The iMessage app. XcodeGen builds the Xcode project from `project.yml` |
| `ios/VoiceTrimExtension/` | Recording, isolation, transcription, alignment, trimming and the SwiftUI interface |
| `ios/harness/` | A Mac command-line tool that runs the app's pipeline on an audio file, for testing without a phone |
| `ios/scripts/` | Install script, icon and logo renderers, and the wav2vec2 conversion script |
| `voicetrim/` | The original Python pipeline for the Mac (CrisperWhisper and DeepFilterNet), kept as a reference |
| `branding/` | The Siftr logo |

## Build and install on an iPhone

You need Xcode 26 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and an iPhone running iOS 26 or later.

1. Set `DEVELOPMENT_TEAM` and `BUNDLE_ID` in `ios/project.yml` to your own Apple Developer team and a bundle ID you own.
2. Connect the iPhone and run `ios/scripts/install.sh`. It renders the icons, generates the Xcode project, builds and installs.
3. On the iPhone, trust the developer under Settings, General, VPN & Device Management, then open Siftr from the + menu in Messages.

To test the pipeline on a Mac, compile `ios/harness/main.swift` with the extension's `Trimmer`, `Transcription`, `Isolation` and `Aligner` files, then run `harness <audio file> <output folder>`. Set `SIFT_MODELS` to a folder holding the compiled `Aligner.mlmodelc` and `aligner_vocab.json` to include re-timing.

## License

Siftr is source-available under the [PolyForm Noncommercial License 1.0.0](LICENSE.md). You may read, run and modify it for noncommercial purposes. Commercial use, including use in a messaging product, requires a separate license from the copyright holder. Contact Samuel Paik-Heintz at https://github.com/paiksca.

Third-party components keep their own licenses. See [NOTICE.md](NOTICE.md).
