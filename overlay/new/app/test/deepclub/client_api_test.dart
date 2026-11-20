import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/deepclub/account_service.dart';
import 'package:dsh_app/deepclub/client_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support.dart';

class _HangingClient extends http.BaseClient {
  _HangingClient({this.headers = true});
  final bool headers;
  bool aborted = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final waiting = Completer<http.StreamedResponse>();
    final body = StreamController<List<int>>();
    unawaited(
      (request as http.Abortable).abortTrigger!.then((_) async {
        aborted = true;
        if (headers) {
          waiting.completeError(http.RequestAbortedException());
        } else {
          body.addError(http.RequestAbortedException());
        }
        await body.close();
      }),
    );
    return headers ? waiting.future : http.StreamedResponse(body.stream, 200);
  }
}

void main() {
  test('only debug builds accept explicit emulator fixture origins', () {
    for (final value in ['http://10.0.2.2:8181', 'http://127.0.0.1:8123/']) {
      expect(resolveDeepClubOrigin(debug: true, testOrigin: value), Uri.parse(value).origin);
      expect(resolveDeepClubOrigin(debug: false, testOrigin: value), deepClubOrigin);
    }
    for (final value in [
      'https://evil.invalid',
      'http://10.0.2.2',
      'http://10.0.2.2:8181/collect',
      'http://user@127.0.0.1:8123',
      'http://localhost:8123',
      'http://127.0.0.1:0',
      'http://127.0.0.1:8123?x=1',
    ]) {
      expect(() => resolveDeepClubOrigin(debug: true, testOrigin: value), throwsA(isA<DeepClubFailure>()));
      expect(resolveDeepClubOrigin(debug: false, testOrigin: value), deepClubOrigin);
    }
  });

  for (final headers in [true, false]) {
    test(
      'timeout aborts a hanging ${headers ? 'DNS/connect/headers' : 'response body'} and releases local logout',
      () async {
        final client = _HangingClient(headers: headers);
        final api = DeepClubApi(client: client, requestTimeout: const Duration(milliseconds: 30));
        final storage = MemoryStore();
        storage.values['session'] = jsonEncode(sessionJson());
        final engine = FakeEngine()..key = 'synthetic-model-key';
        final service = DeepClubAccountService(
          api: api,
          store: storage,
          localEngine: () => engine,
          clearStoppedEngine: () async {},
          appVersion: '1.0',
        );
        addTearDown(() async {
          api.close();
          await service.close();
        });
        final restore = service.restore();
        final logout = service.logout(localOnly: true);
        await expectLater(
          restore,
          throwsA(isA<DeepClubFailure>().having((e) => e.code, 'code', 'network_unavailable')),
        );
        await logout;
        expect(client.aborted, isTrue);
        expect(service.state.signedIn, isFalse);
        expect(service.state.serverNotRevoked, isTrue);
        expect(engine.key, isNull);
      },
    );
  }

  test('redirect responses are rejected and a session token never enters a URL', () async {
    final requests = <http.Request>[];
    final api = DeepClubApi(
      client: MockClient((request) async {
        requests.add(request);
        return http.Response('', 302, headers: {'location': 'https://other.invalid/collect'});
      }),
    );
    addTearDown(api.close);
    await expectLater(
      api.call('GET', '/api/client/bootstrap', session: 'synthetic-session'),
      throwsA(isA<DeepClubFailure>()),
    );
    expect(requests, hasLength(1));
    expect(requests.single.followRedirects, isFalse);
    expect(requests.single.url.toString(), isNot(contains('synthetic-session')));
    expect(requests.single.headers['Authorization'], 'Bearer synthetic-session');
  });
}
