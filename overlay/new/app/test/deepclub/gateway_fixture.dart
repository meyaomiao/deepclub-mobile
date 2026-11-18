// Synthetic native protocol peer for carrier/state regressions. This is not
// the desktop implementation; the separate desktop probe covers actual wire.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/remote/gateway_carrier.dart';
import 'package:dsh_app/remote/gateway_pairing.dart';

const fixtureGatewayId = '12345678-1234-4567-8123-123456789abc';
final fixtureHostKey = 'sha256:${'a' * 64}';
final fixturePairCode = 'c' * 43;
final fixtureDeviceToken = 't' * 43;
// Backend phone sessions use 36 bytes / standard Base64, including + and /.
final fixturePhoneSession = '+///' * 12;

class NativeGatewayFixture {
  NativeGatewayFixture._(this.server, this.gatewayId);
  final HttpServer server;
  final String gatewayId;
  final sockets = <WebSocket>[];
  final requests = <HttpRequest>[];
  final frames = <Map<String, dynamic>>[];
  final _events = <WebSocket, String>{};
  bool paired = false;
  int? reject;
  String? helloKey, helloId;
  String helloVersion = '0.2.2-rc.1';
  bool holdHello = false;
  // A real terminal snapshot for `terminal/attach`; its uplink is recorded in
  // [frames] but not echoed, as a Host does not return input items.
  Map<String, Object?>? attachSnapshot;
  final _silentStreams = <Object?>{};
  // Same advertisedAllowlist shape as the native desktop hello, independent of
  // the phone's supported methods. Tests can narrow or extend it explicitly.
  List<String> advertisedUnary = [
    r'$events/result',
    'session/list',
    'session/modelCatalog',
    'workspaceFiles/read',
    'permissionPresets/catalog',
    'agentPresets/list',
    'agentPresets/select',
  ];
  int assertions = 0;
  final proofPurposes = <String>[];
  final opened = StreamController<WebSocket>.broadcast();
  static Future<NativeGatewayFixture> start({String id = fixtureGatewayId}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = NativeGatewayFixture._(server, id);
    server.listen(fixture._accept);
    return fixture;
  }

