import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/l10n.dart';
import 'account_state.dart';
import 'client_api.dart';

String deepClubErrorText(L10n l10n, String? code) => switch (code) {
  'network_unavailable' => l10n.deepClubNetworkError,
  'invalid_state' || 'invalid_callback' => l10n.deepClubInvalidCallback,
  'authorization_expired' || 'invalid_grant' => l10n.deepClubAuthorizationExpired,
  'authorization_denied' => l10n.deepClubAuthorizationDenied,
  'browser_unavailable' => l10n.deepClubBrowserUnavailable,
  'cleanup_failed' => l10n.deepClubCleanupFailed,
  'session_expired' ||
  'login_required' ||
  'client_relay_token_invalid' ||
  'client_relay_ip_forbidden' ||
  'client_relay_group_unavailable' => l10n.deepClubSessionExpired,
  'E_DEVICE_LIMIT' => l10n.deepClubDeviceLimit,
  'invalid_config' || 'engine_config_unavailable' => l10n.deepClubConfigError,
  _ => l10n.deepClubRequestFailed,
};

class DeepClubAccountPage extends ConsumerWidget {
  const DeepClubAccountPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final account = ref.watch(deepClubAccountProvider);
    final service = ref.read(deepClubAccountProvider.notifier).service;
    Future<void> run(Future<void> Function() action) async {
      try {
        await action();
      } catch (_) {
        /* The account state displays the failure. */
      }
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.deepClubAccount)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            if (!account.loaded || account.busy) const LinearProgressIndicator(),
            if (!account.signedIn)
              const DeepClubLoginPanel()
            else ...[
              Text(
                '${account.user['display_name'] ?? account.user['username'] ?? ''}',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 16),
              if (account.bootstrap case final bootstrap?) Text(l10n.deepClubBalance(_balance(bootstrap))),
              const SizedBox(height: 8),
              Text(account.engineReady ? l10n.deepClubConnected : l10n.deepClubPreparing),
              Text(l10n.deepClubLocalCredentialsOnly, style: Theme.of(context).textTheme.bodySmall),
              if (account.error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(deepClubErrorText(l10n, account.error)),
                ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: account.busy ? null : () => run(service.synchronize),
                icon: const Icon(Icons.refresh),
                label: Text(l10n.deepClubRefresh),
              ),
              if (account.announcement case final announcement?) ...[
                const SizedBox(height: 24),
                Text(l10n.deepClubAnnouncement, style: Theme.of(context).textTheme.titleLarge),
                if (announcement.publish case final publish?) ...[
                  const SizedBox(height: 4),
                  Text(publish, style: Theme.of(context).textTheme.bodySmall),
                ],
                const SizedBox(height: 8),
                Text(announcement.content),
              ],
              const SizedBox(height: 24),
              Text(l10n.deepClubDevices, style: Theme.of(context).textTheme.titleLarge),
              for (final device in account.devices)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('${device['device_name'] ?? device['platform'] ?? ''}'),
                  subtitle: Text(
                    device['is_current'] == true
                        ? l10n.deepClubThisDevice
                        : '${device['platform'] ?? ''} · ${device['app_version'] ?? ''}',
                  ),
                  trailing: TextButton(
                    onPressed: account.busy
                        ? null
                        : () async {
                            final confirmed = await showDialog<bool>(
                              context: context,
                              builder: (c) => AlertDialog(
                                title: Text(l10n.deepClubRevokeDevice),
                                content: Text(l10n.deepClubRevokeConfirm),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(c, false),
                                    child: Text(l10n.deepClubCancel),
                                  ),
                                  FilledButton(
                                    onPressed: () => Navigator.pop(c, true),
                                    child: Text(l10n.deepClubRevokeDevice),
                                  ),
                                ],
                              ),
                            );
                            if (confirmed == true && device['id'] is int) {
                              await run(() => service.revokeDevice(device['id'] as int));
                            }
                          },
                    child: Text(l10n.deepClubRevokeDevice),
                  ),
                ),
              const SizedBox(height: 24),
              FilledButton.tonal(
                onPressed: account.busy
                    ? null
                    : () async {
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (c) => AlertDialog(
                            title: Text(l10n.deepClubLogout),
                            content: Text(l10n.deepClubLogoutConfirm),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(c, false), child: Text(l10n.deepClubCancel)),
                              FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(l10n.deepClubLogout)),
                            ],
                          ),
                        );
                        if (confirmed != true) return;
                        try {
                          await service.logout();
                        } catch (_) {
                          if (!context.mounted || !service.state.signedIn) return;
                          final local = await showDialog<bool>(
                            context: context,
                            builder: (c) => AlertDialog(
                              title: Text(l10n.deepClubLocalLogout),
                              content: Text(l10n.deepClubLocalLogoutConfirm),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(c, false), child: Text(l10n.deepClubCancel)),
                                FilledButton(
                                  onPressed: () => Navigator.pop(c, true),
                                  child: Text(l10n.deepClubLocalLogout),
                                ),
                              ],
                            ),
                          );
                          if (local == true) await run(() => service.logout(localOnly: true));
                        }
                      },
                child: Text(l10n.deepClubLogout),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _balance(Map<String, Object?> bootstrap) {
    final user = bootstrap['user'];
    final site = bootstrap['site'];
    final quota = user is Map ? user['quota'] : null;
    final unit = site is Map ? site['quota_per_unit'] : null;
    if (quota is! num || unit is! num || unit <= 0) return '—';
    return (quota / unit).toStringAsFixed(4);
  }
}

