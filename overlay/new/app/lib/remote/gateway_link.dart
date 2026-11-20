import 'dart:async';

import 'package:dsh_client/dsh_client.dart';

import '../l10n/l10n.dart';
import 'gateway_carrier.dart';
import 'link_status.dart';

/// The client survives network loss; its mux creates a fresh generation and
/// retires pending approvals. Host selection owns and closes this whole link.
class GatewayHostLink implements HostLink {
  GatewayHostLink(this.carrier, {Stream<void>? kicks}) {
    _kicks = kicks?.listen((_) => kick());
  }
  final GatewayCarrier carrier;
  final _statuses = StreamController<HostLinkStatus>.broadcast();
  StreamSubscription<void>? _kicks;
  StreamSubscription<DshConnectionState>? _mux;
  DshClient? _client;
  bool _closed = false;
  HostLinkStatus _status = HostLinkStatus.idle;
  Future<DshClient>? _opening;
  @override
  HostLinkStatus get status => _status;
  @override
  Stream<HostLinkStatus> get statuses => _statuses.stream;
  @override
  Stream<DshClient> get clients => const Stream.empty();
  @override
  DshClient? get currentClient => _status.isConnected ? _client : null;
  void _publish(HostLinkStatus value) {
    _status = value;
    if (!_statuses.isClosed) _statuses.add(value);
  }

  @override
  Future<DshClient> open() async {
    if (_closed) throw const DshClosedException();
    if (_opening case final opening?) return opening;
    final opening = _open();
    _opening = opening;
    try {
      return await opening;
    } finally {
      if (identical(_opening, opening)) _opening = null;
    }
  }

  Future<DshClient> _open() async {
    _publish(const HostLinkStatus(HostLinkPhase.connecting, step: HostLinkStep.connect));
    final client = _client ??= DshClient.withCarrier(carrier);
    _mux ??= client.mux.states.listen((value) {
      final phase = switch (value) {
        DshConnectionState.connected => HostLinkPhase.connected,
        DshConnectionState.unauthorized => HostLinkPhase.failed,
        DshConnectionState.reconnecting => HostLinkPhase.reconnecting,
        DshConnectionState.closed || DshConnectionState.idle => HostLinkPhase.idle,
        _ => HostLinkPhase.connecting,
      };
      final failure = client.mux.lastError;
      final refused = failure is DshCarrierRefusedException ? failure.code : null;
      _publish(
        HostLinkStatus(
          phase,
          error: phase == HostLinkPhase.failed
              ? HostLinkError(
                  HostLinkErrorKind.authFailed,
                  refused == 'PROTOCOL_MISMATCH' ? appL10n.deepClubGatewayIncompatible : appL10n.deepClubGatewayRevoked,
                  diagnosticCode: refused == 'PROTOCOL_MISMATCH'
                      ? HostLinkDiagnosticCode.remoteProtocolMismatch
                      : HostLinkDiagnosticCode.remoteDeviceRevoked,
                )
              : null,
        ),
      );
    });
    try {
      await client.mux.ready(timeout: const Duration(seconds: 40));
      return client;
    } on DshException {
      if (client.mux.state != DshConnectionState.unauthorized) {
        throw HostLinkError(HostLinkErrorKind.hostOffline, appL10n.deepClubGatewayOffline, retryable: true);
      }
      throw HostLinkError(HostLinkErrorKind.authFailed, appL10n.deepClubGatewayRevoked);
    }
  }

  @override
  void kick() {
    // Unauthorized is terminal until a new QR creates a new carrier.
    final mux = _client?.mux;
    if (!_closed &&
        mux != null &&
        mux.state != DshConnectionState.unauthorized &&
        mux.state != DshConnectionState.connected) {
      mux.reconnect();
    }
  }

  @override
  void retry() => kick();
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _kicks?.cancel();
    await _mux?.cancel();
    await _client?.close();
    await carrier.close();
    await _statuses.close();
  }
}
