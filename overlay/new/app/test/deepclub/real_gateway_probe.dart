// Opt-in actual desktop gateway + actual DSH Host with synthetic authority.
// DEEPCLUB_GATEWAY_INFO points to mobile-native-fixture.mjs stateFile.
// flutter test --no-pub test/deepclub/real_gateway_probe.dart
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/remote/gateway_carrier.dart';
import 'package:dsh_app/remote/gateway_pairing.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  test('actual desktop advertised RPCs, mux generation, workspace and files through Android carrier', () async {
    final info = jsonDecode(File(Platform.environment['DEEPCLUB_GATEWAY_INFO']!).readAsStringSync()) as Map;
    // Refresh an expired QR directly on the isolated fixture's management API.
    final pairReply = await http.post(
      Uri.parse('${info['webOrigin']}/mgw/pair'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'publicUrl': info['lanUrl']}),
    );
    expect(pairReply.statusCode, 201);
    final payload = Map<String, dynamic>.from((jsonDecode(pairReply.body) as Map)['payload'] as Map);
    final host = GatewayHost(
      id: payload['gatewayId'] as String,
      name: 'Synthetic desktop',
      hostKey: payload['hostKey'] as String,
      binding: 'synthetic-session',
      endpoints: [Uri.parse(info['lanUrl'] as String)],
    );
    String? saved;
    GatewayCarrier connect({bool pair = false}) => GatewayCarrier(
      host: host,
      deviceId: () async => 'fixture-android-001',
      assertion: (purpose) async {
        final reply = await http.post(
          Uri.parse('${info['authorityOrigin']}/api/client/remote/assertion'),
          headers: {'authorization': 'Bearer fixture-phone', 'content-type': 'application/json'},
          body: jsonEncode({'gateway_id': host.id, 'host_key': host.hostKey, 'purpose': purpose}),
        );
        expect(reply.statusCode, 200);
        return ((jsonDecode(reply.body) as Map)['data'] as Map)['assertion'] as String;
      },
      loadToken: () async => saved,
      relaySession: () => throw StateError('LAN must never request a phone session'),
      pairingCode: pair ? payload['pairingCode'] as String : null,
      onPaired: (token) async => saved = token,
    );
    final pairing = connect(pair: true);
    await pairing.authenticate();
    expect(saved, isNotEmpty);
    await pairing.close();
    final carrier = connect();
    final client = DshClient.withCarrier(carrier);
    addTearDown(client.close);
    final generation = await client.mux.ready();
    expect(generation.clientId, isNotEmpty);
    for (final endpoint in ['permissionPresets/catalog', 'agentPresets/list', 'agentPresets/select']) {
      expect(carrier.allowsEndpoint(endpoint), isTrue, reason: endpoint);
    }
    final created = Map<String, dynamic>.from(
      await client.rpc.call('session/create', {
        'request': {'cwd': info['workspace']},
      }) as Map,
    );
    final session = created['sessionId'] as String;
    expect(await client.rpc.call('permissionPresets/catalog'), isNotNull);
    expect(await client.rpc.call('agentPresets/list'), isNotNull);
    await client.rpc.call('agentPresets/select', {'agentId': session, 'agentPreset': 'standard'});
    await client.rpc.call('workspaceFiles/list', {'workspaceFileScopeId': session, 'path': '.'});
    final text = await client.rpc.call('workspaceFiles/read', {
      'workspaceFileScopeId': session,
      'path': 'hello.txt',
      'range': {'offset': 1, 'limit': 10},
    });
    expect(jsonEncode(text), contains('DeepClub real native gateway fixture'));
    for (final endpoint in ['credentials/get', 'permission/catalog', 'agent-preset-registry/list']) {
      await expectLater(
        client.rpc.call(endpoint),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'METHOD_NOT_ALLOWED')),
      );
    }
  });
}
