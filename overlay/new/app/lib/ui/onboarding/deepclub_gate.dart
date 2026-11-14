import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../deepclub/account_page.dart';
import '../../deepclub/account_state.dart';
import '../../deepclub/client_api.dart';
import '../../launch/launch_state.dart';
import '../../l10n/l10n.dart';
import '../../runtime/runtime_bridge.dart';
import '../../runtime/runtime_state.dart';
import '../../state/hosts_state.dart';
import '../../state/settings_state.dart';
import '../../ui_config/ui_skill.dart';
import '../common/app_sheet.dart';
import '../features/feature_kit.dart';
import '../settings/deepclub_account_page.dart';
import '../shell/brand_mark.dart';
import '../shell/home_shell.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'deepclub_loading.dart';
import 'onboarding_scaffold.dart';

/// Runtime extraction and account login proceed together. Only state listeners
/// request work; rebuilding the view never installs, starts, or synchronizes.
class DeepClubGate extends ConsumerStatefulWidget {
  const DeepClubGate({super.key});
  @override
  ConsumerState<DeepClubGate> createState() => _DeepClubGateState();
}

class _DeepClubGateState extends ConsumerState<DeepClubGate> with WidgetsBindingObserver {
  bool _installAttempted = false, _startAttempted = false, _preparing = false;
  bool _runtimeFailed = false, _hostReady = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ref.listenManual(localRuntimeProvider, (_, _) => _changed());
    ref.listenManual(settingsProvider, (_, _) => _changed());
    ref.listenManual(activeHostProvider, (_, _) => _changed());
    ref.listenManual(deepClubAccountProvider, (before, after) {
      if (before?.signedIn == true && !after.signedIn) _startAttempted = false;
      _changed();
    });
    ref.listenManual(uiSkillAutoInstallProvider, (_, _) {});
    unawaited(
      ref.read(activeHostProvider.notifier).ready.then((_) {
        if (!mounted) return;
        setState(() => _hostReady = true);
        _changed();
      }),
    );
  }

  void _changed() {
    if (!mounted) return;
    if (_hostReady && ref.read(settingsProvider).loaded && ref.read(deepClubAccountProvider).loaded) {
      LaunchController.active.value?.ready(waitsForEngine: false);
    }
    unawaited(_prepare());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(ref.read(deepClubAccountProvider.notifier).synchronize().catchError((Object _) {}));
    }
  }

  Future<void> _startLocal() {
    final settings = ref.read(settingsProvider);
    final origin = deepClubServiceOrigin;
    return ref
        .read(runtimeBridgeProvider)
        .start(
          env: origin == deepClubOrigin ? const {} : {'DEEPCLUB_TEST_ORIGIN': origin},
          phoneStorage: settings.phoneStorage,
          visualReplies: settings.visualReplies,
        );
  }

  Future<void> _prepare({bool retry = false}) async {
    if (_preparing ||
        !mounted ||
        !_hostReady ||
        !ref.read(settingsProvider).loaded ||
        !ref.read(activeHostProvider).isLocal ||
        (_runtimeFailed && !retry)) {
      return;
    }
    _preparing = true;
    try {
      // Re-read after each awaited command: native status may have arrived while
      // this command was in flight. The attempt flags prevent duplicate work.
      while (mounted && ref.read(activeHostProvider).isLocal) {
        final account = ref.read(deepClubAccountProvider);
        final runtime = ref.read(localRuntimeProvider);
        if (!runtime.loaded || !account.loaded || account.cleanupBlocked) break;
        final status = runtime.status;
        final outdated = status.installedVersion != status.bundledVersion || status.installedVersion == null;
        if (!_installAttempted &&
            (status.phase == RuntimePhase.notInstalled ||
                (status.phase == RuntimePhase.installed && outdated) ||
                (retry && status.phase == RuntimePhase.error && outdated))) {
          _installAttempted = true;
          retry = false;
          await ref.read(localRuntimeProvider.notifier).install();
        } else if (!_startAttempted &&
            account.signedIn &&
            !account.busy &&
            (status.phase == RuntimePhase.installed || (retry && status.phase == RuntimePhase.error && !outdated))) {
          _startAttempted = true;
          retry = false;
          await _startLocal();
        } else {
          break;
        }
      }
    } catch (_) {
      if (mounted) setState(() => _runtimeFailed = true);
    } finally {
      _preparing = false;
    }
  }

  Future<void> _retry() async {
    final account = ref.read(deepClubAccountProvider);
    if (account.busy || _preparing) return;
    if (account.cleanupBlocked) {
      try {
        await ref.read(deepClubAccountProvider.notifier).service.retryCleanup();
      } catch (_) {
        /* Public state carries the safe error. */
      }
    } else if (_runtimeFailed || ref.read(localRuntimeProvider).status.phase == RuntimePhase.error) {
      setState(() {
        _runtimeFailed = false;
        _installAttempted = false;
        _startAttempted = false;
      });
      await _prepare(retry: true);
    } else {
      try {
        await ref.read(deepClubAccountProvider.notifier).synchronize();
      } catch (_) {
        /* Public state carries the safe error. */
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(deepClubAccountProvider);
    final runtime = ref.watch(localRuntimeProvider);
    final settings = ref.watch(settingsProvider);
    final host = ref.watch(activeHostProvider);
    if (_hostReady && settings.loaded && !host.isLocal) return const HomeShell();
    return DeepClubGateView(
      account: account,
      runtime: runtime,
      restored: _hostReady && settings.loaded && account.loaded && runtime.loaded,
      runtimeFailed: _runtimeFailed,
      onRetry: _retry,
      home: const HomeShell(),
    );
  }
}

/// The actual first-run surface, also used by deterministic component captures.
/// Its inputs contain public state only; the login panel uses the real account
/// provider and actions. [home] is shown once preparation has actually finished.
class DeepClubGateView extends StatelessWidget {
  const DeepClubGateView({
    super.key,
    required this.account,
    required this.runtime,
    required this.onRetry,
    required this.home,
    this.restored = true,
    this.runtimeFailed = false,
  });

  final DeepClubAccountState account;
  final LocalRuntimeState runtime;
  final VoidCallback onRetry;
  final Widget home;
  final bool restored, runtimeFailed;

  @override
  Widget build(BuildContext context) => DeepClubLoading(
    active: !restored,
    builder: (context, reading) => !restored || reading
        ? OnboardingScaffold(
            contentWidth: 520,
            contentPadding: const EdgeInsets.fromLTRB(AppSpace.gutter, 0, AppSpace.gutter, AppSpace.xl),
            showRuntime: false,
            children: [
              const Spacer(flex: 4),
              const Center(child: BrandMark(size: 48)),
              const SizedBox(height: AppSpace.xxl),
              Text(
                context.l10n.deepClubAppName,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: AppSpace.xxl),
              SizedBox(
                height: 64,
                child: reading
                    ? AppMotion.reduced(context)
                          ? Center(child: Text(context.l10n.deepClubRestoring))
                          : QuietSpinner(label: context.l10n.deepClubRestoring, padding: EdgeInsets.zero)
                    : null,
              ),
              const Spacer(flex: 5),
            ],
          )
        : _accountView(context),
  );

  Widget _accountView(BuildContext context) {
    final ready = account.signedIn && account.engineReady && !account.cleanupBlocked;
    final failed = runtimeFailed || runtime.status.phase == RuntimePhase.error || account.error != null;
    return DeepClubLoading(
      active: account.signedIn && !ready && !failed,
      builder: (context, visible) {
        if (restored && ready && !visible) return home;
        final l10n = context.l10n;
        return OnboardingScaffold(
          contentWidth: 520,
          contentPadding: const EdgeInsets.fromLTRB(AppSpace.gutter, 0, AppSpace.gutter, AppSpace.xl),
          showRuntime: false,
          trailing: restored && account.signedIn
              ? PopupMenuButton<String>(
                  tooltip: l10n.deepClubMore,
                  icon: const Icon(AppIcons.more),
                  constraints: const BoxConstraints(minWidth: 48),
                  onSelected: (_) =>
                      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DeepClubAccountPage())),
                  itemBuilder: (_) => [PopupMenuItem(value: 'account', child: Text(l10n.deepClubAccount))],
                )
              : null,
          children: [
            const Spacer(flex: 4),
            const Center(child: BrandMark(size: 48)),
            const SizedBox(height: AppSpace.xxl),
            if (!account.signedIn) ...[
              SheetGroup(
                margin: EdgeInsets.zero,
                children: [
                  const Padding(padding: EdgeInsets.all(AppSpace.lg), child: DeepClubLoginPanel()),
                  if (!account.cleanupBlocked)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(AppSpace.lg, 0, AppSpace.lg, AppSpace.lg),
                      child: Column(
                        children: [
                          Text(
                            runtimeFailed || runtime.status.phase == RuntimePhase.error
                                ? l10n.deepClubRuntimeFailed
                                : runtime.status.phase == RuntimePhase.installing
                                ? (runtime.progress?.total ?? 0) <= 0
                                      ? l10n.deepClubInstalling
                                      : l10n.deepClubInstallingPercent(_percent(runtime.progress!.fraction))
                                : l10n.deepClubLocalRuntime,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: DshColors.of(context).textTertiary),
                            textAlign: TextAlign.center,
                          ),
                          if ((runtimeFailed || runtime.status.phase == RuntimePhase.error) && !account.cleanupBlocked)
                            TextButton(onPressed: account.busy ? null : onRetry, child: Text(l10n.deepClubRetry)),
                        ],
                      ),
                    ),
                ],
              ),
            ] else ...[
              Semantics(
                header: true,
                liveRegion: ready,
                child: AnimatedSwitcher(
                  duration: AppMotion.of(context, AppMotion.standard),
                  layoutBuilder: (current, _) => current ?? const SizedBox.shrink(),
                  child: Text(
                    ready ? l10n.deepClubConnected : l10n.deepClubPreparing,
                    key: ValueKey(ready),
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
              ),
              const SizedBox(height: AppSpace.sm),
              Text(
                l10n.deepClubPreparationDescription,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: AppSpace.xxl),
              DeepClubPreparationSteps(
                account: account,
                runtime: runtime,
                runtimeFailed: runtimeFailed,
                showProgress: visible,
                onRetry: onRetry,
              ),
              const SizedBox(height: AppSpace.lg),
              Visibility(
                visible: !ready,
                maintainSize: true,
                maintainState: true,
                maintainAnimation: true,
                child: Text(
                  l10n.deepClubKeepOpen,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
                ),
              ),
            ],
            const Spacer(flex: 5),
          ],
        );
      },
    );
  }
}

