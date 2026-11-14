import 'dart:convert';

import 'package:dsh_app/deepclub/account_service.dart';
import 'package:dsh_app/deepclub/agent_config.dart';
import 'package:dsh_app/deepclub/client_api.dart';
import 'package:dsh_app/deepclub/secure_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, Object?> configJson({String revision = 'sha256:first', bool empty = false}) => {
  'revision': revision,
  'base_url': 'https://deepclub.net',
  'api_key_env': 'DEEPCLUB_API_KEY',
  'providers': empty
      ? <String, Object?>{}
      : {
          'deepclub-claude': {
            'displayName': 'Claude',
            'api': 'anthropic-messages',
            'baseURL': 'https://deepclub.net',
            'apiKeyEnv': 'DEEPCLUB_API_KEY',
            'compat': {'forceAdaptiveThinking': true, 'supportsStrictTools': true},
            'models': [
              {
                'id': 'claude-sonnet-5.5',
                'name': 'Claude Sonnet 5.5',
                'reasoningEfforts': {'low': 'low', 'high': 'high'},
              },
            ],
          },
        },
  'models': empty
      ? <Object?>[]
      : [
          {'id': 'claude-sonnet-5.5', 'category': 'chat', 'agent_eligible': true},
        ],
  'tools': {
    'image': {'enabled': false, 'model_ids': <Object?>[]},
  },
  if (!empty) 'recommendation': {'provider': 'deepclub-claude', 'model': 'claude-sonnet-5.5'},
};
Map<String, Object?> sessionJson({bool withKey = true}) => {
  'session_token': 'synthetic-session',
  'expires_at': '2099-01-01T00:00:00Z',
  if (withKey) 'api_key': 'synthetic-model-key',
  if (withKey) 'token_id': 123,
  'user': {'id': 1, 'username': 'fixture', 'display_name': 'Fixture', 'group': 'default', 'role': 1, 'status': 1},
};

class MemoryStore implements DeepClubStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class FakeEngine implements DeepClubEngine {
  final calls = <String>[];
  String? key;
  bool failClear = false;
  int configWrites = 0;
  final recommendations = <bool>[];
  @override
  Future<void> setKey(String key) async {
    calls.add('setKey');
    this.key = key;
  }

  @override
  Future<void> clearKey() async {
    calls.add('clearKey');
    if (failClear) throw StateError('controlled unavailable');
    key = null;
  }

  @override
  Future<void> applyConfig(DeepClubAgentConfig config, {required bool adoptRecommendation}) async {
    calls.add('config:${config.revision}');
    configWrites++;
    recommendations.add(adoptRecommendation);
  }
}

class ServiceRig {
  ServiceRig({MemoryStore? storage, this.connected = true}) : store = storage ?? MemoryStore() {
    api = DeepClubApi(
      client: MockClient((request) async {
        requests.add(request);
        if (handler != null) {
          final response = await handler!(request);
          if (response != null) return response;
        }
        final data = switch (request.url.path) {
          '/api/client/token' => sessionJson(),
          '/api/client/login' || '/api/client/login/2fa' => sessionJson(withKey: false),
          '/api/client/provision' => {
            'api_key': 'synthetic-model-key',
            'token_id': 123,
            'group': 'default',
            'name': 'device',
          },
          '/api/client/agent-config' => configJson(revision: revision),
          '/api/client/bootstrap' => {
            'site': {'quota_per_unit': 500000},
            'user': {'quota': 1000000},
          },
          '/api/client/devices' => [
            {'id': 42, 'device_name': 'This phone', 'is_current': true},
          ],
          _ => null,
        };
        return ok(data);
      }),
    );
    service = DeepClubAccountService(
      api: api,
      store: store,
      localEngine: () => connected ? engine : null,
      clearStoppedEngine: () async {
        nativeClears++;
        if (failNative) throw StateError('controlled failure');
        engine.key = null;
      },
      appVersion: '1.0.0+1',
    );
  }
  final MemoryStore store;
  final engine = FakeEngine();
  late final DeepClubApi api;
  late final DeepClubAccountService service;
  final requests = <http.Request>[];
  Future<http.Response?> Function(http.Request)? handler;
  bool connected, failNative = false;
  int nativeClears = 0;
  String revision = 'sha256:first';
  static http.Response ok(Object? data, {Map<String, String>? headers}) =>
      http.Response(jsonEncode({'success': true, 'data': data}), 200, headers: headers ?? const {});
  Future<void> login() => service.loginWithPassword('fixture', 'synthetic-password');
  Future<void> close() async {
    api.close();
    await service.close();
  }
}
