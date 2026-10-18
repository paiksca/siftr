"""Decode audio files to mono float32 and write results."""

from pathlib import Path

import av
import numpy as np
import soundfile as sf


def load(path, rate=None):
    """Return (samples, rate) as mono float32, resampled to `rate` if given."""
    with av.open(str(path)) as container:
        stream = container.streams.audio[0]
        rate = rate or stream.codec_context.sample_rate
        resampler = av.AudioResampler(format="flt", layout="mono", rate=rate)
        chunks = []
        for frame in container.decode(stream):
            chunks += [f.to_ndarray().reshape(-1) for f in resampler.resample(frame)]
        chunks += [f.to_ndarray().reshape(-1) for f in resampler.resample(None)]
    return np.concatenate(chunks).astype(np.float32), rate


def save(path, samples, rate):
    """Write .m4a as AAC (plays in Messages). Other extensions go through soundfile."""
    if Path(path).suffix.lower() != ".m4a":
        sf.write(str(path), samples, rate)
        return
    with av.open(str(path), "w", format="ipod") as container:
        stream = container.add_stream("aac", rate=rate, layout="mono")
        stream.bit_rate = 64000
        frame = av.AudioFrame.from_ndarray(
            np.clip(samples, -1, 1).reshape(1, -1).astype(np.float32), format="flt", layout="mono"
        )
        frame.sample_rate = rate
        for packet in stream.encode(frame):
            container.mux(packet)
        for packet in stream.encode(None):
            container.mux(packet)
