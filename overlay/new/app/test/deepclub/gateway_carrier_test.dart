import 'package:dsh_app/remote/gateway_pairing.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'gateway_fixture.dart';

void main() {
  test('native pair/reconnect preserves RPC names, mux ready, terminal uplink and cancel', () async {
    final fixture = await NativeGatewayFixture.start();
    addTearDown(fixture.close);
    String? saved;
    final pairing = fixture.carrier(
      code: fixturePairCode,
      onPaired: (token) async {
        saved = token;
      },
    );
    await pairing.authenticate();
    expect(saved, fixtureDeviceToken);
    expect(pairing.hostVersion, '0.2.2-rc.1');
    expect(pairing.peerCapabilities, contains('harness.terminal.v1'));
    expect(fixture.requests.single.headers.value('authorization'), isNull);
    expect(fixture.requests.single.headers.value('x-deepclub-session'), isNull);
    expect(fixture.requests.single.headers.value('x-dsh-device-id'), 'android-fixture-install');
    expect(fixture.requests.single.headers.value('sec-websocket-protocol'), contains('dsh-pair.$fixturePairCode'));
    await pairing.close();

    final carrier = fixture.carrier();
    final client = DshClient.withCarrier(carrier);
    addTearDown(client.close);
    final generation = await client.mux.ready(timeout: const Duration(seconds: 3));
    expect(generation.home, '/fixture');
    expect(generation.clientId, startsWith('native-client-'));
    expect(fixture.proofPurposes, ['pair', 'connect']);
    expect(fixture.requests.last.headers.value('authorization'), 'Bearer $fixtureDeviceToken');
    expect(fixture.requests.last.headers.value('x-deepclub-session'), isNull);
    const args = {
      '_request': {'limit': 5},
    };
    expect(await client.rpc.call('session/list', args), args);
    final request = fixture.frames.lastWhere((f) => f['type'] == 'client-request');
    expect(request['method'], 'session/list');
    expect(request['payload'], {'args': args});
    expect(carrier.allowsEndpoint('session/modelCatalog'), isTrue);
    for (final endpoint in ['credentials/set', 'settings/mutate', 'session/models', 'unknown/call']) {
      await expectLater(
        client.rpc.call(endpoint),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'METHOD_NOT_ALLOWED')),
      );
    }
    expect(fixture.frames.where((f) => f['method'] == 'credentials/set'), isEmpty);

    final stream = client.mux.open('terminal/attach', {
      'request': {'terminalId': 'terminal-A'},
    });
    final values = stream.items.toList();
    stream.send({'input': 'fixture input'});
    stream.endUplink();
    expect(await values.timeout(const Duration(seconds: 2)), [
      {'snapshot': 'terminal/attach'},
      {'input': 'fixture input'},
    ]);
    final follow = client.mux.open('workspace/follow', {});
    await follow.items.first;
    await untilGateway(() => fixture.frames.any((f) => f['type'] == 'cancel' && f['streamId'] == follow.streamId));
    expect(fixture.frames.where((f) => f['type'] == 'open' && f['endpoint'] == r'$events'), hasLength(1));
  });

  test('network loss creates a new generation and retires pending approvals', () async {
    final fixture = await NativeGatewayFixture.start();
    addTearDown(fixture.close);
    final client = DshClient.withCarrier(
      fixture.carrier(),
      muxOptions: const MuxOptions(retryCaps: [Duration(milliseconds: 5)]),
    );
    addTearDown(client.close);
    final first = await client.mux.ready();
    fixture.event({
      'type': 'waterfall',
      'event': 'approval/request',
      'eventId': 'approval-A',
      'agentId': 'session-A',
      'request': {'toolName': 'bash', 'callId': 'call-A', 'reason': 'synthetic approval'},
    });
    await untilGateway(() => client.mux.pendingRequests.isNotEmpty);
    final next = client.mux.generations.first;
    await fixture.sockets.last.close(1011, 'temporary service failure');
    final second = await next.timeout(const Duration(seconds: 3));
    expect(second.number, first.number + 1);
    expect(second.clientId, isNot(first.clientId));
    expect(client.mux.pendingRequests, isEmpty);
    expect(fixture.proofPurposes, ['connect', 'connect']);
  });

  test('1008 revocation stops reconnect; a new login cannot revive the token', () async {
    final fixture = await NativeGatewayFixture.start();
    addTearDown(fixture.close);
    final carrier = fixture.carrier();
    final client = DshClient.withCarrier(carrier, muxOptions: const MuxOptions(retryCaps: [Duration(milliseconds: 5)]));
    addTearDown(client.close);
    await client.mux.ready();
    final refused = client.mux.states.firstWhere((s) => s == DshConnectionState.unauthorized);
    await fixture.sockets.last.close(1008, 'authorization revoked');
    await refused.timeout(const Duration(seconds: 3));
    final requests = fixture.requests.length;
    await expectLater(carrier.authenticate(), throwsA(isA<DshCarrierRefusedException>()));
    expect(fixture.requests, hasLength(requests));
    fixture.reject = 403;
    final newLogin = fixture.carrier(binding: 'login-B');
    addTearDown(newLogin.close);
    await expectLater(newLogin.authenticate(), throwsA(isA<DshCarrierRefusedException>()));
  });

  for (final mismatch in ['hostKey', 'gatewayId']) {
    test('hello rejects a mismatched $mismatch before exposing the client', () async {
      final fixture = await NativeGatewayFixture.start();
      addTearDown(fixture.close);
      if (mismatch == 'hostKey') fixture.helloKey = 'sha256:${'b' * 64}';
      if (mismatch == 'gatewayId') fixture.helloId = '87654321-1234-4567-8123-123456789abc';
      final carrier = fixture.carrier();
      addTearDown(carrier.close);
      await expectLater(carrier.authenticate(), throwsA(isA<DshCarrierRefusedException>()));
      expect(carrier.hostVersion, isNull);
      expect(fixture.frames, isEmpty);
    });
  }

  test('close during hello terminates the pending authenticated socket', () async {
    final fixture = await NativeGatewayFixture.start();
    addTearDown(fixture.close);
    fixture.holdHello = true;
    final carrier = fixture.carrier();
    final opening = carrier.authenticate();
    final outcome = expectLater(opening, throwsA(isA<DshException>()));
    await untilGateway(() => fixture.sockets.isNotEmpty);
    await carrier.close();
    await outcome;
    await untilGateway(() => fixture.sockets.single.readyState != 1);
  });

  test('unknown DSH releases retain known chat/read methods without enabling terminal writes', () async {
    final fixture = await NativeGatewayFixture.start();
    addTearDown(fixture.close);
    fixture.helloVersion = '0.3.0-unknown';
    final carrier = fixture.carrier();
    addTearDown(carrier.close);
    await carrier.authenticate();
    expect(carrier.hostVersion, '0.3.0-unknown');
    expect(carrier.allowsEndpoint('session/list'), isTrue);
    expect(carrier.allowsEndpoint('session/modelCatalog'), isTrue);
    expect(carrier.allowsEndpoint('terminal/attach'), isFalse);
    expect(carrier.peerCapabilities, isNot(contains('harness.terminal.v1')));
  });

  for (final version in ['0.2.2-rc.1', '0.3.0-unknown']) {
    test('advertisedAllowlist intersects actual SDK permission/agent RPCs on $version', () async {
      final fixture = await NativeGatewayFixture.start();
      addTearDown(fixture.close);
      fixture.helloVersion = version;
      fixture.advertisedUnary.addAll([
        'permission/catalog',
        'agent-preset-registry/list',
        'agent-preset-registry/select',
        'credentials/set',
        'settings/mutate',
      ]);
      final carrier = fixture.carrier();
      final client = DshClient.withCarrier(carrier);
      addTearDown(client.close);
      await carrier.authenticate();
      for (final endpoint in ['permissionPresets/catalog', 'agentPresets/list']) {
        expect(carrier.allowsEndpoint(endpoint), isTrue);
        expect(await client.rpc.call(endpoint), isEmpty);
      }
      expect(carrier.allowsEndpoint('agentPresets/select'), version == '0.2.2-rc.1');
      if (version == '0.2.2-rc.1') {
        await client.rpc.call('agentPresets/select', {'sessionId': 's', 'presetId': 'p'});
      }
      for (final endpoint in [
        'permission/catalog',
        'agent-preset-registry/list',
        'agent-preset-registry/select',
        'credentials/set',
        'settings/mutate',
      ]) {
        expect(carrier.allowsEndpoint(endpoint), isFalse);
      }
      expect(fixture.frames.where((f) => f['method'] == 'permission/catalog'), isEmpty);
      // A known safe method is still denied if this peer did not advertise it.
      expect(carrier.allowsEndpoint('workspace/create'), isFalse);
    });
  }

  test('relay classification is restricted to the fixed DeepClub WSS endpoint', () {
    expect(isGatewayRelay(Uri.parse('wss://deepclub.net/ws/mobile/$fixtureGatewayId')), isTrue);
    for (final url in [
      'ws://deepclub.net/ws/mobile',
      'wss://deepclub.net:8443/ws/mobile',
      'wss://deepclub.net.evil.invalid/ws/mobile',
      'ws://192.168.1.5/ws/mobile',
    ]) {
      expect(isGatewayRelay(Uri.parse(url)), isFalse);
    }
  });
}
