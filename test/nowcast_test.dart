import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:skycast/services/nowcast.dart';

/// 512x512 transparent frame with an opaque 60px square at [x],[y].
Uint8List frame({required int x, required int y, int green = 200}) {
  final image = img.Image(width: 512, height: 512, numChannels: 4);
  img.fillRect(image,
      x1: x, y1: y, x2: x + 60, y2: y + 60,
      color: img.ColorRgba8(0, green, 0, 255));
  return img.encodePng(image);
}

double opaqueFraction(img.Image image, int x0, int y0, int x1, int y1) {
  var opaque = 0, total = 0;
  for (var y = y0; y < y1; y++) {
    for (var x = x0; x < x1; x++) {
      total++;
      if (image.getPixel(x, y).a > 128) opaque++;
    }
  }
  return opaque / total;
}

/// Centroid of opaque pixels, or null if there are none.
(double, double)? centroid(img.Image image) {
  var sx = 0.0, sy = 0.0, n = 0;
  for (var y = 0; y < 512; y += 2) {
    for (var x = 0; x < 512; x += 2) {
      if (image.getPixel(x, y).a > 128) {
        sx += x;
        sy += y;
        n++;
      }
    }
  }
  return n == 0 ? null : (sx / n, sy / n);
}

img.Image predictAt(List<Uint8List> frames, int leadMinutes) {
  final predicted = extrapolateFrames(frames);
  final index = NowcastService.leadsMinutes.indexOf(leadMinutes);
  return img.decodePng(predicted[index])!;
}

void main() {
  test('steady eastward drift keeps extrapolating east', () {
    // +20px per step: x = 80, 100, 120, 140.
    final frames4 = [
      frame(x: 80, y: 200),
      frame(x: 100, y: 200),
      frame(x: 120, y: 200),
      frame(x: 140, y: 200),
    ];
    final at30 = predictAt(frames4, 30);

    // Two more steps => expected near x=180.
    expect(opaqueFraction(at30, 190, 215, 220, 245), greaterThan(0.5),
        reason: 'echo should have advected ~40px east of its last position');
    expect(opaqueFraction(at30, 100, 215, 130, 245), lessThan(0.2),
        reason: 'echo should have left its old position');
  });

  test('accelerating echo curves beyond the straight-line prediction', () {
    // Northward motion strengthening each step: y = 400, 400, 378, 334
    // (0, -22, -44 px/step). A straight-line forecast from the latest
    // velocity would put the +30 min centroid near y≈274; with the
    // velocity trend it should land clearly north of that.
    final frames4 = [
      frame(x: 200, y: 400),
      frame(x: 200, y: 400),
      frame(x: 200, y: 378),
      frame(x: 200, y: 334),
    ];
    final at30 = predictAt(frames4, 30);

    final c = centroid(at30);
    expect(c, isNotNull, reason: 'accelerating echo must not vanish');
    expect(c!.$2, lessThan(268),
        reason: 'trend-aware forecast should outrun straight-line y≈274');
    expect(c.$2, greaterThan(180),
        reason: 'damped trend must not fling the echo off the map');
    expect(c.$1, closeTo(230, 25),
        reason: 'no sideways motion was observed');
  });

  test('weakening echo fades with lead time', () {
    // Static blob losing intensity every step.
    final frames4 = [
      frame(x: 200, y: 200, green: 240),
      frame(x: 200, y: 200, green: 180),
      frame(x: 200, y: 200, green: 135),
      frame(x: 200, y: 200, green: 101),
    ];
    final at10 = predictAt(frames4, 10);
    final at60 = predictAt(frames4, 60);

    expect(opaqueFraction(at10, 210, 210, 250, 250), greaterThan(0.5),
        reason: 'echo should still be mostly opaque at +10 min');
    expect(opaqueFraction(at60, 210, 210, 250, 250), 0,
        reason: 'decaying echo should have faded below half opacity by +60');
  });

  test('unpredictable small-scale noise fades while large echo persists', () {
    Uint8List speckledFrame(int seed) {
      final image = img.Image(width: 512, height: 512, numChannels: 4);
      // Static soft-edged disk on the left: predictable, large-scale.
      for (var y = 176; y < 336; y++) {
        for (var x = 48; x < 208; x++) {
          final d = math.sqrt(math.pow(x - 128, 2) + math.pow(y - 256, 2));
          if (d >= 80) continue;
          final a = d < 50 ? 255 : (255 * (80 - d) / 30).round();
          if (a < 40) continue;
          image.setPixelRgba(x, y, 0, 200, 0, a);
        }
      }
      // Fresh random speckles on the right every frame: unpredictable,
      // small-scale echo that should decorrelate out of the forecast.
      final rand = math.Random(seed);
      for (var i = 0; i < 300; i++) {
        final x0 = 320 + rand.nextInt(155);
        final y0 = 16 + rand.nextInt(475);
        img.fillRect(image,
            x1: x0, y1: y0, x2: x0 + 2, y2: y0 + 2,
            color: img.ColorRgba8(0, 200, 0, 255));
      }
      return img.encodePng(image);
    }

    final frames4 = [for (var s = 1; s <= 4; s++) speckledFrame(s)];
    final at60 = predictAt(frames4, 60);

    expect(opaqueFraction(at60, 90, 218, 166, 294), greaterThan(0.6),
        reason: 'large predictable echo should survive the hour');

    final latest = img.decodePng(frames4.last)!;
    final speckleBefore = opaqueFraction(latest, 320, 16, 480, 494);
    final speckleAfter = opaqueFraction(at60, 320, 16, 480, 494);
    expect(speckleBefore, greaterThan(0.02),
        reason: 'sanity: the latest frame does contain speckles');
    expect(speckleAfter, lessThan(speckleBefore * 0.3),
        reason: 'unpredictable speckle noise should mostly fade out');
  });

  test('empty frames produce empty predictions without errors', () {
    final empty =
        img.encodePng(img.Image(width: 512, height: 512, numChannels: 4));
    final predicted = extrapolateFrames([empty, empty, empty, empty]);
    final last = img.decodePng(predicted.last)!;
    expect(opaqueFraction(last, 0, 0, 512, 512), 0);
  });
}
