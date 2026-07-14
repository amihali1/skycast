@Tags(['live'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:skycast/services/nowcast.dart';

/// Hits the real IEM WMS. Run explicitly with:
///   flutter test --tags live test/nowcast_live_test.dart
void main() {
  test('nowcast pipeline produces frames from live IEM data', () async {
    final service = NowcastService();
    // Kansas City — central US, decent odds of echoes somewhere in the
    // 700 km box; the pipeline must succeed either way.
    final result = await service.computeNowcast(39.1, -94.58);

    expect(result.frames.length, NowcastService.leadsMinutes.length);
    expect(result.north, greaterThan(result.south));
    expect(result.east, greaterThan(result.west));

    var totalOpaque = 0;
    for (final frame in result.frames) {
      final image = img.decodePng(frame.png);
      expect(image, isNotNull, reason: 'predicted frame must be valid PNG');
      expect(image!.width, 512);
      for (var y = 0; y < 512; y += 4) {
        for (var x = 0; x < 512; x += 4) {
          if (image.getPixel(x, y).a > 128) totalOpaque++;
        }
      }
    }
    // Diagnostic, not an assertion — dry radar is legitimate.
    // ignore: avoid_print
    print('opaque sample pixels across predicted frames: $totalOpaque');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
