import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/deepclub/account_state.dart';
import 'package:dsh_app/deepclub/client_api.dart';
import 'package:dsh_app/deepclub/secure_store.dart';
import 'package:dsh_app/links/app_links.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/gateway_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'gateway_fixture.dart';
import 'support.dart';

class _NetworkBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

class _Rig {
  _Rig(this.account, this.secrets, this.container);
  final ServiceRig account;
  final MemorySecretStore secrets;
  final ProviderContainer container;
  static Future<_Rig> start() async {
    final account = ServiceRig(sessionToken: fixturePhoneSession);
    account.store.values['remote_only'] = '1';
    var proofs = 0;
    account.handler = (request) async => request.url.path == '/api/client/remote/assertion'
        ? ServiceRig.ok({
            'assertion': '${++proofs}'.padLeft(43, 'p'),
            'expires_at': DateTime.now().toUtc().add(const Duration(seconds: 120)).toIso8601String(),
          })
        : null;
    final secrets = MemorySecretStore();
    final container = ProviderContainer(
      overrides: [
        deepClubStoreProvider.overrideWithValue(account.store),
        deepClubApiProvider.overrideWithValue(account.api),
        deepClubLocalEngineProvider.overrideWithValue(account.engine),
        secretStoreProvider.overrideWithValue(secrets),
        networkKicksProvider.overrideWithValue(const Stream.empty()),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await account.close();
    });
    container.listen(deepClubAccountProvider, (_, _) {});
    await untilGateway(() => container.read(deepClubAccountProvider).loaded);
    await container.read(deepClubAccountProvider.notifier).service.loginWithPassword('fixture', 'synthetic');
    await container.pump();
    container.listen(gatewayHostsProvider, (_, _) {});
    await container.read(gatewayHostsProvider.notifier).ready;
    await container.read(activeHostProvider.notifier).ready;
    return _Rig(account, secrets, container);
  }
}

