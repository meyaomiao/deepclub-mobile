import 'package:dsh_app/deepclub/account_state.dart';
import 'package:dsh_app/deepclub/agent_config.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../packages/dsh_client/test/support/fake_dsh.dart';

class _LocalConnection extends LocalConnectionController {
  _LocalConnection(this.connection);
  final HostConnection connection;
  @override
  Future<HostConnection?> build() async => connection;
}

void main() {
  test('production local engine provider ignores an active remote host', () async {
    final local = await FakeDsh.start(), remote = await FakeDsh.start();
    final localClient = await DshClient.connect(baseUri: local.baseUri, token: FakeDsh.token, startMux: false);
    final remoteClient = await DshClient.connect(baseUri: remote.baseUri, token: FakeDsh.token, startMux: false);
    local.handlers['credentials/set'] = (_) => {'ok': true};
    remote.handlers['credentials/set'] = (_) => {'ok': true};
    final container = ProviderContainer(
      overrides: [
        localConnectionProvider.overrideWith(
          () => _LocalConnection(HostConnection(client: localClient, isLocal: true)),
        ),
        activeConnectionProvider.overrideWithValue(AsyncData(HostConnection(client: remoteClient, isLocal: false))),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await localClient.close();
      await remoteClient.close();
      await local.close();
      await remote.close();
    });
    await container.read(localConnectionProvider.future);
    final engine = container.read(deepClubLocalEngineProvider);
    expect(engine, isA<LocalDeepClubEngine>());
    await engine!.setKey('synthetic-key');
    expect(local.rpcCalls.where((c) => c['method'] == 'credentials/set'), hasLength(1));
    expect(remote.rpcCalls, isEmpty);
  });
}