int _percent(double fraction) => (fraction.clamp(0.0, 1.0) * 100).round();

enum _StepState { waiting, active, complete, failed }

class DeepClubPreparationSteps extends StatelessWidget {
  const DeepClubPreparationSteps({
    super.key,
    required this.account,
    required this.runtime,
    required this.showProgress,
    required this.onRetry,
    this.runtimeFailed = false,
  });

  final DeepClubAccountState account;
  final LocalRuntimeState runtime;
  final bool showProgress, runtimeFailed;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final status = runtime.status;
    final installed =
        status.installedVersion != null &&
        status.installedVersion == status.bundledVersion &&
        status.phase != RuntimePhase.installing;
    final running = status.phase == RuntimePhase.running;
    final failedRuntime = runtimeFailed || status.phase == RuntimePhase.error;
    final failedIndex = account.cleanupBlocked
        ? 0
        : failedRuntime
        ? (installed ? 2 : 1)
        : account.error != null
        ? 3
        : null;
    final current = !installed
        ? 1
        : !running
        ? 2
        : 3;
    final labels = [
      l10n.deepClubSignedIn,
      l10n.deepClubPrepareRuntime,
      l10n.deepClubStartEngine,
      l10n.deepClubSyncModels,
    ];
    final completed = [account.signedIn && !account.cleanupBlocked, installed, running, account.engineReady];
    final error = failedRuntime ? l10n.deepClubRuntimeFailed : deepClubErrorText(l10n, account.error);
    return SheetGroup(
      key: const ValueKey('deepclub-steps'),
      margin: EdgeInsets.zero,
      children: [
        for (var i = 0; i < labels.length; i++)
          _PreparationRow(
            key: ValueKey('deepclub-step-$i'),
            label: labels[i],
            state: failedIndex == i
                ? _StepState.failed
                : completed[i]
                ? _StepState.complete
                : failedIndex == null && current == i
                ? _StepState.active
                : _StepState.waiting,
            showProgress: showProgress,
            fraction: i == 1 && status.phase == RuntimePhase.installing && (runtime.progress?.total ?? 0) > 0
                ? runtime.progress!.fraction
                : null,
            error: failedIndex == i ? error : null,
            onRetry: account.busy ? null : onRetry,
          ),
      ],
    );
  }
}

