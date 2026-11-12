// Opt-in only (intentionally not named *_test.dart). Start start_real_host.mjs,
// then set DEEPCLUB_REAL_HOST_INFO to its ready.json and pass its mock origin:
// flutter test --no-pub --dart-define=DEEPCLUB_TEST_ORIGIN=http://127.0.0.1:PORT test/deepclub/real_host_probe.dart
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/deepclub/agent_config.dart';
import 'package:dsh_app/deepclub/client_api.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

Map<String, Object?> _provider(String base, String id, String keyRef) => {
  'displayName': 'Isolated fixture',
  'api': 'openai-completions',
  'baseURL': '$base/v1',
  'apiKeyEnv': keyRef,
  'models': [
    {
      'id': id,
      'name': 'Fixture chat',
      'contextWindow': 8192,
      'maxTokens': 1024,
      'input': ['text'],
      'reasoningEfforts': {'off': null, 'low': 'low', 'high': 'high'},
    },
  ],
};

DeepClubAgentConfig _config(
  String base, {
  String revision = 'sha256:real-first',
  String route = 'deepclub-fixture',
  String model = 'fixture-chat',
}) => DeepClubAgentConfig.fromJson({
  'revision': revision,
  'base_url': base,
  'api_key_env': deepClubKeyRef,
  'providers': {route: _provider(base, model, deepClubKeyRef)},
  'models': [
    {
      'id': model,
      'name': 'Fixture chat',
      'category': 'chat',
      'agent_eligible': true,
      'endpoints': ['/v1/chat/completions'],
    },
  ],
  'tools': <String, Object?>{},
  'recommendation': {'provider': route, 'model': model},
});

