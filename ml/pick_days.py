"""Ranks candidate training days by CONUS precipitation coverage.

Downloads one composite frame per day (21Z — near the diurnal convective
maximum) and scores the fraction of pixels at or above 20 dBZ, i.e. exactly
the quantity build_dataset.py gates patches on. Greedy selection keeps
picked days apart for regime diversity, so one long-lived synoptic system
doesn't dominate the dataset.

Usage: python pick_days.py --start 2026-05-01 --end 2026-07-14 --count 12
"""

from __future__ import annotations

import argparse
from datetime import date, datetime, time, timedelta
from pathlib import Path

import numpy as np
from PIL import Image

import common

Image.MAX_IMAGE_PIXELS = None


def precip_coverage(d: date, cache: Path) -> float:
    path = common.fetch_frame(datetime.combine(d, time(21, 0)), cache)
    if path is None:
        return -1.0
    idx = np.asarray(Image.open(path))
    return float((idx >= common.PRECIP_INDEX).mean())


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--start", required=True)
    parser.add_argument("--end", required=True)
    parser.add_argument("--count", type=int, default=12)
    parser.add_argument("--min-gap-days", type=int, default=2)
    parser.add_argument("--cache", default="data/raw")
    args = parser.parse_args()

    start = date.fromisoformat(args.start)
    end = date.fromisoformat(args.end)
    scores: list[tuple[float, date]] = []
    d = start
    while d <= end:
        s = precip_coverage(d, Path(args.cache))
        scores.append((s, d))
        print(f"{d} {s:.4f}")
        d += timedelta(days=1)

    picked: list[date] = []
    for s, d in sorted(scores, reverse=True):
        if s < 0:
            continue
        if all(abs((d - p).days) >= args.min_gap_days for p in picked):
            picked.append(d)
        if len(picked) == args.count:
            break

    picked.sort()
    print("\npicked:", ",".join(str(d) for d in picked))


if __name__ == "__main__":
    main()