  GatewayHost host({String binding = 'login-A'}) => GatewayHost(
    id: gatewayId,
    name: 'Fixture computer',
    hostKey: fixtureHostKey,
    binding: binding,
    endpoints: [Uri.parse('ws://127.0.0.1:${server.port}/ws/mobile')],
  );
  Map<String, Object?> qr({DateTime? now}) => {
    'version': 2,
    'gatewayId': gatewayId,
    'gatewayName': 'Fixture computer',
    'hostKey': fixtureHostKey,
    'protocols': [GatewayPairing.protocol],
    'pairingCode': fixturePairCode,
    'expiresAt': (now ?? DateTime.now()).add(const Duration(minutes: 5)).millisecondsSinceEpoch,
    'endpoints': host().endpoints.map((e) => e.toString()).toList(),
    'publicUrl': 'wss://deepclub.net/ws/mobile/$gatewayId',
  };
  String link({Map<String, Object?>? data}) =>
      'https://deepclub.net/pair#${base64UrlEncode(utf8.encode(jsonEncode(data ?? qr()))).replaceAll('=', '')}';
  GatewayCarrier carrier({
    String? code,
    Future<void> Function(String)? onPaired,
    String binding = 'login-A',
    Duration timeout = const Duration(seconds: 2),
  }) => GatewayCarrier(
    host: host(binding: binding),
    deviceId: () async => 'android-fixture-install',
    assertion: (purpose) async {
      proofPurposes.add(purpose);
      return '${++assertions}'.padLeft(43, 'p');
    },
    loadToken: () async => fixtureDeviceToken,
    relaySession: () => throw StateError('LAN must not read the phone session'),
    pairingCode: code,
    onPaired: onPaired,
    timeout: timeout,
  );
  Future<void> _accept(HttpRequest request) async {
    requests.add(request);
    final offered = request.headers.value('sec-websocket-protocol') ?? '';
    final pairing = offered.split(',').map((v) => v.trim()).contains('dsh-pair.$fixturePairCode');
    final valid =
        request.headers.value('x-deepclub-host-key') == fixtureHostKey &&
        request.headers.value('x-deepclub-assertion') != null &&
        (pairing ? !paired : request.headers.value('authorization') == 'Bearer $fixtureDeviceToken');
    if (reject != null || !valid) {
      request.response.statusCode = reject ?? 403;
      await request.response.close();
      return;
    }
    final socket = await WebSocketTransformer.upgrade(
      request,
      protocolSelector: (protocols) => protocols.contains(GatewayPairing.protocol) ? GatewayPairing.protocol : null,
    );
    sockets.add(socket);
    socket.listen((raw) => _receive(socket, raw), onDone: () => _events.remove(socket));
    if (pairing) {
      paired = true;
      socket.add(
        jsonEncode({
          'kind': 'paired',
          'token': fixtureDeviceToken,
          'device': {'id': 'android-fixture-install', 'name': 'DeepClub Android'},
          'gatewayId': gatewayId,
          'gatewayName': 'Fixture computer',
        }),
      );
    }
    if (!holdHello) {
      socket.add(
        jsonEncode({
          'kind': 'hello',
          'protocol': GatewayPairing.protocol,
          'gatewayId': helloId ?? gatewayId,
          'hostKey': helloKey ?? fixtureHostKey,
          'protocols': [GatewayPairing.protocol],
          'dshVersion': helloVersion,
          'capabilities': ['harness.terminal.v1'],
          'allowlist': {
            'unary': advertisedUnary,
            'stream': [r'$events', 'workspace/follow', 'session/follow', 'terminal/attach'],
          },
        }),
      );
    }
    opened.add(socket);
  }

  void _receive(WebSocket socket, Object? raw) {
    final frame = Map<String, dynamic>.from(jsonDecode(raw as String) as Map);
    frames.add(frame);
    final id = frame['streamId'];
    if (frame['type'] == 'client-request') {
      socket.add(
        jsonEncode({
          'type': 'server-response',
          'rpcId': frame['rpcId'],
          'result': {'ok': true, 'value': frame['payload']['args']},
        }),
      );
    } else if (frame['type'] == 'open' && frame['endpoint'] == r'$events') {
      _events[socket] = id as String;
      socket.add(
        jsonEncode({
          'type': 'item',
          'streamId': id,
          'value': {
            'type': 'ready',
            'clientId': 'native-client-${sockets.length}',
            'host': {'home': '/fixture'},
          },
        }),
      );
    } else if (frame['type'] == 'open' && frame['endpoint'] == 'terminal/attach' && attachSnapshot != null) {
      _silentStreams.add(id);
      socket.add(jsonEncode({'type': 'item', 'streamId': id, 'value': attachSnapshot}));
    } else if (frame['type'] == 'open') {
      socket.add(
        jsonEncode({
          'type': 'item',
          'streamId': id,
          'value': {'snapshot': frame['endpoint']},
        }),
      );
    } else if (frame['type'] == 'item' && !_silentStreams.contains(id)) {
      socket.add(jsonEncode({'type': 'item', 'streamId': id, 'value': frame['value']}));
    } else if (frame['type'] == 'end') {
      socket.add(jsonEncode({'type': 'end', 'streamId': id}));
    }
  }

  void event(Map<String, Object?> value) {
    for (final entry in _events.entries) {
      entry.key.add(jsonEncode({'type': 'item', 'streamId': entry.value, 'value': value}));
    }
  }

  Future<void> close() async {
    for (final socket in sockets) {
      await socket.close(1000, 'fixture finished');
    }
    await server.close(force: true);
    await opened.close();
  }
}

Future<void> untilGateway(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 4));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) throw StateError('Synthetic gateway condition timed out');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
