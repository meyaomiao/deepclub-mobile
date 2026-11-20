import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'client_api.dart';

abstract interface class DeepClubStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Android Keystore-backed storage. Session, engine key and PKCE verifier never
/// enter SharedPreferences, route arguments, diagnostics or an authorization URL.
class SecureDeepClubStore implements DeepClubStore {
  const SecureDeepClubStore();
  static const _storage = FlutterSecureStorage();
  static String _key(String key) => 'deepclub.$key';
  @override
  Future<String?> read(String key) => _storage.read(key: _key(key));
  @override
  Future<void> write(String key, String value) => _storage.write(key: _key(key), value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: _key(key));
}

String secureUrlToken() {
  final random = Random.secure();
  return base64UrlEncode(List<int>.generate(32, (_) => random.nextInt(256))).replaceAll('=', '');
}

/// A backend-valid installation identity, distinct from session bindings.
String secureDeviceId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

String pkceChallenge(String verifier) =>
    base64UrlEncode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', '');

class PendingAuthorization {
  const PendingAuthorization({
    required this.state,
    required this.verifier,
    required this.createdAt,
    this.remoteOnly = false,
    this.upgradeBinding,
    this.deviceId,
  });
  factory PendingAuthorization.create({bool remoteOnly = false, String? upgradeBinding, String? deviceId}) =>
      PendingAuthorization(
        state: secureUrlToken(),
        verifier: secureUrlToken(),
        createdAt: DateTime.now().toUtc(),
        remoteOnly: remoteOnly,
        upgradeBinding: upgradeBinding,
        deviceId: deviceId,
      );
  factory PendingAuthorization.decode(String value) {
    final data = jsonObject(jsonDecode(value));
    return PendingAuthorization(
      state: requiredText(data, 'state'),
      verifier: requiredText(data, 'verifier'),
      createdAt: DateTime.parse(requiredText(data, 'created_at')),
      remoteOnly: data['remote_only'] == true,
      upgradeBinding: data['upgrade_binding'] as String?,
      deviceId: data['device_id'] as String?,
    );
  }
  final bool remoteOnly;
  final String? upgradeBinding, deviceId;
  bool get isUpgrade => upgradeBinding != null;
  String get clientId => isUpgrade
      ? 'deepclub-android-agent-upgrade-v1'
      : remoteOnly
      ? 'deepclub-android-remote'
      : deepClubClientId;
  final String state;
  final String verifier;
  final DateTime createdAt;
  String encode() => jsonEncode({
    'state': state,
    'verifier': verifier,
    'created_at': createdAt.toIso8601String(),
    'remote_only': remoteOnly,
    if (isUpgrade) 'upgrade_binding': upgradeBinding,
    if (isUpgrade) 'device_id': deviceId,
  });

  Uri authorizeUri(Map<String, String> device) => Uri.parse('$deepClubServiceOrigin/client/authorize').replace(
    queryParameters: {
      'client_id': clientId,
      'redirect_uri': deepClubRedirect,
      'code_challenge_method': 'S256',
      'code_challenge': pkceChallenge(verifier),
      'state': state,
      ...device,
    },
  );

  /// Match all callback components and reject duplicated parameters/fragments.
  /// Only an authorization code is accepted; tokens in URLs are never imported.
  String codeFrom(Uri uri, {DateTime? now}) {
    if (!isDeepClubCallback(uri) || uri.hasFragment || uri.queryParametersAll.values.any((v) => v.length != 1)) {
      throw const DeepClubFailure('invalid_callback');
    }
    if (uri.queryParameters.keys.any((k) => !const {'code', 'state', 'error', 'error_description'}.contains(k))) {
      throw const DeepClubFailure('invalid_callback');
    }
    if (!_equal(uri.queryParameters['state'] ?? '', state)) throw const DeepClubFailure('invalid_state');
    final age = (now ?? DateTime.now()).difference(createdAt);
    // Upgrade intent has 5 minutes to consent, followed by a fresh 5-minute
    // code window. The token endpoint enforces each authoritative deadline.
    if (age.isNegative || age > const Duration(minutes: 10)) {
      throw const DeepClubFailure('authorization_expired');
    }
    if (uri.queryParameters.containsKey('error')) throw const DeepClubFailure('authorization_denied');
    final code = uri.queryParameters['code'];
    if (code == null || code.isEmpty || code.length > 512) throw const DeepClubFailure('invalid_callback');
    return code;
  }

  static bool _equal(String a, String b) {
    var difference = a.length ^ b.length;
    for (var i = 0; i < b.length; i++) {
      difference |= (i < a.length ? a.codeUnitAt(i) : 0) ^ b.codeUnitAt(i);
    }
    return difference == 0;
  }
}

bool isDeepClubCallback(Uri uri) =>
    uri.scheme == 'deepclub' && uri.host == 'auth' && uri.path == '/callback' && uri.userInfo.isEmpty && !uri.hasPort;
