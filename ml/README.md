# skycast nowcast ML

On-device residual model for the radar nowcast (plan "option A"). The app's
heuristic nowcast (`lib/services/nowcast.dart` v3) already handles advection
and statistical fading; this model learns what that pipeline cannot see —
growth, decay and initiation — and runs on the phone via TFLite. No servers.

## How it fits together

Both training inputs and targets live in the latest observation's
*Lagrangian frame*: history frames are motion-aligned forward, verifying
future frames are warped back along the same motion. Advection is therefore
factored out, and the model's only job is the residual dynamics. At
inference the app feeds its own aligned frames (it already computes them for
S-PROG) and multiplies the model's per-lead output into the render fade.

`common.py` mirrors the Dart pipeline (intensity transform, block matching,
warp semantics). **Constants must match `nowcast.dart` — change both or
neither.**

## Usage

```
.venv\Scripts\activate
python build_dataset.py --days 2026-07-09,2026-07-10   # ~600 MB raw/day
python train.py --epochs 30
```

`train.py` prints the Lagrangian-persistence baseline (what the app
effectively does today). The model only earns its place in the APK if its
validation loss beats that number clearly.

Export lands in `models/nowcast_residual.tflite` (dynamic-range int8,
~1-2 MB). Full-int8 quantization (needs a representative dataset) can come
later if size or latency demand it.

## Data

IEM archive CONUS n0q composites, 5-minute cadence, plate-carrée 0.005°/px:
`https://mesonet.agron.iastate.edu/archive/data/YYYY/MM/DD/GIS/uscomp/n0q_*.png`

Pick storm-active days for training; quiet days produce few patches (the
builder requires ≥2% echo coverage per patch).

## Status / next steps

- [x] Data pipeline + Dart-mirroring motion port (2026-07-16)
- [x] Trainable UNet (~1M params) + TFLite export
- [ ] Curate storm-day list, build real dataset (aim: few thousand patches)
- [ ] Train on GPU (homelab VM or desktop), verify beats persistence
- [ ] Android integration: tflite_flutter, asset bundling, isolate inference,
      web keeps heuristic v3 (tflite_flutter has no web support)
