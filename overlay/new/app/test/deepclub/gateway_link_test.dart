import 'package:dsh_app/deepclub/client_api.dart';
import 'package:dsh_app/remote/gateway_carrier.dart';
import 'package:dsh_app/remote/gateway_link.dart';
import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'gateway_fixture.dart';

void main() {
  test('repeated open retains actual connected mux status and selected route', () async {
    final fixture = await NativeGatewayFixture.start();
    final carrier = fixture.carrier();
    final link = GatewayHostLink(carrier);
    addTearDown(() async {
      await link.close();
      await fixture.close();
    });
    final first = await link.open();
    expect(link.status.phase, HostLinkPhase.connected);
    expect(link.status.path, RelayPath.lan);
    expect(carrier.route, GatewayRoute.lan);
    expect(await link.open(), same(first));
    expect(link.status.phase, HostLinkPhase.connected, reason: 'a reused mux does not emit another connected event');
    expect(link.status.path, RelayPath.lan);
    expect(fixture.sockets, hasLength(1));
    await link.close();
    expect(carrier.route, isNull);
  });

  for (final code in ['rate_limited', 'remote_identity_denied']) {
    test('$code is preserved before any Host socket or relay session is used', () async {
      final fixture = await NativeGatewayFixture.start();
      addTearDown(fixture.close);
      var relayReads = 0;
      final carrier = GatewayCarrier(
        host: fixture.host(),
        deviceId: () async => 'android-fixture-install',
        assertion: (_) async => throw DeepClubFailure(code, status: code == 'rate_limited' ? 429 : 403),
        loadToken: () async => fixtureDeviceToken,
        relaySession: () {
          relayReads++;
          return fixturePhoneSession;
        },
      );
      addTearDown(carrier.close);
      await expectLater(
        carrier.authenticate(),
        throwsA(
          code == 'rate_limited'
              ? isA<DeepClubFailure>().having((e) => e.code, 'code', code)
              : isA<DshCarrierRefusedException>().having((e) => e.code, 'code', code),
        ),
      );
      expect(fixture.requests, isEmpty);
      expect(relayReads, 0);
    });
  }
}
