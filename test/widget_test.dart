import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:skycast/main.dart';

void main() {
  testWidgets('App renders home screen with default place',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const SkycastApp());
    await tester.pump();

    // Default place shown in the app bar; network is unavailable in tests,
    // so the body ends up in loading or error state — either is fine here.
    expect(find.text('New York'), findsOneWidget);
  });
}
