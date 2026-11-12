import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../deepclub/account_page.dart';
import '../../deepclub/account_state.dart';
import '../../deepclub/client_api.dart';
import '../../l10n/l10n.dart';
import '../../runtime/runtime_bridge.dart';
import '../../runtime/runtime_state.dart';
import '../../state/hosts_state.dart';
import '../../state/settings_state.dart';
import '../../ui_config/ui_skill.dart';
import '../remote/remote_screen.dart';
import '../shell/home_shell.dart';
import '../theme/theme.dart';

/// First launch defaults to this phone. Runtime extraction and account login
/// proceed together; no manual API-key or provider-choice step is required.
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
    unawaited(
      ref.read(activeHostProvider.notifier).ready.then((_) {
        if (mounted) setState(() => _hostReady = true);
      }),
    );
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

  Future<void> _prepare() async {
    if (_preparing || !mounted || !_hostReady || !ref.read(activeHostProvider).isLocal) return;
    final account = ref.read(deepClubAccountProvider);
    final runtime = ref.read(localRuntimeProvider);
    if (!runtime.loaded || !account.loaded || account.cleanupBlocked || account.busy) return;
    if (!account.signedIn) _startAttempted = false;
    _preparing = true;
    var requested = false;
    try {
      final status = runtime.status;
      if (!_installAttempted &&
          (status.phase == RuntimePhase.notInstalled ||
              (status.installedVersion != status.bundledVersion && status.phase == RuntimePhase.installed))) {
        _installAttempted = true;
        requested = true;
        await ref.read(localRuntimeProvider.notifier).install();
      } else if (!_startAttempted && account.signedIn && status.phase == RuntimePhase.installed) {
        _startAttempted = true;
        requested = true;
        await _startLocal();
      }
    } catch (_) {
      if (mounted) setState(() => _runtimeFailed = true);
    } finally {
      _preparing = false;
      if (requested && mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final account = ref.watch(deepClubAccountProvider);
    final runtime = ref.watch(localRuntimeProvider);
    final settings = ref.watch(settingsProvider);
    final host = ref.watch(activeHostProvider);
    ref.listen(uiSkillAutoInstallProvider, (_, _) {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_prepare());
    });
    if (!_hostReady || !settings.loaded) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    // A remote host keeps its own account and settings. DeepClub credentials
    // still synchronize only through localConnectionProvider.
    if (!host.isLocal || (account.signedIn && account.engineReady && !account.cleanupBlocked)) return const HomeShell();
    final failed = _runtimeFailed || runtime.status.phase == RuntimePhase.error;
    return Scaffold(
      body: AppBackdrop(
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: ListView(
                padding: const EdgeInsets.all(24),
                shrinkWrap: true,
                children: [
                  const SizedBox(height: 24),
                  if (!account.loaded)
                    const LinearProgressIndicator()
                  else if (!account.signedIn)
                    const DeepClubLoginPanel()
                  else ...[
                    Text(l10n.deepClubPreparing, style: Theme.of(context).textTheme.headlineSmall),
                    const SizedBox(height: 16),
                    if (!failed) const LinearProgressIndicator(),
                    if (account.error != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Text(deepClubErrorText(l10n, account.error)),
                      ),
                    OutlinedButton(
                      onPressed: account.busy
                          ? null
                          : () async {
                              try {
                                await ref.read(deepClubAccountProvider.notifier).synchronize();
                              } catch (_) {}
                            },
                      child: Text(l10n.deepClubRetry),
                    ),
                    TextButton(
                      onPressed: () =>
                          Navigator.of(context)
                              .push(MaterialPageRoute<void>(builder: (_) => const DeepClubAccountPage())),
                      child: Text(l10n.deepClubAccount),
                    ),
                  ],
                  const SizedBox(height: 24),
                  Text(
                    failed
                        ? l10n.deepClubRuntimeFailed
                        : runtime.status.phase == RuntimePhase.installing
                        ? l10n.deepClubInstalling
                        : l10n.deepClubLocalRuntime,
                  ),
                  if (runtime.status.phase == RuntimePhase.installing) ...[
                    const SizedBox(height: 12),
                    LinearProgressIndicator(value: runtime.progress?.fraction),
                  ],
                  if (failed)
                    OutlinedButton(
                      onPressed: account.cleanupBlocked || account.busy
                          ? null
                          : () async {
                              setState(() {
                                _runtimeFailed = false;
                                _installAttempted = false;
                                _startAttempted = false;
                              });
                              try {
                                final status = ref.read(localRuntimeProvider).status;
                                if (status.installedVersion == status.bundledVersion &&
                                    status.installedVersion != null) {
                                  await _startLocal();
                                } else {
                                  await ref.read(localRuntimeProvider.notifier).install();
                                }
                              } catch (_) {
                                if (mounted) setState(() => _runtimeFailed = true);
                              }
                            },
                      child: Text(l10n.deepClubRetry),
                    ),
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: () =>
                        Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const RemoteScreen())),
                    child: Text(l10n.deepClubRemoteSettings),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
