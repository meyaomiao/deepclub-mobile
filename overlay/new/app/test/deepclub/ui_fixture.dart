// Real production widgets with synthetic provider inputs. No credentials or
// replacement static screens are rendered. ui_capture.dart uses this fixture;
// callers can pump fixture.app(...) to capture individual states interactively.
import 'dart:async';

import 'package:dsh_app/deepclub/account_state.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/common/side_insets.dart';
import 'package:dsh_app/ui/onboarding/deepclub_gate.dart';
import 'package:dsh_app/ui/settings/deepclub_account_page.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_app/ui_config/ui_skill.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import '../support/test_fonts.dart';
import 'support.dart';

const fixtureVersion = 'synthetic-runtime';
LocalRuntimeState fixtureRuntime(RuntimePhase phase, {bool installed = true, int? percent}) => LocalRuntimeState(
  loaded: true,
  status: RuntimeStatus(
    phase: phase,
    bundledVersion: fixtureVersion,
    installedVersion: installed ? fixtureVersion : null,
    abi: 'arm64-v8a',
  ),
  progress: percent == null ? null : RuntimeProgressEvent(step: 'extract', done: percent, total: 100),
);

const fixtureUser = {'display_name': '星河', 'username': 'sample'};
const fixtureDevices = <Map<String, Object?>>[
  {'id': 42, 'device_name': '此手机', 'is_current': true, 'platform': 'android'},
  {'id': 43, 'device_name': 'Pixel · Test phone', 'platform': 'android', 'app_version': '1.0.0'},
];
DeepClubAccountState fixtureAccount({
  bool ready = false,
  bool busy = false,
  String? error,
  bool emptyBalance = false,
}) => DeepClubAccountState(
  loaded: true,
  signedIn: true,
  engineReady: ready,
  busy: busy,
  error: error,
  user: fixtureUser,
  devices: fixtureDevices,
  bootstrap: {
    'user': {'quota': emptyBalance ? 0 : 1234000},
    'site': {'quota_per_unit': 500000},
    'announcement': {'publish': '2026-11-13', 'content': 'DeepClub 移动端现已支持自动配置模型和工具。'},
  },
);

enum DeepClubUiScene {
  login,
  browser,
  extracting,
  starting,
  syncing,
  completed,
  runtimeFailure,
  syncFailure,
  revoked,
  reauthorize,
  cleanup,
  account,
  accountBusy,
  accountOffline,
  zeroBalance,
}

({DeepClubAccountState account, LocalRuntimeState runtime, bool accountPage}) sceneState(DeepClubUiScene scene) =>
    switch (scene) {
      DeepClubUiScene.login => (
        account: const DeepClubAccountState(loaded: true),
        runtime: fixtureRuntime(RuntimePhase.installing, installed: false, percent: 45),
        accountPage: false,
      ),
      DeepClubUiScene.browser => (
        account: const DeepClubAccountState(loaded: true, awaitingBrowser: true),
        runtime: fixtureRuntime(RuntimePhase.installing, installed: false, percent: 45),
        accountPage: false,
      ),
      DeepClubUiScene.extracting => (
        account: fixtureAccount(),
        runtime: fixtureRuntime(RuntimePhase.installing, installed: false, percent: 45),
        accountPage: false,
      ),
      DeepClubUiScene.starting => (
        account: fixtureAccount(),
        runtime: fixtureRuntime(RuntimePhase.starting),
        accountPage: false,
      ),
      DeepClubUiScene.syncing || DeepClubUiScene.completed => (
        account: fixtureAccount(busy: true),
        runtime: fixtureRuntime(RuntimePhase.running),
        accountPage: false,
      ),
      DeepClubUiScene.runtimeFailure => (
        account: fixtureAccount(),
        runtime: fixtureRuntime(RuntimePhase.error, installed: false),
        accountPage: false,
      ),
      DeepClubUiScene.syncFailure => (
        account: fixtureAccount(error: 'network_unavailable'),
        runtime: fixtureRuntime(RuntimePhase.running),
        accountPage: false,
      ),
      DeepClubUiScene.revoked => (
        account: const DeepClubAccountState(loaded: true, error: 'session_expired'),
        runtime: fixtureRuntime(RuntimePhase.installed),
        accountPage: false,
      ),
      DeepClubUiScene.reauthorize => (
        account: const DeepClubAccountState(loaded: true, error: 'authorization_expired'),
        runtime: fixtureRuntime(RuntimePhase.installed),
        accountPage: false,
      ),
      DeepClubUiScene.cleanup => (
        account: const DeepClubAccountState(loaded: true, cleanupBlocked: true, error: 'cleanup_failed'),
        runtime: fixtureRuntime(RuntimePhase.error),
        accountPage: false,
      ),
      DeepClubUiScene.account => (
        account: fixtureAccount(ready: true),
        runtime: fixtureRuntime(RuntimePhase.running),
        accountPage: true,
      ),
      DeepClubUiScene.accountBusy => (
        account: fixtureAccount(ready: true, busy: true),
        runtime: fixtureRuntime(RuntimePhase.running),
        accountPage: true,
      ),
      DeepClubUiScene.accountOffline => (
        account: fixtureAccount(ready: true, error: 'network_unavailable'),
        runtime: fixtureRuntime(RuntimePhase.running),
        accountPage: true,
      ),
      DeepClubUiScene.zeroBalance => (
        account: fixtureAccount(ready: true, emptyBalance: true),
        runtime: fixtureRuntime(RuntimePhase.running),
        accountPage: true,
      ),
    };

