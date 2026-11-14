import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/ui/onboarding/onboarding_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_fonts.dart';
import 'ui_fixture.dart';

const uiLayouts = <({String name, Size size, double scale})>[
  (name: 'phone', size: Size(360, 800), scale: 1),
  (name: 'phone_large', size: Size(360, 800), scale: 1.3),
  (name: 'phone_accessible', size: Size(360, 800), scale: 2),
  (name: 'wide', size: Size(840, 800), scale: 1),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadTestFonts);
  for (final brightness in Brightness.values) {
    for (final locale in AppLocale.supported) {
      for (final layout in uiLayouts) {
        testWidgets('${brightness.name} ${locale.languageCode} ${layout.name}: all real surfaces fit', (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = layout.size;
          tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
          tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
          addTearDown(tester.view.reset);
          for (final scene in DeepClubUiScene.values) {
            final fixture = DeepClubUiFixture(scene);
            await tester.pumpWidget(fixture.app(brightness: brightness, locale: locale, textScale: layout.scale));
            await tester.pump(const Duration(milliseconds: 300));
            if (scene == DeepClubUiScene.completed) {
              fixture.account.emit(fixtureAccount(ready: true));
              await tester.pump();
            }
            expect(tester.takeException(), isNull, reason: scene.name);
            if (!fixture.accountPage) {
              final frame = tester.widget<OnboardingScaffold>(find.byType(OnboardingScaffold));
              expect(frame.contentWidth, 520);
              final step = find.byKey(const ValueKey('deepclub-steps'));
              if (step.evaluate().isNotEmpty) {
                final rect = tester.getRect(step);
                expect(rect.width, lessThanOrEqualTo(520));
                expect(rect.center.dx, closeTo(layout.size.width / 2, 0.01));
                expect(rect.left, greaterThanOrEqualTo(16));
                expect(layout.size.width - rect.right, closeTo(rect.left, 0.01));
              }
            }
            await tester.pumpWidget(const SizedBox());
            await fixture.close();
          }
        });
      }
    }
  }

  testWidgets('stage transitions keep row centers, spacing and card edges fixed', (tester) async {
    final fixture = DeepClubUiFixture(DeepClubUiScene.extracting);
    addTearDown(fixture.close);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(fixture.app());
    await tester.pump(const Duration(milliseconds: 300));
    List<Rect> rects() => [for (var i = 0; i < 4; i++) tester.getRect(find.byKey(ValueKey('deepclub-step-$i')))];
    final before = rects();
    final card = tester.getRect(find.byKey(const ValueKey('deepclub-steps')));
    for (var i = 1; i < before.length; i++) {
      expect(before[i].height, closeTo(before[0].height, 0.001));
      expect(before[i].left, closeTo(before[0].left, 0.001));
      expect(before[i].right, closeTo(before[0].right, 0.001));
      if (i > 1) expect(before[i].top - before[i - 1].bottom, closeTo(before[1].top - before[0].bottom, 0.001));
    }
    for (final phase in [RuntimePhase.starting, RuntimePhase.running]) {
      fixture.runtime.emit(fixtureRuntime(phase));
      await tester.pump();
      final after = [...rects(), tester.getRect(find.byKey(const ValueKey('deepclub-steps')))];
      final expected = [...before, card];
      for (var i = 0; i < expected.length; i++) {
        expect(after[i].left, closeTo(expected[i].left, 0.001));
        expect(after[i].top, closeTo(expected[i].top, 0.001));
        expect(after[i].width, closeTo(expected[i].width, 0.001));
        expect(after[i].height, closeTo(expected[i].height, 0.001));
      }
    }
  });

  testWidgets('keyboard keeps password submission reachable at large text', (tester) async {
    final fixture = DeepClubUiFixture(DeepClubUiScene.login);
    addTearDown(fixture.close);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(fixture.app(locale: AppLocale.en, textScale: 1.3));
    await tester.ensureVisible(find.text(lookupL10n(AppLocale.en).deepClubPasswordLogin));
    await tester.tap(find.text(lookupL10n(AppLocale.en).deepClubPasswordLogin));
    await tester.pump();
    final submit = find.text(lookupL10n(AppLocale.en).deepClubLogin);
    await tester.ensureVisible(submit);
    expect(tester.getRect(submit).bottom, lessThanOrEqualTo(500));
    expect(tester.takeException(), isNull);
  });
}
