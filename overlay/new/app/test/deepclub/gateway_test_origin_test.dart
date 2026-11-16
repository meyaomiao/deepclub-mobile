import 'package:dsh_app/deepclub/client_api.dart';
import 'package:dsh_app/remote/gateway_pairing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'gateway_fixture.dart';

void main() {
  test('relay credentials are limited to the selected service origin and gateway path', () {
    final origin = Uri.parse(deepClubServiceOrigin);
    final relay = origin.replace(scheme: origin.scheme == 'https' ? 'wss' : 'ws', path: '/ws/mobile/$fixtureGatewayId');
    expect(isGatewayRelay(relay), isTrue);
    expect(gatewayEndpoint(relay.toString(), fixtureGatewayId), relay);
    for (final untrusted in [
      relay.replace(port: origin.port + 1),
      relay.replace(host: 'deepclub.net.evil.invalid'),
      relay.replace(userInfo: 'phone-session'),
      relay.replace(query: 'token=secret'),
      relay.replace(fragment: 'secret'),
      relay.replace(path: '/ws/mobile'),
      relay.replace(path: '/ws/mobile/not-a-gateway'),
      relay.replace(scheme: relay.scheme == 'ws' ? 'wss' : 'ws'),
    ]) {
      expect(isGatewayRelay(untrusted), isFalse);
    }
    expect(isGatewayRelay(Uri.parse('ws://10.0.2.2:18342/ws/mobile')), isFalse);
    if (origin.host == '10.0.2.2') {
      expect(origin.toString(), 'http://10.0.2.2:18340');
      expect(isGatewayRelay(Uri.parse('wss://deepclub.net/ws/mobile/$fixtureGatewayId')), isFalse);
      expect(
        () => gatewayEndpoint('ws://10.0.2.2:18341/ws/mobile/$fixtureGatewayId', fixtureGatewayId),
        throwsA(isA<GatewayPairingFailure>()),
      );
    }
  });
}