class UiAccountController extends DeepClubAccountController {
  UiAccountController(this.initial, this.rig);
  final DeepClubAccountState initial;
  final ServiceRig rig;
  int browserCalls = 0, syncCalls = 0;
  @override
  DeepClubAccountState build() {
    service = rig.service;
    final subscription = service.changes.listen((next) {
      if (ref.mounted) state = next;
    });
    ref.onDispose(subscription.cancel);
    return initial;
  }

  void emit(DeepClubAccountState next) => state = next;
  @override
  Future<void> browserLogin() async {
    browserCalls++;
    await service.beginBrowserLogin();
  }

  @override
  Future<void> synchronize() {
    syncCalls++;
    return service.synchronize();
  }
}

class UiRuntimeController extends LocalRuntimeController {
  UiRuntimeController(this.initial);
  final LocalRuntimeState initial;
  int installs = 0;
  Future<void> Function()? onInstall;
  @override
  LocalRuntimeState build() => initial;
  void emit(LocalRuntimeState next) => state = next;
  @override
  Future<void> install() async {
    installs++;
    await onInstall?.call();
  }
}

class UiSettingsController extends SettingsController {
  UiSettingsController([this.initial = const AppSettings(loaded: true)]);
  final AppSettings initial;
  @override
  AppSettings build() => initial;
  void emit(AppSettings next) => state = next;
}

class UiHostController extends ActiveHostController {
  UiHostController([this.initial = HostRef.local]);
  final HostRef initial;
  @override
  HostRef build() => initial;
  @override
  Future<void> get ready async {}
  void emit(HostRef next) => state = next;
}

class UiSkillInstaller extends UiSkillAutoInstaller {
  @override
  UiSkillInstallResult? build() => null;
}

class DeepClubUiFixture {
  DeepClubUiFixture(DeepClubUiScene scene) {
    final data = sceneState(scene);
    account = UiAccountController(data.account, rig);
    runtime = UiRuntimeController(data.runtime);
    accountPage = data.accountPage;
  }
  final rig = ServiceRig(connected: false);
  late final UiAccountController account;
  late final UiRuntimeController runtime;
  late final bool accountPage;
  final settings = UiSettingsController();
  final host = UiHostController();
  int retries = 0;

  List<Override> get overrides => [
    deepClubAccountProvider.overrideWith(() => account),
    localRuntimeProvider.overrideWith(() => runtime),
    settingsProvider.overrideWith(() => settings),
    activeHostProvider.overrideWith(() => host),
    uiSkillAutoInstallProvider.overrideWith(UiSkillInstaller.new),
  ];

  Widget app({
    Widget? home,
    Brightness brightness = Brightness.light,
    Locale locale = AppLocale.zhCN,
    double textScale = 1,
    bool reducedMotion = false,
    List<Override> extraOverrides = const [],
  }) {
    final base = brightness == Brightness.dark ? buildDarkTheme() : buildLightTheme();
    return ProviderScope(
      key: ObjectKey(this),
      overrides: [...overrides, ...extraOverrides],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: withTestFonts(base.copyWith(textTheme: base.textTheme.apply(fontFamilyFallback: const [cjkFamily]))),
        locale: locale,
        supportedLocales: AppLocale.supported,
        localizationsDelegates: L10n.localizationsDelegates,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale), disableAnimations: reducedMotion),
          child: MirroredSideInsets(child: child!),
        ),
        home: RepaintBoundary(
          key: const ValueKey('deepclub-capture'),
          child:
              home ??
              (accountPage
                  ? const DeepClubAccountPage()
                  : Consumer(
                      builder: (context, ref, _) => DeepClubGateView(
                        account: ref.watch(deepClubAccountProvider),
                        runtime: ref.watch(localRuntimeProvider),
                        onRetry: () => retries++,
                        home: const HomeShell(),
                      ),
                    )),
        ),
      ),
    );
  }

  Future<void> close() => rig.close();
}
