import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../deepclub/account_state.dart';
import '../../l10n/l10n.dart';
import '../../state/gateway_state.dart';
import '../../state/hosts_state.dart';
import '../common/app_sheet.dart';
import '../onboarding/deepclub_loading.dart';
import '../onboarding/local_install.dart';
import '../settings/deepclub_account_page.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../workspace/workspaces_page.dart';
import 'pairing_page.dart' show pairingScannerProvider;

Future<void> openGatewayPairing(BuildContext context) =>
    Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const GatewayPairingPage()));

String gatewayPairError(L10n l10n, String? code) => switch (code) {
  'invalid_pairing' => l10n.deepClubGatewayInvalid,
  'pairing_expired' || 'remote_assertion_expired' => l10n.deepClubGatewayExpired,
  'version_incompatible' || 'PROTOCOL_MISMATCH' => l10n.deepClubGatewayIncompatible,
  'host_key_mismatch' || 'PEER_IDENTITY_MISMATCH' => l10n.deepClubGatewayHostChanged,
  'rate_limited' => l10n.deepClubRateLimited,
  'remote_identity_denied' ||
  'remote_account_mismatch' ||
  'remote_gateway_account_mismatch' ||
  'DEVICE_REVOKED' => l10n.deepClubGatewayWrongAccount,
  'login_required' || 'session_expired' => l10n.deepClubSignInToContinue,
  _ => l10n.deepClubGatewayPairFailed,
};

/// The same scanner serves camera and photo input. The pasted/linked secret is
/// consumed directly and is never rendered, saved in routes, or sent to logs.
class GatewayPairingPage extends ConsumerStatefulWidget {
  const GatewayPairingPage({super.key, this.initial = false});
  final bool initial;
  @override
  ConsumerState<GatewayPairingPage> createState() => _GatewayPairingPageState();
}

class _GatewayPairingPageState extends ConsumerState<GatewayPairingPage> {
  int _scannerEpoch = 0;
  bool _finished = false, _finishing = false;
  Stopwatch? _attemptClock;
  late final GatewayPairController _controller;
  @override
  void initState() {
    super.initState();
    _controller = ref.read(gatewayPairProvider.notifier)..attach();
    ref.listenManual(gatewayPairProvider.select((s) => s.hasLink), (_, hasLink) {
      if (hasLink) unawaited(_pending());
    });
    scheduleMicrotask(() {
      if (!mounted) return;
      _controller.reset();
      unawaited(_pending());
    });
  }

  @override
  void dispose() {
    _controller.detach();
    // Cancel an unfinished attempt before disposing the camera/page.
    if (!_finished) _controller.cancel();
    super.dispose();
  }

  Future<void> _pending() async {
    if (!mounted || !ref.read(deepClubAccountProvider).signedIn) return;
    if (ref.read(gatewayPairProvider).hasLink) _attemptClock = Stopwatch()..start();
    final host = await _controller.pending();
    if (host != null && mounted) await _finish(host);
  }

  Future<void> _pair(String input) async {
    if (ref.read(gatewayPairProvider).busy) return;
    _attemptClock = Stopwatch()..start();
    final host = await _controller.pair(input);
    if (host != null && mounted) await _finish(host);
  }

  Future<void> _finish(GatewayHost host) async {
    if (_finished || _finishing) return;
    _finishing = true;
    final elapsed = _attemptClock?.elapsedMilliseconds ?? 0;
    // Match the shared 300 ms delay / 500 ms minimum presentation contract.
    if (elapsed >= 300 && elapsed < 800) await Future<void>.delayed(Duration(milliseconds: 800 - elapsed));
    if (!mounted ||
        !ref.read(deepClubAccountProvider).signedIn ||
        ref.read(deepClubAccountProvider).binding != host.binding) {
      _finishing = false;
      return;
    }
    _finished = true;
    final navigator = Navigator.of(context);
    ref.read(activeHostProvider.notifier).select(HostRef.gateway(host.id, name: host.name));
    // The initial scanner is the gate's body; keep the gate below projects so
    // signing out still returns to the account flow.
    final route = MaterialPageRoute<void>(builder: (_) => const WorkspacesPage());
    if (widget.initial) {
      unawaited(navigator.push(route));
    } else {
      unawaited(navigator.pushReplacement(route));
    }
  }

