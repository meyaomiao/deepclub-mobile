import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_app/share_code/conversation_html.dart';
import 'package:dsh_app/share_code/conversation_share.dart';
import 'package:dsh_app/share_code/share_code_state.dart';
import 'package:dsh_app/share_code/share_codec.dart';
import 'package:dsh_app/share_code/share_link.dart';
import 'package:dsh_app/share_code/share_models.dart';
import 'package:dsh_app/share_code/share_net.dart';
import 'package:dsh_app/share_hosted/hosted_client.dart';
import 'package:dsh_app/share_hosted/hosted_link.dart';
import 'package:dsh_app/ui/replay/conversation_out.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('hosted upload, download and delete reject without sending a request', () async {
    var requests = 0;
    final client = HostedShareClient(
      client: MockClient((request) async {
        requests++;
        return http.Response('{}', 200);
      }),
    );
    addTearDown(client.close);
    final link = HostedLink(
      id: 'a1B2c3D4e5',
      key: 'A' * 43,
      deleteToken: 'synthetic-delete-token',
      title: 'Local test',
      createdAt: DateTime.utc(2026),
      ttl: HostedTtl.month,
    );
    final unavailable = throwsA(
      isA<HostedShareException>().having((e) => e.kind, 'kind', HostedShareError.unavailable),
    );
    await expectLater(client.upload(Uint8List.fromList([1, 2, 3]), HostedTtl.week), unavailable);
    await expectLater(client.download(link.url), unavailable);
    await expectLater(client.delete(link), unavailable);
    // Caller-supplied origins cannot enable an upstream fallback.
    final other = HostedShareClient(
      origin: 'https://example.invalid',
      client: MockClient((request) async {
        requests++;
        return http.Response('', 200);
      }),
    );
    addTearDown(other.close);
    await expectLater(other.upload(Uint8List(0), HostedTtl.forever), unavailable);
    expect(requests, 0);
  });

  test('local inline and legacy files parse without optional network enrichment', () async {
    var clientsCreated = 0;
    final net = HttpShareNet(
      client: () {
        clientsCreated++;
        throw StateError('No network client may be created');
      },
    );
    final payload = ProfileShare(
      name: 'Local config',
      settings: {
        'subagent': {'maxDepth': 2},
      },
    );
    final code = encodeShareCode(payload);
    final link = ShareLink.inline(ShareKind.profile, code);
    expect(link.webLink, startsWith('deepclub://share/profile?p='));
    expect((await resolveShareLink(link, net)).toJson(), payload.toJson());
    final legacy = ShareLink.parse(Uri.parse('dshgo://share/profile?p=$code'))!;
    expect((await resolveShareLink(legacy, net)).toJson(), payload.toJson());
    final landing = ShareLink.find('saved https://go.dshtui.com/share/#p=$code')!;
    expect((await resolveShareLink(landing, net)).toJson(), payload.toJson());
    final legacyFile = jsonEncode({'dshgo': 1, 'kind': 'profile', 'name': 'Local config', 'code': code});
    expect(decodeShareFile(legacyFile).toJson(), payload.toJson());
    expect(decodeShareFile(encodeShareFile(payload)).toJson(), payload.toJson());
    expect(await net.npmFacts('@acme/example', '1.0.0'), isNull);
    await expectLater(net.fetchGist('a' * 32), throwsA(isA<GistException>()));
    await expectLater(
      net.createGist(token: 'synthetic-token', fileName: 'test.deepclub', content: legacyFile),
      throwsA(isA<GistException>()),
    );
    expect(clientsCreated, 0);
  });

  test('conversation files and offline HTML retain replay data with DeepClub output types', () {
    final share = ConversationShare.fromJson({
      'v': 2,
      'schema': 1,
      'kind': 'conversation',
      'title': 'Local replay',
      'start': '2026-01-01T00:00:00Z',
      'entries': <Object?>[],
    });
    final file = encodeConversationFile(share, const []);
    expect(decodeConversationFile(file).share.title, 'Local replay');
    expect(shareFileMime, 'application/vnd.deepclub.agent+json');
    expect(ConversationOut.fileName(share.title, ConversationFormat.file), 'Local replay.deepclub');
    expect(ConversationFormat.file.mime, shareFileMime);
    final html = conversationHtml(file, title: share.title);
    expect(html, contains('Local replay · DeepClub'));
    expect(html, contains("connect-src 'none'"));
    expect(html, contains('application/vnd.deepclub.agent+json'));
    expect(html, isNot(contains('https://github.com/ccch1mneyyy/dsh-go/releases/latest')));
    expect(html, isNot(contains("'/api/v1/c/'")));
    expect(html, contains('Local replay'));
  });
}
