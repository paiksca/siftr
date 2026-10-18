"""Transcribe, denoise, cut and join one recording."""

from dataclasses import dataclass

import numpy as np
import soxr

from .align import tighten
from .audio import load
from .enhance import enhance
from .plan import Plan, Settings, make_plan
from .render import render, snap_segments
from .transcribe import transcribe, transcribe_text


@dataclass
class Result:
    plan: Plan
    samples: np.ndarray
    rate: int
    before: float  # seconds
    after: float
    transcript: str  # what the speaker meant, punctuated and without fillers

    @property
    def marked(self):
        """Verbatim transcript with removed tokens in braces."""
        return " ".join(f"{{{w.text}}}" if r else w.text for w, r in self.plan.tokens)


def clean(path, size="medium", language=None, settings=None, device=None, denoise=True):
    samples, rate = load(path)
    before = len(samples) / rate
    if denoise:
        # Timestamps from noisy audio spread into neighboring silence, so transcribe after.
        samples, rate = enhance(samples, rate)
    speech = soxr.resample(samples, rate, 16000)
    words = transcribe(speech, size=size, language=language, device=device)
    text = transcribe_text(speech, size=size, language=language, device=device)
    plan = make_plan(tighten(words, samples, rate), before, settings)
    cleaned = render(samples, rate, snap_segments(plan.keep, plan.snap, samples, rate))
    return Result(plan, cleaned, rate, before, len(cleaned) / rate, text)