class _PreparationRow extends StatelessWidget {
  const _PreparationRow({
    super.key,
    required this.label,
    required this.state,
    required this.showProgress,
    this.fraction,
    this.error,
    this.onRetry,
  });

  final String label;
  final _StepState state;
  final bool showProgress;
  final double? fraction;
  final String? error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    final theme = Theme.of(context);
    final active = state == _StepState.active;
    final value = fraction == null ? null : _percent(fraction!);
    final status = switch (state) {
      _StepState.waiting => l10n.deepClubStepWaiting,
      _StepState.active => l10n.deepClubStepActive,
      _StepState.complete => l10n.deepClubStepComplete,
      _StepState.failed => l10n.deepClubStepFailed,
    };
    final color = state == _StepState.failed
        ? theme.colorScheme.error
        : active
        ? theme.colorScheme.onSurface
        : colors.textTertiary;
    return Semantics(
      container: true,
      liveRegion: state == _StepState.complete || state == _StepState.failed,
      label: '$label，$status',
      value: active && value != null ? '$value%' : null,
      // Stage completion is announced once; percentage ticks do not repeatedly
      // interrupt the screen reader. The value remains available on focus.
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg, vertical: AppSpace.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ExcludeSemantics(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 52),
                child: Row(
                  children: [
                    SizedBox.square(
                      dimension: AppSpace.xl,
                      child: active && showProgress && value == null && !AppMotion.reduced(context)
                          ? const QuietSpinner(padding: EdgeInsets.zero)
                          : Icon(
                              switch (state) {
                                _StepState.complete => AppIcons.done,
                                _StepState.failed => AppIcons.error,
                                _StepState.active => AppIcons.inProgress,
                                _StepState.waiting => AppIcons.pending,
                              },
                              size: AppSpace.xl,
                              color: color,
                            ),
                    ),
                    const SizedBox(width: AppSpace.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AnimatedDefaultTextStyle(
                            duration: AppMotion.of(context, AppMotion.standard),
                            style: theme.textTheme.bodyLarge!.copyWith(color: color),
                            child: Text(label),
                          ),
                          if (active && value == null && AppMotion.reduced(context))
                            Text(status, style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary)),
                        ],
                      ),
                    ),
                    if (active && value != null) ...[
                      const SizedBox(width: AppSpace.md),
                      Text('$value%', style: AppType.tabular(theme.textTheme.bodyMedium!.copyWith(color: color))),
                    ],
                  ],
                ),
              ),
            ),
            // Every row keeps the same progress slot; changing stages never
            // moves the labels or the message below the card.
            SizedBox(
              height: AppSpace.xs,
              child: active && showProgress && value != null
                  ? Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 320),
                        child: LinearProgressIndicator(
                          value: fraction!.clamp(0.0, 1.0),
                          minHeight: AppSpace.xs,
                          borderRadius: const BorderRadius.all(Radius.circular(AppSpace.xs)),
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    )
                  : null,
            ),
            if (error != null) ...[
              const SizedBox(height: AppSpace.sm),
              Text(error!, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error)),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(AppIcons.retry),
                  label: Text(l10n.deepClubRetry),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
