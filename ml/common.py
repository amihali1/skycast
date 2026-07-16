"""Shared pieces of the skycast nowcast-ML pipeline.

Everything here mirrors lib/services/nowcast.dart so that training sees the
same inputs the app produces at inference time: the same intensity
transform, the same block-matching motion estimation, and the same warp
semantics. Constants deliberately match the Dart file — change them in both
places or not at all.
"""

from __future__ import annotations

import math
import time
from datetime import datetime
from pathlib import Path

import numpy as np
import requests
from PIL import Image

MATCH_SIZE = 256  # working resolution, px (Dart _matchSize)
BLOCKS = 8  # motion grid (Dart _blockCount)
SEARCH_RANGE = 16  # max block displacement, px (Dart _searchRange)
BASELINE_MINUTES = 15  # spacing of observed frames
FRAME_OFFSETS_MIN = [45, 30, 15, 0]  # history, oldest first
LEADS_MIN = [10, 20, 30, 45, 60]  # forecast leads (Dart leadsMinutes)

# IEM CONUS composite geometry (from the .wld file).
ARCHIVE_URL = (
    "https://mesonet.agron.iastate.edu/archive/data/"
    "{t:%Y/%m/%d}/GIS/uscomp/n0q_{t:%Y%m%d%H%M}.png"
)
GRID_DEG_PER_PX = 0.005
GRID_LON0 = -126.0  # west edge
GRID_LAT0 = 50.0  # north edge
GRID_W = 12200
GRID_H = 5400
KM_PER_DEG = 111.32

# The app fetches a 700 km (mercator) square; at mid-CONUS latitudes that is
# ~570 true km over 256 match px => ~2.2 km/px. Training patches use that
# fixed true-km scale.
PATCH_KM = 568.0
KM_PER_PX = PATCH_KM / MATCH_SIZE

# Palette index of 20 dBZ (index = 2 * (dBZ + 32)): the floor for "real
# precipitation" when gating patches. The luminance the model consumes is
# NOT monotonic in dBZ (reds are darker than pale blues), so gates must use
# the palette index, never the luminance.
PRECIP_INDEX = 104


def fetch_frame(t: datetime, cache_dir: Path) -> Path | None:
    """Downloads (or reuses) the archive composite for time [t].

    Returns None on 404 — archive gaps happen and callers should skip the
    whole sample rather than train against a hole. Transient network
    failures are retried with backoff and also degrade to None (skipped
    sample) rather than killing a multi-hour build; a systematic outage
    shows up as a run of "archive gap" skips in the log.
    """
    cache_dir.mkdir(parents=True, exist_ok=True)
    path = cache_dir / f"n0q_{t:%Y%m%d%H%M}.png"
    if path.exists():
        return path
    for backoff in (5, 15, 45, 120, None):
        try:
            resp = requests.get(ARCHIVE_URL.format(t=t), timeout=120)
            if resp.status_code == 404:
                return None
            resp.raise_for_status()
        except requests.exceptions.RequestException as e:
            if backoff is None:
                print(f"giving up on {path.name}: {e}")
                return None
            time.sleep(backoff)
            continue
        tmp = path.with_suffix(".part")
        tmp.write_bytes(resp.content)
        tmp.rename(path)
        return path
    return None


