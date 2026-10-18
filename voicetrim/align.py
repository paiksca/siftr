"""Tighten word timestamps to where the audio has sound."""

import numpy as np

from .transcribe import Word


def frame_db(samples, rate, frame=0.01):
    hop = max(1, int(frame * rate))
    n = len(samples) // hop
    power = np.mean(samples[: n * hop].reshape(n, hop) ** 2, axis=1)
    return 10 * np.log10(power + 1e-12), hop


def tighten(words, samples, rate, word_range_db=35.0, file_range_db=55.0):
    """Trim each word's silent start and end.

    A frame counts as sound if it is within `word_range_db` of the word's loudest frame and
    within `file_range_db` of the recording's loudest frame. Works best on denoised audio,
    because model timestamps tend to spread into neighboring silence when there is noise.
    """
    db, hop = frame_db(samples, rate)
    if not len(db):
        return list(words)
    floor = db.max() - file_range_db
    out = []
    for w in words:
        lo, hi = int(w.start * rate / hop), int(np.ceil(w.end * rate / hop))
        seg = db[lo:hi]
        loud = np.flatnonzero(seg >= max(seg.max() - word_range_db, floor)) if len(seg) else []
        if len(loud) == 0:
            out.append(w)
            continue
        start = (lo + loud[0]) * hop / rate
        end = (lo + loud[-1] + 1) * hop / rate
        out.append(Word(w.text, max(w.start, start), min(w.end, end)))
    return out
