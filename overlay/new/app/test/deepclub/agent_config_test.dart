import 'package:dsh_app/deepclub/agent_config.dart';
import 'package:dsh_app/deepclub/client_api.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../packages/dsh_client/test/support/fake_dsh.dart';
import 'support.dart';

void main() {
  test('merge removes withdrawn managed routes and preserves unrelated routes and provider DTO fields', () {
    final config = DeepClubAgentConfig.fromJson(configJson());
    final merged = mergeDeepClubProviders({
      'custom-local': {
        'models': ['mine'],
      },
      'deepclub-old': {
        'models': ['withdrawn'],
      },
    }, config);
    expect(merged.keys, unorderedEquals(['custom-local', 'deepclub-claude']));
    expect(merged['custom-local'], {
      'models': ['mine'],
    });
    expect((merged['deepclub-claude'] as Map)['compat'], {'forceAdaptiveThinking': true, 'supportsStrictTools': true});
    expect(((merged['deepclub-claude'] as Map)['models'] as List).single['reasoningEfforts'], {
      'low': 'low',
      'high': 'high',
    });
    expect(mergeDeepClubProviders(merged, DeepClubAgentConfig.fromJson(configJson(empty: true))), {
      'custom-local': {
        'models': ['mine'],
      },
    });
  });

  test('recommendation only applies without sessions or any explicit model/thinking choice', () {
    expect(mayAdoptRecommendation(hasSessions: false, userDefaults: {}), isTrue);
    expect(mayAdoptRecommendation(hasSessions: true, userDefaults: {}), isFalse);
    for (final field in ['provider', 'model', 'reasoningEffort']) {
      expect(mayAdoptRecommendation(hasSessions: false, userDefaults: {field: ''}), isFalse);
    }
  });

  test('config cannot route the device credential to an unrelated server or manage custom routes', () {
    for (final base in [
      'https://other.invalid/v1',
      'http://deepclub.net/v1',
      'https://deepclub.net:444/v1',
      'https://u@deepclub.net/v1',
    ]) {
      final config = configJson();
      ((config['providers'] as Map)['deepclub-claude'] as Map)['baseURL'] = base;
      expect(() => DeepClubAgentConfig.fromJson(config), throwsA(isA<DeepClubFailure>()));
    }
    final config = configJson();
    final providers = config['providers'] as Map;
    providers['custom-route'] = providers.remove('deepclub-claude');
    expect(() => DeepClubAgentConfig.fromJson(config), throwsA(isA<DeepClubFailure>()));
  });

  group('real DshClient RPC contract', () {
    late FakeDsh host;
    late DshClient client;
    late LocalDeepClubEngine engine;
    late Map<String, Map<String, Object?>> namespaces;
    late List<Map<String, Object?>> sessions;
    setUp(() async {
      host = await FakeDsh.start();
      namespaces = {
        'llm-pi-ai': {
          'ns': 'llm-pi-ai',
          'revision': 4,
          'schema': {},
          'value': {
            'providers': {
              'custom-keep': {'api': 'openai-completions'},
              'deepclub-old': {'api': 'openai-completions'},
            },
          },
          'user': {},
        },
        'agent-default-model': {
          'ns': 'agent-default-model',
          'revision': 3,
          'schema': {},
          'value': {'provider': 'deepseek', 'model': 'default', 'reasoningEffort': 'high'},
          'user': {},
        },
        'deepclub-tools': {
          'ns': 'deepclub-tools',
          'revision': 1,
          'schema': {},
          'value': {'catalog': {}},
          'user': {},
        },
      };
      sessions = [];
      host.handlers['settings/describe'] = (_) => {
        'ok': true,
        'value': {'writable': true, 'namespaces': namespaces.values.toList()},
      };
      host.handlers['settings/mutate'] = (args) {
        final ns = namespaces[args['ns']]!;
        expect(args['expectedRevision'], ns['revision']);
        var value = Map<String, Object?>.from(ns['value'] as Map);
        for (final raw in args['ops'] as List) {
          final op = raw as Map;
          value = withPath(value, (op['path'] as List).cast<String>(), op['value']);
        }
        ns['value'] = value;
        ns['revision'] = (ns['revision'] as int) + 1;
        return {'ok': true, 'value': ns};
      };
      host.handlers['session/list'] = (_) => {
        'ok': true,
        'value': {'items': sessions},
      };
      host.handlers['credentials/set'] = (_) => {'ok': true};
      host.handlers['credentials/unset'] = (_) => {'ok': true};
      client = await DshClient.connect(baseUri: host.baseUri, token: FakeDsh.token, startMux: false);
      engine = LocalDeepClubEngine(HostConnection(client: client, isLocal: true));
    });
    tearDown(() async {
      await client.close();
      await host.close();
    });

    List<Map<String, Object?>> mutations() => [
      for (final call in host.rpcCalls)
        if (call['method'] == 'settings/mutate') Map<String, Object?>.from((call['payload'] as Map)['args'] as Map),
    ];

    test('only local target, credentials/set reference, default model without any effort/session mutation', () async {
      expect(
        () => LocalDeepClubEngine(HostConnection(client: client, isLocal: false)),
        throwsA(isA<DeepClubFailure>()),
      );
      await engine.setKey('synthetic-model-key');
      final keyArgs = (host.rpcCalls.single['payload'] as Map)['args'];
      expect(keyArgs, {'ref': 'DEEPCLUB_API_KEY', 'value': 'synthetic-model-key'});
      await engine.applyConfig(DeepClubAgentConfig.fromJson(configJson()), adoptRecommendation: true);
      final writes = mutations();
      expect(writes.map((w) => w['ns']), ['llm-pi-ai', 'agent-default-model', 'deepclub-tools']);
      expect(writes[1]['ops'], [
        {
          'op': 'set',
          'path': ['provider'],
          'value': 'deepclub-claude',
        },
        {
          'op': 'set',
          'path': ['model'],
          'value': 'claude-sonnet-5.5',
        },
      ]);
      expect((namespaces['agent-default-model']!['value'] as Map)['reasoningEffort'], 'high');
      expect(host.rpcCalls.where((c) => c['method'] == 'session/selectModel'), isEmpty);
      expect((namespaces['llm-pi-ai']!['value'] as Map)['providers'], contains('custom-keep'));
      expect((namespaces['llm-pi-ai']!['value'] as Map)['providers'], isNot(contains('deepclub-old')));
      final count = writes.length;
      await engine.applyConfig(DeepClubAgentConfig.fromJson(configJson()), adoptRecommendation: true);
      expect(mutations(), hasLength(count), reason: 'the persisted catalog revision suppresses rewrites after restart');
    });

    test('existing session and explicit thinking choice both prevent recommendation writes', () async {
      sessions = [
        {'sessionId': 'existing', 'id': 'existing'},
      ];
      await engine.applyConfig(DeepClubAgentConfig.fromJson(configJson()), adoptRecommendation: true);
      expect(mutations().where((w) => w['ns'] == 'agent-default-model'), isEmpty);
      sessions = [];
      namespaces['agent-default-model']!['user'] = {'reasoningEffort': 'off'};
      await engine.applyConfig(
        DeepClubAgentConfig.fromJson(configJson(revision: 'sha256:second')),
        adoptRecommendation: true,
      );
      expect(mutations().where((w) => w['ns'] == 'agent-default-model'), isEmpty);
    });

    test('logout disables tools before unsetting engine credential', () async {
      await engine.clearKey();
      expect(host.rpcCalls.map((c) => c['method']), ['settings/describe', 'settings/mutate', 'credentials/unset']);
      expect((namespaces['deepclub-tools']!['value'] as Map)['catalog'], {'models': [], 'tools': {}});
      expect((host.rpcCalls.last['payload'] as Map)['args'], {'ref': 'DEEPCLUB_API_KEY'});
    });
  });
}
