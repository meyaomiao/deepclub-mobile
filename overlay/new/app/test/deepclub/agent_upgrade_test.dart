import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/deepclub/client_api.dart';
import 'package:dsh_app/deepclub/secure_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'support.dart';

http.Response intentReply(http.Request request, {String? url}) {
  final body = Map<String, dynamic>.from(jsonDecode(request.body) as Map);
  final relative = Uri(
    path: '/client/authorize',
    queryParameters: {
      'client_id': 'deepclub-android-agent-upgrade-v1',
      'client_type': 'agent',
      'state': body['state'],
      'code_challenge': body['code_challenge'],
      'code_challenge_method': 'S256',
      'redirect_uri': deepClubRedirect,
      'upgrade_intent': 'synthetic-intent',
    },
  );
  return ServiceRig.ok({'intent': 'synthetic-intent', 'authorize_url': url ?? relative.toString(), 'expires_in': 300});
}

Future<void> remoteLogin(ServiceRig rig) async {
  await rig.service.restore();
  rig.store.values['device_id'] = 'fixed-installation';
  await rig.service.setRemoteOnly(true);
  await rig.login();
  rig.requests.clear();
}

Uri callback(ServiceRig rig, {bool denied = false}) {
  final pending = PendingAuthorization.decode(rig.store.values['pkce']!);
  return Uri.parse(deepClubRedirect).replace(
    queryParameters: {'state': pending.state, if (denied) 'error': 'access_denied' else 'code': 'synthetic-code'},
  );
}

void expectRemote(ServiceRig rig, String binding) {
  expect(rig.service.state.signedIn, isTrue);
  expect(rig.service.state.remoteOnly, isTrue);
  expect(rig.service.state.binding, binding);
  expect(rig.store.values['device_id'], 'fixed-installation');
  expect(
    rig.requests.where(
      (r) =>
          r.url.path.endsWith('/logout') || r.url.path.endsWith('/provision') || r.url.path.endsWith('/agent-config'),
    ),
    isEmpty,
  );
  expect(rig.engine.calls, isEmpty);
  expect(rig.nativeClears, 0);
}

