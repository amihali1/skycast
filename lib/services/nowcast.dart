import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

/// On-device radar nowcasting by motion extrapolation.
///
/// v2: four observed NEXRAD frames (t-45 … t-0) instead of three, with
///  - robust motion: per-block median over three frame pairs plus an
///    iterative correction pass against the latest frame,
///  - curvature: a damped per-block velocity trend so echoes can follow
///    arcs instead of straight lines,
///  - growth/decay: per-block intensity trend applied as an alpha fade or
///    build with lead time, so dying showers die in the forecast too.
///
/// v3 (S-PROG style): the latest field is split into spatial-scale bands and
/// each band's temporal autocorrelation is measured across the
/// motion-compensated history. Band contributions are faded as phi^lead, so
/// unpredictable small-scale cells drop out of the forecast quickly while
/// organized large-scale precipitation persists. Unlike real S-PROG the
/// filtered field is not rendered directly (it looks blurry); it is applied
/// as a per-pixel intensity ratio on top of the sharp advected frame.
///
/// Still no physics — Lagrangian extrapolation with statistical scale
/// filtering, useful to roughly an hour. It cannot predict new storm
/// formation.
class NowcastService {
  NowcastService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const _imageSize = 512; // fetched/output frame edge, px
  static const _matchSize = 256; // downsampled edge for motion estimation
  static const _blockCount = 8; // 8x8 motion grid
  static const _searchRange = 16; // max block displacement, match px
  static const _baselineMinutes = 15; // time between observed frames
  static const _halfExtentM = 350000.0; // half bbox edge, mercator meters
  static const frameOffsetsMinutes = [45, 30, 15, 0];
  static const leadsMinutes = [10, 20, 30, 45, 60];

  static const _earthRadius = 6378137.0;

  Future<NowcastResult> computeNowcast(
      double latitude, double longitude) async {
    final cx = _earthRadius * longitude * math.pi / 180;
    final cy = _earthRadius *
        math.log(math.tan(math.pi / 4 + (latitude * math.pi / 180) / 2));
    final bbox = (
      xMin: cx - _halfExtentM,
      yMin: cy - _halfExtentM,
      xMax: cx + _halfExtentM,
      yMax: cy + _halfExtentM,
    );

    final frames = await Future.wait([
      for (final offset in frameOffsetsMinutes)
        _fetchFrame(
            bbox,
            offset == 0
                ? 'nexrad-n0q'
                : 'nexrad-n0q-m${offset.toString().padLeft(2, '0')}m'),
    ]);

    final pngs = await _runExtrapolation(frames);

    final south = _mercatorToLat(bbox.yMin);
    final north = _mercatorToLat(bbox.yMax);
    final west = bbox.xMin / _earthRadius * 180 / math.pi;
    final east = bbox.xMax / _earthRadius * 180 / math.pi;

    return NowcastResult(
      frames: [
        for (var i = 0; i < leadsMinutes.length; i++)
          NowcastFrame(leadMinutes: leadsMinutes[i], png: pngs[i]),
      ],
      south: south,
      west: west,
      north: north,
      east: east,
    );
  }

  /// Runs the heavy pixel work off the UI thread where isolates exist
  /// (Android); on the web this runs inline, which is acceptable one-off work.
  Future<List<Uint8List>> _runExtrapolation(List<Uint8List> framePngs) =>
      compute(extrapolateFrames, framePngs);

  Future<Uint8List> _fetchFrame(
      ({double xMin, double yMin, double xMax, double yMax}) bbox,
      String layer) async {
    final uri = Uri.parse(
        'https://mesonet.agron.iastate.edu/cgi-bin/wms/nexrad/n0q.cgi'
        '?SERVICE=WMS&VERSION=1.1.1&REQUEST=GetMap'
        '&LAYERS=$layer&STYLES=&SRS=EPSG:3857'
        '&BBOX=${bbox.xMin},${bbox.yMin},${bbox.xMax},${bbox.yMax}'
        '&WIDTH=$_imageSize&HEIGHT=$_imageSize&FORMAT=image/png&TRANSPARENT=true');
    final response = await _client.get(uri);
    if (response.statusCode != 200) {
      throw Exception('Radar frame fetch failed (${response.statusCode})');
    }
    return response.bodyBytes;
  }

