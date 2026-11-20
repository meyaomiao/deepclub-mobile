import 'dart:async';

import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Link implements HostLink {
  final _statuses = StreamController<HostLinkStatus>.broadcast();
  @override
  HostLinkStatus status = const HostLinkStatus(HostLinkPhase.connecting);
  @override
  Stream<HostLinkStatus> get statuses => _statuses.stream;
  void connected(RelayPath path) {
    status = HostLinkStatus(HostLinkPhase.connected, path: path);
    _statuses.add(status);
  }

  @override
  Future<void> close() => _statuses.close();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final path in [RelayPath.lan, RelayPath.relay]) {
    test('publishes ${path.name} when the host connects during the initial status read', () async {
      const host = HostRef.gateway('task-gateway');
      final link = _Link();
      final container = ProviderContainer(overrides: [hostLinkProvider(host).overrideWithValue(link)]);
      addTearDown(() async {
        container.dispose();
        await link.close();
      });
      final provider = hostLinkStatusProvider(host);
      final subscription = container.listen(provider, (_, value) {
        if (value.value?.phase == HostLinkPhase.connecting) link.connected(path);
      });
      addTearDown(subscription.close);
      await Future<void>.delayed(Duration.zero);
      final view = container.read(provider).requireValue;
      expect(view.phase, HostLinkPhase.connected);
      expect(view.path, path);
    });
  }
}
