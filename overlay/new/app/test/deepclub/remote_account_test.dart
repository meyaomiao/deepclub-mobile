import 'dart:convert';

import 'package:dsh_app/deepclub/client_api.dart';
import 'package:dsh_app/deepclub/secure_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'gateway_fixture.dart';
import 'support.dart';

void main() {
  test('remote password and 2FA stay session-only and never touch a local engine', () async {
    final rig = ServiceRig(sessionToken: fixturePhoneSession);
    addTearDown(rig.close);
    await rig.service.restore();
    await rig.service.setRemoteOnly(true);
    rig.handler = (request) async {
      if (request.url.path == '/api/client/login') {
        return ServiceRig.ok({'require_2fa': true, 'pending_token': 'pending'});
      }
      if (request.url.path == '/api/client/login/2fa') {
        return ServiceRig.ok({
          ...sessionJson(withKey: false, token: fixturePhoneSession),
          'client_type': 'android_remote',
        });
      }
      return null;
    };
    await rig.login();
    final login = jsonDecode(rig.requests.single.body) as Map;
    expect(login['client_type'], 'android_remote');
    expect(login['platform'], 'android');
    expect(login['device_id'], matches(RegExp(r'^[A-Za-z0-9._:-]{1,64}$')));
    await rig.service.verify2fa('123456');
    await rig.service.localEngineConnected();
    await rig.service.synchronize();
    expect(rig.service.state.signedIn, isTrue);
    expect(rig.service.state.remoteOnly, isTrue);
    expect(rig.service.state.binding, isNotEmpty);
    expect(rig.service.state.engineReady, isFalse);
    expect(
      rig.requests.where((r) => r.url.path.endsWith('/provision') || r.url.path.endsWith('/agent-config')),
      isEmpty,
    );
    expect(rig.engine.calls, isEmpty);
    await rig.service.logout();
    expect(rig.nativeClears, 0, reason: 'remote-only logout must not install/start/clear an absent runtime');
    expect(rig.store.values['session'], isNull);
  });

  test('remote browser flow binds client id/type and its restart preserves session-only mode', () async {
    final rig = ServiceRig(sessionToken: fixturePhoneSession);
    addTearDown(rig.close);
    await rig.service.restore();
    await rig.service.setRemoteOnly(true);
    final uri = await rig.service.beginBrowserLogin();
    expect(uri.queryParameters['client_id'], 'deepclub-android-remote');
    expect(uri.queryParameters['client_type'], 'android_remote');
    expect(uri.queryParameters['redirect_uri'], deepClubRedirect);
    final pending = PendingAuthorization.decode(rig.store.values['pkce']!);
    rig.handler = (request) async {
      if (request.url.path != '/api/client/token') return null;
      final body = jsonDecode(request.body) as Map;
      if (body['client_type'] != 'android_remote') {
        return http.Response(jsonEncode({'success': false, 'code': 'invalid_grant'}), 400);
      }
      return ServiceRig.ok({
        ...sessionJson(withKey: false, token: fixturePhoneSession),
        'client_type': 'android_remote',
      });
    };
    await rig.service.acceptCallback(
      Uri.parse(deepClubRedirect).replace(queryParameters: {'code': 'fixture-code', 'state': pending.state}),
    );
    final exchange = jsonDecode(rig.requests.first.body) as Map;
    expect(exchange['client_id'], 'deepclub-android-remote');
    expect(exchange['client_type'], 'android_remote');
    final binding = rig.service.state.binding;
    final restarted = ServiceRig(storage: rig.store);
    addTearDown(restarted.close);
    await restarted.service.restore();
    expect(restarted.service.state.remoteOnly, isTrue);
    expect(restarted.service.state.binding, binding, reason: 'an app restart retains the existing login binding');
    expect(
      restarted.requests.where((r) => r.url.path.endsWith('/provision') || r.url.path.endsWith('/agent-config')),
      isEmpty,
    );
    expect(restarted.engine.calls, isEmpty);
  });

  test('a rejected browser exchange remains visible after the resume refresh', () async {
    final rig = ServiceRig(sessionToken: fixturePhoneSession);
    addTearDown(rig.close);
    await rig.service.restore();
    await rig.service.setRemoteOnly(true);
    await rig.service.beginBrowserLogin();
    final pending = PendingAuthorization.decode(rig.store.values['pkce']!);
    rig.handler = (request) async => request.url.path == '/api/client/token'
        ? http.Response(jsonEncode({'success': false, 'code': 'invalid_grant'}), 400)
        : null;
    final exchange = rig.service.acceptCallback(
      Uri.parse(deepClubRedirect).replace(queryParameters: {'code': 'rejected-code', 'state': pending.state}),
    );
    // Android resumes while the callback is still exchanging its one-use code.
    final resume = rig.service.synchronize();
    await expectLater(exchange, throwsA(isA<DeepClubFailure>()));
    await resume;
    expect(rig.service.state.signedIn, isFalse);
    expect(rig.service.state.awaitingBrowser, isFalse);
    expect(rig.service.state.error, 'invalid_grant');
    expect(rig.requests.where((request) => request.url.path.endsWith('/bootstrap')), isEmpty);
    await rig.service.beginBrowserLogin();
    expect(rig.service.state.error, isNull, reason: 'an explicit retry clears the prior failure');
  });

  test('remote response cannot import a model key or another platform client type', () async {
    final rig = ServiceRig(sessionToken: fixturePhoneSession);
    addTearDown(rig.close);
    await rig.service.restore();
    await rig.service.setRemoteOnly(true);
    for (final response in [
      sessionJson(),
      {...sessionJson(withKey: false, token: fixturePhoneSession), 'client_type': 'ios_remote'},
    ]) {
      rig.handler = (request) async => request.url.path == '/api/client/login' ? ServiceRig.ok(response) : null;
      await expectLater(
        rig.login(),
        throwsA(isA<DeepClubFailure>().having((e) => e.code, 'code', 'invalid_client_type')),
      );
      expect(rig.service.state.signedIn, isFalse);
      expect(rig.engine.calls, isEmpty);
    }
  });

  test('existing P0 authorization gains one stable pairing binding without provisioning another Key', () async {
    final rig = ServiceRig();
    addTearDown(rig.close);
    rig.store.values['session'] = jsonEncode(sessionJson());
    await rig.service.restore();
    final binding = rig.service.state.binding;
    expect(binding, isNotEmpty);
    expect(rig.requests.where((r) => r.url.path.endsWith('/provision')), isEmpty);
    final restarted = ServiceRig(storage: rig.store);
    addTearDown(restarted.close);
    await restarted.service.restore();
    expect(restarted.service.state.binding, binding);
    expect(restarted.requests.where((r) => r.url.path.endsWith('/provision')), isEmpty);
  });

  test('assertions use current session, exact snake_case request and bounded UTC expiry', () async {
    final rig = ServiceRig(sessionToken: fixturePhoneSession);
    addTearDown(rig.close);
    await rig.service.setRemoteOnly(true);
    await rig.login();
    var expiry = DateTime.now().toUtc().add(const Duration(seconds: 120)).toIso8601String();
    rig.handler = (request) async => request.url.path == '/api/client/remote/assertion'
        ? ServiceRig.ok({'assertion': 'p' * 43, 'expires_at': expiry})
        : null;
    expect(await rig.service.remoteAssertion(fixtureGatewayId, fixtureHostKey, 'pair'), 'p' * 43);
    final request = rig.requests.last;
    expect(request.headers['Authorization'], 'Bearer $fixturePhoneSession');
    expect(jsonDecode(request.body), {'gateway_id': fixtureGatewayId, 'host_key': fixtureHostKey, 'purpose': 'pair'});
    expiry = DateTime.now().toUtc().subtract(const Duration(minutes: 1)).toIso8601String();
    await expectLater(
      rig.service.remoteAssertion(fixtureGatewayId, fixtureHostKey, 'connect'),
      throwsA(isA<DeepClubFailure>()),
    );
    rig.handler = (request) async => request.url.path == '/api/client/remote/assertion'
        ? http.Response(jsonEncode({'success': false, 'code': 'client_session_invalid'}), 401)
        : null;
    await expectLater(
      rig.service.remoteAssertion(fixtureGatewayId, fixtureHostKey, 'connect'),
      throwsA(isA<DeepClubFailure>()),
    );
    expect(rig.service.state.signedIn, isFalse);
    expect(rig.store.values['session'], isNull);
  });
}
