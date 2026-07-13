import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:skycast/services/nowcast.dart';

/// Renders a 512x512 transparent frame with an opaque 60px square at [x].
Uint8List frameWithBlobAt(int x) {
  final image = img.Image(width: 512, height: 512, numChannels: 4);
  img.fillRect(image,
      x1: x,
      y1: 200,
      x2: x + 60,
      y2: 260,
      color: img.ColorRgba8(0, 200, 0, 255));
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

void main() {
  test('extrapolation moves an eastward-drifting echo further east', () {
    // Blob moves +20px per 15-minute step: x=100 (t-30), 120 (t-15), 140 (now).
    final frames = [
      frameWithBlobAt(100),
      frameWithBlobAt(120),
      frameWithBlobAt(140),
    ];

    final predicted = extrapolateFrames(frames);
    expect(predicted.length, NowcastService.leadsMinutes.length);

    // +30 min = two more steps => expected near x=180.
    final index = NowcastService.leadsMinutes.indexOf(30);
    final at30 = img.decodePng(predicted[index])!;

    // Blob core present at the predicted location...
    expect(opaqueFraction(at30, 190, 215, 220, 245), greaterThan(0.5),
        reason: 'echo should have advected ~40px east of its last position');
    // ...and no longer at the original t-30 position.
    expect(opaqueFraction(at30, 100, 215, 130, 245), lessThan(0.2),
        reason: 'echo should have left its old position');
  });

  test('empty frames produce empty predictions without errors', () {
    final empty = img.encodePng(img.Image(width: 512, height: 512, numChannels: 4));
    final predicted = extrapolateFrames([empty, empty, empty]);
    final last = img.decodePng(predicted.last)!;
    expect(opaqueFraction(last, 0, 0, 512, 512), 0);
  });
}
