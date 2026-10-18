import numpy as np
import pytest

from voicetrim.align import tighten
from voicetrim.transcribe import Word

RATE = 1000


def tone(seconds, amp):
    return amp * np.sin(2 * np.pi * 100 * np.arange(int(seconds * RATE)) / RATE)


def test_trims_silence_inside_word_span():
    samples = np.concatenate([np.zeros(300), tone(0.4, 0.5), np.zeros(300)]).astype(np.float32)
    (w,) = tighten([Word("okay", 0.0, 1.0)], samples, RATE)
    assert w.start == pytest.approx(0.3, abs=0.011)
    assert w.end == pytest.approx(0.7, abs=0.011)


def test_keeps_quiet_onset_within_range():
    # A soft onset 20 dB below the vowel stays part of the word.
    samples = np.concatenate([np.zeros(200), tone(0.1, 0.05), tone(0.3, 0.5), np.zeros(200)])
    (w,) = tighten([Word("so", 0.0, 0.8)], samples.astype(np.float32), RATE)
    assert w.start == pytest.approx(0.2, abs=0.011)


def test_silent_word_left_alone():
    samples = np.concatenate([tone(0.5, 0.5), np.zeros(500)]).astype(np.float32)
    w = Word("uh", 0.6, 0.9)
    assert tighten([w], samples, RATE) == [w]


def test_never_widens():
    samples = tone(1.0, 0.5).astype(np.float32)
    (w,) = tighten([Word("hi", 0.2, 0.4)], samples, RATE)
    assert (w.start, w.end) == (0.2, 0.4)
