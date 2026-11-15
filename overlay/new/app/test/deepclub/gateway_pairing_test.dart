import 'dart:convert';

import 'package:dsh_app/remote/gateway_pairing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'gateway_fixture.dart';

void main() {
  final now = DateTime.utc(2026, 11, 14, 12);
  Map<String, Object?> qr() => {
    'version': 2,
    'gatewayId': fixtureGatewayId,
    'gatewayName': 'My computer',
    'hostKey': fixtureHostKey,
    'protocols': ['dsh-mobile-v1', GatewayPairing.protocol],
    'pairingCode': fixturePairCode,
    'expiresAt': now.add(const Duration(minutes: 5)).millisecondsSinceEpoch,
    'publicUrl': 'wss://deepclub.net/ws/mobile/$fixtureGatewayId',
    'endpoints': ['wss://deepclub.net/ws/mobile/$fixtureGatewayId', 'ws://192.168.1.5:18744/ws/mobile'],
  };
  String encoded(Map<String, Object?> data) => base64UrlEncode(utf8.encode(jsonEncode(data))).replaceAll('=', '');
  GatewayPairing parse(Map<String, Object?> data) =>
      GatewayPairing.parse('https://deepclub.net/pair#${encoded(data)}', now: now);
  Matcher failure(String code) => throwsA(isA<GatewayPairingFailure>().having((e) => e.code, 'code', code));

  test('universal QR, app link and pasted payload share the v2 parser; LAN comes first', () {
    for (final link in [
      'https://deepclub.net/pair#${encoded(qr())}',
      'deepclub://pair#${encoded(qr())}',
      encoded(qr()),
    ]) {
      final pairing = GatewayPairing.parse(link, now: now);
      expect(pairing.gatewayId, fixtureGatewayId);
      expect(pairing.endpoints.first.host, '192.168.1.5');
      expect(pairing.endpoints, hasLength(2));
      expect(pairing.hostKey, fixtureHostKey);
    }
  });
  test('expired and incompatible offers fail before a connection is attempted', () {
    expect(() => parse({...qr(), 'expiresAt': now.millisecondsSinceEpoch}), failure('pairing_expired'));
    expect(
      () => parse({...qr(), 'expiresAt': now.add(const Duration(hours: 1)).millisecondsSinceEpoch}),
      failure('invalid_pairing'),
    );
    expect(
      () => parse({
        ...qr(),
        'protocols': ['dsh-mobile-v1'],
      }),
      failure('version_incompatible'),
    );
    expect(() => parse({...qr(), 'version': 3}), failure('version_incompatible'));
  });
  test('fingerprints and one-use secrets must have the documented shape', () {
    for (final key in ['sha256:${'A' * 64}', 'SHA256:${'a' * 64}', 'a' * 64, 'sha256:${'a' * 63}']) {
      expect(() => parse({...qr(), 'hostKey': key}), failure('invalid_pairing'));
    }
    expect(() => parse({...qr(), 'pairingCode': '12345678'}), failure('invalid_pairing'));
  });
  test('untrusted origins, credential-bearing URLs and fake private DNS names are rejected', () {
    for (final prefix in [
      'http://deepclub.net/pair',
      'https://deepclub.net.evil.invalid/pair',
      'https://deepclub.net:8443/pair',
      'https://deepclub.net/pair?send=1',
      'https://user@deepclub.net/pair',
    ]) {
      expect(() => GatewayPairing.parse('$prefix#${encoded(qr())}', now: now), failure('invalid_pairing'));
    }
    for (final endpoint in [
      'ws://10.evil.invalid/ws/mobile',
      'ws://192.168.evil.invalid/ws/mobile',
      'wss://other.invalid/ws/mobile',
      'ws://192.168.1.2/ws/mobile?token=secret',
      'ws://user:secret@192.168.1.2/ws/mobile',
      'wss://deepclub.net/ws/mobile/wrong-id',
    ]) {
      expect(
        () => parse({
          ...qr(),
          'endpoints': [endpoint],
        }),
        failure('invalid_pairing'),
      );
    }
  });
  test('saved host metadata never includes pairing code, token or account session', () {
    final pair = parse(qr());
    final saved = GatewayHost(
      id: pair.gatewayId,
      name: pair.name,
      hostKey: pair.hostKey,
      endpoints: pair.endpoints,
      binding: 'fresh-login-binding',
    );
    final raw = jsonEncode(saved.toJson());
    expect(raw, isNot(contains(fixturePairCode)));
    expect(raw, isNot(contains(fixtureDeviceToken)));
    expect(saved.toJson().keys.toSet(), {'id', 'name', 'hostKey', 'endpoints', 'binding'});
    final loaded = GatewayHost.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    expect(loaded.hostKey, saved.hostKey);
    expect(loaded.binding, saved.binding);
    expect(loaded.endpoints, saved.endpoints);
  });
}
