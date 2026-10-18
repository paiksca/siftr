"""Speech denoising with DeepFilterNet's command-line tool."""

import os
import subprocess
import tempfile
from pathlib import Path

import numpy as np
import soundfile as sf
import soxr

RATE = 48000  # DeepFilterNet works on 48 kHz audio
DEFAULT_BINARY = Path(__file__).resolve().parent.parent / "tools" / "deep-filter" / "deep-filter"


def binary():
    path = Path(os.environ.get("VOICETRIM_DEEP_FILTER", DEFAULT_BINARY))
    if not path.exists():
        raise FileNotFoundError(f"deep-filter not found at {path}; set VOICETRIM_DEEP_FILTER")
    return path


def enhance(samples, rate, atten_lim_db=100.0):
    """Return (denoised samples, 48000). Timing is preserved, so word timestamps still apply."""
    audio = soxr.resample(samples, rate, RATE) if rate != RATE else samples
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "in.wav"
        sf.write(src, audio, RATE, subtype="PCM_16")
        subprocess.run(
            [binary(), "-D", "-a", str(atten_lim_db), "-o", str(Path(tmp) / "out"), str(src)],
            check=True, capture_output=True,
        )
        out, _ = sf.read(Path(tmp) / "out" / "in.wav", dtype="float32")
    return out[: len(audio)].astype(np.float32), RATE
