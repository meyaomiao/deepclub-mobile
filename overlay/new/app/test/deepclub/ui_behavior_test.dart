import 'package:dsh_app/deepclub/account_state.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/onboarding/deepclub_gate.dart';
import 'package:dsh_app/ui/settings/deepclub_account_page.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_fonts.dart';
import 'ui_fixture.dart';

final progress = find.byWidgetPredicate((widget) => widget is ProgressIndicator);
const homeKey = ValueKey('actual-home-handoff');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadTestFonts);
  setUp(() => AppLocale.use(AppLocale.zhCN));

  Future<DeepClubUiFixture> mount(
    WidgetTester tester,
    DeepClubUiScene scene, {
    Widget? home,
    bool reduced = false,
  }) async {
    final fixture = DeepClubUiFixture(scene);
    addTearDown(fixture.close);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(fixture.app(home: home, reducedMotion: reduced));
    return fixture;
  }

  for (final scene in DeepClubUiScene.values) {
    testWidgets('${scene.name}: at most one progress indicator and one retry', (tester) async {
      await mount(tester, scene);
      await tester.pump(const Duration(milliseconds: 300));
      expect(progress.evaluate().length, lessThanOrEqualTo(1));
      expect(find.text(appL10n.deepClubRetry).evaluate().length, lessThanOrEqualTo(1));
      if ({DeepClubUiScene.extracting, DeepClubUiScene.starting, DeepClubUiScene.syncing}.contains(scene)) {
        expect(progress, findsOneWidget);
        expect(find.text(appL10n.deepClubRetry), findsNothing);
        expect(find.text(appL10n.deepClubRemoteSettings), findsNothing);
        expect(find.text(appL10n.deepClubAccount), findsNothing);
      }
      if (scene == DeepClubUiScene.cleanup) {
        expect(find.text(appL10n.deepClubCleanupFailed), findsOneWidget);
        expect(find.text(appL10n.deepClubRuntimeFailed), findsNothing);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('quick preparation never flashes a spinner; shown work stays 500 ms', (tester) async {
    final fixture = DeepClubUiFixture(DeepClubUiScene.syncing);
    addTearDown(fixture.close);
    Widget surface(DeepClubAccountState account) => DeepClubGateView(
      account: account,
      runtime: fixtureRuntime(RuntimePhase.running),
      onRetry: () {},
      home: const SizedBox(key: homeKey),
    );
    await tester.pumpWidget(fixture.app(home: surface(fixtureAccount())));
    await tester.pump(const Duration(milliseconds: 299));
    expect(progress, findsNothing);
    await tester.pumpWidget(fixture.app(home: surface(fixtureAccount(ready: true))));
    expect(find.byKey(homeKey), findsOneWidget);
    expect(progress, findsNothing);

    await tester.pumpWidget(fixture.app(home: surface(fixtureAccount())));
    await tester.pump(const Duration(milliseconds: 300));
    expect(progress, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(fixture.app(home: surface(fixtureAccount(ready: true))));
    expect(find.byKey(homeKey), findsNothing);
    expect(progress, findsNothing);
    expect(find.text(appL10n.deepClubConnected), findsOneWidget);
    expect(find.byKey(const ValueKey('deepclub-steps')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 399));
    expect(find.byKey(homeKey), findsNothing);
    expect(progress, findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byKey(homeKey), findsOneWidget);
    expect(progress, findsNothing);
  });

  testWidgets('restoring settings uses launch branding and respects both timing thresholds', (tester) async {
    final fixture = DeepClubUiFixture(DeepClubUiScene.syncing);
    addTearDown(fixture.close);
    Widget surface(bool restored) => DeepClubGateView(
      account: fixtureAccount(ready: true),
      runtime: fixtureRuntime(RuntimePhase.running),
      restored: restored,
      onRetry: () {},
      home: const SizedBox(key: homeKey),
    );
    await tester.pumpWidget(fixture.app(home: surface(false)));
    expect(find.text('DeepClub'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 299));
    expect(progress, findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    expect(progress, findsOneWidget);
    await tester.pumpWidget(fixture.app(home: surface(true)));
    await tester.pump(const Duration(milliseconds: 499));
    expect(progress, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byKey(homeKey), findsOneWidget);
  });

  testWidgets('account skeleton waits 300 ms and a visible read remains for 500 ms', (tester) async {
    final fixture = DeepClubUiFixture(DeepClubUiScene.account);
    addTearDown(fixture.close);
    await tester.pumpWidget(fixture.app());
    fixture.account.emit(const DeepClubAccountState());
    await tester.pump();
    final skeleton = find.byWidgetPredicate((widget) => widget.runtimeType.toString() == '_AccountSkeleton');
    expect(skeleton, findsNothing);
    await tester.pump(const Duration(milliseconds: 100));
    fixture.account.emit(fixtureAccount(ready: true));
    await tester.pump();
    expect(skeleton, findsNothing);
    expect(find.byType(DeepClubAccountOverview), findsOneWidget);
    fixture.account.emit(const DeepClubAccountState());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 299));
    expect(skeleton, findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    expect(skeleton, findsOneWidget);
    fixture.account.emit(fixtureAccount(ready: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 499));
    expect(skeleton, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
    expect(skeleton, findsNothing);
    expect(find.byType(DeepClubAccountOverview), findsOneWidget);
  });

  testWidgets('reduced motion keeps static stages and percentage semantics', (tester) async {
    final semantics = tester.ensureSemantics();
    final fixture = await mount(tester, DeepClubUiScene.extracting, reduced: true);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.bySemanticsLabel('${appL10n.deepClubPrepareRuntime}，${appL10n.deepClubStepActive}'), findsOneWidget);
    final node = tester.getSemantics(
      find.bySemanticsLabel('${appL10n.deepClubPrepareRuntime}，${appL10n.deepClubStepActive}'),
    );
    expect(node.value, '45%');
    fixture.runtime.emit(fixtureRuntime(RuntimePhase.running));
    await tester.pump();
    expect(progress, findsNothing);
    expect(find.text(appL10n.deepClubSyncModels), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('unknown extraction total uses one quiet ring without a false percentage', (tester) async {
    final fixture = await mount(tester, DeepClubUiScene.extracting);
    fixture.runtime.emit(
      fixture.runtime.initial.copyWith(progress: const RuntimeProgressEvent(step: 'extract', done: 0, total: 0)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('0%'), findsNothing);
  });

  testWidgets('runtime failure offers one actionable retry; account action stays in menu', (tester) async {
    final fixture = await mount(tester, DeepClubUiScene.runtimeFailure);
    await tester.tap(find.text(appL10n.deepClubRetry));
    expect(fixture.retries, 1);
    expect(progress, findsNothing);
    await tester.tap(find.byTooltip(appL10n.deepClubMore));
    await tester.pumpAndSettle();
    expect(find.text(appL10n.deepClubAccount), findsOneWidget);
  });

  testWidgets('refresh leaves account geometry fixed and unrelated web action enabled', (tester) async {
    final fixture = await mount(tester, DeepClubUiScene.account);
    final overview = find.byKey(const ValueKey('deepclub-account-overview'));
    final refresh = find.byKey(const ValueKey('deepclub-account-refresh'));
    final before = tester.getRect(overview);
    final refreshBefore = tester.getRect(refresh);
    fixture.account.emit(fixtureAccount(ready: true, busy: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.getRect(overview), before);
    expect(tester.getRect(refresh), refreshBefore);
    expect(progress, findsOneWidget);
    final web = tester.widget<SettingsTile>(find.widgetWithText(SettingsTile, appL10n.deepClubManageOnWeb));
    expect(web.onTap, isNotNull);
    final busyRefresh = tester.widget<SettingsTile>(refresh);
    expect(busyRefresh.onTap, isNull);
    fixture.account.emit(fixtureAccount(ready: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.getRect(overview), before);
    expect(tester.getRect(refresh), refreshBefore);
    expect(progress, findsNothing);
  });

  testWidgets('actual gate installs once, then starts on state changes without build effects', (tester) async {
    final fixture = DeepClubUiFixture(DeepClubUiScene.login);
    addTearDown(fixture.close);
    const channel = MethodChannel('dsh/runtime');
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    fixture.runtime.onInstall = () async {
      fixture.runtime.emit(fixtureRuntime(RuntimePhase.installing, installed: false, percent: 12));
    };
    await tester.pumpWidget(fixture.app(home: const DeepClubGate()));
    fixture.runtime.emit(fixtureRuntime(RuntimePhase.notInstalled, installed: false));
    await tester.pump();
    expect(fixture.runtime.installs, 1);
    for (var i = 0; i < 4; i++) {
      await tester.pumpWidget(fixture.app(home: const DeepClubGate(), textScale: i.isEven ? 1.0 : 1.3));
    }
    expect(fixture.runtime.installs, 1);
    expect(calls.where((call) => call.method == 'start'), isEmpty);
    fixture.settings.emit(const AppSettings(loaded: true, phoneStorage: true, visualReplies: false));
    fixture.runtime.emit(fixtureRuntime(RuntimePhase.installed));
    fixture.account.emit(fixtureAccount());
    await tester.pump();
    expect(calls.where((call) => call.method == 'start'), hasLength(1));
    final args = calls.singleWhere((call) => call.method == 'start').arguments as Map;
    expect(args['phoneStorage'], isTrue);
    expect(args['visualReplies'], isFalse);
    await tester.pumpWidget(fixture.app(home: const DeepClubGate(), textScale: 1.3));
    expect(calls.where((call) => call.method == 'start'), hasLength(1));
    expect(fixture.account.syncCalls, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('login and parallel install never show two indicators', (tester) async {
    final fixture = await mount(tester, DeepClubUiScene.login);
    fixture.account.emit(const DeepClubAccountState(loaded: true, busy: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(progress, findsOneWidget);
    expect(find.text(appL10n.deepClubInstallingPercent(45)), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('long preparation makes no unsupported background notification promise', (tester) async {
    await mount(tester, DeepClubUiScene.syncing);
    await tester.pump(const Duration(seconds: 61));
    expect(find.text(appL10n.deepClubKeepOpen), findsOneWidget);
    expect(find.textContaining('完成后通知'), findsNothing);
    expect(find.text(appL10n.deepClubRetry), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
