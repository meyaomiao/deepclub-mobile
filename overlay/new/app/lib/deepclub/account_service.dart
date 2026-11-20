import 'dart:async';
import 'dart:convert';

import 'agent_config.dart';
import 'client_api.dart';
import 'secure_store.dart';

class DeepClubSession {
  const DeepClubSession({
    required this.token,
    required this.expiresAt,
    required this.user,
    this.apiKey,
    this.revision,
    this.initialChoiceDone = false,
  });
  factory DeepClubSession.fromJson(Map<String, Object?> data) => DeepClubSession(
    token: requiredText(data, 'session_token'),
    expiresAt: DateTime.parse(requiredText(data, 'expires_at')),
    user: jsonObject(data['user']),
    apiKey: data['api_key'] as String?,
    revision: data['revision'] as String?,
    initialChoiceDone: data['initial_choice_done'] == true,
  );
  final String token;
  final DateTime expiresAt;
  final Map<String, Object?> user;
  final String? apiKey;
  final String? revision;
  final bool initialChoiceDone;
  DeepClubSession copyWith({String? apiKey, String? revision, DateTime? expiresAt, bool? initialChoiceDone}) =>
      DeepClubSession(
        token: token,
        expiresAt: expiresAt ?? this.expiresAt,
        user: user,
        apiKey: apiKey ?? this.apiKey,
        revision: revision ?? this.revision,
        initialChoiceDone: initialChoiceDone ?? this.initialChoiceDone,
      );
  Map<String, Object?> toJson() => {
    'session_token': token,
    'expires_at': expiresAt.toIso8601String(),
    'user': user,
    'api_key': apiKey,
    'revision': revision,
    'initial_choice_done': initialChoiceDone,
  };
}

/// Public state carries no session token, API key, password or PKCE verifier.
class DeepClubAccountState {
  const DeepClubAccountState({
    this.loaded = false,
    this.busy = false,
    this.signedIn = false,
    this.awaitingBrowser = false,
    this.require2fa = false,
    this.engineReady = false,
    this.cleanupBlocked = false,
    this.serverNotRevoked = false,
    this.user = const {},
    this.bootstrap,
    this.devices = const [],
    this.config,
    this.error,
  });
  final bool loaded, busy, signedIn, awaitingBrowser, require2fa, engineReady, cleanupBlocked, serverNotRevoked;
  final Map<String, Object?> user;
  final Map<String, Object?>? bootstrap;
  final List<Map<String, Object?>> devices;
  final DeepClubAgentConfig? config;
  final String? error;

  /// Optional, display-only bootstrap data. Malformed announcements do not
  /// change account or engine state, and their text is never treated as a link.
  ({String content, String? publish})? get announcement {
    final value = bootstrap?['announcement'];
    if (value is! Map) return null;
    final content = value['content'];
    if (content is! String || content.trim().isEmpty) return null;
    final publish = value['publish'];
    return (content: content.trim(), publish: publish is String && publish.trim().isNotEmpty ? publish.trim() : null);
  }
}

/// Serializes login, sync and logout. In particular, a late sync cannot restore
/// the key after logout finishes. The engine callback returns a local client only.
class DeepClubAccountService {
  DeepClubAccountService({
    required this.api,
    required this.store,
    required this.localEngine,
    required this.clearStoppedEngine,
    required this.appVersion,
  });
  final DeepClubApi api;
  final DeepClubStore store;
  final DeepClubEngine? Function() localEngine;
  final Future<void> Function() clearStoppedEngine;
  final String appVersion;
  final _changes = StreamController<DeepClubAccountState>.broadcast();
  Stream<DeepClubAccountState> get changes => _changes.stream;
  Future<void> _tail = Future.value();
  DeepClubSession? _session;
  String? _pending2fa;
  bool _loaded = false,
      _busy = false,
      _awaiting = false,
      _ready = false,
      _cleanupBlocked = false,
      _serverNotRevoked = false;
  String? _error;
  DeepClubAgentConfig? _config;
  Map<String, Object?>? _bootstrap;
  List<Map<String, Object?>> _devices = const [];
  DeepClubEngine? _keyEngine;
  DeepClubEngine? _configEngine;
  String? _keyValue;
  DeepClubAccountState get state => DeepClubAccountState(
    loaded: _loaded,
    busy: _busy,
    signedIn: _session != null,
    awaitingBrowser: _awaiting,
    require2fa: _pending2fa != null,
    engineReady: _ready,
    cleanupBlocked: _cleanupBlocked,
    serverNotRevoked: _serverNotRevoked,
    user: _session?.user ?? const {},
    bootstrap: _bootstrap,
    devices: _devices,
    config: _config,
    error: _error,
  );
  void _publish() {
    if (!_changes.isClosed) _changes.add(state);
  }

