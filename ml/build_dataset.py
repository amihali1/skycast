"""Builds training samples from the IEM NEXRAD n0q archive.

For each sample time T0 the script downloads the four history frames the app
would have fetched (T0-45..T0) plus the five verifying future frames
(T0+10..T0+60), cuts random echo-bearing patches, estimates motion exactly
like the app, and stores:

  inputs  (4, 256, 256) uint8 — history, motion-aligned to T0's frame
  targets (5, 256, 256) uint8 — future frames warped back along the motion
  valid   (5, 256, 256) bool  — in-bounds mask for the warped targets

Because both inputs and targets live in T0's Lagrangian frame, advection is
already accounted for; the model only has to learn growth, decay and
initiation — the residual the heuristic nowcast cannot see.

Usage:
  python build_dataset.py --days 2026-07-09,2026-07-10 [--hour-stride 1]
      [--patches-per-time 4] [--out data/samples] [--cache data/raw]
"""

from __future__ import annotations

import argparse
import random
from datetime import datetime, timedelta
from pathlib import Path

import numpy as np
from PIL import Image

import common

Image.MAX_IMAGE_PIXELS = None  # the CONUS composite trips the default limit

# Patch centres are sampled inside radar-covered CONUS, with margin so the
# widest (northern) patches stay on the grid.
LAT_RANGE = (27.0, 47.0)
LON_RANGE = (-119.0, -72.0)

# Patch must contain real precipitation at T0, not just clear-air clutter:
# >=1% of native pixels at or above 20 dBZ (see common.PRECIP_INDEX).
MIN_PRECIP_FRACTION = 0.01


def build_time(t0: datetime, args, rng: random.Random) -> int:
    # Resume support: a crashed run can be relaunched without recomputing
    # sample times that already produced patches.
    out_dir = Path(args.out)
    if list(out_dir.glob(f"s_{t0:%Y%m%d%H%M}_*.npz")):
        print(f"{t0:%Y-%m-%d %H:%M}: already built, skipped")
        return 0

    cache = Path(args.cache)
    times = [t0 - timedelta(minutes=m) for m in common.FRAME_OFFSETS_MIN] + [
        t0 + timedelta(minutes=m) for m in common.LEADS_MIN
    ]
    paths = [common.fetch_frame(t, cache) for t in times]
    if any(p is None for p in paths):
        print(f"{t0:%Y-%m-%d %H:%M}: archive gap, skipped")
        return 0

    images = [Image.open(p) for p in paths]
    out_dir.mkdir(parents=True, exist_ok=True)

    saved = 0
    attempts = 0
    while saved < args.patches_per_time and attempts < args.patches_per_time * 10:
        attempts += 1
        lat = rng.uniform(*LAT_RANGE)
        lon = rng.uniform(*LON_RANGE)

        extracted = common.extract_patch(images[3], lat, lon)
        if extracted is None:
            continue
        latest, precip_frac = extracted
        if precip_frac < MIN_PRECIP_FRACTION:
            continue

        others = [common.extract_patch(im, lat, lon) for im in images[:3] + images[4:]]
        if any(p is None for p in others):
            continue
        history = [p[0] for p in others[:3]] + [latest]
        futures = [p[0] for p in others[3:]]

        vx, vy = common.estimate_motion(history)

        # Align history to T0's frame: the frame k steps back must be
        # advected forward k steps.
        inputs = np.stack(
            [common.warp(frame, vx, vy, steps=3 - i) for i, frame in
             enumerate(history[:3])] + [latest]
        )

        targets = np.zeros((len(common.LEADS_MIN), *latest.shape), np.uint8)
        valid = np.zeros_like(targets, dtype=bool)
        for i, lead in enumerate(common.LEADS_MIN):
            steps = lead / common.BASELINE_MINUTES
            targets[i], valid[i] = common.warp_back(futures[i], vx, vy, steps)

        name = f"s_{t0:%Y%m%d%H%M}_{lat:.1f}_{lon:.1f}.npz"
        np.savez_compressed(
            out_dir / name,
            inputs=inputs,
            targets=targets,
            valid=np.packbits(valid),
        )
        saved += 1

    print(f"{t0:%Y-%m-%d %H:%M}: {saved} patches ({attempts} attempts)")
    return saved


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--days", required=True,
                        help="comma-separated YYYY-MM-DD list")
    parser.add_argument("--hour-stride", type=int, default=1)
    parser.add_argument("--patches-per-time", type=int, default=4)
    parser.add_argument("--out", default="data/samples")
    parser.add_argument("--cache", default="data/raw")
    parser.add_argument("--seed", type=int, default=0)
    args = parser.parse_args()

    rng = random.Random(args.seed)
    total = 0
    for day in args.days.split(","):
        base = datetime.strptime(day.strip(), "%Y-%m-%d")
        for hour in range(1, 24, args.hour_stride):
            total += build_time(base + timedelta(hours=hour), args, rng)
    print(f"total samples: {total}")


if __name__ == "__main__":
    main()
