import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/deepclub/client_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'support.dart';

class _FailingDeleteStore extends MemoryStore {
  bool failDelete = false;
  @override
  Future<void> delete(String key) async {
    if (failDelete && key == 'session') throw StateError('controlled keystore failure');
    await super.delete(key);
  }
}

void main() {
  test('bootstrap announcement projects plain text without requests or blocking account access', () async {
    final rig = ServiceRig();
    addTearDown(rig.close);
    Object? announcement = {
      'content': '  Notice\n<a href="https://example.invalid">plain text</a>  ',
      'publish': '2026-11-12',
    };
    rig.handler = (request) async =>
        request.url.path == '/api/client/bootstrap' ? ServiceRig.ok({'announcement': announcement}) : null;
    await rig.login();
    final requests = rig.requests.length;
    expect(rig.service.state.announcement, (
      content: 'Notice\n<a href="https://example.invalid">plain text</a>',
      publish: '2026-11-12',
    ));
    expect(rig.requests, hasLength(requests), reason: 'reading the projection performs no HTTP');
    for (final missing in [
      null,
      'invalid',
      {'content': 7},
      {'content': '  '},
    ]) {
      announcement = missing;
      await rig.service.synchronize();
      expect(rig.service.state.announcement, isNull);
      expect(rig.service.state.signedIn, isTrue);
      expect(rig.service.state.engineReady, isTrue);
      expect(rig.service.state.error, isNull);
    }
  });

  test('password + 2FA provisions once and all account requests use session Bearer', () async {
    final rig = ServiceRig();
    addTearDown(rig.close);
    rig.handler = (request) async => request.url.path == '/api/client/login'
        ? ServiceRig.ok({'require_2fa': true, 'pending_token': 'pending-fixture', 'expires_in': 300})
        : null;
    await rig.login();
    expect(rig.service.state.require2fa, isTrue);
    expect(rig.service.state.signedIn, isFalse);
    expect(rig.requests, hasLength(1));
    await rig.service.verify2fa('123456');
    expect(rig.service.state.signedIn, isTrue);
    expect(rig.service.state.engineReady, isTrue);
    final verify = rig.requests.singleWhere((r) => r.url.path == '/api/client/login/2fa');
    expect(jsonDecode(verify.body), {'pending_token': 'pending-fixture', 'code': '123456'});
    for (final r in rig.requests.where((r) => !r.url.path.contains('/login'))) {
      expect(r.headers['Authorization'], 'Bearer synthetic-session');
      expect(r.url.query, isEmpty);
      expect(r.followRedirects, isFalse);
      expect(r.url.origin, deepClubOrigin);
    }
    expect(rig.store.values.toString(), isNot(contains('synthetic-password')));
    expect(rig.store.values.toString(), isNot(contains('pending-fixture')));
    expect(rig.store.values['session'], contains('synthetic-model-key'));
  });

  test('same revision performs no config/key rewrite, changed revision preserves choice', () async {
    final rig = ServiceRig();
    addTearDown(rig.close);
    await rig.login();
    expect(rig.engine.configWrites, 1);
    expect(rig.engine.recommendations, [true]);
    await rig.service.synchronize();
    expect(rig.engine.configWrites, 1);
    expect(rig.engine.calls.where((c) => c == 'setKey'), hasLength(1));
    rig.revision = 'sha256:changed';
    await rig.service.synchronize();
    expect(rig.engine.configWrites, 2);
    expect(rig.engine.recommendations, [true, false]);
  });

  for (final status in [401, 403]) {
    test(
      '$status clears persisted and engine credentials without auto-provision bypass, then supports fresh login',
      () async {
        final rig = ServiceRig();
        addTearDown(rig.close);
        await rig.login();
        final callsBefore = rig.requests.length;
        rig.handler = (request) async => request.url.path.endsWith('/agent-config')
            ? http.Response(jsonEncode({'success': false, 'code': 'client_relay_token_invalid'}), status)
            : null;
        await expectLater(rig.service.synchronize(), throwsA(isA<DeepClubFailure>()));
        expect(rig.engine.key, isNull);
        expect(rig.service.state.signedIn, isFalse);
        expect(rig.service.state.engineReady, isFalse);
        expect(rig.store.values.containsKey('session'), isFalse);
        expect(rig.requests.skip(callsBefore).where((r) => r.url.path.endsWith('/provision')), isEmpty);
        rig.handler = null;
        await rig.login();
        expect(rig.service.state.engineReady, isTrue);
        expect(rig.engine.key, 'synthetic-model-key');
      },
    );
  }

  test('failed server logout retains session until explicit local-only exit reports non-revocation', () async {
    final rig = ServiceRig();
    addTearDown(rig.close);
    await rig.login();
    rig.handler = (request) async {
      if (request.url.path.endsWith('/logout')) throw http.ClientException('controlled offline');
      return null;
    };
    await expectLater(rig.service.logout(), throwsA(isA<DeepClubFailure>()));
    expect(rig.service.state.signedIn, isTrue);
    await rig.service.logout(localOnly: true);
    expect(rig.service.state.signedIn, isFalse);
    expect(rig.service.state.serverNotRevoked, isTrue);
    expect(rig.engine.key, isNull);
    expect(rig.store.values.containsKey('session'), isFalse);
  });

  test('offline engine cleanup uses native stop/clear and retries the catalog on reconnect', () async {
    final rig = ServiceRig();
    addTearDown(rig.close);
    await rig.login();
    rig.connected = false;
    await rig.service.logout(localOnly: true);
    expect(rig.nativeClears, 1);
    expect(rig.store.values['cleanup'], 'catalog');
    expect(rig.engine.key, isNull);
    rig.connected = true;
    await rig.service.localEngineConnected();
    expect(rig.store.values.containsKey('cleanup'), isFalse);
    expect(rig.service.state.signedIn, isFalse);
  });

  test('failed cleanup survives process restart and blocks stale session restoration', () async {
    final rig = ServiceRig();
    addTearDown(rig.close);
    await rig.login();
    rig.engine.failClear = true;
    rig.failNative = true;
    await expectLater(rig.service.logout(localOnly: true), throwsA(isA<DeepClubFailure>()));
    expect(rig.service.state.cleanupBlocked, isTrue);
    expect(rig.store.values['cleanup'], 'credentials');
    // Simulate a process killed before secure session deletion completed.
    rig.store.values['session'] = jsonEncode(sessionJson());
    final restarted = ServiceRig(storage: rig.store);
    addTearDown(restarted.close);
    await restarted.service.restore();
    expect(restarted.service.state.signedIn, isFalse);
    expect(restarted.engine.key, isNull);
    expect(restarted.requests, isEmpty);
    await restarted.login();
    expect(restarted.service.state.engineReady, isTrue);
  });

  test('secure-storage deletion failure still clears the engine and remains recoverable', () async {
    final storage = _FailingDeleteStore();
    final rig = ServiceRig(storage: storage);
    addTearDown(rig.close);
    await rig.login();
    storage.failDelete = true;
    await expectLater(rig.service.logout(localOnly: true), throwsA(isA<DeepClubFailure>()));
    expect(rig.engine.key, isNull);
    expect(rig.service.state.cleanupBlocked, isTrue);
    expect(storage.values['cleanup'], 'credentials');
    storage.failDelete = false;
    await rig.service.retryCleanup();
    expect(rig.service.state.cleanupBlocked, isFalse);
    expect(storage.values['session'], isNull);
    final restarted = ServiceRig(storage: storage);
    addTearDown(restarted.close);
    await restarted.service.restore();
    expect(restarted.service.state.serverNotRevoked, isTrue);
  });

  test('logout queued behind a slow sync is the last mutation and cannot resurrect the key', () async {
    final rig = ServiceRig();
    addTearDown(rig.close);
    await rig.login();
    final entered = Completer<void>(), release = Completer<void>();
    rig.handler = (request) async {
      if (request.url.path.endsWith('/agent-config')) {
        entered.complete();
        await release.future;
      }
      return null;
    };
    final sync = rig.service.synchronize();
    await entered.future;
    final logout = rig.service.logout();
    release.complete();
    await Future.wait([sync, logout]);
    expect(rig.engine.calls.last, 'clearKey');
    expect(rig.engine.key, isNull);
    expect(rig.store.values['session'], isNull);
  });

  test('renewal header updates secure session expiry and revoking current device clears local state', () async {
    final rig = ServiceRig();
    addTearDown(rig.close);
    rig.handler = (request) async => request.url.path.endsWith('/bootstrap')
        ? ServiceRig.ok(
            {
              'site': {'quota_per_unit': 1},
              'user': {'quota': 2},
            },
            headers: {'x-client-session-expires-at': '2099-04-01T00:00:00Z'},
          )
        : null;
    await rig.login();
    expect(jsonDecode(rig.store.values['session']!)['expires_at'], '2099-04-01T00:00:00.000Z');
    await rig.service.revokeDevice(42);
    expect(rig.requests.last.method, 'DELETE');
    expect(rig.requests.last.url.path, '/api/client/devices/42');
    expect(rig.engine.key, isNull);
    expect(rig.service.state.signedIn, isFalse);
  });
}
