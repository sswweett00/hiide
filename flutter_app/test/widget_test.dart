// Basic widget test for the Hiide Flutter app.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hiide_flutter/core/backend/mock_backend_service.dart';
import 'package:hiide_flutter/main.dart';

void main() {
  testWidgets('HiideApp loads', (WidgetTester tester) async {
    final backendService = MockBackendService();

    await tester.pumpWidget(
      ProviderScope(
        child: HiideApp(backendService: backendService),
      ),
    );
    // Let the router build its initial frame.
    await tester.pump();

    // Splash screen shows the app name.
    expect(find.text('Hiide'), findsOneWidget);

    backendService.dispose();
  });
}
