import 'dart:convert';

import 'package:dsh_app/deepclub/client_api.dart';
import 'package:dsh_app/deepclub/secure_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  test('RFC7636 S256 vector and independent secure state/verifier', () {
    expect(pkceChallenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'), 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
    final first = PendingAuthorization.create(), second = PendingAuthorization.create();
    for (final value in [first.state, first.verifier, second.state, second.verifier]) {
      expect(value, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
    }
    expect({first.state, first.verifier, second.state, second.verifier}, hasLength(4));
  });

  test('callback validates origin/path/state/duplicates and never imports URL tokens', () {
    final pending = PendingAuthorization.create();
    final uri = Uri.parse(deepClubRedirect).replace(queryParameters: {'state': pending.state, 'code': 'code-fixture'});
    expect(pending.codeFrom(uri), 'code-fixture');
    for (final invalid in [
      uri.replace(scheme: 'https'),
      uri.replace(host: 'auth.evil.invalid'),
      uri.replace(path: '/callback/extra'),
      uri.replace(userInfo: 'attacker'),
      uri.replace(port: 80),
      uri.replace(fragment: 'access_token=secret'),
      uri.replace(queryParameters: {'state': 'wrong', 'code': 'a'}),
      Uri.parse('$uri&state=${pending.state}'),
      uri.replace(queryParameters: {'state': pending.state, 'code': 'a', 'session_token': 'never-import'}),
      uri.replace(queryParameters: {'state': pending.state, 'api_key': 'never-import'}),
    ]) {
      expect(() => pending.codeFrom(invalid), throwsA(isA<DeepClubFailure>()));
    }
    expect(
      () => pending.codeFrom(uri, now: pending.createdAt.add(const Duration(minutes: 11))),
      throwsA(isA<DeepClubFailure>()),
    );
  });

  test('cold-start callback exchanges once with secure pending state and exact token JSON', () async {
    final storage = MemoryStore();
    final before = ServiceRig(storage: storage);
    final authorize = await before.service.beginBrowserLogin();
    final pending = PendingAuthorization.decode(storage.values['pkce']!);
    expect(authorize.origin, deepClubOrigin);
    expect(authorize.path, '/client/authorize');
    expect(
      authorize.queryParameters.keys,
      unorderedEquals([
        'client_id',
        'redirect_uri',
        'code_challenge_method',
        'code_challenge',
        'state',
        'device_id',
        'device_name',
        'platform',
        'app_version',
      ]),
      reason: 'the web authorization page accepts this exact strict field set',
    );
    expect(authorize.queryParameters, containsPair('client_id', 'deepclub-agent'));
    expect(authorize.queryParameters, containsPair('redirect_uri', deepClubRedirect));
    expect(authorize.queryParameters, containsPair('code_challenge_method', 'S256'));
    expect(authorize.toString(), isNot(contains(pending.verifier)));
    expect(authorize.queryParameters['device_id'], matches(RegExp(r'^[A-Za-z0-9._:-]{1,64}$')));
    final device = authorize.queryParameters['device_id'];
    await before.close();
    final after = ServiceRig(storage: storage);
    addTearDown(after.close);
    await after.service.restore();
    final callback = Uri.parse(deepClubRedirect).replace(queryParameters: {'state': pending.state, 'code': 'once'});
    await after.service.acceptCallback(callback);
    expect(storage.values.containsKey('pkce'), isFalse);
    final exchange = after.requests.singleWhere((r) => r.url.path == '/api/client/token');
    expect(jsonDecode(exchange.body), {
      'grant_type': 'authorization_code',
      'client_id': 'deepclub-agent',
      'redirect_uri': deepClubRedirect,
      'code': 'once',
      'code_verifier': pending.verifier,
    });
    expect(exchange.headers.containsKey('Authorization'), isFalse);
    expect(after.requests.where((r) => r.url.path == '/api/client/provision'), isEmpty);
    await expectLater(after.service.acceptCallback(callback), throwsA(isA<DeepClubFailure>()));
    expect(after.requests.where((r) => r.url.path == '/api/client/token'), hasLength(1));
    final nextAuthorize = await after.service.beginBrowserLogin();
    expect(nextAuthorize.queryParameters['device_id'], device);
  });

  test('verified browser denial consumes pending verifier without exchanging a token', () async {
    final rig = ServiceRig();
    addTearDown(rig.close);
    final uri = await rig.service.beginBrowserLogin();
    final callback = Uri.parse(deepClubRedirect)
        .replace(queryParameters: {'state': uri.queryParameters['state']!, 'error': 'access_denied'});
    await expectLater(rig.service.acceptCallback(callback), throwsA(isA<DeepClubFailure>()));
    expect(rig.requests, isEmpty);
    expect(rig.store.values['pkce'], isNull);
    expect(rig.service.state.awaitingBrowser, isFalse);
  });

  test('wrong state makes no API request and leaves pending attempt available', () async {
    final rig = ServiceRig();
    addTearDown(rig.close);
    await rig.service.beginBrowserLogin();
    await expectLater(
      rig.service.acceptCallback(Uri.parse('$deepClubRedirect?code=x&state=wrong')),
      throwsA(isA<DeepClubFailure>()),
    );
    expect(rig.requests, isEmpty);
    expect(rig.store.values['pkce'], isNotNull);
  });
}
