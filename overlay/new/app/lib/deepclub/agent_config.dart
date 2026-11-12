import 'package:dsh_client/dsh_client.dart';

import '../state/connection_state.dart';
import 'client_api.dart';

class DeepClubAgentConfig {
  DeepClubAgentConfig._(this.raw, this.revision, this.providers, this.recommendation);
  factory DeepClubAgentConfig.fromJson(Object? value) {
    final data = jsonObject(value);
    final revision = requiredText(data, 'revision');
    if (data['api_key_env'] != deepClubKeyRef) throw const DeepClubFailure('invalid_config');
    final providers = jsonObject(data['providers']);
    for (final entry in providers.entries) {
      final provider = jsonObject(entry.value);
      final url = Uri.tryParse(provider['baseURL'] as String? ?? '');
      // This app's device key is scoped to DeepClub; no server-supplied route
      // may silently send it to an unrelated gateway.
      if (!entry.key.startsWith('deepclub-') ||
          provider['apiKeyEnv'] != deepClubKeyRef ||
          provider.containsKey('apiKey') ||
          url == null ||
          !isDeepClubServiceBase(url) ||
          provider['models'] is! List) {
        throw const DeepClubFailure('invalid_config');
      }
    }
    final recommendation = data['recommendation'] == null ? null : jsonObject(data['recommendation']);
    if (recommendation != null) {
      final provider = recommendation['provider'];
      final model = recommendation['model'];
      final route = providers[provider];
      if (route is! Map || model is! String || !(route['models'] as List).any((m) => m is Map && m['id'] == model)) {
        throw const DeepClubFailure('invalid_config');
      }
    }
    return DeepClubAgentConfig._(data, revision, providers, recommendation);
  }
  final Map<String, Object?> raw;
  final String revision;
  final Map<String, Object?> providers;
  final Map<String, Object?>? recommendation;
}

/// Replaces only the service-owned routes, including withdrawn models, without
/// touching any custom route, session selection or reasoning effort.
Map<String, Object?> mergeDeepClubProviders(Map<String, Object?> existing, DeepClubAgentConfig config) => {
  for (final entry in existing.entries)
    if (!entry.key.startsWith('deepclub-')) entry.key: entry.value,
  ...config.providers,
};

bool mayAdoptRecommendation({required bool hasSessions, required Map<String, Object?>? userDefaults}) =>
    !hasSessions &&
    !const ['provider', 'model', 'reasoningEffort'].any((key) => userDefaults?.containsKey(key) ?? false);

abstract interface class DeepClubEngine {
  Future<void> setKey(String key);
  Future<void> clearKey();
  Future<void> applyConfig(DeepClubAgentConfig config, {required bool adoptRecommendation});
}

/// Constructed exclusively from localConnectionProvider. Captures the client,
/// never reacquires the active host after an await or a host switch.
class LocalDeepClubEngine implements DeepClubEngine {
  LocalDeepClubEngine(HostConnection connection) : _client = connection.client {
    if (!connection.isLocal) throw const DeepClubFailure('remote_credentials_forbidden');
  }
  final DshClient _client;
  @override
  Future<void> setKey(String key) => _client.setProviderKey(key, ref: deepClubKeyRef);
  @override
  Future<void> clearKey() async {
    try {
      final description = await _client.describeSettings();
      final tools = description.namespaces['deepclub-tools'];
      if (tools != null) {
        await _client.mutateSettingsView('deepclub-tools', [
          SettingsOp.set(['catalog'], {'models': <Object?>[], 'tools': <String, Object?>{}}),
        ], expectedRevision: tools.revision);
      }
    } finally {
      await _client.clearProviderKey(ref: deepClubKeyRef);
    }
  }

  @override
  Future<void> applyConfig(DeepClubAgentConfig config, {required bool adoptRecommendation}) async {
    final description = await _client.describeSettings();
    final tools = description.namespaces['deepclub-tools'];
    if (tools == null || !tools.writable) throw const DeepClubFailure('engine_config_unavailable');
    final catalog = tools.value['catalog'];
    if (catalog is Map && catalog['revision'] == config.revision) return;
    final pi = description.namespaces['llm-pi-ai'];
    if (pi == null || !pi.writable) throw const DeepClubFailure('engine_config_unavailable');
    final existing = pi.value['providers'] == null ? <String, Object?>{} : jsonObject(pi.value['providers']);
    final merged = mergeDeepClubProviders(existing, config);
    if (!jsonEquals(existing, merged)) {
      // expectedRevision prevents overwriting a concurrently edited route.
      await _client.mutateSettingsView('llm-pi-ai', [
        SettingsOp.set(['providers'], merged),
      ], expectedRevision: pi.revision);
    }
    if (adoptRecommendation && config.recommendation != null) {
      final defaults = description.namespaces['agent-default-model'];
      if (defaults != null && defaults.writable) {
        final sessions = await _client.listSessions();
        if (mayAdoptRecommendation(hasSessions: sessions.isNotEmpty, userDefaults: defaults.user)) {
          await _client.mutateSettingsView('agent-default-model', [
            SettingsOp.set(['provider'], config.recommendation!['provider']),
            SettingsOp.set(['model'], config.recommendation!['model']),
          ], expectedRevision: defaults.revision);
        }
      }
    }
    // Commit the revision after all configuration writes have succeeded.
    await _client.mutateSettingsView('deepclub-tools', [
      SettingsOp.set(['catalog'], config.raw),
    ], expectedRevision: tools.revision);
  }
}
