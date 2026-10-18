"""Command line: voicetrim message.m4a -o clean.m4a"""

import argparse
import json
import time
from pathlib import Path

from .audio import save
from .pipeline import clean
from .plan import Settings


def summary(result):
    removed = ", ".join(
        f"{n} {r}{'s' if n > 1 else ''}" for r, n in result.plan.removed.items()
    )
    n = result.plan.pauses_shortened
    saved = result.before - result.after
    return (
        f"Removed: {removed or 'nothing'}. Shortened {n} long pause{'' if n == 1 else 's'}.\n"
        f"{result.before:.1f} s -> {result.after:.1f} s, saved {saved:.1f} s "
        f"({saved / result.before:.0%})"
    )


def main(argv=None):
    p = argparse.ArgumentParser(
        description="Remove ums, repeats, false starts and long pauses from a voice message."
    )
    p.add_argument("input")
    p.add_argument("-o", "--output", help="output .m4a or .wav (default: <input>.clean.m4a)")
    p.add_argument("--model", default="medium", choices=["small", "medium", "turbo", "large"])
    p.add_argument("--language", help="e.g. en; detected if omitted")
    p.add_argument("--device", choices=["mps", "cuda", "cpu"], help="default: fastest available")
    p.add_argument("--max-pause", type=float, default=Settings.max_pause)
    p.add_argument("--cut-pause", type=float, default=Settings.cut_pause)
    p.add_argument("--keep-repeats", action="store_true")
    p.add_argument("--no-denoise", action="store_true")
    p.add_argument("--json", help="also write the transcript and plan to this file")
    args = p.parse_args(argv)

    out = Path(args.output or Path(args.input).with_suffix(".clean.m4a"))
    settings = Settings(
        max_pause=args.max_pause, cut_pause=args.cut_pause, remove_repeats=not args.keep_repeats
    )
    t0 = time.time()
    result = clean(args.input, args.model, args.language, settings, args.device,
                   denoise=not args.no_denoise)
    save(out, result.samples, result.rate)

    print(result.transcript)
    print()
    print(result.marked)
    print()
    print(f"{summary(result)} in {time.time() - t0:.1f} s. Wrote {out}")

    if args.json:
        Path(args.json).write_text(json.dumps({
            "transcript": result.transcript,
            "tokens": [{"text": w.text, "start": w.start, "end": w.end, "removed": r}
                       for w, r in result.plan.tokens],
            "keep": result.plan.keep,
            "before": result.before,
            "after": result.after,
        }, indent=2))


if __name__ == "__main__":
    main()
