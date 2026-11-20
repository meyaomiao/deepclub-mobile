import 'package:dsh_app/deepclub/account_state.dart';
import 'package:dsh_app/deepclub/client_api.dart';
import 'package:dsh_app/deepclub/secure_store.dart';
import 'package:dsh_app/links/app_links.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  testWidgets('cold-start callback reaches account before LinkHost is mounted', (tester) async {
    final rig = ServiceRig();
    final pending = PendingAuthorization.create();
    await rig.store.write('pkce', pending.encode());
    const channel = MethodChannel('deepclub/test-links');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async => true);
    final links = AppLinks(channel: channel);
    // Held before either the regular router or account subscribes.
    links.add(Uri.parse(deepClubRedirect).replace(queryParameters: {'state': pending.state, 'code': 'cold-code'}));
    final container = ProviderContainer(
      overrides: [
        deepClubStoreProvider.overrideWithValue(rig.store),
        deepClubApiProvider.overrideWithValue(rig.api),
        deepClubLocalEngineProvider.overrideWithValue(rig.engine),
        appLinksProvider.overrideWithValue(links),
      ],
    );
    addTearDown(() async {
      container.dispose();
      links.dispose();
      await rig.close();
    });
    container.listen(deepClubAccountProvider, (_, _) {}, fireImmediately: true);
    await tester.pump();
    expect(container.read(deepClubAccountProvider).signedIn, isTrue);
    expect(container.read(deepClubAccountProvider).engineReady, isTrue);
    expect(container.read(linkRouterProvider).context, isNull);
    expect(rig.requests.where((r) => r.url.path == '/api/client/token'), hasLength(1));
  });
}