void main() {
  _NetworkBinding();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('pairing persists metadata/token separately; logout closes the production gateway link', () async {
    final fixture = await NativeGatewayFixture.start();
    addTearDown(fixture.close);
    final rig = await _Rig.start();
    final c = rig.container;
    final paired = await c.read(gatewayPairProvider.notifier).pair(fixture.link());
    expect(paired, isNotNull);
    expect(rig.secrets.values[GatewayHost.tokenKey(fixtureGatewayId)], fixtureDeviceToken);
    final raw = (await SharedPreferences.getInstance()).getString(GatewayHostsController.prefsKey)!;
    expect(raw, isNot(contains(fixtureDeviceToken)));
    expect(raw, isNot(contains(fixturePairCode)));
    expect(raw, isNot(contains('synthetic-session')));
    final selected = HostRef.gateway(paired!.id, name: paired.name);
    expect(HostRef.decode(selected.encode()), selected);
    c.read(activeHostProvider.notifier).select(selected);
    c.listen(activeConnectionProvider, (_, _) {});
    final connection = await c.read(remoteConnectionProvider(selected).future);
    expect(connection?.kind, HostKind.gateway);
    expect(connection?.isLocal, isFalse);
    expect(connection?.client.mux.generation?.home, '/fixture');
    final requests = fixture.requests.length;
    await c.read(deepClubAccountProvider.notifier).service.logout();
    await c.pump();
    await untilGateway(() => fixture.sockets.last.readyState != 1 && c.read(gatewayHostsProvider).hosts.isEmpty);
    expect(rig.secrets.values, isEmpty);
    expect(c.read(activeHostProvider), HostRef.local);
    expect(connection!.client.mux.state, DshConnectionState.closed);
    expect(fixture.requests, hasLength(requests));
    expect(rig.account.engine.calls, isEmpty);
  });

  test('switching gateway hosts retires the old client, selected session, approvals and model intent', () async {
    final a = await NativeGatewayFixture.start();
    final b = await NativeGatewayFixture.start(id: '87654321-1234-4567-8123-123456789abc');
    addTearDown(a.close);
    addTearDown(b.close);
    final rig = await _Rig.start();
    final c = rig.container;
    final binding = c.read(deepClubAccountProvider).binding;
    for (final fixture in [a, b]) {
      await c.read(gatewayHostsProvider.notifier).save(fixture.host(binding: binding), fixtureDeviceToken);
    }
    final hostA = HostRef.gateway(a.gatewayId), hostB = HostRef.gateway(b.gatewayId);
    c.listen(activeConnectionProvider, (_, _) {});
    c.read(activeHostProvider.notifier).select(hostA);
    await c.pump();
    final first = (await c.read(remoteConnectionProvider(hostA).future))!;
    final identityA = c.read(readListIdentityProvider);
    c.read(currentSessionProvider.notifier).select('same-session-id');
    c.read(pendingModelProvider.notifier).select(const ModelSelection(provider: 'computer-A', model: 'only-A'));
    a.event({
      'type': 'waterfall',
      'event': 'approval/request',
      'eventId': 'approval-A',
      'agentId': 'same-session-id',
      'request': {'toolName': 'bash', 'callId': 'call-A', 'reason': 'synthetic approval'},
    });
    await untilGateway(() => first.client.mux.pendingRequests.isNotEmpty);
    c.read(activeHostProvider.notifier).select(hostB);
    expect(c.read(currentSessionProvider), isNull);
    expect(c.read(pendingModelProvider), isNull);
    await c.pump();
    final second = (await c.read(remoteConnectionProvider(hostB).future))!;
    await untilGateway(() => first.client.mux.state == DshConnectionState.closed);
    expect(second.client, isNot(same(first.client)));
    expect(second.client.mux.pendingRequests, isEmpty);
    expect(c.read(readListIdentityProvider), isNot(identityA));
    expect(c.read(activeConnectionProvider).value?.hostId, b.gatewayId);
    expect(rig.account.engine.calls, isEmpty, reason: 'phone auto-configuration never targets either computer');
  });

  test('new login binding cannot use saved gateway metadata from the previous session', () async {
    final fixture = await NativeGatewayFixture.start();
    addTearDown(fixture.close);
    final rig = await _Rig.start();
    final c = rig.container;
    final old = fixture.host(binding: 'previous-login-binding');
    await (await SharedPreferences.getInstance()).setString(
      GatewayHostsController.prefsKey,
      jsonEncode([old.toJson()]),
    );
    c.invalidate(gatewayHostsProvider);
    await c.read(gatewayHostsProvider.notifier).ready;
    final host = HostRef.gateway(old.id);
    c.read(activeHostProvider.notifier).select(host);
    expect(c.read(hostLinkProvider(host)), isNull);
    expect(c.read(readListIdentityProvider), isNull);
    expect(fixture.requests, isEmpty);
  });

  test('upgrade cancellation retains gateway credentials; successful exchange clears old binding', () async {
    final fixture = await NativeGatewayFixture.start();
    addTearDown(fixture.close);
    final rig = await _Rig.start();
    final c = rig.container;
    final service = c.read(deepClubAccountProvider.notifier).service;
    final paired = (await c.read(gatewayPairProvider.notifier).pair(fixture.link()))!;
    final oldBinding = service.state.binding;
    final install = (await service.remoteDevice())['device_id'];
    rig.account.handler = (request) async {
      if (request.url.path.endsWith('/agent-upgrade/intents')) {
        final body = Map<String, dynamic>.from(jsonDecode(request.body) as Map);
        return ServiceRig.ok({
          'intent': 'synthetic-intent',
          'authorize_url': Uri(
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
          ).toString(),
          'expires_in': 300,
        });
      }
      if (request.url.path.endsWith('/token')) {
        return ServiceRig.ok({...sessionJson(), 'client_type': 'agent', 'device_id': install});
      }
      return null;
    };
    await service.enableLocal();
    await service.cancelBrowserLogin();
    await c.pump();
    expect(service.state.binding, oldBinding);
    expect(c.read(gatewayHostsProvider).byId(paired.id), isNotNull);
    expect(rig.secrets.values[GatewayHost.tokenKey(paired.id)], fixtureDeviceToken);
    await service.enableLocal();
    final pending = PendingAuthorization.decode(rig.account.store.values['pkce']!);
    await service.acceptCallback(
      Uri.parse(deepClubRedirect).replace(queryParameters: {'state': pending.state, 'code': 'synthetic-code'}),
    );
    await c.pump();
    await untilGateway(() => c.read(gatewayHostsProvider).hosts.isEmpty && rig.secrets.values.isEmpty);
    expect(service.state.binding, isNot(oldBinding));
    expect((await service.remoteDevice())['device_id'], install);
    expect(service.state.remoteOnly, isFalse);
  });

  test('incoming pair link routes through the early inbox and binds the current login', () async {
    final fixture = await NativeGatewayFixture.start();
    addTearDown(fixture.close);
    final rig = await _Rig.start();
    final c = rig.container;
    c.read(gatewayPairProvider);
    c.read(appLinksProvider).add(Uri.parse(fixture.link()));
    await untilGateway(() => c.read(gatewayPairProvider).hasLink);
    final host = await c.read(gatewayPairProvider.notifier).pending();
    expect(host?.id, fixtureGatewayId);
    expect(c.read(gatewayPairProvider).hasLink, isFalse);
    expect(c.read(gatewayPairProvider).host?.binding, c.read(deepClubAccountProvider).binding);
  });
}
