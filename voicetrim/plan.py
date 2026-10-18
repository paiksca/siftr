"""Decide which spans of a recording to keep. Only deletes, never adds."""

import re
from dataclasses import dataclass, field

FILLERS = {"um", "uh", "uhm", "umm", "erm", "er", "ah", "eh", "hmm", "mm", "mhm"}
# Words people repeat on purpose, as in "had had" or "very very".
INTENTIONAL_REPEATS = {"had", "that", "very", "really", "no", "so", "bye", "ha", "yeah"}


@dataclass
class Settings:
    max_pause: float = 0.5  # natural pauses longer than this are shortened to it
    cut_pause: float = 0.2  # pause left where a filler or repeat was removed
    lead: float = 0.15  # silence kept before the first word
    tail: float = 0.25  # silence kept after the last word
    guard: float = 0.04  # margin kept around each word, for timestamp error
    remove_repeats: bool = True
    keep_events: bool = True  # keep [laughter] and other sounds that aren't fillers


@dataclass
class Plan:
    keep: list  # [(start, end)] in seconds
    tokens: list  # [(word, reason or None)] in spoken order
    # Per kept span, which way each edge may move to a quieter point: starts earlier (-1),
    # ends later (1) next to silence or either way (0) where a removed word follows at once.
    snap: list = field(default_factory=list)
    pauses_shortened: int = 0
    removed: dict = field(default_factory=dict)  # reason -> count


def _norm(text):
    return re.sub(r"[^\w'-]", "", text.lower())


def classify(word, settings):
    """Return why a single token should go, or None to keep it."""
    bracketed = word.text.startswith("[") and word.text.endswith("]")
    norm = _norm(word.text)
    if norm in FILLERS:
        return "filler"
    if bracketed and not settings.keep_events:
        return "event"
    if not bracketed and len(norm) > 1 and norm.endswith("-"):
        return "false start"
    return None


def _mark_repeats(words, reasons):
    """Mark the first copy of a word or phrase said twice in a row."""
    idx = [i for i, r in enumerate(reasons) if r is None]
    norms = [_norm(words[i].text) for i in idx]
    i = 0
    while i < len(idx):
        for n in (3, 2, 1):
            a, b = norms[i : i + n], norms[i + n : i + 2 * n]
            if len(b) == n and a == b and not (n == 1 and a[0] in INTENTIONAL_REPEATS):
                for j in idx[i : i + n]:
                    reasons[j] = "repeat"
                i += n
                break
        else:
            i += 1


def make_plan(words, duration, settings=None):
    settings = settings or Settings()
    if not words:
        return Plan(keep=[(0.0, duration)], tokens=[])

    reasons = [classify(w, settings) for w in words]
    if settings.remove_repeats:
        _mark_repeats(words, reasons)
    kept = [i for i, r in enumerate(reasons) if r is None]
    plan = Plan(keep=[], tokens=list(zip(words, reasons)))
    for r in reasons:
        if r:
            plan.removed[r] = plan.removed.get(r, 0) + 1
    if not kept:
        return plan

    first, last = words[kept[0]], words[kept[-1]]
    start, start_dir = max(0.0, first.start - settings.lead), -1  # starts only move earlier
    for ka, kb in zip(kept, kept[1:]):
        a, b = words[ka], words[kb]
        gap = max(0.0, b.start - a.end)
        cut = kb - ka > 1
        if not cut and gap <= settings.max_pause:
            continue
        if cut:
            # Keep only the silence on either side of the removed tokens.
            tail_room = max(0.0, words[ka + 1].start - a.end)
            head_room = max(0.0, b.start - words[kb - 1].end)
            want = settings.cut_pause
        else:
            tail_room = head_room = gap / 2
            want = settings.max_pause
            plan.pauses_shortened += 1
        tail = min(tail_room, want / 2)
        head = min(head_room, want - tail)
        tail = min(tail_room, want - head)
        # Onsets are loud and fade-outs quiet, so a kept word's start always gets its
        # margin, while its end stops at the boundary if a removed word follows at once.
        tail = max(tail, min(settings.guard, tail_room))
        head = max(head, min(settings.guard, gap / 2))
        plan.keep.append((start, a.end + tail))
        plan.snap.append((start_dir, 1 if tail_room >= settings.guard else 0))
        start = b.start - head
    plan.keep.append((start, min(duration, last.end + settings.tail)))
    plan.snap.append((start_dir, 1))
    return plan
