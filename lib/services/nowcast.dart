import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

/// On-device radar nowcasting by extrapolation (Lagrangian persistence).
///
/// Fetches three observed NEXRAD composite frames (t-30, t-15, t-0) for a
/// region around a point from the IEM WMS, estimates a storm-motion field by
/// block matching, then advects the latest frame forward to produce
/// short-term "future radar" frames. No physics — assumes echoes keep moving
/// the way they have been, which holds up reasonably for ~30-60 minutes.
class NowcastService {
  NowcastService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const _imageSize = 512; // fetched/output frame edge, px
  static const _matchSize = 256; // downsampled edge for motion estimation
  static const _blockCount = 8; // 8x8 motion grid
  static const _searchRange = 16; // max block displacement, match px
  static const _baselineMinutes = 15; // time between matched frames
  static const _halfExtentM = 350000.0; // half bbox edge, mercator meters
  static const leadsMinutes = [10, 20, 30, 45, 60];

  static const _earthRadius = 6378137.0;

  Future<NowcastResult> computeNowcast(double latitude, double longitude) async {
    final cx = _earthRadius * longitude * math.pi / 180;
    final cy = _earthRadius *
        math.log(math.tan(math.pi / 4 + (latitude * math.pi / 180) / 2));
    final bbox = (
      xMin: cx - _halfExtentM,
      yMin: cy - _halfExtentM,
      xMax: cx + _halfExtentM,
      yMax: cy + _halfExtentM,
    );

    // t-30, t-15, t-0 observed frames.
    final frames = await Future.wait([
      _fetchFrame(bbox, 'nexrad-n0q-m30m'),
      _fetchFrame(bbox, 'nexrad-n0q-m15m'),
      _fetchFrame(bbox, 'nexrad-n0q'),
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

/// Isolate entry point: [t-30, t-15, t-0] PNGs in, one PNG per lead out.
List<Uint8List> extrapolateFrames(List<Uint8List> framePngs) {
  const size = NowcastService._imageSize;
  const matchSize = NowcastService._matchSize;

  final decoded = framePngs.map((png) {
    final image = img.decodePng(png);
    if (image == null) throw Exception('Failed to decode radar frame');
    return image.width == size
        ? image
        : img.copyResize(image, width: size, height: size);
  }).toList();

  // Single-channel echo intensity at match resolution for block matching.
  final intensities = decoded
      .map((f) => _intensity(
          img.copyResize(f, width: matchSize, height: matchSize), matchSize))
      .toList();

  // Motion per baseline step, averaged over the two frame pairs.
  final fieldA = _motionField(intensities[0], intensities[1], matchSize);
  final fieldB = _motionField(intensities[1], intensities[2], matchSize);
  final field = _averageAndFill(fieldA, fieldB);

  // Warp the latest frame forward for each lead time.
  final latest = decoded[2].convert(numChannels: 4);
  final src = latest.getBytes(order: img.ChannelOrder.rgba);
  final results = <Uint8List>[];
  const scale = size / matchSize;
  for (final lead in NowcastService.leadsMinutes) {
    final steps = lead / NowcastService._baselineMinutes;
    final out = Uint8List(size * size * 4);
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final v = _sampleField(field, x / scale, y / scale, matchSize);
        final sx = (x - v.$1 * scale * steps).round();
        final sy = (y - v.$2 * scale * steps).round();
        if (sx < 0 || sx >= size || sy < 0 || sy >= size) continue;
        final si = (sy * size + sx) * 4;
        final di = (y * size + x) * 4;
        out[di] = src[si];
        out[di + 1] = src[si + 1];
        out[di + 2] = src[si + 2];
        out[di + 3] = src[si + 3];
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

/// Echo intensity: alpha-gated luminance, so transparent (no echo) pixels
/// are zero and matching is driven by precipitation structure.
Uint8List _intensity(img.Image frame, int size) {
  final rgba = frame.convert(numChannels: 4).getBytes(order: img.ChannelOrder.rgba);
  final out = Uint8List(size * size);
  for (var i = 0; i < size * size; i++) {
    final a = rgba[i * 4 + 3];
    if (a < 32) continue;
    out[i] =
        ((rgba[i * 4] + 2 * rgba[i * 4 + 1] + rgba[i * 4 + 2]) >> 2).clamp(1, 255);
  }
  return out;
}

typedef _Field = List<List<(double, double)?>>;

/// Block-matching motion estimation: for each block of [prev], find the
/// displacement into [next] minimizing sum of absolute differences.
/// Returns null for blocks with too little echo to match reliably.
_Field _motionField(Uint8List prev, Uint8List next, int size) {
  const blocks = NowcastService._blockCount;
  const range = NowcastService._searchRange;
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
      // Under ~5% echo coverage the SAD surface is noise.
      if (echoPixels < blockSize * blockSize ~/ 4 ~/ 20) continue;

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
          if (sad < bestSad) {
            bestSad = sad;
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

/// Average two motion fields, fill unmatched blocks with the median motion,
/// and smooth with a 3x3 box filter.
_Field _averageAndFill(_Field a, _Field b) {
  const blocks = NowcastService._blockCount;

  final merged = List.generate(
      blocks, (_) => List<(double, double)?>.filled(blocks, null));
  final xs = <double>[];
  final ys = <double>[];
  for (var by = 0; by < blocks; by++) {
    for (var bx = 0; bx < blocks; bx++) {
      final va = a[by][bx];
      final vb = b[by][bx];
      final v = va != null && vb != null
          ? ((va.$1 + vb.$1) / 2, (va.$2 + vb.$2) / 2)
          : va ?? vb;
      merged[by][bx] = v;
      if (v != null) {
        xs.add(v.$1);
        ys.add(v.$2);
      }
    }
  }

  double median(List<double> values) {
    if (values.isEmpty) return 0;
    final sorted = [...values]..sort();
    return sorted[sorted.length ~/ 2];
  }

  final fill = (median(xs), median(ys));
  final smoothed = List.generate(
      blocks, (_) => List<(double, double)?>.filled(blocks, fill));
  for (var by = 0; by < blocks; by++) {
    for (var bx = 0; bx < blocks; bx++) {
      var sumX = 0.0, sumY = 0.0, n = 0;
      for (var oy = -1; oy <= 1; oy++) {
        for (var ox = -1; ox <= 1; ox++) {
          final ny = by + oy, nx = bx + ox;
          if (ny < 0 || ny >= blocks || nx < 0 || nx >= blocks) continue;
          final v = merged[ny][nx] ?? fill;
          sumX += v.$1;
          sumY += v.$2;
          n++;
        }
      }
      smoothed[by][bx] = (sumX / n, sumY / n);
    }
  }
  return smoothed;
}

/// Bilinear interpolation of the block motion field at match-resolution
/// coordinates.
(double, double) _sampleField(_Field field, double x, double y, int size) {
  const blocks = NowcastService._blockCount;
  final blockSize = size / blocks;
  final gx = ((x - blockSize / 2) / blockSize).clamp(0.0, blocks - 1.0);
  final gy = ((y - blockSize / 2) / blockSize).clamp(0.0, blocks - 1.0);
  final x0 = gx.floor(), y0 = gy.floor();
  final x1 = math.min(x0 + 1, blocks - 1), y1 = math.min(y0 + 1, blocks - 1);
  final fx = gx - x0, fy = gy - y0;

  (double, double) at(int by, int bx) => field[by][bx] ?? (0, 0);
  final top = (
    at(y0, x0).$1 * (1 - fx) + at(y0, x1).$1 * fx,
    at(y0, x0).$2 * (1 - fx) + at(y0, x1).$2 * fx
  );
  final bottom = (
    at(y1, x0).$1 * (1 - fx) + at(y1, x1).$1 * fx,
    at(y1, x0).$2 * (1 - fx) + at(y1, x1).$2 * fx
  );
  return (
    top.$1 * (1 - fy) + bottom.$1 * fy,
    top.$2 * (1 - fy) + bottom.$2 * fy
  );
}
