import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/deepclub/account_state.dart';
import 'package:dsh_app/ui/onboarding/local_install.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/state/gateway_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/onboarding/deepclub_gate.dart';
import 'package:dsh_app/ui/remote/gateway_pairing_page.dart';
import 'package:dsh_app/ui/remote/pairing_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_fonts.dart';
import 'ui_fixture.dart';

class _UiPairController extends GatewayPairController {
  _UiPairController(this.initial);
  final GatewayPairState initial;
  @override
  GatewayPairState build() => initial;
  @override
  void reset() {}
  @override
  Future<GatewayHost?> pending() async => null;
  void emit(GatewayPairState value) => state = value;
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLocale.use(AppLocale.zhCN);
  });
  final progress = find.byWidgetPredicate((w) => w is ProgressIndicator);
  void phone(WidgetTester tester) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.reset);
  }

  testWidgets('remote-only choice prevents extraction before and throughout sign-in', (tester) async {
    phone(tester);
    final fixture = DeepClubUiFixture(DeepClubUiScene.login);
    addTearDown(fixture.close);
    await fixture.rig.service.restore();
    await tester.pumpWidget(
      fixture.app(
        home: const DeepClubGate(),
        extraOverrides: [
          secretStoreProvider.overrideWithValue(MemorySecretStore()),
          pairingScannerProvider.overrideWithValue((context, onCode) => const ColoredBox(color: Colors.black)),
        ],
      ),
    );
    await tester.pump();
    fixture.runtime.emit(fixtureRuntime(RuntimePhase.notInstalled, installed: false));
    await tester.pump();
    expect(fixture.runtime.installs, 0, reason: 'nothing extracts before the user can choose remote-only');
    await tester.tap(find.byKey(const ValueKey('deepclub-remote-only')));
    await tester.pump();
    expect(fixture.account.service.state.remoteOnly, isTrue);
    expect(find.text(appL10n.deepClubLocalRuntime), findsNothing);
    await fixture.rig.login();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.byType(GatewayPairingPage), findsOneWidget);
    expect(find.text(appL10n.deepClubLocalNotInstalled), findsOneWidget);
    expect(fixture.runtime.installs, 0);
    expect(fixture.rig.nativeClears, 0);
    expect(fixture.rig.engine.calls, isEmpty);
    expect(
      fixture.rig.requests.where((r) => r.url.path.endsWith('/provision') || r.url.path.endsWith('/agent-config')),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('default browser authorization starts one parallel runtime preparation', (tester) async {
    phone(tester);
    final fixture = DeepClubUiFixture(DeepClubUiScene.login);
    addTearDown(fixture.close);
    await fixture.rig.service.restore();
    await tester.pumpWidget(
      fixture.app(
        home: const DeepClubGate(),
        extraOverrides: [secretStoreProvider.overrideWithValue(MemorySecretStore())],
      ),
    );
    await tester.pump();
    fixture.runtime.emit(fixtureRuntime(RuntimePhase.notInstalled, installed: false));
    fixture.runtime.onInstall = () async =>
        fixture.runtime.emit(fixtureRuntime(RuntimePhase.installing, installed: false, percent: 45));
    await tester.pump();
    expect(fixture.runtime.installs, 0);
    await tester.tap(find.text(appL10n.deepClubBrowserLogin));
    await tester.pump();
    await tester.pump();
    expect(fixture.account.service.state.awaitingBrowser, isTrue);
    expect(fixture.runtime.installs, 1);
    expect(progress.evaluate().length, lessThanOrEqualTo(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('browser waiting authorization button grows around 2x English text', (tester) async {
    phone(tester);
    AppLocale.use(AppLocale.en);
    final fixture = DeepClubUiFixture(
      DeepClubUiScene.account,
      accountState: const DeepClubAccountState(loaded: true, signedIn: true, remoteOnly: true, awaitingBrowser: true),
    );
    addTearDown(fixture.close);
    await tester.pumpWidget(fixture.app(home: const LocalInstallPage(), locale: AppLocale.en, textScale: 2));
    await tester.pump(const Duration(milliseconds: 300));
    final label = find.text(appL10n.deepClubUseLocal);
    final button = find.ancestor(of: label, matching: find.byType(FilledButton));
    await tester.ensureVisible(button);
    await tester.pump();
    final bounds = tester.getRect(button), text = tester.getRect(label);
    expect(bounds.contains(text.topLeft), isTrue);
    expect(bounds.contains(text.bottomRight), isTrue);
    expect(progress, findsOneWidget);
    expect(fixture.runtime.installs, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final locale in [AppLocale.zhCN, AppLocale.en]) {
    for (final brightness in Brightness.values) {
      for (final width in [360.0, 840.0]) {
        testWidgets('pairing states fit $locale $brightness ${width.toInt()}dp at 1.3x', (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 800);
          addTearDown(tester.view.reset);
          AppLocale.use(locale);
          final fixture = DeepClubUiFixture(DeepClubUiScene.account);
          addTearDown(fixture.close);
          final flow = _UiPairController(const GatewayPairState(busy: true));
          await tester.pumpWidget(
            fixture.app(
              home: const GatewayPairingPage(),
              locale: locale,
              brightness: brightness,
              textScale: 1.3,
              extraOverrides: [
                gatewayPairProvider.overrideWith(() => flow),
                pairingScannerProvider.overrideWithValue(
                  (context, onCode) => const Center(child: Text('Camera preview')),
                ),
              ],
            ),
          );
          expect(progress, findsNothing);
          await tester.pump(const Duration(milliseconds: 299));
          expect(progress, findsNothing);
          await tester.pump(const Duration(milliseconds: 1));
          expect(progress, findsOneWidget);
          expect(find.text(appL10n.deepClubRetry), findsNothing);
          final pairingBox = tester.getRect(find.byType(AspectRatio).first);
          expect(pairingBox.width, lessThanOrEqualTo(488));
          expect((pairingBox.center.dx - width / 2).abs(), lessThan(1));
          flow.emit(const GatewayPairState(error: 'pairing_expired'));
          await tester.pump();
          expect(progress, findsNothing);
          expect(find.text(appL10n.deepClubGatewayExpired), findsOneWidget);
          expect(find.text(appL10n.deepClubScanAgain), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        });
      }
    }
  }
}
