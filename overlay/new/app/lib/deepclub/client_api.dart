import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:http/http.dart' as http;

const deepClubOrigin = 'https://deepclub.net';
const _testOrigin = String.fromEnvironment('DEEPCLUB_TEST_ORIGIN');

/// Only a debug build can target the emulator's synthetic fixture server.
/// Profile/release builds ignore this define and always use the production site.
String get deepClubServiceOrigin => resolveDeepClubOrigin(debug: kDebugMode, testOrigin: _testOrigin);

String resolveDeepClubOrigin({required bool debug, required String testOrigin}) {
  if (!debug || testOrigin.isEmpty) return deepClubOrigin;
  final uri = Uri.tryParse(testOrigin);
  if (uri == null ||
      uri.scheme != 'http' ||
      !const {'10.0.2.2', '127.0.0.1'}.contains(uri.host) ||
      !uri.hasPort ||
      uri.port < 1 ||
      uri.port > 65535 ||
      uri.userInfo.isNotEmpty ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const DeepClubFailure('invalid_test_origin');
  }
  return uri.origin;
}

bool isDeepClubServiceBase(Uri uri) {
  final origin = Uri.parse(deepClubServiceOrigin);
  return uri.scheme == origin.scheme &&
      uri.host == origin.host &&
      uri.port == origin.port &&
      uri.userInfo.isEmpty &&
      !uri.hasQuery &&
      !uri.hasFragment;
}

const deepClubClientId = 'deepclub-agent';
const deepClubRedirect = 'deepclub://auth/callback';
const deepClubKeyRef = 'DEEPCLUB_API_KEY';

/// Deliberately omits response bodies, URLs and headers from diagnostic text.
class DeepClubFailure implements Exception {
  const DeepClubFailure(this.code, {this.status, this.data});
  final String code;
  final int? status;
  final Object? data;
  bool get invalidSession => status == 401 || status == 403;
  @override
  String toString() => 'DeepClubFailure($code)';
}

class ClientReply {
  const ClientReply(this.data, this.expiresAt);
  final Object? data;
  final DateTime? expiresAt;
  Map<String, Object?> get object => jsonObject(data);
}

Map<String, Object?> jsonObject(Object? value) {
  if (value is! Map<String, dynamic>) throw const DeepClubFailure('invalid_response');
  return Map<String, Object?>.from(value);
}

String requiredText(Map<String, Object?> data, String name) {
  final value = data[name];
  if (value is! String || value.isEmpty) throw const DeepClubFailure('invalid_response');
  return value;
}

/// Device session Bearer is used only on this fixed API origin. Redirects are
/// refused, including same-origin redirects, so a server redirect cannot forward
/// a session or a password to another endpoint.
class DeepClubApi {
  DeepClubApi({http.Client? client, this.requestTimeout = const Duration(seconds: 30)})
    : _client = client ?? http.Client();
  final http.Client _client;
  final Duration requestTimeout;

  Future<ClientReply> call(String method, String path, {String? session, Map<String, Object?>? body}) async {
    if (!path.startsWith('/api/client/') || path.contains('?') || path.contains('#')) {
      throw const DeepClubFailure('invalid_endpoint');
    }
    final abort = Completer<void>();
    final request = http.AbortableRequest(method, Uri.parse('$deepClubServiceOrigin$path'), abortTrigger: abort.future)
      ..followRedirects = false
      ..headers['Accept'] = 'application/json';
    if (session != null) request.headers['Authorization'] = 'Bearer $session';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    try {
      final response = await _client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(
            requestTimeout,
            onTimeout: () {
              abort.complete();
              throw TimeoutException('DeepClub request deadline');
            },
          );
      Map<String, Object?> payload;
      try {
        payload = jsonObject(jsonDecode(response.body));
      } catch (_) {
        throw DeepClubFailure('invalid_response', status: response.statusCode);
      }
      if (response.statusCode < 200 || response.statusCode >= 300 || payload['success'] != true) {
        // The code is machine-readable; the server's arbitrary message is never
        // interpolated into logs (it may include request/account details).
        final code = payload['code'] ?? payload['error'];
        throw DeepClubFailure(
          code is String ? code : 'request_rejected',
          status: response.statusCode,
          data: payload['data'],
        );
      }
      return ClientReply(payload['data'], DateTime.tryParse(response.headers['x-client-session-expires-at'] ?? ''));
    } on DeepClubFailure {
      rethrow;
    } on TimeoutException {
      throw const DeepClubFailure('network_unavailable');
    } on http.ClientException {
      throw const DeepClubFailure('network_unavailable');
    }
  }

  void close() => _client.close();
}
