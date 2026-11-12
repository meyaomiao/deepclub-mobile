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

String pkceChallenge(String verifier) =>
    base64UrlEncode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', '');

class PendingAuthorization {
  const PendingAuthorization({required this.state, required this.verifier, required this.createdAt});
  factory PendingAuthorization.create() =>
      PendingAuthorization(state: secureUrlToken(), verifier: secureUrlToken(), createdAt: DateTime.now().toUtc());
  factory PendingAuthorization.decode(String value) {
    final data = jsonObject(jsonDecode(value));
    return PendingAuthorization(
      state: requiredText(data, 'state'),
      verifier: requiredText(data, 'verifier'),
      createdAt: DateTime.parse(requiredText(data, 'created_at')),
    );
  }
  final String state;
  final String verifier;
  final DateTime createdAt;
  String encode() => jsonEncode({'state': state, 'verifier': verifier, 'created_at': createdAt.toIso8601String()});

  Uri authorizeUri(Map<String, String> device) => Uri.parse('$deepClubServiceOrigin/client/authorize').replace(
    queryParameters: {
      'client_id': deepClubClientId,
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
    if (age.isNegative || age > const Duration(minutes: 10)) throw const DeepClubFailure('authorization_expired');
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
