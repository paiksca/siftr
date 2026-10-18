"""Verbatim transcription with word timings, using CrisperWhisper."""

import os
from dataclasses import dataclass
from functools import lru_cache

# Run the few PyTorch ops that Apple GPUs lack on the CPU instead of failing.
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")


@dataclass
class Word:
    text: str
    start: float
    end: float


@lru_cache(maxsize=2)
def _model(size, device):
    from crisperwhisper import CrisperWhisperModel
    from transformers.generation import utils

    # transformers' MPS-only deferred stop check crashes on Whisper's EncoderDecoderCache
    utils.DeferredStopCheck.is_supported = staticmethod(lambda *a, **k: False)

    compute = "float32" if device == "cpu" else "float16"
    return CrisperWhisperModel(size, backend="transformers", device=device, compute_type=compute)


def default_device():
    import torch

    if torch.cuda.is_available():
        return "cuda"
    return "mps" if torch.backends.mps.is_available() else "cpu"


def transcribe(speech, size="medium", language=None, device=None):
    """Return every spoken token in 16 kHz mono audio, fillers and false starts included."""
    result = _model(size, device or default_device()).transcribe(
        speech, language=language, mode="verbatim", word_timestamps=True
    )
    return [Word(w.word.strip(), w.start, w.end) for w in result.words if w.word.strip()]


def transcribe_text(speech, size="medium", language=None, device=None):
    """Return what the speaker meant: punctuated, numbers formatted, disfluencies dropped."""
    result = _model(size, device or default_device()).transcribe(
        speech, language=language, mode="intended"
    )
    return result.text.strip()
