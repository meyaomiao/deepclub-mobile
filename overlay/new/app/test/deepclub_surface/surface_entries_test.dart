import 'dart:io';

import 'package:dsh_app/ui/settings/deepclub_account_page.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/share_code/conversation_share.dart';
import 'package:dsh_app/share_code/share_codec.dart';
import 'package:dsh_app/share_code/share_link.dart';
import 'package:dsh_app/share_code/share_models.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/drawer_destination.dart';
import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/media_generation.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/media/generate_mode.dart';
import 'package:dsh_app/ui/chat/media/media_card.dart';
import 'package:dsh_app/state/quick_panel_state.dart';
import 'package:dsh_app/state/read_list_cache.dart';
import 'package:dsh_app/ui/chat/model_sheet.dart';
import 'package:dsh_app/ui/chat/widgets/notice_row.dart';
import 'package:dsh_app/ui/features/feature_catalog.dart';
import 'package:dsh_app/ui/shell/adaptive/adaptive_rail.dart';
import 'package:dsh_app/ui/shell/session_search_page.dart';
import 'package:dsh_app/ui/shell/sessions_drawer.dart' show NewChatButton, SessionsDrawer;
import 'package:dsh_app/ui/share/share_panel.dart';
import 'package:dsh_app/ui/share_code/share_code_panel.dart';
import 'package:dsh_app/ui/share_code/share_out.dart';
import 'package:dsh_app/ui/share_hosted/hosted_links_tile.dart';
import 'package:dsh_app/ui/share_hosted/manage_links_button.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../replay/support/conversation_fixture.dart';

class _LocalOut extends ShareOut {
  _LocalOut() : super(files: const FilesChannel());

  final copied = <String>[];
  final sharedText = <String>[];
  final written = <String, String>{};
  final sharedFiles = <File>[];

  @override
  Future<void> copy(String text) async => copied.add(text);
  @override
  Future<void> shareText(String text) async => sharedText.add(text);
  @override
  Future<File> write(String name, String content) async {
    written[name] = content;
    return File('/local-export/$name');
  }

  @override
  Future<void> shareFile(File file, {String? text}) async => sharedFiles.add(file);
}

class _NoticeRoutes extends NavigatorObserver {
  final pushed = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => pushed.add(route);
}

class _LegacyMediaMode extends GenerateModeStore {
  @override
  GenerateModes build() => const GenerateModes(byKey: {'s1': GenerateParams()});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('feature routes keep agent work and lead model management to DeepClub', () {
    final items = featureSections.expand((section) => section.items).toList();
    final ids = items.map((item) => item.id).toSet();
    expect(ids, containsAll(['files', 'terminal', 'jobs', 'plan-goal', 'schedules', 'permission', 'skills', 'export']));
    for (final retired in ['phone', 'pets', 'companion', 'forum', 'community', 'plugins', 'ds-bot', 'websearch']) {
      expect(ids, isNot(contains(retired)), reason: retired);
    }
    expect(items.singleWhere((item) => item.id == 'models').native!(null), isA<DeepClubAccountPage>());
  });