  static double _mercatorToLat(double y) =>
      (2 * math.atan(math.exp(y / _earthRadius)) - math.pi / 2) * 180 / math.pi;
}

class NowcastFrame {
  const NowcastFrame({required this.leadMinutes, required this.png});

  final int leadMinutes;
  final Uint8List png;
}

class NowcastResult {
  const NowcastResult({
    required this.frames,
    required this.south,
    required this.west,
    required this.north,
    required this.east,
  });

  final List<NowcastFrame> frames;
  final double south;
  final double west;
  final double north;
  final double east;
}

/// Isolate entry point: observed PNGs (oldest first, evenly spaced
/// [NowcastService._baselineMinutes] apart, latest = now) in, one PNG per
/// entry of [NowcastService.leadsMinutes] out.
List<Uint8List> extrapolateFrames(List<Uint8List> framePngs) {
  const size = NowcastService._imageSize;
  const matchSize = NowcastService._matchSize;
  const blocks = NowcastService._blockCount;

  final decoded = framePngs.map((png) {
    final image = img.decodePng(png);
    if (image == null) throw Exception('Failed to decode radar frame');
    return image.width == size
        ? image
        : img.copyResize(image, width: size, height: size);
  }).toList();
  final n = decoded.length;
  assert(n >= 3, 'need at least three observed frames');

  final intensities = decoded
      .map((f) => _intensity(
          img.copyResize(f, width: matchSize, height: matchSize), matchSize))
      .toList();

  // Pairwise motion fields between consecutive frames.
  final pairFields = [
    for (var k = 0; k < n - 1; k++)
      _motionField(intensities[k], intensities[k + 1], matchSize,
          NowcastService._searchRange),
  ];

  // Robust base velocity: per-block median across pairs, blended toward the
  // most recent pair so fresh accelerations are not fully suppressed.
  final vx = Float64List(blocks * blocks);
  final vy = Float64List(blocks * blocks);
  final valid = List<bool>.filled(blocks * blocks, false);

  // Recency-first: the most recent pair that saw echo in this block wins.
  // Older pairs describe where the storm *was* accelerating from; spatial
  // smoothing and the correction pass below handle matching noise.
  for (var b = 0; b < blocks * blocks; b++) {
    final by = b ~/ blocks, bx = b % blocks;
    for (final f in pairFields.reversed) {
      final v = f[by][bx];
      if (v != null) {
        vx[b] = v.$1;
        vy[b] = v.$2;
        valid[b] = true;
        break;
      }
    }
  }

  // Curvature: scene-level velocity trend across the frame pairs. Estimated
  // globally (per-pair scene medians) because per-block velocity history
  // breaks down as echoes cross block boundaries. Heavily damped and clamped
  // so noise cannot fling echoes off the map.
  var dvxG = 0.0, dvyG = 0.0;
  if (pairFields.length > 1) {
    List<double> sceneMedian(_Field f, double Function((double, double)) pick) =>
        [
          for (var by = 0; by < blocks; by++)
            for (var bx = 0; bx < blocks; bx++)
              if (f[by][bx] != null) pick(f[by][bx]!)
        ];
    final firstX = _median(sceneMedian(pairFields.first, (v) => v.$1));
    final firstY = _median(sceneMedian(pairFields.first, (v) => v.$2));
    final lastX = _median(sceneMedian(pairFields.last, (v) => v.$1));
    final lastY = _median(sceneMedian(pairFields.last, (v) => v.$2));
    dvxG = (lastX - firstX) / (pairFields.length - 1) * 0.5;
    dvyG = (lastY - firstY) / (pairFields.length - 1) * 0.5;
    final speed = math.sqrt(lastX * lastX + lastY * lastY);
    final maxTrend = math.max(1.5, 0.4 * speed);
    final trend = math.sqrt(dvxG * dvxG + dvyG * dvyG);
    if (trend > maxTrend) {
      dvxG *= maxTrend / trend;
      dvyG *= maxTrend / trend;
    }
  }

  // Correction pass: advect t-1 forward one step with the current field,
  // block-match the result against t-0 with a small search radius, and add
  // the residual displacement.
  final predictedNow = Uint8List(matchSize * matchSize);
  for (var y = 0; y < matchSize; y++) {
    for (var x = 0; x < matchSize; x++) {
      final b = _blockAt(x, y, matchSize);
      final sx = (x - vx[b]).round();
      final sy = (y - vy[b]).round();
      if (sx < 0 || sx >= matchSize || sy < 0 || sy >= matchSize) continue;
      predictedNow[y * matchSize + x] =
          intensities[n - 2][sy * matchSize + sx];
    }
  }
  final residual =
      _motionField(predictedNow, intensities[n - 1], matchSize, 6);
  for (var b = 0; b < blocks * blocks; b++) {
    final r = residual[b ~/ blocks][b % blocks];
    if (r != null) {
      vx[b] += r.$1;
      vy[b] += r.$2;
    }
  }

  // Spread the corrected vectors outward into echo-free blocks ring by
  // ring, so the motion of nearby precipitation applies where echoes are
  // about to arrive instead of being diluted by zeros.
  _dilate(vx, [...valid], blocks);
  _dilate(vy, [...valid], blocks);

  _smooth(vx, blocks);
  _smooth(vy, blocks);

  // Growth/decay: per-block intensity ratio between the latest frame and the
  // one two steps back, as a per-step geometric rate. The older frame is
  // motion-compensated first — otherwise a moving echo reads as "decay" in
  // the blocks it is leaving and would be faded out of the forecast.
  final olderAligned = Uint8List(matchSize * matchSize);
  for (var y = 0; y < matchSize; y++) {
    for (var x = 0; x < matchSize; x++) {
      final sx = (x - 2 * _bilinear(vx, x.toDouble(), y.toDouble(), matchSize))
          .round();
      final sy = (y - 2 * _bilinear(vy, x.toDouble(), y.toDouble(), matchSize))
          .round();
      if (sx < 0 || sx >= matchSize || sy < 0 || sy >= matchSize) continue;
      olderAligned[y * matchSize + x] =
          intensities[n - 3][sy * matchSize + sx];
    }
  }
  final growthValid = List<bool>.filled(blocks * blocks, false);
  final growth = _growthField(
      olderAligned, intensities[n - 1], matchSize, blocks, growthValid);
  _dilate(growth, growthValid, blocks);
  _smooth(growth, blocks);

  // Scale-dependent predictability (S-PROG style): split the intensity
  // field into spatial-scale bands and measure, per band, how quickly it
  // decorrelates across the motion-compensated observed frames. At each
  // lead time every band is damped by phi^steps, so small unpredictable
  // cells fade out of the forecast while broad organized shields persist.
  Float32List toFloat(Uint8List u) {
    final f = Float32List(u.length);
    for (var i = 0; i < u.length; i++) {
      f[i] = u[i].toDouble();
    }
    return f;
  }

  // Advects an observed frame forward one baseline step with the final
  // velocity field, so consecutive frames compare in a common (Lagrangian)
  // frame; without this, motion itself reads as decorrelation.
  Float32List warpOneStep(Uint8List frame) {
    final out = Float32List(matchSize * matchSize);
    for (var y = 0; y < matchSize; y++) {
      for (var x = 0; x < matchSize; x++) {
        final sx =
            (x - _bilinear(vx, x.toDouble(), y.toDouble(), matchSize)).round();
        final sy =
            (y - _bilinear(vy, x.toDouble(), y.toDouble(), matchSize)).round();
        if (sx < 0 || sx >= matchSize || sy < 0 || sy >= matchSize) continue;
        out[y * matchSize + x] = frame[sy * matchSize + sx].toDouble();
      }
    }
    return out;
  }

  // Only the latest pair (t-1 → t-0) is used for the correlations: the
  // correction pass above tuned the velocity field to map exactly that
  // transition, so its warp alignment is trustworthy. Warping older pairs
  // with the same single field misaligns them whenever the motion is
  // accelerating, and misalignment reads as false decorrelation that fades
  // healthy echoes (same Eulerian-trap class of bug as growth/velocity
  // trends).
  final latestF = toFloat(intensities[n - 1]);
  final phi = List<double>.of(_defaultPhi);
  final aligned = warpOneStep(intensities[n - 2]);
  final mask = Uint8List(matchSize * matchSize);
  var maskCount = 0;
  for (var i = 0; i < mask.length; i++) {
    if (aligned[i] > 0 || latestF[i] > 0) {
      mask[i] = 1;
      maskCount++;
    }
  }
  // Under ~800 echo pixels the statistics are unstable; keep the defaults.
  if (maskCount >= 800) {
    final cascadeOld = _cascade(aligned, matchSize);
    final cascadeNew = _cascade(latestF, matchSize);
    for (var k = 0; k < _levelCount; k++) {
      final r = _maskedCorrelation(cascadeOld[k], cascadeNew[k], mask);
      if (!r.isNaN) phi[k] = r.clamp(0.05, 0.999);
    }
  }
  // A finer scale can never be more persistent than a coarser one; noisy
  // correlations occasionally say otherwise, so lower the finer level
  // (never inflate the coarser one).
  for (var k = _levelCount - 2; k >= 0; k--) {
    phi[k] = math.min(phi[k], phi[k + 1]);
  }
  final cascadeNow = _cascade(latestF, matchSize);

  // Advect the latest frame along curved trajectories for each lead time.
  final latest = decoded[n - 1].convert(numChannels: 4);
  final src = latest.getBytes(order: img.ChannelOrder.rgba);
  final results = <Uint8List>[];
  const scale = size / matchSize;

  for (final lead in NowcastService.leadsMinutes) {
    final steps = lead / NowcastService._baselineMinutes;
    final substeps = math.min(steps.ceil(), 3);
    final dt = steps / substeps;

    // Per-pixel predictability ratio for this lead: the scale-filtered
    // field over the observed one. Where small-scale detail dominates the
    // filtered value collapses and the ratio fades the echo; where a broad
    // shield dominates it stays near 1.
    final decay = [
      for (var k = 0; k < _levelCount; k++) math.pow(phi[k], steps).toDouble()
    ];
    final scaleFade = Float32List(matchSize * matchSize);
    for (var i = 0; i < scaleFade.length; i++) {
      final observed = latestF[i];
      if (observed < 4) {
        // Too faint for a stable ratio. Echo that exists at full
        // resolution but barely registers here is by definition
        // finest-scale detail, so give it the finest band's persistence —
        // a flat 1.0 would let sub-block echoes sail through the filter.
        scaleFade[i] = math.max(0.15, decay[0]);
        continue;
      }
      var filtered = 0.0;
      for (var k = 0; k < _levelCount; k++) {
        filtered += cascadeNow[k][i] * decay[k];
      }
      scaleFade[i] = ((filtered + 2) / (observed + 2)).clamp(0.15, 1.1);
    }

    final out = Uint8List(size * size * 4);

    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        // Backward semi-Lagrangian: walk from the output pixel back to its
        // source, sampling the (time-varying) velocity along the way.
        var px = x / scale;
        var py = y / scale;
        var tau = steps;
        for (var s = 0; s < substeps; s++) {
          tau -= dt / 2; // midpoint of this substep
          final bvx = _bilinear(vx, px, py, matchSize) + dvxG * tau;
          final bvy = _bilinear(vy, px, py, matchSize) + dvyG * tau;
          px -= bvx * dt;
          py -= bvy * dt;
          tau -= dt / 2;
        }
        final sx = (px * scale).round();
        final sy = (py * scale).round();
        if (sx < 0 || sx >= size || sy < 0 || sy >= size) continue;
        final si = (sy * size + sx) * 4;
        final alpha = src[si + 3];
        if (alpha == 0) continue;

        // Growth rate and predictability travel with the parcel: sample at
        // the source, not the destination, so a decaying cell keeps
        // decaying as it moves.
        final g = _bilinear(growth, px, py, matchSize);
        final mx = px.round().clamp(0, matchSize - 1);
        final my = py.round().clamp(0, matchSize - 1);
        final fade = (math.pow(g, steps).toDouble().clamp(0.2, 1.5) *
                scaleFade[my * matchSize + mx])
            .clamp(0.05, 1.5);
        final di = (y * size + x) * 4;
        out[di] = src[si];
        out[di + 1] = src[si + 1];
        out[di + 2] = src[si + 2];
        out[di + 3] = (alpha * fade).round().clamp(0, 255);
      }
    }
    results.add(img.encodePng(img.Image.fromBytes(
      width: size,
      height: size,
      bytes: out.buffer,
      order: img.ChannelOrder.rgba,
    )));
  }
  return results;
}