/// Shared by the first launch and the account page. Password and 2FA fields live
/// only in widget memory and are cleared on successful submission/disposal.
class DeepClubLoginPanel extends ConsumerStatefulWidget {
  const DeepClubLoginPanel({super.key});
  @override
  ConsumerState<DeepClubLoginPanel> createState() => _DeepClubLoginPanelState();
}

class _DeepClubLoginPanelState extends ConsumerState<DeepClubLoginPanel> {
  final _username = TextEditingController(), _password = TextEditingController(), _code = TextEditingController();
  bool _passwordMode = false;
  String? _error;
  List<Map<String, Object?>> _limitedDevices = const [];
  final _revokeIds = <int>{};
  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _error = null);
    try {
      await action();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error is DeepClubFailure ? error.code : 'operation_failed';
        if (error is DeepClubFailure && error.code == 'E_DEVICE_LIMIT' && error.data is Map) {
          final devices = (error.data as Map)['active_devices'];
          if (devices is List) _limitedDevices = [for (final d in devices) jsonObject(d)];
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final account = ref.watch(deepClubAccountProvider);
    final controller = ref.read(deepClubAccountProvider.notifier);
    final service = controller.service;
    final error = _error ?? account.error;
    return AutofillGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.deepClubLoginTitle, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 12),
          Text(l10n.deepClubLoginDescription),
          const SizedBox(height: 24),
          if (account.serverNotRevoked)
            Padding(padding: const EdgeInsets.only(bottom: 16), child: Text(l10n.deepClubServerNotRevoked)),
          if (account.cleanupBlocked) ...[
            Text(l10n.deepClubCleanupFailed),
            FilledButton(
              onPressed: account.busy ? null : () => _run(service.retryCleanup),
              child: Text(l10n.deepClubRetry),
            ),
          ] else ...[
            FilledButton.icon(
              onPressed: account.busy ? null : () => _run(controller.browserLogin),
              icon: const Icon(Icons.open_in_browser),
              label: Text(account.awaitingBrowser ? l10n.deepClubRestartBrowserLogin : l10n.deepClubBrowserLogin),
            ),
            if (account.awaitingBrowser) ...[
              Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(l10n.deepClubWaitingBrowser)),
              TextButton(
                onPressed: account.busy ? null : () => _run(service.cancelBrowserLogin),
                child: Text(l10n.deepClubCancel),
              ),
            ],
            TextButton(
              onPressed: account.busy ? null : () => setState(() => _passwordMode = !_passwordMode),
              child: Text(l10n.deepClubPasswordLogin),
            ),
            if (_passwordMode || account.require2fa) ...[
              if (!account.require2fa) ...[
                TextField(
                  controller: _username,
                  enabled: !account.busy,
                  autofillHints: const [AutofillHints.username],
                  decoration: InputDecoration(labelText: l10n.deepClubUsername),
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  enabled: !account.busy,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  autofillHints: const [AutofillHints.password],
                  decoration: InputDecoration(labelText: l10n.deepClubPassword),
                ),
              ] else
                TextField(
                  controller: _code,
                  enabled: !account.busy,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(labelText: l10n.deepClubTwoFactorCode),
                ),
              for (final device in _limitedDevices)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('${device['device_name'] ?? device['platform'] ?? ''}'),
                  value: _revokeIds.contains(device['id']),
                  onChanged: account.busy
                      ? null
                      : (checked) {
                          final id = device['id'];
                          if (id is int) {
                            setState(() {
                              if (checked == true) {
                                _revokeIds.add(id);
                              } else {
                                _revokeIds.remove(id);
                              }
                            });
                          }
                        },
                ),
              if (account.require2fa)
                TextButton(
                  onPressed: account.busy ? null : () => _run(service.cancelBrowserLogin),
                  child: Text(l10n.deepClubCancel),
                ),
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: account.busy
                    ? null
                    : () => _run(() async {
                        if (account.require2fa) {
                          await service.verify2fa(_code.text.trim(), revokeSessionIds: _revokeIds.toList());
                          _code.clear();
                        } else {
                          await service.loginWithPassword(
                            _username.text.trim(),
                            _password.text,
                            revokeSessionIds: _revokeIds.toList(),
                          );
                          _password.clear();
                        }
                      }),
                child: Text(account.require2fa ? l10n.deepClubVerify : l10n.deepClubLogin),
              ),
            ],
          ],
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(deepClubErrorText(l10n, error), style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: () =>
                launchUrl(Uri.parse('$deepClubServiceOrigin/profile'), mode: LaunchMode.externalApplication),
            child: Text(l10n.deepClubManageOnWeb),
          ),
        ],
      ),
    );
  }
}
