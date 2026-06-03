#!/usr/bin/env python3
"""Analyze Goose's heart-rate-samples.json — validate K18 BPM extraction.

After pulling Goose's app container with `devicectl device copy from`,
run this against the heart-rate-samples.json file. It reports:

  - Sample counts by source (separates live standard-BLE from K18-derived)
  - Time range
  - BPM distribution + plausibility check (a real human is 35-220)
  - Zone breakdown using user's HRmax

Usage:
    python3 Scripts/analyze_hr_samples.py [path/to/heart-rate-samples.json] [HRmax]

Defaults:
    JSON path: /tmp/goose-container/Library/Application Support/GooseSwift/heart-rate-samples.json
    HRmax:     187 (Vincent's max from body table)
"""
from __future__ import annotations

import json
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_PATH = Path(
    "/tmp/goose-container/Library/Application Support/GooseSwift/heart-rate-samples.json"
)
DEFAULT_MAX_HR = 187


def zone_for(bpm: int, max_hr: int) -> int:
    """Return 1-5 for a real zone, 0 for sub-zone-1, -1 for implausible."""
    if bpm <= 0 or bpm >= 240:
        return -1
    frac = bpm / max_hr
    if frac >= 0.9:
        return 5
    if frac >= 0.8:
        return 4
    if frac >= 0.7:
        return 3
    if frac >= 0.6:
        return 2
    if frac >= 0.5:
        return 1
    return 0


def main(argv: list[str]) -> int:
    path = Path(argv[0]) if argv else DEFAULT_PATH
    max_hr = int(argv[1]) if len(argv) > 1 else DEFAULT_MAX_HR

    if not path.exists():
        print(f"No file at {path}", file=sys.stderr)
        return 1

    data = json.loads(path.read_text())
    samples = data.get("samples") or []

    if not samples:
        print("No samples in file.")
        return 0

    print(f"Loaded {len(samples)} samples from {path}")
    print(f"Using HRmax = {max_hr}")
    print()

    # By source
    by_source: Counter[str] = Counter()
    for sample in samples:
        by_source[sample.get("source", "unknown")] += 1
    print("By source:")
    for source, count in by_source.most_common():
        print(f"  {count:6d}  {source}")
    print()

    # Time range
    times = sorted(sample.get("capturedAt", "") for sample in samples)
    print(f"Time range: {times[0]} → {times[-1]}")
    span_min = (
        (datetime.fromisoformat(times[-1].replace("Z", "+00:00"))
         - datetime.fromisoformat(times[0].replace("Z", "+00:00"))).total_seconds() / 60
    )
    print(f"Span:        {span_min:.1f} minutes")
    print()

    # BPM distribution + plausibility
    bpms = [s["bpm"] for s in samples if isinstance(s.get("bpm"), int)]
    plausible = [bpm for bpm in bpms if 35 <= bpm <= 220]
    implausible = [bpm for bpm in bpms if bpm not in plausible and (bpm < 35 or bpm > 220)]
    print(f"BPM range:     min {min(bpms)} / max {max(bpms)} / mean {sum(bpms)/len(bpms):.1f}")
    print(f"Plausible:     {len(plausible)} / {len(bpms)} ({100*len(plausible)/len(bpms):.0f}%)")
    if implausible:
        print(f"⚠️  Implausible: {len(implausible)} samples outside 35-220 — likely wrong byte offset")
        print(f"   Implausible values: {sorted(set(implausible))[:10]}")
    print()

    # Zone breakdown
    print("Zone distribution (using time-weighted bins assumed 1s per sample):")
    zones: Counter[int] = Counter()
    for bpm in plausible:
        zones[zone_for(bpm, max_hr)] += 1
    total = sum(zones.values()) or 1
    for zone in range(0, 6):
        count = zones.get(zone, 0)
        pct = 100 * count / total
        label = "Below Z1" if zone == 0 else f"Z{zone}"
        bar = "█" * int(pct / 2)
        print(f"  {label:<8} {count:5d} ({pct:5.1f}%) {bar}")

    # K18-specific check
    k18_samples = [s for s in samples if "k1" in s.get("source", "").lower() or "k18" in s.get("source", "").lower()]
    if k18_samples:
        print()
        print(f"⭐ K18-derived samples: {len(k18_samples)}")
        k18_bpms = [s["bpm"] for s in k18_samples]
        print(f"  BPM range: {min(k18_bpms)}-{max(k18_bpms)}")
    else:
        print()
        print("ℹ️  No K18-derived samples in this file (looking for 'k1' or 'k18' in source)")

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