int _blockAt(int x, int y, int size) {
  const blocks = NowcastService._blockCount;
  final blockSize = size ~/ blocks;
  final bx = (x ~/ blockSize).clamp(0, blocks - 1);
  final by = (y ~/ blockSize).clamp(0, blocks - 1);
  return by * blocks + bx;
}

double _median(List<double> values) {
  if (values.isEmpty) return 0;
  final sorted = [...values]..sort();
  return sorted[sorted.length ~/ 2];
}

/// In-place 3x3 box smoothing of a blocks*blocks grid.
void _smooth(Float64List grid, int blocks) {
  final copy = Float64List.fromList(grid);
  for (var by = 0; by < blocks; by++) {
    for (var bx = 0; bx < blocks; bx++) {
      var sum = 0.0, n = 0;
      for (var oy = -1; oy <= 1; oy++) {
        for (var ox = -1; ox <= 1; ox++) {
          final ny = by + oy, nx = bx + ox;
          if (ny < 0 || ny >= blocks || nx < 0 || nx >= blocks) continue;
          sum += copy[ny * blocks + nx];
          n++;
        }
      }
      grid[by * blocks + bx] = sum / n;
    }
  }
}

/// Per-block geometric intensity growth rate per baseline step, from the
/// frame two steps back to the latest. 1.0 = steady state. Marks blocks with
/// a trustworthy ratio in [valid].
Float64List _growthField(Uint8List older, Uint8List latest, int size,
    int blocks, List<bool> valid) {
  final blockSize = size ~/ blocks;
  final field = Float64List(blocks * blocks)..fillRange(0, blocks * blocks, 1);
  for (var by = 0; by < blocks; by++) {
    for (var bx = 0; bx < blocks; bx++) {
      var sumOld = 0, sumNew = 0;
      for (var y = by * blockSize; y < (by + 1) * blockSize; y += 2) {
        for (var x = bx * blockSize; x < (bx + 1) * blockSize; x += 2) {
          sumOld += older[y * size + x];
          sumNew += latest[y * size + x];
        }
      }
      // Both frames need real echo for a trustworthy ratio.
      if (sumOld > 500 && sumNew > 500) {
        field[by * blocks + bx] = math.sqrt(sumNew / sumOld).clamp(0.7, 1.15);
        valid[by * blocks + bx] = true;
      }
    }
  }
  return field;
}

