# Third-party notices

Siftr's own code is licensed under the PolyForm Noncommercial License 1.0.0 (see `LICENSE.md`). It includes or uses the following third-party work, under their own licenses.

## In the iPhone app

- wav2vec2-base-960h by Facebook AI (Meta), converted to Core ML in `ios/VoiceTrimExtension/Models/Aligner.mlpackage`. Licensed under the Apache License 2.0 (`licenses/Apache-2.0.txt`). Source: https://huggingface.co/facebook/wav2vec2-base-960h
- Apple's Speech, AVFoundation, Core ML and Messages frameworks, used under the Apple Developer Program License Agreement.

## In the Mac reference pipeline (`voicetrim/`, not shipped in the app)

- DeepFilterNet command-line tool by Hendrik Schröter, in `tools/deep-filter/`. Licensed under MIT or Apache 2.0 (`licenses/DeepFilterNet-MIT.txt`). Source: https://github.com/Rikorose/DeepFilterNet
- CrisperWhisper by Nyra Health. Its inference code is MIT. Its model weights are downloaded at run time and are under the Nyra Health Non-Commercial Research License, so any commercial use of the Mac pipeline needs a license from Nyra. Source: https://github.com/nyrahealth/CrisperWhisper
- Python packages listed in `pyproject.toml`, under their own licenses.
