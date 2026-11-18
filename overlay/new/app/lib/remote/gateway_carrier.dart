import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';

import '../deepclub/client_api.dart';
import '../deepclub/secure_store.dart' show secureDeviceId;
import 'gateway_pairing.dart';

/// Safe route metadata; never exposes an endpoint, account proof or token.
enum GatewayRoute { lan, relay }

// Intersect desktop-advertised support with this client's known protocol. An
// unknown release cannot opt the phone into settings or credential management.
const _nativeUnary = {
  r'$events/result',
  'session/list',
  'session/search',
  'session/create',
  'session/selectModel',
  'session/modelCatalog',
  'session/rename',
  'session/fork',
  'session/prompt',
  'session/attachment',
  'session/updateQueue',
  'session/cancel',
  'session/page',
  'session/projections',
  'workspace/create',
  'workspace/rename',
  'workspace/delete',
  'workspace/insertBefore',
  'workspace/insertSessionBefore',
  'workspace/archiveSession',
  'workspace/unarchiveSession',
  'workspace/pinSession',
  'workspace/unpinSession',
  'directoryPicker/list',
  'directoryPicker/createDirectory',
  'workspaceFiles/list',
  'workspaceFiles/stat',
  'workspaceFiles/read',
  'workspaceFiles/readBytes',
  'fileReferences/list',
  'terminal/environment',
  'terminal/shells',
  'terminal/list',
  'terminal/create',
  'terminal/rename',
  'terminal/close',
  'permissionPresets/catalog',
  'agentPresets/list',
  'agentPresets/select',
};
const _nativeStreams = {
  r'$events',
  'session/follow',
  'session/control',
  'workspace/follow',
  'workspaceFiles/changes',
  'terminal/retain',
  'terminal/attach',
};

// DSH releases whose gated contracts (workspace, directory picker, terminal,
// permission/agent presets) were checked against this client. rc.3 adds
// optional terminal origin/control/sandboxMode fields, which parsing ignores,
// and an optional `typed` write flag; earlier releases validate a closed
// write shape. Any other release keeps the restricted chat/read set below.
const _validatedHostVersions = <String, ({bool typedTerminalInput})>{
  '0.2.2-alpha.2': (typedTerminalInput: false),
  '0.2.2-rc.1': (typedTerminalInput: false),
  '0.2.2-rc.3': (typedTerminalInput: true),
};

const _compatibleChatReads = {
  r'$events/result',
  'session/list',
  'session/search',
  'session/create',
  'session/selectModel',
  'session/modelCatalog',
  'session/rename',
  'session/fork',
  'session/prompt',
  'session/attachment',
  'session/updateQueue',
  'session/cancel',
  'session/page',
  'session/projections',
  'directoryPicker/list',
  'workspaceFiles/list',
  'workspaceFiles/stat',
  'workspaceFiles/read',
  'workspaceFiles/readBytes',
  'fileReferences/list',
  'permissionPresets/catalog',
  'agentPresets/list',
};

/// The desktop forwards native Typert/mux envelopes without translating them.
/// DshMux owns generations, stream resync and approval lifetime.
class GatewayCarrier extends DshCarrier {
  GatewayCarrier({
    required this.host,
    required this.deviceId,
    required this.assertion,
    required this.loadToken,
    required this.relaySession,
    this.pairingCode,
    this.onPaired,
    this.onRefused,
    this.timeout = const Duration(seconds: 12),
  });

  final GatewayHost host;
  final Future<String> Function() deviceId;
  final Future<String> Function(String purpose) assertion;
  final Future<String?> Function() loadToken;
  final String Function() relaySession;
  final String? pairingCode;
  final Future<void> Function(String token)? onPaired;
  final void Function(String code)? onRefused;
  final Duration timeout;
  _GatewaySocket? _socket, _authenticating;
  Future<_GatewaySocket>? _opening;
  bool _closed = false;
  DshCarrierRefusedException? _refused;
  String? _version;
  GatewayRoute? _route;
  GatewayRoute? get route => _socket == null ? null : _route;
  Set<String>? _capabilities, _allowlist;

  @override
  String get kind => GatewayPairing.protocol;
  @override
  String? get hostVersion => _socket == null ? null : _version;
  @override
  Set<String>? get peerCapabilities => _socket == null ? null : _capabilities;
  @override
  bool get acceptsTypedTerminalInput =>
      _socket != null && (_validatedHostVersions[_version]?.typedTerminalInput ?? false);
  @override
  DshTracer? get tracer => null;
  @override
  bool allowsEndpoint(String endpoint) => _allowlist?.contains(endpoint) ?? false;

  Future<void> authenticate() async => _ensure();

  Future<_GatewaySocket> _ensure() async {
    if (_closed) throw const DshClosedException();
    if (_refused case final error?) throw error;
    if (_socket case final socket?) return socket;
    if (_opening case final opening?) return opening;
    final opening = _connect();
    _opening = opening;
    try {
      return await opening;
    } on DeepClubFailure catch (error) {
      if (error.code == 'rate_limited') rethrow;
      if (error.invalidSession || error.code == 'login_required') {
        _refuse('DEVICE_REVOKED');
        throw _refused!;
      }
      throw const DshTransportException('Account verification is unavailable');
    } on DshException {
      rethrow;
    } catch (_) {
      throw const DshTransportException('Saved computer authorization is unavailable');
    } finally {
      if (identical(_opening, opening)) _opening = null;
    }
  }

