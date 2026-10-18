import numpy as np
import pytest

from voicetrim.plan import Settings, make_plan
from voicetrim.render import render, snap
from voicetrim.transcribe import Word


def words(*spec):
    return [Word(t, s, e) for t, s, e in spec]


def removed(plan):
    return [(w.text, r) for w, r in plan.tokens if r]


def kept_length(plan):
    return sum(e - s for s, e in plan.keep)


def test_filler_removed_and_gap_capped():
    ws = words(("so", 0.0, 0.3), ("[um]", 0.5, 1.2), ("we", 1.4, 1.6))
    plan = make_plan(ws, 2.0)
    assert removed(plan) == [("[um]", "filler")]
    assert len(plan.keep) == 2
    gap = plan.keep[1][0] - plan.keep[0][1]
    assert gap > 0.5  # the filler and most of its silence are cut


def test_cut_leaves_short_pause():
    ws = words(("so", 0.0, 0.3), ("[um]", 0.5, 1.2), ("we", 1.4, 1.6))
    plan = make_plan(ws, 2.0, Settings(cut_pause=0.2, lead=0, tail=0))
    left = (plan.keep[0][1] - 0.3) + (1.4 - plan.keep[1][0])
    assert left == pytest.approx(0.2)


def test_touching_words_end_at_boundary_but_onsets_keep_margin():
    ws = words(("go", 0.0, 0.2), ("th-", 0.2, 0.45), ("on", 0.45, 0.5), ("it", 0.5, 0.7))
    plan = make_plan(ws, 1.0, Settings(guard=0.04, lead=0, tail=0))
    assert plan.keep[0][1] == pytest.approx(0.2)
    assert plan.keep[1][0] == pytest.approx(0.45 - 0.04)
    assert plan.snap == [(-1, 0), (-1, 1)]


def test_guard_kept_next_to_silence():
    ws = words(("go", 0.0, 0.2), ("[um]", 0.4, 0.6), ("on", 0.8, 1.0))
    plan = make_plan(ws, 1.2, Settings(guard=0.04, cut_pause=0.0, lead=0, tail=0))
    assert plan.keep[0][1] == pytest.approx(0.24)
    assert plan.keep[1][0] == pytest.approx(0.76)
    assert plan.snap == [(-1, 1), (-1, 1)]


def test_snap_directions():
    rate = 1000
    samples = np.ones(1000, dtype=np.float32)
    samples[480:490] = 0  # quiet spot before t
    samples[520:530] = 0.5  # quieter than the rest, louder than the first spot
    assert snap(0.5, samples, rate, -1) < 0.5
    assert snap(0.5, samples, rate, 1) > 0.5
    assert snap(0.5, samples, rate, 0) < 0.5


def test_repeat_drops_first_copy():
    ws = words(("we", 0.0, 0.2), ("we", 0.3, 0.5), ("need", 0.6, 0.9))
    plan = make_plan(ws, 1.0)
    assert removed(plan) == [("we", "repeat")]
    assert plan.tokens[1][1] is None


def test_repeat_across_filler():
    ws = words(("to", 0.0, 0.2), ("[uh]", 0.3, 0.6), ("to", 0.7, 0.9), ("go", 1.0, 1.2))
    assert removed(make_plan(ws, 1.5)) == [("to", "repeat"), ("[uh]", "filler")]


def test_phrase_repeat():
    ws = words(("i", 0.0, 0.1), ("think", 0.1, 0.4), ("i", 0.5, 0.6), ("think", 0.6, 0.9),
               ("so", 1.0, 1.2))
    assert removed(make_plan(ws, 1.5)) == [("i", "repeat"), ("think", "repeat")]


def test_intentional_repeat_kept():
    ws = words(("had", 0.0, 0.2), ("had", 0.3, 0.5))
    assert removed(make_plan(ws, 1.0)) == []


def test_false_start_removed():
    ws = words(("the", 0.0, 0.2), ("th-", 0.3, 0.4), ("thursday", 0.5, 1.0))
    assert removed(make_plan(ws, 1.2)) == [("th-", "false start")]


def test_long_pause_shortened():
    ws = words(("hi", 0.0, 0.3), ("there", 2.3, 2.6))
    plan = make_plan(ws, 3.0, Settings(max_pause=0.5, lead=0, tail=0))
    assert plan.pauses_shortened == 1
    assert kept_length(plan) == pytest.approx(0.3 + 0.5 + 0.3)


def test_short_pause_untouched():
    ws = words(("hi", 0.0, 0.3), ("there", 0.6, 0.9))
    plan = make_plan(ws, 1.0, Settings(lead=0, tail=0))
    assert plan.keep == [(0.0, 0.9)]


def test_laughter_kept_by_default():
    ws = words(("ha", 0.0, 0.2), ("[laughter]", 0.3, 1.0))
    assert removed(make_plan(ws, 1.2)) == []


def test_no_words_keeps_everything():
    assert make_plan([], 3.0).keep == [(0.0, 3.0)]


def test_render_crossfade_length():
    rate = 1000
    samples = np.ones(3000, dtype=np.float32)
    out = render(samples, rate, [(0.0, 1.0), (2.0, 3.0)], xfade=0.02)
    assert len(out) == 2000 - 20
    assert np.allclose(out[990:1000], np.cos(np.linspace(0, 1, 20)[10:] * np.pi / 2)
                       + np.sin(np.linspace(0, 1, 20)[10:] * np.pi / 2), atol=1e-5)