/// Iteratively spreads values from valid blocks into invalid neighbors
/// (mean of valid neighbors), ring by ring, until every reachable block has
/// a value. Blocks with no valid block anywhere keep their initial value.
void _dilate(Float64List grid, List<bool> valid, int blocks) {
  for (var pass = 0; pass < blocks; pass++) {
    final newlyValid = <int>[];
    for (var by = 0; by < blocks; by++) {
      for (var bx = 0; bx < blocks; bx++) {
        final b = by * blocks + bx;
        if (valid[b]) continue;
        var sum = 0.0, n = 0;
        for (var oy = -1; oy <= 1; oy++) {
          for (var ox = -1; ox <= 1; ox++) {
            final ny = by + oy, nx = bx + ox;
            if (ny < 0 || ny >= blocks || nx < 0 || nx >= blocks) continue;
            final nb = ny * blocks + nx;
            if (valid[nb]) {
              sum += grid[nb];
              n++;
            }
          }
        }
        if (n > 0) {
          grid[b] = sum / n;
          newlyValid.add(b);
        }
      }
    }
    if (newlyValid.isEmpty) break;
    for (final b in newlyValid) {
      valid[b] = true;
    }
  }
}

/// Bilinear sample of a blocks*blocks grid at match-resolution coordinates.
double _bilinear(Float64List grid, double x, double y, int size) {
  const blocks = NowcastService._blockCount;
  final blockSize = size / blocks;
  final gx = ((x - blockSize / 2) / blockSize).clamp(0.0, blocks - 1.0);
  final gy = ((y - blockSize / 2) / blockSize).clamp(0.0, blocks - 1.0);
  final x0 = gx.floor(), y0 = gy.floor();
  final x1 = math.min(x0 + 1, blocks - 1), y1 = math.min(y0 + 1, blocks - 1);
  final fx = gx - x0, fy = gy - y0;
  final top =
      grid[y0 * blocks + x0] * (1 - fx) + grid[y0 * blocks + x1] * fx;
  final bottom =
      grid[y1 * blocks + x0] * (1 - fx) + grid[y1 * blocks + x1] * fx;
  return top * (1 - fy) + bottom * fy;
}