  void _refuse(String code) {
    _refused ??= DshCarrierRefusedException(code, 'Computer authorization requires a new pairing');
    onRefused?.call(code);
  }

  Future<_GatewaySocket> _connect() async {
    final code = pairingCode;
    final token = code == null ? await loadToken() : null;
    if (code == null && (token == null || token.isEmpty)) {
      _refuse('DEVICE_REVOKED');
      throw _refused!;
    }
    final installation = await deviceId();
    for (final endpoint in host.endpoints) {
      _GatewaySocket? physical;
      try {
        // Each attempt needs a new one-use assertion, even after a LAN failure.
        final proof = await assertion(code == null ? 'connect' : 'pair');
        if (_closed) throw const DshClosedException();
        final socket = await WebSocket.connect(
          endpoint.toString(),
          protocols: [GatewayPairing.protocol, if (code != null) 'dsh-pair.$code'],
          headers: {
            if (token != null) 'Authorization': 'Bearer $token',
            'X-DSH-Device-ID': installation,
            'X-DSH-Device-Name': base64Encode(utf8.encode('DeepClub Android')),
            'X-DeepClub-Assertion': proof,
            'X-DeepClub-Host-Key': host.hostKey,
            if (isGatewayRelay(endpoint)) 'X-DeepClub-Session': relaySession(),
          },
        ).timeout(timeout);
        if (_closed) {
          await socket.close(1000, 'client closed');
          throw const DshClosedException();
        }
        physical = _authenticating = _GatewaySocket(
          socket,
          onLost: (lost) {
            if (identical(_socket, lost)) _socket = null;
            if (lost.socket.closeCode == 1008) _refuse('DEVICE_REVOKED');
          },
        );
        final hello = await physical.hello.future.timeout(timeout);
        if (socket.protocol != GatewayPairing.protocol ||
            hello['protocol'] != GatewayPairing.protocol ||
            hello['gatewayId'] != host.id ||
            hello['hostKey'] != host.hostKey) {
          _refuse(hello['hostKey'] != host.hostKey ? 'PEER_IDENTITY_MISMATCH' : 'PROTOCOL_MISMATCH');
          throw _refused!;
        }
        final version = hello['dshVersion'];
        final capabilities = _strings(hello['capabilities']);
        final allowlist = hello['allowlist'];
        final unary = allowlist is Map ? _strings(allowlist['unary']) : null;
        final streams = allowlist is Map ? _strings(allowlist['stream']) : null;
        if (version is! String ||
            version.isEmpty ||
            capabilities == null ||
            unary == null ||
            streams == null ||
            !streams.contains(r'$events')) {
          _refuse('PROTOCOL_MISMATCH');
          throw _refused!;
        }
        if (code != null) {
          final paired = await physical.paired.future.timeout(timeout);
          final deviceToken = paired['token'];
          if (paired['gatewayId'] != host.id ||
              deviceToken is! String ||
              !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(deviceToken) ||
              onPaired == null) {
            throw const DshProtocolException('Invalid paired response');
          }
          await onPaired!(deviceToken);
        }
        if (_closed || physical.ended) throw const DshClosedException();
        _version = version;
        final knownVersion = _validatedHostVersions.containsKey(version);
        _capabilities = knownVersion ? capabilities : capabilities.difference({'harness.terminal.v1'});
        final safeUnary = unary.intersection(knownVersion ? _nativeUnary : _compatibleChatReads);
        final safeStreams = streams.intersection(
          knownVersion ? _nativeStreams : _nativeStreams.difference({'terminal/retain', 'terminal/attach'}),
        );
        _allowlist = {...safeUnary, ...safeStreams};
        physical.streams = safeStreams;
        _route = isGatewayRelay(endpoint) ? GatewayRoute.relay : GatewayRoute.lan;
        _socket = physical;
        _authenticating = null;
        return physical;
      } on DeepClubFailure catch (error) {
        await physical?.close(1000, 'authorization failed');
        if (error.code == 'rate_limited') rethrow;
        if (error.code == 'remote_identity_denied') {
          _refuse(error.code);
          throw _refused!;
        }
        if (error.invalidSession || error.code == 'login_required') {
          _refuse('DEVICE_REVOKED');
          throw _refused!;
        }
        throw const DshTransportException('Account verification is unavailable');
      } on DshCarrierRefusedException {
        await physical?.close(1000, 'authorization refused');
        rethrow;
      } on WebSocketException catch (error) {
        await physical?.close(1000, 'connect failed');
        if (error.httpStatusCode == 401 || error.httpStatusCode == 403) {
          _refuse('DEVICE_REVOKED');
          throw _refused!;
        }
      } on DshClosedException {
        await physical?.close(1000, 'client closed');
        rethrow;
      } catch (_) {
        await physical?.close(1000, 'connect failed');
        if (_refused case final error?) throw error;
      } finally {
        if (identical(_authenticating, physical)) _authenticating = null;
      }
    }
    throw const DshTransportException('Computer is offline');
  }

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    final socket = await _ensure();
    if (!allowsEndpoint(endpoint)) {
      return const RpcError(DshRemoteException('METHOD_NOT_ALLOWED', 'Endpoint is unavailable on this computer'));
    }
    return socket.call(endpoint, args, timeout ?? const Duration(seconds: 30));
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) async {
    final socket = await _ensure();
    socket.socket.pingInterval = options.pingInterval;
    return socket;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _authenticating?.close(1000, 'client closed');
    await _socket?.close(1000, 'client closed');
    _socket = null;
  }
}