def extract_patch(
    image: Image.Image, lat: float, lon: float
) -> tuple[np.ndarray, float] | None:
    """Cuts a PATCH_KM x PATCH_KM patch centred on (lat, lon) and returns
    (MATCH_SIZE x MATCH_SIZE uint8 intensity, fraction of native pixels at
    or above PRECIP_INDEX).

    The archive grid is plate-carree, so a square-in-km patch spans more
    columns than rows by 1/cos(lat). Returns None if the patch leaves the
    grid.
    """
    rows = round(PATCH_KM / (GRID_DEG_PER_PX * KM_PER_DEG))
    cols = round(rows / math.cos(math.radians(lat)))
    cx = (lon - GRID_LON0) / GRID_DEG_PER_PX
    cy = (GRID_LAT0 - lat) / GRID_DEG_PER_PX
    x0 = int(cx - cols / 2)
    y0 = int(cy - rows / 2)
    if x0 < 0 or y0 < 0 or x0 + cols > GRID_W or y0 + rows > GRID_H:
        return None
    crop = image.crop((x0, y0, x0 + cols, y0 + rows))

    # The archive composite is palettized with an opaque black background
    # (index 0) instead of the WMS transparency the app sees, so the app's
    # alpha gate cannot work here. Map palette->luminance with the same
    # (r + 2g + b) >> 2 formula as Dart _intensity(), forcing index 0 to
    # zero to recover the "no echo" state.
    pal = np.array(image.getpalette(), dtype=np.int32).reshape(-1, 3)
    lum = np.clip((pal[:, 0] + 2 * pal[:, 1] + pal[:, 2]) >> 2, 1, 255)
    lum[0] = 0
    idx = np.asarray(crop)
    native = lum[idx].astype(np.uint8)
    resized = Image.fromarray(native, "L").resize(
        (MATCH_SIZE, MATCH_SIZE), Image.BILINEAR
    )
    return np.asarray(resized), float((idx >= PRECIP_INDEX).mean())