void main() {
  test('explicit intent and one exchange keep the same installation until success', () async {
    final rig = ServiceRig();
    addTearDown(rig.close);
    await remoteLogin(rig);
    final binding = rig.service.state.binding;
    final exchanged = Completer<http.Response>();
    rig.handler = (request) async {
      if (request.url.path.endsWith('/agent-upgrade/intents')) return intentReply(request);
      if (request.url.path.endsWith('/token')) return exchanged.future;
      return null;
    };
    final uri = await rig.service.enableLocal();
    expect(uri.origin, deepClubServiceOrigin);
    expect(uri.path, '/client/authorize');
    expect(uri.queryParameters.values, isNot(contains('synthetic-session')));
    final request = rig.requests.single;
    expect(request.headers['Authorization'], 'Bearer synthetic-session');
    final body = jsonDecode(request.body) as Map;
    expect(body.keys.toSet(), {'state', 'code_challenge', 'code_challenge_method', 'redirect_uri'});
    final pending = PendingAuthorization.decode(rig.store.values['pkce']!);
    expect(body['code_challenge'], pkceChallenge(pending.verifier));
    expectRemote(rig, binding);
    final result = rig.service.acceptCallback(callback(rig));
    await Future<void>.delayed(Duration.zero);
    expectRemote(rig, binding);
    exchanged.complete(
      ServiceRig.ok({
        ...sessionJson(token: 'new-agent-session'),
        'client_type': 'agent',
        'device_id': 'fixed-installation',
        'client_session_id': 43,
      }),
    );
    await result;
    final token = rig.requests.singleWhere((r) => r.url.path.endsWith('/token'));
    expect(token.headers['Authorization'], isNull);
    expect(jsonDecode(token.body), {
      'grant_type': 'authorization_code',
      'client_id': 'deepclub-android-agent-upgrade-v1',
      'client_type': 'agent',
      'redirect_uri': deepClubRedirect,
      'code': 'synthetic-code',
      'code_verifier': pending.verifier,
    });
    expect(rig.service.state.remoteOnly, isFalse);
    expect(rig.service.state.signedIn, isTrue);
    expect(rig.service.state.binding, isNot(binding));
    expect(rig.store.values['device_id'], 'fixed-installation');
    expect(rig.store.values['remote_device_id'], isNull);
    expect(rig.service.state.engineReady, isTrue);
    expect(rig.requests.where((r) => r.url.path.endsWith('/logout') || r.url.path.endsWith('/provision')), isEmpty);
    final restarted = ServiceRig(storage: rig.store);
    addTearDown(restarted.close);
    await restarted.service.restore();
    expect(restarted.service.state.remoteOnly, isFalse);
    expect(restarted.store.values['device_id'], 'fixed-installation');
  });

  for (final failure in ['cancel', 'invalid_grant', 'upgrade_not_allowed', 'validation_unavailable', 'network']) {
    test('$failure leaves the existing remote authorization and binding usable', () async {
      final rig = ServiceRig();
      addTearDown(rig.close);
      await remoteLogin(rig);
      final binding = rig.service.state.binding;
      rig.handler = (request) async {
        if (request.url.path.endsWith('/agent-upgrade/intents')) return intentReply(request);
        if (request.url.path.endsWith('/token')) {
          if (failure == 'network') throw http.ClientException('synthetic network loss');
          return http.Response(
            jsonEncode({'success': false, 'code': failure}),
            failure == 'upgrade_not_allowed'
                ? 403
                : failure == 'validation_unavailable'
                ? 503
                : 400,
          );
        }
        return null;
      };
      await rig.service.enableLocal();
      await expectLater(
        rig.service.acceptCallback(callback(rig, denied: failure == 'cancel')),
        throwsA(isA<DeepClubFailure>()),
      );
      expectRemote(rig, binding);
      expect(rig.store.values['pkce'], isNull);
      expect(rig.service.state.awaitingBrowser, isFalse);
      final restarted = ServiceRig(storage: rig.store);
      addTearDown(restarted.close);
      await restarted.service.restore();
      expectRemote(restarted, binding);
    });
  }

  test('restart keeps pending upgrade and migrates the previously authorized remote identity', () async {
    final rig = ServiceRig();
    addTearDown(rig.close);
    await remoteLogin(rig);
    final binding = rig.service.state.binding;
    rig.handler = (request) async => request.url.path.endsWith('/agent-upgrade/intents') ? intentReply(request) : null;
    await rig.service.enableLocal();
    final returning = callback(rig);
    rig.store.values['remote_device_id'] = 'fixed-installation';
    rig.store.values['device_id'] = 'obsolete-split-agent-id';
    final restarted = ServiceRig(storage: rig.store);
    addTearDown(restarted.close);
    await restarted.service.restore();
    expectRemote(restarted, binding);
    expect(restarted.service.state.awaitingBrowser, isTrue);
    restarted.handler = (request) async => request.url.path.endsWith('/token')
        ? ServiceRig.ok({...sessionJson(), 'client_type': 'agent', 'device_id': 'fixed-installation'})
        : null;
    await restarted.service.acceptCallback(returning);
    expect(restarted.service.state.remoteOnly, isFalse);
    expect(restarted.store.values['device_id'], 'fixed-installation');
    await expectLater(restarted.service.acceptCallback(returning), throwsA(isA<DeepClubFailure>()));
    expect(restarted.requests.where((r) => r.url.path.endsWith('/token')), hasLength(1));
  });

  for (final invalid in ['missing_token', 'missing_user', 'wrong_user', 'missing_expiry']) {
    test('$invalid response cannot change the remote mode or fixed identity', () async {
      final rig = ServiceRig();
      addTearDown(rig.close);
      await remoteLogin(rig);
      final binding = rig.service.state.binding;
      final stored = rig.store.values['session'];
      rig.handler = (request) async {
        if (request.url.path.endsWith('/agent-upgrade/intents')) return intentReply(request);
        if (request.url.path.endsWith('/token')) {
          final data = {...sessionJson(), 'client_type': 'agent', 'device_id': 'fixed-installation'};
          if (invalid == 'missing_token') data.remove('session_token');
          if (invalid == 'missing_user') data.remove('user');
          if (invalid == 'missing_expiry') data.remove('expires_at');
          if (invalid == 'wrong_user') data['user'] = {'id': 2};
          return ServiceRig.ok(data);
        }
        return null;
      };
      await rig.service.enableLocal();
      await expectLater(rig.service.acceptCallback(callback(rig)), throwsA(isA<DeepClubFailure>()));
      expectRemote(rig, binding);
      expect(rig.store.values['session'], stored);
      expect((await rig.service.remoteDevice())['client_type'], 'android_remote');
    });
  }

  test('post-exchange configuration failure retains the newly authorized agent for retry', () async {
    final rig = ServiceRig();
    addTearDown(rig.close);
    await remoteLogin(rig);
    final binding = rig.service.state.binding;
    rig.handler = (request) async {
      if (request.url.path.endsWith('/agent-upgrade/intents')) return intentReply(request);
      if (request.url.path.endsWith('/token')) {
        return ServiceRig.ok({
          ...sessionJson(token: 'new-agent-session'),
          'client_type': 'agent',
          'device_id': 'fixed-installation',
        });
      }
      if (request.url.path.endsWith('/agent-config')) throw http.ClientException('synthetic outage');
      return null;
    };
    await rig.service.enableLocal();
    await expectLater(rig.service.acceptCallback(callback(rig)), throwsA(isA<DeepClubFailure>()));
    expect(rig.service.state.remoteOnly, isFalse);
    expect(rig.service.state.binding, isNot(binding));
    expect(rig.service.relaySession(), 'new-agent-session');
    expect(jsonDecode(rig.store.values['session']!)['remote_only'], isFalse);
    rig.handler = null;
    await rig.service.synchronize();
    expect(rig.service.state.engineReady, isTrue);
  });

  test('untrusted browser origin and mismatched exchange identity cannot switch mode', () async {
    final rig = ServiceRig();
    addTearDown(rig.close);
    await remoteLogin(rig);
    final binding = rig.service.state.binding;
    rig.handler = (request) async => request.url.path.endsWith('/agent-upgrade/intents')
        ? intentReply(request, url: 'https://evil.invalid/client/authorize')
        : null;
    await expectLater(rig.service.enableLocal(), throwsA(isA<DeepClubFailure>()));
    expectRemote(rig, binding);
    rig.handler = (request) async {
      if (request.url.path.endsWith('/agent-upgrade/intents')) return intentReply(request);
      if (request.url.path.endsWith('/token')) {
        return ServiceRig.ok({...sessionJson(), 'client_type': 'agent', 'device_id': 'wrong-installation'});
      }
      return null;
    };
    await rig.service.enableLocal();
    await expectLater(rig.service.acceptCallback(callback(rig)), throwsA(isA<DeepClubFailure>()));
    expectRemote(rig, binding);
  });
}