/// Echo intensity: alpha-gated luminance, so transparent (no echo) pixels
/// are zero and matching is driven by precipitation structure.
Uint8List _intensity(img.Image frame, int size) {
  final rgba =
      frame.convert(numChannels: 4).getBytes(order: img.ChannelOrder.rgba);
  final out = Uint8List(size * size);
  for (var i = 0; i < size * size; i++) {
    final a = rgba[i * 4 + 3];
    if (a < 32) continue;
    out[i] = ((rgba[i * 4] + 2 * rgba[i * 4 + 1] + rgba[i * 4 + 2]) >> 2)
        .clamp(1, 255);
  }
  return out;
}

/// Gaussian sigmas (match-resolution px) separating the cascade's scale
/// bands. The field splits into [_levelCount] components: finest bandpass
/// first, low-pass residual last. At 256 px over a 700 km domain these cut
/// structure at wavelengths of very roughly 10 / 20 / 40 / 80 km.
const _cascadeSigmas = [1.5, 3.0, 6.0, 12.0];
const _levelCount = 5; // _cascadeSigmas bandpass levels + low-pass residual

/// Fallback per-level lag-1 autocorrelations (finest first) for scenes with
/// too little echo to measure them. Climatology-flavored: small scales live
/// tens of minutes, synoptic envelopes hours.
const _defaultPhi = [0.55, 0.75, 0.90, 0.97, 0.995];

