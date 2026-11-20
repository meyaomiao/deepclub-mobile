// Explicit visual capture entrypoint (not part of the platform-independent
// default test glob). Uses the same production widgets as ui_behavior_test.
//
// DSH_TEST_FONT_DIR=... FLUTTER_ROOT=... flutter test --no-pub --update-goldens
//   test/deepclub/ui_capture.dart
// Add --dart-define=DEEPCLUB_FULL_MATRIX=true for all languages/sizes/scales.
import 'dart:io';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_fonts.dart';
import 'ui_fixture.dart';
import 'ui_geometry_test.dart' show uiLayouts;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadTestFonts);
  const full = bool.fromEnvironment('DEEPCLUB_FULL_MATRIX');
  final layouts = full ? uiLayouts : [uiLayouts.first];
  final locales = full ? AppLocale.supported : [AppLocale.zhCN];
  for (final brightness in Brightness.values) {
    for (final locale in locales) {
      for (final layout in layouts) {
        for (final scene in DeepClubUiScene.values) {
          testWidgets('${scene.name} ${brightness.name} ${locale.languageCode} ${layout.name}', (tester) async {
            final fixture = DeepClubUiFixture(scene);
            addTearDown(fixture.close);
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = layout.size;
            tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
            tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
            addTearDown(tester.view.reset);
            await tester.pumpWidget(fixture.app(brightness: brightness, locale: locale, textScale: layout.scale));
            await tester.pump(const Duration(milliseconds: 300));
            if (scene == DeepClubUiScene.completed) {
              fixture.account.emit(fixtureAccount(ready: true));
              await tester.pump();
            }
            // Let only the entry fade finish; a deterministic phase of the
            // actual quiet spinner is captured without pumpAndSettle looping.
            await tester.pump(const Duration(milliseconds: 240));
            expect(tester.takeException(), isNull);
            await expectLater(
              find.byKey(const ValueKey('deepclub-capture')),
              matchesGoldenFile(
                'goldens/${Platform.operatingSystem}/${scene.name}_${brightness.name}_${locale.languageCode}_${layout.name}.png',
              ),
            );
            await tester.pumpWidget(const SizedBox());
          });
        }
      }
    }
  }
}