void main() {
  test('real DSH 0.2.2rc1 settings, defaults, credentials and clear contract', () async {
    final infoPath = Platform.environment['DEEPCLUB_REAL_HOST_INFO'];
    expect(infoPath, isNotNull, reason: 'Opt-in probe needs an isolated start_real_host.mjs fixture');
    final info = jsonObject(jsonDecode(await File(infoPath!).readAsString()));
    final base = requiredText(info, 'mockOrigin');
    final engineUrl = Uri.parse(requiredText(info, 'baseUrl'));
    final root = requiredText(info, 'root');
    expect(info['version'], '0.2.2-rc.1');
    final temporaryRoot = await Directory('/tmp').resolveSymbolicLinks();
    expect(root, startsWith('$temporaryRoot/deepclub-real-host-'));
    expect(engineUrl.host, '127.0.0.1');
    expect(engineUrl.scheme, 'http');
    expect(
      deepClubServiceOrigin,
      base,
      reason: 'The compile-time debug origin must be the fixture mock, never production',
    );
    final client = await DshClient.connect(baseUri: engineUrl, token: requiredText(info, 'token'), startMux: false);
    addTearDown(client.close);
    final engine = LocalDeepClubEngine(HostConnection(client: client, isLocal: true));
    final before = await client.describeSettings();
    for (final ns in ['agent-default-model', 'llm-pi-ai', 'deepclub-tools']) {
      expect(before.namespaces[ns], isNotNull, reason: 'Real Host must expose $ns');
      expect(before.namespaces[ns]!.writable, isTrue);
    }
    expect(await client.listSessions(), isEmpty);
    expect(before.namespaces['agent-default-model']!.user ?? {}, isEmpty);
    final initialEffort = before.namespaces['agent-default-model']!.value['reasoningEffort'];
    final pi = before.namespaces['llm-pi-ai']!;
    await client.mutateSettingsView('llm-pi-ai', [
      SettingsOp.set(['providers'], {'custom-fixture': _provider(base, 'custom-chat', 'DEEPCLUB_PROBE_OTHER')}),
    ], expectedRevision: pi.revision);
    await client.setProviderKey('synthetic-unrelated-credential', ref: 'DEEPCLUB_PROBE_OTHER');
    await engine.setKey('synthetic-deepclub-credential');
    expect((await client.describeCredentials([deepClubKeyRef]))[deepClubKeyRef]!.configured, isTrue);
    await engine.applyConfig(_config(base), adoptRecommendation: true);
    final first = await client.describeSettings();
    final defaults = first.namespaces['agent-default-model']!;
    expect(defaults.value['provider'], 'deepclub-fixture');
    expect(defaults.value['model'], 'fixture-chat');
    expect(defaults.value['reasoningEffort'], initialEffort);
    final routes = first.namespaces['llm-pi-ai']!.value['providers'] as Map;
    expect(routes.keys, unorderedEquals(['custom-fixture', 'deepclub-fixture']));
    expect((first.namespaces['deepclub-tools']!.value['catalog'] as Map)['revision'], 'sha256:real-first');
    final catalog = await client.listModels();
    expect(catalog.models.any((m) => m.provider == 'deepclub-fixture' && m.id == 'fixture-chat'), isTrue);
    expect(catalog.defaultSelection?.provider, 'deepclub-fixture');
    expect(catalog.defaultSelection?.model, 'fixture-chat');
    final firstRevisions = {
      for (final ns in ['agent-default-model', 'llm-pi-ai', 'deepclub-tools']) ns: first.namespaces[ns]!.revision,
    };
    await engine.applyConfig(_config(base), adoptRecommendation: true);
    final same = await client.describeSettings();
    expect({for (final ns in firstRevisions.keys) ns: same.namespaces[ns]!.revision}, firstRevisions);
    // Real session selection and an explicit future-session default must survive
    // a new server recommendation and a withdrawn managed provider.
    await client.mutateSettingsView('agent-default-model', [
      SettingsOp.set(['provider'], 'custom-fixture'),
      SettingsOp.set(['model'], 'custom-chat'),
      SettingsOp.set(['reasoningEffort'], 'high'),
    ], expectedRevision: same.namespaces['agent-default-model']!.revision);
    final created = await client.createSession(cwd: root);
    await client.setModel(created.sessionId, provider: 'custom-fixture', model: 'custom-chat', reasoningEffort: 'high');
    final selectedBefore = (await client.projections(created.sessionId))!.nextModel!;
    await engine.applyConfig(
      _config(base, revision: 'sha256:real-second', route: 'deepclub-second', model: 'fixture-second'),
      adoptRecommendation: true,
    );
    final changed = await client.describeSettings();
    final selectedAfter = (await client.projections(created.sessionId))!.nextModel!;
    expect(
      (selectedAfter.provider, selectedAfter.model, selectedAfter.reasoningEffort),
      (selectedBefore.provider, selectedBefore.model, selectedBefore.reasoningEffort),
    );
    expect(changed.namespaces['agent-default-model']!.value['provider'], 'custom-fixture');
    expect(changed.namespaces['agent-default-model']!.value['model'], 'custom-chat');
    expect(changed.namespaces['agent-default-model']!.value['reasoningEffort'], 'high');
    expect(
      (changed.namespaces['llm-pi-ai']!.value['providers'] as Map).keys,
      unorderedEquals(['custom-fixture', 'deepclub-second']),
    );
    await engine.clearKey();
    final credentials = await client.describeCredentials([deepClubKeyRef, 'DEEPCLUB_PROBE_OTHER']);
    expect(credentials[deepClubKeyRef]?.configured ?? false, isFalse);
    expect(credentials['DEEPCLUB_PROBE_OTHER']!.configured, isTrue);
    final cleared = await client.describeSettings();
    expect(cleared.namespaces['deepclub-tools']!.value['catalog'], {'models': [], 'tools': {}});
    final stored = await File('${info['dshHome']}/.credentials.yaml').readAsString();
    expect(stored.contains('synthetic-deepclub-credential'), isFalse);
    expect(stored.contains('synthetic-unrelated-credential'), isTrue);
    final calls = jsonObject(jsonDecode((await http.get(Uri.parse('$base/test-count'))).body));
    expect(calls['modelCalls'], 0);
    final evidence = {
      'version': info['version'],
      'initialRevisions': {for (final ns in firstRevisions.keys) ns: before.namespaces[ns]!.revision},
      'configuredRevisions': firstRevisions,
      'sameRevisionNoWrites': true,
      'recommendation': {'provider': defaults.value['provider'], 'model': defaults.value['model']},
      'initialReasoningEffort': initialEffort,
      'existingSelectionPreserved': true,
      'preservedSessionReasoningEffort': selectedAfter.reasoningEffort,
      'withdrawnRouteRemoved': true,
      'customRoutePreserved': true,
      'credentialRemovedFromDisk': true,
      'unrelatedCredentialPreserved': true,
      'toolsCleared': true,
      'modelCalls': calls['modelCalls'],
    };
    await File('$root/probe-result.json').writeAsString(const JsonEncoder.withIndent('  ').convert(evidence));
    // Safe evidence only: never the fixture token, cookies or credential contents.
    // ignore: avoid_print
    print('REAL_HOST_EVIDENCE ${jsonEncode(evidence)}');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