  test('saved and newly selected quick shortcuts cannot reopen retired services', () async {
    SharedPreferences.setMockInitialValues({
      QuickPanelController.itemsKey: ['plugins', 'engine', 'web', 'remote', 'settings', 'engine'],
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(quickPanelProvider.notifier);
    await controller.setSwipe(true); // Also waits for stored items to load.
    expect(container.read(quickPanelProvider).items, [DrawerDestination.engine, DrawerDestination.settings]);
    await controller.setItems([DrawerDestination.plugins, DrawerDestination.features, DrawerDestination.web]);
    expect(container.read(quickPanelProvider).items, [DrawerDestination.features]);
    expect((await SharedPreferences.getInstance()).getStringList(QuickPanelController.itemsKey), ['features']);
  });

  testWidgets('default drawer and rail keep Agent actions without mode or Web entry', (tester) async {
    usePhoneView(tester);
    final harness = ChatHarness(session: 's1', connected: false);
    final destinations = <DrawerDestination>[];
    var closed = 0;
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: 320,
              child: SessionsDrawer(onClose: () => closed++, onOpen: destinations.add),
            ),
          ),
        ),
        overrides: harness.overrides,
      ),
    );
    await pumpFrames(tester);
    expect(find.byTooltip(appL10n.modeKeyTooltip), findsNothing);
    expect(find.byTooltip(appL10n.webSwitchToWeb), findsNothing);
    expect(find.byKey(const ValueKey('mode-key')), findsNothing);
    expect(find.byType(NewChatButton), findsOneWidget);
    expect(find.byType(SessionSearchBar), findsOneWidget);
    expect(find.byKey(const ValueKey('identity-host-details')), findsOneWidget);
    expect(find.byKey(const ValueKey('identity-host-switcher')), findsOneWidget);

    await tester.tap(find.byTooltip(appL10n.commonSettings));
    await tester.tap(find.byTooltip(appL10n.hubSettingsAllFeatures));
    await tester.tap(find.byKey(const ValueKey('identity-host-details')));
    expect(destinations, [DrawerDestination.settings, DrawerDestination.features, DrawerDestination.engine]);
    final container = ProviderScope.containerOf(tester.element(find.byType(SessionsDrawer)));
    await tester.tap(find.byType(NewChatButton));
    await tester.pump();
    expect(container.read(currentSessionProvider), isNull);
    expect(closed, 1);

    // The computer-management route remains available through the host picker.
    await tester.tap(find.byKey(const ValueKey('identity-host-switcher')));
    await pumpFrames(tester);
    await tester.tap(find.text(appL10n.remoteConnectComputer));
    await pumpFrames(tester);
    expect(destinations.last, DrawerDestination.remote);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    final railActions = <String>[];
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: SizedBox(
            width: 68,
            height: 500,
            child: AdaptiveRail(
              onMenu: () => railActions.add('menu'),
              menuTooltip: 'menu',
              onSearch: () => railActions.add('search'),
              onHost: () => railActions.add('host'),
              onWeb: () => railActions.add('web'),
              onSettings: () => railActions.add('settings'),
            ),
          ),
        ),
        overrides: harness.overrides,
      ),
    );
    await pumpFrames(tester);
    expect(find.byKey(const ValueKey('rail-web')), findsNothing);
    for (final action in ['menu', 'search', 'host', 'settings']) {
      await tester.tap(find.byKey(ValueKey('rail-$action')));
    }
    expect(railActions, ['menu', 'search', 'host', 'settings']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('empty model catalog offers the DeepClub account and no credential form', (tester) async {
    usePhoneView(tester);
    const catalog = ModelCatalog(defaultSelection: null, groups: [], failures: [], routableProviders: []);
    await tester.pumpWidget(
      testApp(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showModelSheet(context, current: null, onSelected: (_) {}),
              child: const Text('open'),
            ),
          ),
        ),
        overrides: [
          modelCatalogProvider.overrideWith((ref) async => catalog),
          modelListViewProvider.overrideWithValue(
            ReadListView(value: catalog, readOnly: false, status: ReadListStatus.current),
          ),
          modelSelectionScopeProvider.overrideWithValue(Object()),
        ],
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text(appL10n.deepClubAccount), findsOneWidget);
    expect(find.text(appL10n.deepClubModelsUnavailable), findsOneWidget);
    expect(find.text(appL10n.viewModelEnterKey), findsNothing);
    expect(find.text(appL10n.viewModelAddProvider), findsNothing);
  });

  testWidgets('copy and share always emit a local code even with a legacy market URL', (tester) async {
    usePhoneView(tester);
    final out = _LocalOut();
    final payload = ProfileShare(name: 'Local profile');
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: ShareCodePanel(payload: payload, title: 'Local profile', webLink: 'https://go.dshtui.com/p/old-plugin'),
        ),
        overrides: [shareOutProvider.overrideWithValue(out)],
      ),
    );
    await tester.tap(find.byKey(const ValueKey('share-code-copy')));
    await tester.pump();
    expect(out.copied.single, startsWith('deepclub://share/profile?p='));
    expect(decodeShareCode(ShareLink.parse(Uri.parse(out.copied.single))!.code!).toJson(), payload.toJson());
    await tester.tap(find.byKey(const ValueKey('share-code-share')));
    await tester.pumpAndSettle();
    expect(out.sharedText.single, contains(out.copied.single));
    expect(out.sharedText.single, isNot(contains('go.dshtui.com')));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('large profiles export a local file without a Gist action', (tester) async {
    usePhoneView(tester);
    final out = _LocalOut();
    final payload = ProfileShare(
      skills: [
        for (var i = 0; i < 3; i++)
          SharedSkill(
            name: 'skill-$i',
            files: {
              'SKILL.md': [for (var j = 0; j < 200; j++) 'line $j $i-$j ${j * 7919 % 1000}'].join('\n'),
            },
          ),
      ],
    );
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: ShareCodePanel(payload: payload, title: 'Local profile'),
        ),
        overrides: [shareOutProvider.overrideWithValue(out)],
      ),
    );
    expect(find.byKey(const ValueKey('share-code-gist')), findsNothing);
    expect(find.byKey(const ValueKey('share-code-gist-token')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('share-code-share')));
    await tester.pumpAndSettle();
    expect(out.sharedText, isEmpty);
    expect(out.sharedFiles.single.path, endsWith('.deepclub'));
    expect(decodeShareFile(out.written.values.single).toJson(), payload.toJson());
  });

  testWidgets('legacy media state cannot change Agent messages or restore old menu entries', (tester) async {
    usePhoneView(tester);
    final harness = ChatHarness(session: 's1');
    await tester.pumpWidget(
      testApp(
        const ChatScreen(),
        overrides: [
          ...harness.overrides,
          mediaPluginProvider.overrideWithValue(MediaPluginState.ready),
          generateModeProvider.overrideWith(_LegacyMediaMode.new),
        ],
      ),
    );
    await pumpFrames(tester);
    expect(find.byType(GenerateCapsule), findsNothing);
    await tester.enterText(find.byType(TextField), 'Draw a quiet seaside town');
    tester.widget<Composer>(find.byType(Composer)).onSend();
    await pumpFrames(tester);
    expect(harness.controllers['s1']!.sent, ['Draw a quiet seaside town']);
    await tester.tap(find.bySemanticsLabel(appL10n.chatAddAttachment));
    await pumpFrames(tester);
    expect(find.text(appL10n.chatGallery), findsOneWidget);
    expect(find.text(appL10n.chatTakePhoto), findsOneWidget);
    expect(find.text(appL10n.mediaGenerateTile), findsNothing);
    expect(find.text(appL10n.phoneControlTitle), findsNothing);
    expect(find.text(appL10n.featuresPermissions), findsOneWidget);
    expect(find.text(appL10n.hubSessionPlanMode), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('missing model credentials offer account authorization instead of a DeepSeek key', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: NoticeRow(
            item: NoticeChatItem(
              seq: 1,
              kind: 'error',
              text: 'missing',
              failure: LlmFailure(code: 'MISSING_CREDENTIAL', message: 'missing'),
            ),
          ),
        ),
      ),
    );
    expect(find.text(appL10n.deepClubAccount), findsOneWidget);
    expect(find.text(appL10n.deepClubModelsUnavailable), findsOneWidget);
    expect(find.text(appL10n.chatDeepSeekKeyMissing), findsNothing);
    expect(find.text(appL10n.chatGoToSettings), findsNothing);
  });

  testWidgets('real NO_ADAPTER failure offers account recovery without changing the model', (tester) async {
    usePhoneView(tester);
    // Captured from DSH 0.2.2rc1 after an empty catalog withdrew this route.
    final transcript = ChatTranscript()
      ..apply(
        SessionLogEvent.fromJson({
          'type': 'turn/end',
          'seq': 18,
          'time': 1794509693381,
          'data': {
            'turn': 1,
            'reason': {
              'kind': 'error',
              'error': {'message': 'no adapter registered for provider "deepclub-deepseek"', 'code': 'NO_ADAPTER'},
            },
          },
        }),
      );
    final notice = transcript.items.whereType<NoticeChatItem>().single;
    expect(notice.failure!.code, 'NO_ADAPTER');
    final routes = _NoticeRoutes();
    var retries = 0;
    await tester.pumpWidget(
      testApp(
        Navigator(
          observers: [routes],
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (_) => Scaffold(
              body: NoticeRow(item: notice, action: (label: 'retry', onPressed: () => retries++)),
            ),
          ),
        ),
        overrides: [modelSelectionScopeProvider.overrideWithValue(Object())],
      ),
    );
    final context = tester.element(find.byType(NoticeRow));
    final container = ProviderScope.containerOf(context, listen: false);
    const selected = ModelSelection(provider: 'deepclub-deepseek', model: 'deepseek-v4-pro');
    container.read(pendingModelProvider.notifier).select(selected);
    await tester.pump();
    expect(find.text('当前模型暂不可用，请刷新账号或选择其他模型'), findsOneWidget);
    expect(find.text(appL10n.deepClubAccount), findsOneWidget);
    expect(find.text(appL10n.chatErrTurn), findsNothing);
    expect(find.text('retry'), findsNothing);
    expect(routes.pushed, hasLength(1), reason: 'no automatic account navigation');
    expect(container.read(pendingModelProvider), same(selected));
    await tester.tap(find.text(appL10n.deepClubAccount));
    expect(routes.pushed, hasLength(2));
    final accountRoute = routes.pushed.last as MaterialPageRoute<void>;
    expect(accountRoute.builder(context), isA<DeepClubAccountPage>());
    expect(container.read(pendingModelProvider), same(selected));
    expect(retries, 0);
    // Check the route target without starting the account service in this UI test.
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('old media authorization errors lead to the DeepClub account', (tester) async {
    usePhoneView(tester);
    final meta = MediaMeta.fromJson({
      'v': 1,
      'rid': 'synthetic-auth-error',
      'kind': 'image',
      'status': 'failed',
      'items': <Object?>[],
      'request': {'provider': 'legacy', 'n': 1},
      'error': {'code': 'auth', 'message': 'Authorization required'},
    })!;
    await tester.pumpWidget(testApp(Scaffold(body: MediaCard(meta: meta))));
    expect(find.text(appL10n.deepClubAccount), findsOneWidget);
    expect(find.text(appL10n.chatGoToSettings), findsNothing);
  });

  testWidgets('conversation panel exposes image, file and text but no hosted link', (tester) async {
    usePhoneView(tester);
    final share = ConversationShare(title: 'Local replay', start: t0, entries: const []);
    final state = ChatState(items: fixtureItems, turns: fixtureTurns, title: share.title, loading: false);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: SharePanel(
            subject: ConversationSubject(
              replay: ReplaySource(share: share, state: state),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('share-to-link')), findsNothing);
    expect(find.byKey(const ValueKey('share-to-image')), findsOneWidget);
    expect(find.byKey(const ValueKey('share-to-file')), findsOneWidget);
    expect(find.byKey(const ValueKey('share-to-text')), findsOneWidget);
    await tester.pumpWidget(
      testApp(const Scaffold(body: Column(children: [ManageLinksButton(), HostedLinksSettingsTile()]))),
    );
    expect(find.byType(TextButton), findsNothing);
  });
}