def _motion_field(prev: np.ndarray, nxt: np.ndarray, search: int) -> np.ndarray:
    """Block-matching motion, port of Dart _motionField().

    Returns (BLOCKS, BLOCKS, 2) float with NaN where a block had too little
    echo to match. Same 2-px sampling stride, same 15% coverage gate, same
    small-displacement penalty.
    """
    size = prev.shape[0]
    bs = size // BLOCKS
    # Sample every 2nd pixel, as the Dart loops do.
    ps = prev[::2, ::2].astype(np.int32)
    # Pad the next frame so partially out-of-frame displacements cost ~255
    # per missing pixel (Dart charges 255 per out-of-column pixel).
    pad = search // 2 + 1
    ns = np.pad(nxt[::2, ::2].astype(np.int32), pad, constant_values=-255)

    half = bs // 2  # block edge in sampled px
    n_blocks = BLOCKS * BLOCKS
    echo = (ps > 0).reshape(BLOCKS, half, BLOCKS, half).swapaxes(1, 2)
    echo_px = echo.reshape(n_blocks, -1).sum(axis=1)
    gate = (bs * bs // 4) * 3 // 20

    best_cost = np.full(n_blocks, np.inf)
    best = np.zeros((n_blocks, 2))
    for dy in range(-search, search + 1, 2):
        for dx in range(-search, search + 1, 2):
            shifted = ns[
                pad + dy // 2 : pad + dy // 2 + size // 2,
                pad + dx // 2 : pad + dx // 2 + size // 2,
            ]
            diff = np.abs(ps - shifted)
            sad = (
                diff.reshape(BLOCKS, half, BLOCKS, half)
                .swapaxes(1, 2)
                .reshape(n_blocks, -1)
                .sum(axis=1)
            )
            cost = sad + echo_px * (abs(dx) + abs(dy))
            better = cost < best_cost
            best_cost = np.where(better, cost, best_cost)
            best[better] = (dx, dy)

    best[echo_px < gate] = np.nan
    return best.reshape(BLOCKS, BLOCKS, 2)


def _dilate(grid: np.ndarray, valid: np.ndarray) -> None:
    """Ring-by-ring spread of valid values into invalid blocks, in place.
    Port of Dart _dilate()."""
    for _ in range(BLOCKS):
        padded = np.pad(grid, 1)
        pvalid = np.pad(valid, 1)
        acc = np.zeros_like(grid)
        cnt = np.zeros_like(grid)
        for oy in (-1, 0, 1):
            for ox in (-1, 0, 1):
                sl = padded[1 + oy : 1 + oy + BLOCKS, 1 + ox : 1 + ox + BLOCKS]
                vl = pvalid[1 + oy : 1 + oy + BLOCKS, 1 + ox : 1 + ox + BLOCKS]
                acc += np.where(vl, sl, 0.0)
                cnt += vl
        newly = ~valid & (cnt > 0)
        if not newly.any():
            return
        grid[newly] = acc[newly] / cnt[newly]
        valid |= newly


def _smooth(grid: np.ndarray) -> np.ndarray:
    """3x3 box smoothing with edge-shrunk kernels, port of Dart _smooth()."""
    padded = np.pad(grid, 1)
    ones = np.pad(np.ones_like(grid), 1)
    acc = np.zeros_like(grid)
    cnt = np.zeros_like(grid)
    for oy in (-1, 0, 1):
        for ox in (-1, 0, 1):
            acc += padded[1 + oy : 1 + oy + BLOCKS, 1 + ox : 1 + ox + BLOCKS]
            cnt += ones[1 + oy : 1 + oy + BLOCKS, 1 + ox : 1 + ox + BLOCKS]
    return acc / cnt


def bilinear_field(grid: np.ndarray, size: int = MATCH_SIZE) -> np.ndarray:
    """Expands a BLOCKS x BLOCKS grid to per-pixel values, port of Dart
    _bilinear() (block centres, clamped edges)."""
    bs = size / BLOCKS
    coords = np.clip((np.arange(size) - bs / 2) / bs, 0.0, BLOCKS - 1.0)
    i0 = np.floor(coords).astype(int)
    i1 = np.minimum(i0 + 1, BLOCKS - 1)
    f = coords - i0
    fx = f[None, :]
    fy = f[:, None]
    top = grid[np.ix_(i0, i0)] * (1 - fx) + grid[np.ix_(i0, i1)] * fx
    bottom = grid[np.ix_(i1, i0)] * (1 - fx) + grid[np.ix_(i1, i1)] * fx
    return top * (1 - fy) + bottom * fy


def estimate_motion(frames: list[np.ndarray]) -> tuple[np.ndarray, np.ndarray]:
    """Full motion pipeline of extrapolateFrames() minus the scene-level
    curvature trend (alignment warps use the plain field, as the Dart
    warpOneStep does): recency-first merge, correction pass against the
    latest frame, dilate, smooth. Returns per-block (vx, vy)."""
    pair_fields = [
        _motion_field(frames[k], frames[k + 1], SEARCH_RANGE)
        for k in range(len(frames) - 1)
    ]

    vx = np.zeros((BLOCKS, BLOCKS))
    vy = np.zeros((BLOCKS, BLOCKS))
    valid = np.zeros((BLOCKS, BLOCKS), dtype=bool)
    for field in reversed(pair_fields):
        ok = ~np.isnan(field[..., 0]) & ~valid
        vx[ok] = field[..., 0][ok]
        vy[ok] = field[..., 1][ok]
        valid |= ok

    predicted = warp(frames[-2], vx, vy, steps=1)
    residual = _motion_field(predicted, frames[-1], search=6)
    ok = ~np.isnan(residual[..., 0])
    vx[ok] += residual[..., 0][ok]
    vy[ok] += residual[..., 1][ok]

    _dilate(vx, valid.copy())
    _dilate(vy, valid.copy())
    return _smooth(vx), _smooth(vy)


def warp(frame: np.ndarray, vx: np.ndarray, vy: np.ndarray, steps: float) -> np.ndarray:
    """out(x) = frame(x - steps*v): advects [frame] forward [steps] baseline
    steps. Port of Dart warpOneStep()/olderAligned sampling (round + zero
    outside)."""
    return _sample(frame, vx, vy, -steps)


def warp_back(frame: np.ndarray, vx: np.ndarray, vy: np.ndarray, steps: float
              ) -> tuple[np.ndarray, np.ndarray]:
    """target(x) = frame(x + steps*v): pulls a future frame back to the
    latest observation's Lagrangian frame. Also returns the in-bounds mask
    so out-of-frame pixels can be excluded from the loss."""
    out = _sample(frame, vx, vy, +steps)
    mask = _sample(np.ones_like(frame), vx, vy, +steps) > 0
    return out, mask


def _sample(frame: np.ndarray, vx: np.ndarray, vy: np.ndarray, factor: float
            ) -> np.ndarray:
    size = frame.shape[0]
    fvx = bilinear_field(vx, size)
    fvy = bilinear_field(vy, size)
    ys, xs = np.mgrid[0:size, 0:size]
    sx = np.round(xs + factor * fvx).astype(int)
    sy = np.round(ys + factor * fvy).astype(int)
    inside = (sx >= 0) & (sx < size) & (sy >= 0) & (sy < size)
    out = np.zeros_like(frame)
    out[inside] = frame[sy[inside], sx[inside]]
    return out