/// Splits a field into bandpass levels (finest first) plus a low-pass
/// residual (last) — a difference-of-Gaussians approximation of the S-PROG
/// FFT cascade.
List<Float32List> _cascade(Float32List field, int size) {
  final levels = <Float32List>[];
  var prev = field;
  for (final sigma in _cascadeSigmas) {
    final blurred = _gaussianBlur(field, size, sigma);
    final level = Float32List(size * size);
    for (var i = 0; i < size * size; i++) {
      level[i] = prev[i] - blurred[i];
    }
    levels.add(level);
    prev = blurred;
  }
  levels.add(prev);
  return levels;
}

/// Approximate Gaussian blur of a size*size field: three box passes per
/// axis (O(n) per pass via running sums), edges replicated.
Float32List _gaussianBlur(Float32List src, int size, double sigma) {
  final a = Float32List.fromList(src);
  final b = Float32List(size * size);
  for (final w in _boxesForGauss(sigma, 3)) {
    final r = (w - 1) ~/ 2;
    _boxBlurH(a, b, size, r);
    _boxBlurV(b, a, size, r);
  }
  return a;
}

/// Box widths whose triple application approximates a Gaussian of [sigma].
List<int> _boxesForGauss(double sigma, int n) {
  final wIdeal = math.sqrt(12 * sigma * sigma / n + 1);
  var wl = wIdeal.floor();
  if (wl.isEven) wl--;
  final wu = wl + 2;
  final mIdeal =
      (12 * sigma * sigma - n * wl * wl - 4 * n * wl - 3 * n) / (-4 * wl - 4);
  final m = mIdeal.round();
  return [for (var i = 0; i < n; i++) i < m ? wl : wu];
}

void _boxBlurH(Float32List src, Float32List dst, int size, int r) {
  final norm = 1.0 / (2 * r + 1);
  for (var y = 0; y < size; y++) {
    final row = y * size;
    var sum = 0.0;
    for (var x = -r; x <= r; x++) {
      sum += src[row + x.clamp(0, size - 1)];
    }
    for (var x = 0; x < size; x++) {
      dst[row + x] = sum * norm;
      sum += src[row + (x + r + 1).clamp(0, size - 1)] -
          src[row + (x - r).clamp(0, size - 1)];
    }
  }
}

