"""Join kept spans of audio with short crossfades."""

import numpy as np


def snap(t, samples, rate, direction, window=0.04, frame=0.005):
    """Move a cut point up to `window` seconds to the quietest 5 ms frame.

    `direction` is -1 (earlier only), 1 (later only) or 0 (either way).
    """
    hop = max(1, int(frame * rate))
    lo = max(0, int((t - window * (direction <= 0)) * rate))
    hi = min(len(samples), int((t + window * (direction >= 0)) * rate) + hop)
    if hi - lo < 2 * hop:
        return t
    starts = range(lo, hi - hop, hop)
    energy = [float(np.mean(samples[s : s + hop] ** 2)) for s in starts]
    best = starts[int(np.argmin(energy))]
    return (best + hop / 2) / rate


def snap_segments(segments, directions, samples, rate):
    """Snap interior cut points in the allowed directions. The outer edges stay put."""
    out = []
    for i, ((s, e), (sd, ed)) in enumerate(zip(segments, directions)):
        s = s if i == 0 else snap(s, samples, rate, sd)
        e = e if i == len(segments) - 1 else snap(e, samples, rate, ed)
        if e > s:
            out.append((s, e))
    return out


def render(samples, rate, segments, xfade=0.02):
    """Concatenate segments, overlapping each join by an equal-power crossfade."""
    pieces = [samples[int(s * rate) : int(e * rate)].copy() for s, e in segments]
    pieces = [p for p in pieces if len(p)]
    if not pieces:
        return np.zeros(0, dtype=samples.dtype)
    out = [pieces[0]]
    n = int(xfade * rate)
    for p in pieces[1:]:
        prev = out[-1]
        k = min(n, len(prev), len(p))
        if k:
            t = np.linspace(0, 1, k, dtype=np.float32)
            prev[-k:] = prev[-k:] * np.cos(t * np.pi / 2) + p[:k] * np.sin(t * np.pi / 2)
        out.append(p[k:])
    return np.concatenate(out)
