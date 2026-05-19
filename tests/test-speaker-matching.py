#!/usr/bin/env python3
"""Test: _match_anchors_to_batch_speakers matching algo.

Tests the greedy overlap-based algorithm that maps live meeting speaker IDs
(from speakers.json written by dictee-meeting-live) to batch diarization
speaker labels (from dictee-transcribe.py _parse_diarize_output).

Live speaker IDs are integers stored as string keys ("0", "1", ...).
Batch speaker labels are strings like "Speaker 0", "Speaker 1", etc.
"""
from collections import defaultdict


def match_anchors(name_map, anchors, batch_segments):
    """Pure-function copy of TranscribeWindow._match_anchors_to_batch_speakers.

    Args:
        name_map: {"0": "Alice", "1": "Bob"} (str keys)
        anchors:  {"0": [{"start": float, "end": float}, ...], ...}
        batch_segments: [{"speaker": "Speaker N", "start": float, "end": float}, ...]

    Returns: {"Speaker N": name}
    """
    overlap_matrix = defaultdict(lambda: defaultdict(float))
    for live_spk_str, live_anchors in anchors.items():
        for anchor in live_anchors:
            a_start, a_end = anchor["start"], anchor["end"]
            for seg in batch_segments:
                b_start, b_end = seg["start"], seg["end"]
                overlap = max(0.0, min(a_end, b_end) - max(a_start, b_start))
                if overlap > 0:
                    overlap_matrix[live_spk_str][seg["speaker"]] += overlap

    used_batch_spks = set()
    result = {}
    live_spks_by_confidence = sorted(
        name_map.keys(),
        key=lambda s: max(overlap_matrix[s].values()) if overlap_matrix[s] else 0,
        reverse=True,
    )
    for live_spk_str in live_spks_by_confidence:
        candidates = [
            (bs, ov) for bs, ov in overlap_matrix[live_spk_str].items()
            if bs not in used_batch_spks
        ]
        if not candidates:
            continue
        best = max(candidates, key=lambda c: c[1])[0]
        result[best] = name_map[live_spk_str]
        used_batch_spks.add(best)
    return result


# ---------------------------------------------------------------------------
# Test 1: identical IDs (most common case — live Speaker 0 == batch Speaker 0)
# ---------------------------------------------------------------------------
name_map = {"0": "Alice", "1": "Bob"}
anchors = {
    "0": [{"start": 0.0, "end": 5.0}, {"start": 10.0, "end": 12.0}],
    "1": [{"start": 5.0, "end": 10.0}],
}
batch = [
    {"speaker": "Speaker 0", "start": 0.0, "end": 5.0},
    {"speaker": "Speaker 1", "start": 5.0, "end": 10.0},
    {"speaker": "Speaker 0", "start": 10.0, "end": 12.0},
]
result = match_anchors(name_map, anchors, batch)
assert result == {"Speaker 0": "Alice", "Speaker 1": "Bob"}, f"Test 1 FAIL: {result}"
print("PASS: test 1 — identical IDs")

# ---------------------------------------------------------------------------
# Test 2: swapped IDs (live 0=Alice appears in batch as Speaker 2)
# ---------------------------------------------------------------------------
name_map = {"0": "Alice", "1": "Bob"}
anchors = {
    "0": [{"start": 0.0, "end": 5.0}, {"start": 10.0, "end": 12.0}],
    "1": [{"start": 5.0, "end": 10.0}],
}
batch = [
    {"speaker": "Speaker 2", "start": 0.0, "end": 5.0},
    {"speaker": "Speaker 0", "start": 5.0, "end": 10.0},
    {"speaker": "Speaker 2", "start": 10.0, "end": 12.0},
]
result = match_anchors(name_map, anchors, batch)
assert result == {"Speaker 2": "Alice", "Speaker 0": "Bob"}, f"Test 2 FAIL: {result}"
print("PASS: test 2 — swapped IDs")

# ---------------------------------------------------------------------------
# Test 3: batch has extra speaker not seen in live → stays unnamed
# ---------------------------------------------------------------------------
name_map = {"0": "Alice"}
anchors = {"0": [{"start": 0.0, "end": 5.0}]}
batch = [
    {"speaker": "Speaker 0", "start": 0.0, "end": 5.0},
    {"speaker": "Speaker 1", "start": 5.0, "end": 10.0},
]
result = match_anchors(name_map, anchors, batch)
assert result == {"Speaker 0": "Alice"}, f"Test 3 FAIL: {result}"
print("PASS: test 3 — extra batch speaker stays unnamed")

# ---------------------------------------------------------------------------
# Test 4: no overlap anywhere (anchor completely outside batch range)
# ---------------------------------------------------------------------------
name_map = {"0": "Alice"}
anchors = {"0": [{"start": 100.0, "end": 105.0}]}
batch = [{"speaker": "Speaker 0", "start": 0.0, "end": 5.0}]
result = match_anchors(name_map, anchors, batch)
assert result == {}, f"Test 4 FAIL: {result}"
print("PASS: test 4 — no overlap → no mapping")

print("\nALL TESTS PASS")