void _boxBlurV(Float32List src, Float32List dst, int size, int r) {
  final norm = 1.0 / (2 * r + 1);
  for (var x = 0; x < size; x++) {
    var sum = 0.0;
    for (var y = -r; y <= r; y++) {
      sum += src[x + size * y.clamp(0, size - 1)];
    }
    for (var y = 0; y < size; y++) {
      dst[y * size + x] = sum * norm;
      sum += src[x + size * (y + r + 1).clamp(0, size - 1)] -
          src[x + size * (y - r).clamp(0, size - 1)];
    }
  }
}

/// Pearson correlation of [a] and [b] over pixels where [mask] is nonzero.
/// NaN when the masked sample is degenerate.
double _maskedCorrelation(Float32List a, Float32List b, Uint8List mask) {
  var count = 0;
  var sumA = 0.0, sumB = 0.0;
  for (var i = 0; i < mask.length; i++) {
    if (mask[i] == 0) continue;
    count++;
    sumA += a[i];
    sumB += b[i];
  }
  if (count < 2) return double.nan;
  final meanA = sumA / count, meanB = sumB / count;
  var cov = 0.0, varA = 0.0, varB = 0.0;
  for (var i = 0; i < mask.length; i++) {
    if (mask[i] == 0) continue;
    final da = a[i] - meanA, db = b[i] - meanB;
    cov += da * db;
    varA += da * da;
    varB += db * db;
  }
  final denom = math.sqrt(varA * varB);
  if (denom < 1e-9) return double.nan;
  return cov / denom;
}

typedef _Field = List<List<(double, double)?>>;

/// Block-matching motion estimation: for each block of [prev], find the
/// displacement into [next] minimizing sum of absolute differences.
/// Returns null for blocks with too little echo to match reliably.
_Field _motionField(Uint8List prev, Uint8List next, int size, int range) {
  const blocks = NowcastService._blockCount;
  final blockSize = size ~/ blocks;

  final field = List.generate(
      blocks, (_) => List<(double, double)?>.filled(blocks, null));

  for (var by = 0; by < blocks; by++) {
    for (var bx = 0; bx < blocks; bx++) {
      final x0 = bx * blockSize;
      final y0 = by * blockSize;

      var echoPixels = 0;
      for (var y = y0; y < y0 + blockSize; y += 2) {
        for (var x = x0; x < x0 + blockSize; x += 2) {
          if (prev[y * size + x] > 0) echoPixels++;
        }
      }
      // Under ~15% echo coverage the SAD surface is noise: thin slivers of
      // a storm crossing the block boundary produce confident-looking
      // garbage vectors that then dilate into the forecast path.
      if (echoPixels < blockSize * blockSize ~/ 4 * 3 ~/ 20) continue;

      var bestSad = 1 << 30;
      var bestDx = 0;
      var bestDy = 0;
      for (var dy = -range; dy <= range; dy += 2) {
        for (var dx = -range; dx <= range; dx += 2) {
          var sad = 0;
          for (var y = y0; y < y0 + blockSize; y += 2) {
            final sy = y + dy;
            if (sy < 0 || sy >= size) {
              sad = 1 << 30;
              break;
            }
            for (var x = x0; x < x0 + blockSize; x += 2) {
              final sx = x + dx;
              sad += sx < 0 || sx >= size
                  ? 255
                  : (prev[y * size + x] - next[sy * size + sx]).abs();
            }
            if (sad >= bestSad) break;
          }
          // Small displacement penalty: on a flat SAD surface (weak or
          // featureless echo) prefer the smallest motion instead of
          // whichever corner of the search window came first. Scaled by
          // echo coverage so it stays sub-dominant to real structure.
          final cost = sad + echoPixels * (dx.abs() + dy.abs());
          if (cost < bestSad) {
            bestSad = cost;
            bestDx = dx;
            bestDy = dy;
          }
        }
      }
      field[by][bx] = (bestDx.toDouble(), bestDy.toDouble());
    }
  }
  return field;
}
