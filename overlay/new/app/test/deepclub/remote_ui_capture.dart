// Explicit component matrix: real production pages, synthetic public state and
// camera placeholder. This does not represent an emulator or hardware camera.
import 'dart:io';

import 'package:dsh_app/deepclub/account_state.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/gateway_state.dart';
import 'package:dsh_app/ui/onboarding/local_install.dart';
import 'package:dsh_app/ui/remote/gateway_pairing_page.dart';
import 'package:dsh_app/ui/remote/pairing_page.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_fonts.dart';
import 'ui_fixture.dart';

class _CapturePair extends GatewayPairController {
  _CapturePair(this.value);
  final GatewayPairState value;
  @override
  GatewayPairState build() => value;
  @override
  void reset() {}
  @override
  Future<GatewayHost?> pending() async => null;
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final layouts = [
    (name: 'phone', size: const Size(360, 800), scale: 1.0),
    (name: 'phone_large', size: const Size(360, 800), scale: 1.3),
    (name: 'wide', size: const Size(840, 800), scale: 1.0),
  ];
  for (final locale in AppLocale.supported) {
    for (final brightness in Brightness.values) {
      for (final layout in layouts) {
        for (final scene in ['scan', 'pairing', 'expired', 'account_mismatch', 'upgrade', 'upgrade_waiting']) {
          testWidgets('$scene ${locale.languageCode} ${brightness.name} ${layout.name}', (tester) async {
            AppLocale.use(locale);
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = layout.size;
            addTearDown(tester.view.reset);
            final fixture = DeepClubUiFixture(
              DeepClubUiScene.account,
              accountState: DeepClubAccountState(
                loaded: true,
                signedIn: true,
                remoteOnly: true,
                binding: 'synthetic-binding',
                awaitingBrowser: scene == 'upgrade_waiting',
              ),
            );
            addTearDown(fixture.close);
            final flow = switch (scene) {
              'pairing' => const GatewayPairState(busy: true),
              'expired' => const GatewayPairState(error: 'pairing_expired'),
              'account_mismatch' => const GatewayPairState(error: 'remote_account_mismatch'),
              _ => const GatewayPairState(),
            };
            await tester.pumpWidget(
              fixture.app(
                home: scene.startsWith('upgrade') ? const LocalInstallPage() : const GatewayPairingPage(),
                locale: locale,
                brightness: brightness,
                textScale: layout.scale,
                extraOverrides: [
                  gatewayPairProvider.overrideWith(() => _CapturePair(flow)),
                  pairingScannerProvider.overrideWithValue(
                    (context, onCode) => ColoredBox(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      child: const Center(child: Icon(AppIcons.qrCode, size: 48)),
                    ),
                  ),
                ],
              ),
            );
            await tester.pump(const Duration(milliseconds: 300));
            await tester.pump(const Duration(milliseconds: 240));
            expect(tester.takeException(), isNull);
            expect(find.byWidgetPredicate((w) => w is ProgressIndicator).evaluate().length, lessThanOrEqualTo(1));
            await expectLater(
              find.byKey(const ValueKey('deepclub-capture')),
              matchesGoldenFile(
                'goldens/${Platform.operatingSystem}/remote_${scene}_${brightness.name}_${locale.languageCode}_${layout.name}.png',
              ),
            );
            await tester.pumpWidget(const SizedBox());
          });
        }
      }
    }
  }
}
