// Opt-in diagnosis against a local synthetic Go client API and isolated DSH.
// Set DEEPCLUB_REAL_TURN=1 to execute one synthetic session turn. All approvals
// are refused, so the Android fixture's absolute /root write cannot execute here.
// Does not discover or touch Android or user profiles.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/deepclub/agent_config.dart';
import 'package:dsh_app/deepclub/client_api.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _probeTurn(DshClient client, DeepClubAgentConfig config, String root) async {
  final created = await client.createSession(cwd: root);
  await client.setModel(
    created.sessionId,
    provider: config.recommendation!['provider'] as String,
    model: config.recommendation!['model'] as String,
    reasoningEffort: 'off',
  );
  final ready = Completer<void>(), ended = Completer<TurnEndReason>();
  final evidence = <Map<String, Object?>>[];
  final approvals = client.hostEvents.listen((event) {
    if (event is ApprovalRequestedEvent) unawaited(client.respondApproval(event.request, ApprovalDecision.reject));
  });
  final events = client
      .watch(created.sessionId)
      .listen(
        (event) {
          if (event is SessionSnapshotEvent && !ready.isCompleted) ready.complete();
          if (event is ToolCallEvent) {
            evidence.add({'type': 'tool/call', 'name': event.name, 'arguments': event.decodedArguments});
          }
          if (event is ToolResultEvent) {
            evidence.add({'type': 'tool/result', 'error': event.isError, 'code': event.failure?.code});
          }
          if (event is AssistantMessageEvent) evidence.add({'type': 'assistant/message', 'text': event.message.text});
          if (event is TurnEndedEvent && !ended.isCompleted) ended.complete(event.reason);
        },
        onError: (Object error, StackTrace stack) {
          if (!ready.isCompleted) ready.completeError(error, stack);
          if (!ended.isCompleted) ended.completeError(error, stack);
        },
      );
  try {
    await ready.future.timeout(const Duration(seconds: 15));
    await client.prompt(
      created.sessionId,
      'DeepClub isolated adapter diagnostic. Write the fixture confirmation only inside $root. Do not write outside this temporary workspace.',
    );
    final result = await ended.future.timeout(const Duration(seconds: 45));
    // ignore: avoid_print
    print(
      'REAL_TURN ${jsonEncode({'session': created.sessionId, 'preset': created.agentPreset, 'reason': result.kind, 'code': result.error?.code, 'message': result.error?.message, 'events': evidence})}',
    );
    expect(result.isError, isFalse);
    expect(evidence.any((event) => event['type'] == 'tool/call'), isTrue);
  } finally {
    if (!ended.isCompleted) await client.cancel(created.sessionId);
    await events.cancel();
    await approvals.cancel();
  }
}

void main() {
  test('full synthetic agent-config against real Host', () async {
    final info = jsonObject(jsonDecode(await File(Platform.environment['DEEPCLUB_REAL_HOST_INFO']!).readAsString()));
    expect(deepClubServiceOrigin, 'http://127.0.0.1:18453');
    final api = DeepClubApi();
    addTearDown(api.close);
    final login = (await api.call(
      'POST',
      '/api/client/login',
      body: {
        'username': Platform.environment['DEEPCLUB_FIXTURE_USERNAME']!,
        'password': Platform.environment['DEEPCLUB_FIXTURE_PASSWORD']!,
        'device_id': 'mobile-auth-diag-${DateTime.now().microsecondsSinceEpoch}',
        'device_name': 'Isolated Dart diagnosis',
        'platform': 'android',
        'app_version': '1.0.0',
      },
    )).object;
    final session = requiredText(login, 'session_token');
    addTearDown(() async {
      await api.call('POST', '/api/client/logout', session: session, body: {});
    });
    final provision = (await api.call('POST', '/api/client/provision', session: session, body: {})).object;
    final key = requiredText(provision, 'api_key');
    final full = (await api.call('GET', '/api/client/agent-config', session: session)).object;
    // The only allowed test transformation is the Android emulator's host alias.
    final mapped = jsonDecode(jsonEncode(full).replaceAll('http://10.0.2.2:18453', deepClubServiceOrigin));
    final config = DeepClubAgentConfig.fromJson(mapped);
    final client = await DshClient.connect(
      baseUri: Uri.parse(requiredText(info, 'baseUrl')),
      token: requiredText(info, 'token'),
      startMux: false,
    );
    addTearDown(client.close);
    final engine = LocalDeepClubEngine(HostConnection(client: client, isLocal: true));
    final before = await client.describeSettings();
    // ignore: avoid_print
    print(
      'FULL_CONFIG_INPUT ${jsonEncode({
        'revision': config.revision,
        'providers': config.providers.keys.toList(),
        'namespaces': {
          for (final ns in ['llm-pi-ai', 'agent-default-model', 'deepclub-tools']) ns: {'present': before.namespaces.containsKey(ns), 'writable': before.namespaces[ns]?.writable, 'revision': before.namespaces[ns]?.revision},
        },
      })}',
    );
    expect(
      config.recommendation,
      isNotNull,
      reason: 'The live fixture catalog must have an available published chat model; do not substitute stale configuration.',
    );
    var stage = 'credentials/set';
    try {
      await engine.setKey(key);
      // ignore: avoid_print
      print('PASS credentials/set');
      stage = 'applyConfig';
      await engine.applyConfig(config, adoptRecommendation: true);
      // ignore: avoid_print
      print('PASS full applyConfig');
      final applied = await client.describeSettings();
      final resolvedProviders = applied.namespaces['llm-pi-ai']!.value['providers'] as Map;
      for (final route in config.providers.entries) {
        final expectedRoute = route.value as Map;
        final resolved = resolvedProviders[route.key] as Map;
        for (final field in ['api', 'baseURL', 'apiKeyEnv', 'displayName']) {
          expect(resolved[field], expectedRoute[field]);
        }
        for (final compat in (expectedRoute['compat'] as Map).entries) {
          expect((resolved['compat'] as Map)[compat.key], compat.value);
        }
        expect(
          ((resolved['models'] as List).first as Map)['reasoningEfforts'],
          ((expectedRoute['models'] as List).first as Map)['reasoningEfforts'],
        );
      }
      expect(applied.namespaces['agent-default-model']!.value['provider'], config.recommendation!['provider']);
      expect(applied.namespaces['agent-default-model']!.value['model'], config.recommendation!['model']);
      expect(applied.namespaces['deepclub-tools']!.value['catalog'], config.raw);
      if (Platform.environment['DEEPCLUB_REAL_TURN'] == '1') {
        stage = 'actual session turn';
        await _probeTurn(client, config, requiredText(info, 'root'));
      }
      stage = 'clearKey';
      await engine.clearKey();
      expect((await client.describeCredentials([deepClubKeyRef]))[deepClubKeyRef]?.configured ?? false, isFalse);
      // ignore: avoid_print
      print('PASS full fixture configuration and cleanup');
    } catch (error) {
      final after = await client.describeSettings();
      final safe = error.toString().replaceAll(key, '<synthetic-key>').replaceAll(session, '<synthetic-session>');
      // ignore: avoid_print
      print(
        'FULL_CONFIG_FAILURE ${jsonEncode({
          'stage': stage,
          'error': safe,
          'revisionsAfter': {
            for (final ns in ['llm-pi-ai', 'agent-default-model', 'deepclub-tools']) ns: after.namespaces[ns]?.revision,
          },
        })}',
      );
      rethrow;
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