  Future<void> _paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
    if (!mounted) return;
    if (text.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(context.l10n.remotePairPasteEmpty)));
      return;
    }
    await _pair(text);
  }

  void _restart() {
    _controller.reset();
    setState(() => _scannerEpoch++);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final account = ref.watch(deepClubAccountProvider);
    final flow = ref.watch(gatewayPairProvider);
    ref.listen(deepClubAccountProvider.select((s) => s.signedIn), (_, signedIn) {
      if (signedIn) unawaited(_pending());
    });
    return AppPage.list(
      title: l10n.deepClubScanComputer,
      subtitle: Text(l10n.deepClubScanDescription),
      actions: [
        GlassIconButton(
          icon: AppIcons.profile,
          tooltip: l10n.deepClubAccount,
          onPressed: () =>
              Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DeepClubAccountPage())),
        ),
      ],
      children: [
        Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(AppSpace.gutter, AppSpace.sm, AppSpace.gutter, AppSpace.xxl),
              child: !account.signedIn
                  ? const SheetGroup(
                      margin: EdgeInsets.zero,
                      children: [Padding(padding: EdgeInsets.all(AppSpace.lg), child: DeepClubLoginPanel())],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        AspectRatio(
                          aspectRatio: 1,
                          child: ClipRSuperellipse(
                            borderRadius: AppShape.radiusLg,
                            child: flow.busy || flow.host != null
                                ? ColoredBox(
                                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                    child: DeepClubLoading(
                                      active: flow.busy,
                                      builder: (context, visible) => Padding(
                                        padding: const EdgeInsets.all(AppSpace.lg),
                                        child: Column(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            SizedBox.square(
                                              dimension: AppSpace.xl,
                                              child: flow.host != null
                                                  ? const Icon(AppIcons.done)
                                                  : DeepClubBusyIcon(visible: visible, idle: AppIcons.computer),
                                            ),
                                            const SizedBox(height: AppSpace.lg),
                                            Text(
                                              flow.host == null
                                                  ? l10n.deepClubGatewayPairing
                                                  : l10n.deepClubGatewayPairSuccess,
                                              textAlign: TextAlign.center,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  )
                                : KeyedSubtree(
                                    key: ValueKey(_scannerEpoch),
                                    child: ref.watch(pairingScannerProvider)(context, (code) => unawaited(_pair(code))),
                                  ),
                          ),
                        ),
                        const SizedBox(height: AppSpace.lg),
                        Text(
                          l10n.deepClubGatewayScanHint,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: AppSpace.sm),
                        TextButton.icon(
                          onPressed: flow.busy ? null : () => unawaited(_paste()),
                          icon: const Icon(AppIcons.paste),
                          label: Text(l10n.remotePairPasteLink),
                        ),
                        if (flow.error != null) ...[
                          const SizedBox(height: AppSpace.lg),
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              gatewayPairError(l10n, flow.error),
                              style: TextStyle(color: Theme.of(context).colorScheme.error),
                            ),
                          ),
                          const SizedBox(height: AppSpace.sm),
                          FilledButton(onPressed: _restart, child: Text(l10n.deepClubScanAgain)),
                        ],
                        if (widget.initial) ...[
                          const SizedBox(height: AppSpace.lg),
                          Text(
                            l10n.deepClubLocalNotInstalled,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: DshColors.of(context).textTertiary),
                          ),
                          TextButton(
                            onPressed: () => openLocalInstall(context),
                            child: Text(l10n.deepClubInstallLocal),
                          ),
                        ],
                      ],
                    ),
            ),
          ),
        ),
      ],
    );
  }
}
