import '../l10n/l10n.dart';

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
