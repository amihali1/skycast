import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skycast/widgets/drizzle_icon.dart';

void main() {
  setUpAll(() async {
    // Golden tests render text with a placeholder font unless the real
    // icon font is loaded explicitly.
    final path =
        '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/'
        'material_fonts/materialicons-regular.otf';
    final bytes = File(path).readAsBytesSync();
    final loader = FontLoader('MaterialIcons')
      ..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  });

  testWidgets('drizzle icon golden', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: const Color(0xFF1C2733),
          body: Center(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              spacing: 32,
              children: const [
                DrizzleIcon(size: 128, color: Colors.white),
                Icon(Icons.water_drop, size: 128, color: Colors.white),
                DrizzleIcon(size: 24, color: Colors.white),
                Icon(Icons.water_drop, size: 24, color: Colors.white),
              ],
            ),
          ),
        ),
      ),
    );
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/drizzle_icon.png'),
    );
  });
}