  Future<T> _run<T>(Future<T> Function() operation) {
    final result = _tail.then((_) async {
      _busy = true;
      _error = null;
      _publish();
      try {
        return await operation();
      } catch (error) {
        _error = error is DeepClubFailure
            ? (error.invalidSession ? 'session_expired' : error.code)
            : 'operation_failed';
        if (error is DeepClubFailure && error.invalidSession && _session != null) {
          try {
            await _clearLocal();
          } catch (_) {
            _error = 'cleanup_failed';
            rethrow;
          }
        }
        rethrow;
      } finally {
        _busy = false;
        _publish();
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _save() async {
    if (_session case final session?) await store.write('session', jsonEncode(session.toJson()));
  }

  Future<ClientReply> _authenticated(String method, String path, {Map<String, Object?>? body}) async {
    final session = _session;
    if (session == null) throw const DeepClubFailure('login_required');
    final reply = await api.call(method, path, session: session.token, body: body);
    if (reply.expiresAt case final expiry?) {
      _session = _session!.copyWith(expiresAt: expiry);
      await _save();
    }
    return reply;
  }

  Future<void> restore() => _run(() async {
    try {
      _serverNotRevoked = await store.read('server_not_revoked') == '1';
      // The marker is committed before any logout cleanup. A killed process
      // cannot revive its old secure-storage session on the next launch.
      if (await store.read('cleanup') != null) {
        await _clearLocal();
      } else if (await store.read('session') case final raw?) {
        _session = DeepClubSession.fromJson(jsonObject(jsonDecode(raw)));
      }
      _awaiting = await store.read('pkce') != null;
      if (_session != null) await _synchronize();
    } finally {
      _loaded = true;
    }
  });

  Future<Map<String, String>> _device() async {
    var id = await store.read('device_id');
    if (id == null) {
      id = secureUrlToken();
      await store.write('device_id', id);
    }
    return {'device_id': id, 'device_name': 'DeepClub Android', 'platform': 'android', 'app_version': appVersion};
  }

  Future<Uri> beginBrowserLogin() => _run(() async {
    final pending = PendingAuthorization.create();
    await store.write('pkce', pending.encode());
    _pending2fa = null;
    _awaiting = true;
    return pending.authorizeUri(await _device());
  });

  Future<void> cancelBrowserLogin() => _run(() async {
    await store.delete('pkce');
    _awaiting = false;
    _pending2fa = null;
  });

  Future<void> acceptCallback(Uri uri) => _run(() async {
    final raw = await store.read('pkce');
    if (raw == null) throw const DeepClubFailure('authorization_expired');
    final pending = PendingAuthorization.decode(raw);
    final String code;
    try {
      code = pending.codeFrom(uri);
    } on DeepClubFailure catch (error) {
      if (error.code == 'authorization_denied' || error.code == 'authorization_expired') {
        await store.delete('pkce');
        _awaiting = false;
      }
      rethrow;
    }
    // Consume before the network request, including when exchange fails. A new
    // browser attempt is the recovery path; no duplicate callback can exchange.
    await store.delete('pkce');
    _awaiting = false;
    final reply = await api.call(
      'POST',
      '/api/client/token',
      body: {
        'grant_type': 'authorization_code',
        'client_id': deepClubClientId,
        'redirect_uri': deepClubRedirect,
        'code': code,
        'code_verifier': pending.verifier,
      },
    );
    await _acceptSession(reply.object);
  });

  Future<void> loginWithPassword(String username, String password, {List<int> revokeSessionIds = const []}) =>
      _run(() async {
        await store.delete('pkce');
        _awaiting = false;
        final result = await api.call(
          'POST',
          '/api/client/login',
          body: {
            'username': username,
            'password': password,
            ...await _device(),
            if (revokeSessionIds.isNotEmpty) 'revoke_session_ids': revokeSessionIds,
          },
        );
        if (result.object['require_2fa'] == true) {
          _pending2fa = requiredText(result.object, 'pending_token');
          return;
        }
        await _acceptSession(result.object);
      });

  Future<void> verify2fa(String code, {List<int> revokeSessionIds = const []}) => _run(() async {
    if (_pending2fa == null) throw const DeepClubFailure('authorization_expired');
    final result = await api.call(
      'POST',
      '/api/client/login/2fa',
      body: {
        'pending_token': _pending2fa,
        'code': code,
        if (revokeSessionIds.isNotEmpty) 'revoke_session_ids': revokeSessionIds,
      },
    );
    _pending2fa = null;
    await _acceptSession(result.object);
  });

  Future<void> _acceptSession(Map<String, Object?> data) async {
    // Finish any failed previous-account cleanup before making a new key usable.
    if (await store.read('cleanup') != null) await _clearLocal();
    await store.delete('cleanup');
    _session = DeepClubSession.fromJson(data);
    await store.delete('server_not_revoked');
    _serverNotRevoked = false;
    _ready = false;
    await _save();
    await _synchronize();
  }

  Future<void> synchronize() => _run(_synchronize);
  Future<void> _synchronize() async {
    if (_session == null) return;
    if (_session!.apiKey == null) {
      final provision = await _authenticated('POST', '/api/client/provision', body: {});
      _session = _session!.copyWith(apiKey: requiredText(provision.object, 'api_key'));
      await _save();
    }
    // Validate the current session/Key before healing a local credential.
    _config = DeepClubAgentConfig.fromJson((await _authenticated('GET', '/api/client/agent-config')).data);
    await _applyToLocal();
    _bootstrap = (await _authenticated('GET', '/api/client/bootstrap')).object;
    await _loadDevices();
  }

  Future<void> localEngineConnected() => _run(() async {
    if (await store.read('cleanup') != null) await _clearLocal();
    if (_session != null) {
      // A failed startup fetch leaves no validated config. Recheck on connect.
      if (_config == null) {
        await _synchronize();
      } else {
        await _applyToLocal();
      }
    }
  });

  Future<void> _applyToLocal() async {
    final engine = localEngine();
    final config = _config;
    final session = _session;
    if (engine == null || config == null || session?.apiKey == null) {
      _ready = false;
      return;
    }
    if (!identical(engine, _keyEngine) || session!.apiKey != _keyValue) {
      await engine.setKey(session!.apiKey!);
      _keyEngine = engine;
      _keyValue = session.apiKey;
    }
    if (session.revision != config.revision || !identical(engine, _configEngine)) {
      await engine.applyConfig(config, adoptRecommendation: !session.initialChoiceDone);
      _configEngine = engine;
      _session = _session!.copyWith(
        revision: config.revision,
        initialChoiceDone: session.initialChoiceDone || config.recommendation != null,
      );
      await _save();
    }
    _ready = true;
  }

  Future<void> _loadDevices() async {
    final result = await _authenticated('GET', '/api/client/devices');
    if (result.data is! List) throw const DeepClubFailure('invalid_response');
    _devices = [for (final item in result.data as List) jsonObject(item)];
  }

  Future<void> revokeDevice(int id) => _run(() async {
    final current = _devices.any((d) => d['id'] == id && d['is_current'] == true);
    await _authenticated('DELETE', '/api/client/devices/$id');
    if (current) {
      await _clearLocal();
    } else {
      await _loadDevices();
    }
  });

  Future<void> logout({bool localOnly = false}) => _run(() async {
    var unconfirmed = localOnly;
    if (!localOnly && _session != null) {
      try {
        await _authenticated('POST', '/api/client/logout', body: {});
      } on DeepClubFailure catch (error) {
        if (!error.invalidSession) rethrow;
        unconfirmed = error.status == 403;
      }
    }
    _serverNotRevoked = unconfirmed;
    await _clearLocal();
  });

  Future<void> _clearLocal() async {
    _cleanupBlocked = true;
    _session = null;
    _config = null;
    _bootstrap = null;
    _devices = const [];
    _pending2fa = null;
    _awaiting = false;
    _ready = false;
    _keyValue = null;
    _keyEngine = null;
    _configEngine = null;
    _publish();
    // Keystore failures must not skip clearing the running engine. The marker
    // prevents interrupted cleanup from restoring a saved session later.
    var storageFailed = false;
    try {
      await store.write('cleanup', 'credentials');
    } catch (_) {
      storageFailed = true;
    }
    try {
      await store.delete('session');
      await store.delete('pkce');
      if (_serverNotRevoked) await store.write('server_not_revoked', '1');
    } catch (_) {
      storageFailed = true;
    }
    try {
      final engine = localEngine();
      if (engine != null) {
        try {
          await engine.clearKey();
          if (storageFailed) throw const DeepClubFailure('cleanup_failed');
          await store.delete('cleanup');
          _cleanupBlocked = false;
          return;
        } catch (_) {
          // A disconnected/failed engine must be stopped before its file is
          // changed, otherwise an in-memory credential could remain usable.
        }
      }
      await clearStoppedEngine();
      if (storageFailed) throw const DeepClubFailure('cleanup_failed');
      // Native cleanup clears the Key while stopped; remove a stale catalog
      // through the engine API once a local connection is available again.
      await store.write('cleanup', 'catalog');
      _cleanupBlocked = false;
    } catch (_) {
      _cleanupBlocked = true;
      throw const DeepClubFailure('cleanup_failed');
    }
  }

  Future<void> retryCleanup() => _run(_clearLocal);
  Future<void> close() => _changes.close();
}
