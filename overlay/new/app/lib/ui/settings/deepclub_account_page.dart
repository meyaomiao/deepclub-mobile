import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../deepclub/account_page.dart';
import '../../deepclub/account_state.dart';
import '../../deepclub/client_api.dart';
import '../../l10n/l10n.dart';
import '../common/app_sheet.dart';
import '../common/overview_card.dart';
import '../common/status_chip.dart';
import '../onboarding/deepclub_loading.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'settings_widgets.dart';

String _balance(Map<String, Object?>? bootstrap) {
  final user = bootstrap?['user'];
  final site = bootstrap?['site'];
  final quota = user is Map ? user['quota'] : null;
  final unit = site is Map ? site['quota_per_unit'] : null;
  if (quota is! num || unit is! num || unit <= 0) return '—';
  return (quota / unit).toStringAsFixed(4);
}

/// Shared overview for the settings hub and account details. It reflects the
/// phone's account only; it does not write remote host settings or model choices.
class DeepClubAccountOverview extends ConsumerWidget {
  const DeepClubAccountOverview({super.key, this.openDetails = true});
  final bool openDetails;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(deepClubAccountProvider);
    final l10n = context.l10n;
    final name = '${account.user['display_name'] ?? account.user['username'] ?? ''}'.trim();
    return OverviewCard(
      key: const ValueKey('deepclub-account-overview'),
      margin: const EdgeInsets.fromLTRB(AppSpace.gutter, 0, AppSpace.gutter, AppSpace.xxl),
      leading: Icon(
        account.signedIn ? AppIcons.profile : AppIcons.lock,
        size: AppSpace.xxxl,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      title: Text(account.signedIn && name.isNotEmpty ? name : l10n.deepClubAccount),
      subtitle: Text(
        account.signedIn ? l10n.deepClubBalance(_balance(account.bootstrap)) : l10n.deepClubSignInToContinue,
      ),
      footer: OverviewFooter(
        tone: account.engineReady
            ? StatusTone.ok
            : account.error != null
            ? StatusTone.error
            : StatusTone.idle,
        text: account.engineReady
            ? l10n.deepClubConnected
            : account.signedIn
            ? l10n.deepClubPreparing
            : l10n.deepClubLocalRuntime,
      ),
      onTap: openDetails
          ? () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DeepClubAccountPage()))
          : null,
    );
  }
}

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
        /* The account state displays the safe failure. */
      }
    }

    Future<bool> confirm(String title, String message) async =>
        await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: Text(l10n.deepClubCancel)),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(title)),
            ],
          ),
        ) ==
        true;

    return DeepClubLoading(
      active: !account.loaded,
      builder: (context, reading) => AppPage.list(
        title: l10n.deepClubAccount,
        children: [
          if (!account.loaded || reading)
            reading ? const _AccountSkeleton() : const SizedBox(height: _AccountSkeleton.height)
          else if (!account.signedIn)
            const SheetGroup(
              margin: EdgeInsets.fromLTRB(AppSpace.gutter, 0, AppSpace.gutter, AppSpace.xxl),
              children: [Padding(padding: EdgeInsets.all(AppSpace.lg), child: DeepClubLoginPanel())],
            )
          else ...[
            const DeepClubAccountOverview(openDetails: false),
            SheetGroup(
              margin: const EdgeInsets.fromLTRB(AppSpace.gutter, 0, AppSpace.gutter, AppSpace.xxl),
              children: [
                SettingsTile(
                  icon: AppIcons.localOnly,
                  tinted: false,
                  title: l10n.deepClubThisDevice,
                  subtitle: l10n.deepClubLocalCredentialsOnly,
                ),
                if (account.error != null)
                  SettingsTile(
                    key: const ValueKey('deepclub-account-error'),
                    icon: AppIcons.error,
                    tinted: false,
                    title: l10n.deepClubNeedsAttention,
                    subtitle: deepClubErrorText(l10n, account.error),
                  ),
                DeepClubLoading(
                  active: account.busy,
                  builder: (context, visible) => SettingsTile(
                    key: const ValueKey('deepclub-account-refresh'),
                    title: l10n.deepClubRefresh,
                    icon: AppIcons.refresh,
                    tinted: false,
                    chevron: false,
                    trailing: SizedBox.square(
                      dimension: AppSpace.xl,
                      child: visible ? const DeepClubBusyIcon(visible: true, idle: AppIcons.refresh) : null,
                    ),
                    onTap: account.busy ? null : () => run(service.synchronize),
                  ),
                ),
                SettingsTile(
                  icon: AppIcons.openExternal,
                  tinted: false,
                  title: l10n.deepClubManageOnWeb,
                  onTap: () =>
                      launchUrl(Uri.parse('$deepClubServiceOrigin/profile'), mode: LaunchMode.externalApplication),
                ),
              ],
            ),
            if (account.announcement case final announcement?)
              SheetGroup(
                title: l10n.deepClubAnnouncement,
                margin: const EdgeInsets.fromLTRB(AppSpace.gutter, 0, AppSpace.gutter, AppSpace.xxl),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(AppSpace.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (announcement.publish case final publish?) ...[
                          Text(
                            publish,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: DshColors.of(context).textTertiary),
                          ),
                          const SizedBox(height: AppSpace.sm),
                        ],
                        Text(announcement.content),
                      ],
                    ),
                  ),
                ],
              ),
            SheetGroup(
              title: l10n.deepClubDevices,
              margin: const EdgeInsets.fromLTRB(AppSpace.gutter, 0, AppSpace.gutter, AppSpace.xxl),
              children: [
                if (account.devices.isEmpty)
                  SettingsTile(icon: AppIcons.thisPhone, tinted: false, title: l10n.deepClubNoDevices),
                for (final device in account.devices)
                  SettingsTile(
                    icon: AppIcons.thisPhone,
                    tinted: false,
                    title: '${device['device_name'] ?? device['platform'] ?? ''}',
                    subtitle: device['is_current'] == true
                        ? l10n.deepClubThisDevice
                        : '${device['platform'] ?? ''} · ${device['app_version'] ?? ''}',
                    trailing: IconButton(
                      icon: const Icon(AppIcons.logout),
                      tooltip: l10n.deepClubRevokeDevice,
                      onPressed: account.busy || device['id'] is! int
                          ? null
                          : () async {
                              if (await confirm(l10n.deepClubRevokeDevice, l10n.deepClubRevokeConfirm)) {
                                await run(() => service.revokeDevice(device['id'] as int));
                              }
                            },
                    ),
                  ),
              ],
            ),
            SheetGroup(
              margin: const EdgeInsets.fromLTRB(AppSpace.gutter, 0, AppSpace.gutter, AppSpace.xxl),
              children: [
                SettingsTile(
                  icon: AppIcons.logout,
                  title: l10n.deepClubLogout,
                  danger: true,
                  tinted: false,
                  chevron: false,
                  onTap: account.busy
                      ? null
                      : () async {
                          if (!await confirm(l10n.deepClubLogout, l10n.deepClubLogoutConfirm)) return;
                          try {
                            await service.logout();
                          } catch (_) {
                            if (!context.mounted || !service.state.signedIn) return;
                            if (await confirm(l10n.deepClubLocalLogout, l10n.deepClubLocalLogoutConfirm)) {
                              await run(() => service.logout(localOnly: true));
                            }
                          }
                        },
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _AccountSkeleton extends StatelessWidget {
  const _AccountSkeleton();
  static const height = 3 * 64 + AppSpace.xs + AppSpace.sm + AppSpace.xxl;
  @override
  Widget build(BuildContext context) => SheetGroup(
    margin: const EdgeInsets.fromLTRB(AppSpace.gutter, 0, AppSpace.gutter, AppSpace.xxl),
    children: [
      for (var i = 0; i < 3; i++)
        SizedBox(
          height: 64,
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.lg),
            child: Row(
              children: [
                Container(
                  width: AppSpace.xxxl,
                  height: AppSpace.xxxl,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: AppSpace.md),
                Expanded(
                  child: Container(
                    height: AppSpace.lg,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      borderRadius: const BorderRadius.all(Radius.circular(AppSpace.xs)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
    ],
  );
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
    return DeepClubLoading(
      active: account.busy,
      builder: (context, visible) => AutofillGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.deepClubLoginTitle, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: AppSpace.md),
            Text(l10n.deepClubLoginDescription),
            const SizedBox(height: AppSpace.xxl),
            if (account.serverNotRevoked)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpace.lg),
                child: Text(l10n.deepClubServerNotRevoked),
              ),
            if (account.cleanupBlocked) ...[
              Text(l10n.deepClubCleanupFailed),
              FilledButton.icon(
                onPressed: account.busy ? null : () => _run(service.retryCleanup),
                icon: DeepClubBusyIcon(visible: visible, idle: AppIcons.retry, button: true),
                label: Text(l10n.deepClubRetry),
              ),
            ] else ...[
              FilledButton.icon(
                onPressed: account.busy ? null : () => _run(controller.browserLogin),
                icon: DeepClubBusyIcon(
                  visible: visible && !_passwordMode && !account.require2fa,
                  idle: AppIcons.browser,
                  button: true,
                ),
                label: Text(account.awaitingBrowser ? l10n.deepClubRestartBrowserLogin : l10n.deepClubBrowserLogin),
              ),
              if (account.awaitingBrowser) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpace.md),
                  child: Text(l10n.deepClubWaitingBrowser),
                ),
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
                  const SizedBox(height: AppSpace.md),
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
                const SizedBox(height: AppSpace.lg),
                FilledButton.tonalIcon(
                  icon: DeepClubBusyIcon(visible: visible, idle: AppIcons.lock, button: true),
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
                  label: Text(account.require2fa ? l10n.deepClubVerify : l10n.deepClubLogin),
                ),
              ],
            ],
            if (error != null && !account.cleanupBlocked)
              Padding(
                padding: const EdgeInsets.only(top: AppSpace.lg),
                child: Text(
                  deepClubErrorText(l10n, error),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: AppSpace.lg),
            TextButton(
              onPressed: () =>
                  launchUrl(Uri.parse('$deepClubServiceOrigin/profile'), mode: LaunchMode.externalApplication),
              child: Text(l10n.deepClubManageOnWeb),
            ),
          ],
        ),
      ),
    );
  }
}
