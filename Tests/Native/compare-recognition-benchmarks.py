#!/usr/bin/env python3
"""Compare two private full-meeting replays without treating either as truth."""
import argparse
from collections import defaultdict
import json
import math
from pathlib import Path
import re


AEC_IDENTIFIER = re.compile(
    r"(-mic\.clean\.)[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}(\.caf)\Z",
    re.IGNORECASE)


def source_track(name):
    # AcousticEcho adds a fresh UUID to each cleaned copy of the same mic track.
    # Preserve the source prefix; other filenames and raw/clean tracks differ.
    return AEC_IDENTIFIER.sub(r"\1caf", name) if name is not None else None


def groups(segments):
    result = defaultdict(list)
    for segment in segments:
        # Segment and AEC-copy IDs are regenerated; source and bounds are stable.
        key = (source_track(segment.get("audioFile")), segment["start"], segment["end"])
        result[key].append(segment)
    for group in result.values():
        group.sort(key=lambda s: (s["speaker"], s["text"]))
    return result


def same_embedding(first, second):
    if first is None or second is None:
        return first is second
    return len(first) == len(second) and all(
        math.isfinite(a) and math.isfinite(b) and abs(a - b) <= 1e-6
        for a, b in zip(first, second))


def compare(before, after):
    for field in ["meetingID", "mode", "audioSeconds"]:
        if field not in before or before[field] != after.get(field):
            raise ValueError(f"Benchmark inputs differ: {field}")
    for result in [before, after]:
        if result.get("turboActivityHeld") is not True:
            raise ValueError("Benchmark must hold the same Turbo activity as the app")
        if not result["segments"]:
            raise ValueError("An empty transcript cannot validate recognition quality")
        metrics = result.get("recognitionPerformance", {})
        if not all(metrics.get(key, 0) > 0 for key in ["qwenCalls", "gigaCalls"]):
            raise ValueError("Both recognition models must have run")
    first, second = groups(before["segments"]), groups(after["segments"])
    report = dict(removed_segments=0, added_segments=0, text_changes=0,
                  speaker_changes=0, remote_embedding_changes=0,
                  remote_embedding_exact_changes=0, differences=[])
    for key in sorted(first.keys() | second.keys(), key=str):
        old, new = first[key], second[key]
        report["removed_segments"] += max(0, len(old) - len(new))
        report["added_segments"] += max(0, len(new) - len(old))
        for a, b in zip(old, new):
            changes = []
            for field, counter in [("text", "text_changes"), ("speaker", "speaker_changes")]:
                if a[field] != b[field]:
                    report[counter] += 1
                    changes.append(field)
            if "-mic." not in (key[0] or ""):
                if a.get("embedding") != b.get("embedding"):
                    report["remote_embedding_exact_changes"] += 1
                if not same_embedding(a.get("embedding"), b.get("embedding")):
                    report["remote_embedding_changes"] += 1
                    changes.append("remote_embedding")
            if changes:
                report["differences"].append(dict(track=key[0], start=key[1], end=key[2], changes=changes,
                                                  before={k: a[k] for k in ["text", "speaker"]},
                                                  after={k: b[k] for k in ["text", "speaker"]}))
    report["equivalent"] = not any(report[k] for k in ["removed_segments", "added_segments", "text_changes", "speaker_changes", "remote_embedding_changes"])
    report["baseline_seconds"], report["candidate_seconds"] = before["seconds"], after["seconds"]
    if not all(math.isfinite(x) and x > 0 for x in [before["seconds"], after["seconds"]]):
        raise ValueError("Elapsed times must be finite and positive")
    report["speedup"] = before["seconds"] / after["seconds"]
    report["time_saved_percent"] = 100 * (before["seconds"] - after["seconds"]) / before["seconds"]
    report["baseline_segment_count"], report["candidate_segment_count"] = len(before["segments"]), len(after["segments"])
    report["interpretation"] = "Agreement with baseline, not WER against a human transcript"
    return report


def read_result(path):
    lines = path.read_text().splitlines()
    if "RECOGNITION_MEETING_BENCHMARK_OK" not in lines:
        raise ValueError(f"Incomplete benchmark: {path}")
    results = [row for row in (json.loads(line) for line in lines if line.startswith("{")) if row.get("kind") == "result"]
    if len(results) != 1:
        raise ValueError(f"Expected exactly one completed result: {path}")
    return results[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before", type=Path)
    parser.add_argument("after", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = compare(read_result(args.before), read_result(args.after))
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({k: v for k, v in report.items() if k != "differences"}, ensure_ascii=False))
    return 0 if report["equivalent"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
