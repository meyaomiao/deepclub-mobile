// Component evidence only. Actual App network screenshots are recorded separately.
import 'dart:io';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/remote/gateway_pairing_page.dart';
import 'package:dsh_app/ui/remote/network_details_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_fonts.dart';
import 'ui_fixture.dart';

void main() {
  setUpAll(loadTestFonts);
  const host = HostRef.gateway('12345678-1234-4567-8123-123456789abc', name: 'Fixture computer');
  for (final route in [RelayPath.lan, RelayPath.relay]) {
    for (final locale in [AppLocale.en, AppLocale.zhCN]) {
      for (final dark in [false, true]) {
        for (final size in ['phone', 'large-text', 'wide']) {
          testWidgets('gateway network ${route.name} ${locale.languageCode} $dark $size', (tester) async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = Size(size == 'wide' ? 840 : 360, 800);
            addTearDown(tester.view.reset);
            AppLocale.use(locale);
            final fixture = DeepClubUiFixture(DeepClubUiScene.login);
            addTearDown(fixture.close);
            await tester.pumpWidget(
              fixture.app(
                home: const Scaffold(body: RemoteNetworkDetailsSheet(host: host)),
                locale: locale,
                brightness: dark ? Brightness.dark : Brightness.light,
                textScale: size == 'large-text' ? 1.3 : 1,
                extraOverrides: [
                  hostNameProvider(host).overrideWithValue('Fixture computer'),
                  hostLinkStatusProvider(host)
                      .overrideWith((_) => Stream.value(HostLinkStatus(HostLinkPhase.connected, path: route))),
                ],
              ),
            );
            await tester.pumpAndSettle();
            expect(find.text('SSH'), findsNothing);
            expect(find.text(appL10n.deepClubMyComputer), findsOneWidget);
            expect(find.text(appL10n.deepClubGatewayConnected), findsOneWidget);
            expect(find.text(route.label), findsOneWidget);
            expect(find.text(appL10n.deepClubGatewayNetworkHint), findsOneWidget);
            expect(gatewayPairError(appL10n, 'rate_limited'), appL10n.deepClubRateLimited);
            expect(gatewayPairError(appL10n, 'remote_identity_denied'), appL10n.deepClubGatewayWrongAccount);
            expect(tester.takeException(), isNull);
            final output = Platform.environment['DEEPCLUB_P4_CAPTURE_DIR'];
            if (output != null) {
              await expectLater(
                find.byKey(const ValueKey('deepclub-capture')),
                matchesGoldenFile(
                  Uri.file('$output/network_${route.name}_${locale.languageCode}_${dark ? 'dark' : 'light'}_$size.png'),
                ),
              );
            }
          });
        }
      }
    }
  }

  testWidgets('SSH retains its existing connection label and hint', (tester) async {
    AppLocale.use(AppLocale.en);
    const ssh = HostRef.ssh('ssh-fixture');
    final fixture = DeepClubUiFixture(DeepClubUiScene.login);
    addTearDown(fixture.close);
    await tester.pumpWidget(
      fixture.app(
        home: const Scaffold(body: RemoteNetworkDetailsSheet(host: ssh)),
        locale: AppLocale.en,
        extraOverrides: [
          hostNameProvider(ssh).overrideWithValue('SSH fixture'),
          hostLinkStatusProvider(ssh).overrideWith((_) => Stream.value(const HostLinkStatus(HostLinkPhase.connected))),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('SSH'), findsNWidgets(2));
    expect(find.text(appL10n.hostDetailsSshNetworkHint), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