Set<String>? _strings(Object? value) =>
    value is List && value.every((e) => e is String) ? value.cast<String>().toSet() : null;

class _GatewaySocket implements DshMuxLink {
  _GatewaySocket(this.socket, {required this.onLost}) {
    // Pair/hello can arrive before DshMux.start; subscribe immediately.
    socket.listen(_receive, onDone: _lost, onError: (Object _) => _lost());
    paired.future.ignore();
    hello.future.ignore();
  }
  final WebSocket socket;
  final void Function(_GatewaySocket socket) onLost;
  final hello = Completer<Map<String, Object?>>();
  final paired = Completer<Map<String, Object?>>();
  final _pending = <String, Completer<RpcResult>>{};
  Set<String> streams = const {};
  DshMuxFrameHandler? _frame;
  DshMuxLossHandler? _loss;
  bool _ended = false;
  bool get ended => _ended;

  void _receive(dynamic raw) {
    if (_ended) return;
    try {
      if (raw is! String || raw.length > 16 * 1024 * 1024) throw const FormatException();
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      final value = Map<String, Object?>.from(decoded);
      if (value['kind'] == 'paired') {
        if (!paired.isCompleted) paired.complete(value);
      } else if (value['kind'] == 'hello') {
        if (!hello.isCompleted) hello.complete(value);
      } else if (value['type'] == 'server-response') {
        final waiter = _pending[value['rpcId']];
        if (waiter == null) return;
        final result = value['result'];
        if (result is! Map || result['ok'] is! bool) throw const FormatException();
        _pending.remove(value['rpcId']);
        waiter.complete(
          result['ok'] == true ? RpcOk(result['value']) : RpcError(DshRemoteException.fromJson(result['error'])),
        );
      } else if (const {'item', 'end', 'error'}.contains(value['type']) && value['streamId'] is String) {
        _frame?.call(value);
      } else {
        throw const FormatException();
      }
    } catch (_) {
      _lost();
      unawaited(socket.close(4002, 'invalid native frame'));
    }
  }

  void _lost() {
    if (_ended) return;
    _ended = true;
    const error = DshCarrierLostException('Computer connection ended');
    if (!hello.isCompleted) hello.completeError(error);
    if (!paired.isCompleted) paired.completeError(error);
    for (final waiter in _pending.values) {
      if (!waiter.isCompleted) waiter.completeError(error);
    }
    _pending.clear();
    onLost(this);
    _loss?.call(error, null);
  }

  Future<RpcResult> call(String endpoint, Map<String, Object?> args, Duration timeout) async {
    final id = secureDeviceId();
    final waiter = Completer<RpcResult>();
    _pending[id] = waiter;
    try {
      _send({
        'type': 'client-request',
        'rpcId': id,
        'method': endpoint,
        'payload': {'args': args},
      });
      return await waiter.future.timeout(
        timeout,
        onTimeout: () => throw const DshTransportException('Computer request timed out'),
      );
    } finally {
      _pending.remove(id);
    }
  }

  void _send(Map<String, Object?> frame) {
    if (_ended) throw const DshCarrierLostException('Computer connection ended');
    socket.add(jsonEncode(frame));
  }

  @override
  void start({required DshMuxFrameHandler onFrame, required DshMuxLossHandler onLost}) {
    _frame = onFrame;
    _loss = onLost;
    if (_ended) onLost(const DshCarrierLostException('Computer connection ended'), null);
  }

  @override
  void open(String streamId, String endpoint, Map<String, Object?> payload) {
    if (!streams.contains(endpoint)) {
      _frame?.call({
        'type': 'error',
        'streamId': streamId,
        'error': {'code': 'METHOD_NOT_ALLOWED', 'message': 'Stream is unavailable on this computer'},
      });
      return;
    }
    _send({'type': 'open', 'streamId': streamId, 'endpoint': endpoint, 'payload': payload});
  }

  @override
  void sendItem(String streamId, Object? value) => _send({'type': 'item', 'streamId': streamId, 'value': value});
  @override
  void endUplink(String streamId) => _send({'type': 'end', 'streamId': streamId});
  @override
  void cancel(String streamId) => _send({'type': 'cancel', 'streamId': streamId});
  @override
  Future<void> close(int code, String reason) async {
    if (_ended) return;
    _lost();
    await socket.close(code, reason);
  }
}
