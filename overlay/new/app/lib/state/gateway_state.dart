import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dsh_client/dsh_client.dart' show DshCarrierRefusedException;
import 'package:shared_preferences/shared_preferences.dart';

import '../deepclub/account_state.dart';
import '../deepclub/client_api.dart';
import '../links/app_links.dart';
import '../remote/gateway_carrier.dart';
import '../remote/gateway_pairing.dart';
import 'hosts_state.dart';
import 'read_list_epoch.dart';

export '../remote/gateway_pairing.dart';

class GatewayHostsState {
  const GatewayHostsState({this.hosts = const [], this.loaded = false, this.error});
  final List<GatewayHost> hosts;
  final bool loaded;
  final String? error;
  GatewayHost? byId(String id) {
    for (final host in hosts) {
      if (host.id == id) return host;
    }
    return null;
  }
}

/// Only public metadata enters preferences. Every token stays in SecretStore.
/// Mutation order prevents an old save from landing after logout cleanup.
class GatewayHostsController extends Notifier<GatewayHostsState> {
  static const prefsKey = 'deepclub_gateway_hosts';
  late Future<void> _loaded;
  Future<void> _tail = Future.value();
  Future<void> get ready => _loaded;
  @override
  GatewayHostsState build() {
    _loaded = _load();
    ref.listen(deepClubAccountProvider, (before, after) {
      if (after.loaded && (!after.signedIn || before?.signedIn == true && before?.binding != after.binding)) {
        unawaited(
          clear().catchError((Object _) {
            if (ref.mounted) state = const GatewayHostsState(loaded: true, error: 'storage_failed');
          }),
        );
      }
    });
    return const GatewayHostsState();
  }

  Future<void> _load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(prefsKey);
      final hosts = raw == null
          ? <GatewayHost>[]
          : (jsonDecode(raw) as List).map((e) => GatewayHost.fromJson(Map<String, dynamic>.from(e as Map))).toList();
      if (ref.mounted) state = GatewayHostsState(hosts: hosts, loaded: true);
    } catch (_) {
      if (ref.mounted) state = const GatewayHostsState(loaded: true);
    }
  }

  Future<void> _run(Future<void> Function() action) {
    final result = _tail.then((_) async {
      await _loaded;
      await action();
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _persist(List<GatewayHost> hosts) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(prefsKey, jsonEncode(hosts.map((h) => h.toJson()).toList()))) {
      throw const DeepClubFailure('storage_failed');
    }
    if (ref.mounted) state = GatewayHostsState(hosts: List.unmodifiable(hosts), loaded: true);
  }

  Future<void> save(GatewayHost host, String token) => _run(() async {
    final account = ref.read(deepClubAccountProvider);
    if (!account.signedIn || host.binding != account.binding) throw const DeepClubFailure('login_required');
    await ref.read(secretStoreProvider).write(GatewayHost.tokenKey(host.id), token);
    await _persist([...state.hosts.where((h) => h.id != host.id), host]);
    ref.read(readListCredentialEpochProvider.notifier).advance();
  });

  Future<void> remove(String id) => _run(() async {
    // Retire the link before an asynchronous Keystore or disk write can fail.
    final hosts = state.hosts.where((h) => h.id != id).toList();
    state = GatewayHostsState(hosts: hosts, loaded: true);
    await ref.read(activeHostProvider.notifier).forget((h) => h.kind == HostKind.gateway && h.id == id);
    await ref.read(secretStoreProvider).delete(GatewayHost.tokenKey(id));
    await _persist(hosts);
  });

  Future<void> clear() => _run(() async {
    final hosts = state.hosts;
    state = const GatewayHostsState(loaded: true);
    await ref.read(activeHostProvider.notifier).forget((h) => h.kind == HostKind.gateway);
    var failed = false;
    for (final host in hosts) {
      try {
        await ref.read(secretStoreProvider).delete(GatewayHost.tokenKey(host.id));
      } catch (_) {
        failed = true;
      }
    }
    await _persist([]);
    if (failed) throw const DeepClubFailure('storage_failed');
  });
}

final gatewayHostsProvider = NotifierProvider<GatewayHostsController, GatewayHostsState>(GatewayHostsController.new);

typedef GatewayCarrierFactory = GatewayCarrier Function(
  GatewayHost host, {
  String? code,
  Future<void> Function(String)? paired,
});
final gatewayCarrierFactoryProvider = Provider<GatewayCarrierFactory>((ref) {
  final service = ref.read(deepClubAccountProvider.notifier).service;
  final secrets = ref.read(secretStoreProvider);
  return (host, {code, paired}) {
    void bound() {
      if (!service.state.signedIn || service.state.binding != host.binding) {
        throw const DeepClubFailure('login_required');
      }
    }

    return GatewayCarrier(
      host: host,
      deviceId: () async {
        bound();
        return (await service.remoteDevice())['device_id']!;
      },
      assertion: (purpose) async {
        bound();
        final proof = await service.remoteAssertion(host.id, host.hostKey, purpose);
        bound();
        return proof;
      },
      loadToken: () => secrets.read(GatewayHost.tokenKey(host.id)),
      relaySession: () {
        bound();
        return service.relaySession();
      },
      pairingCode: code,
      onPaired: paired,
    );
  };
});

bool isGatewayPairLink(Uri uri) =>
    uri.scheme == 'https' && uri.host == 'deepclub.net' && uri.path == '/pair' ||
    uri.scheme == 'deepclub' && uri.host == 'pair' && uri.path.isEmpty;

class GatewayPairState {
  const GatewayPairState({this.busy = false, this.error, this.host, this.hasLink = false});
  final bool busy, hasLink;
  final String? error;
  final GatewayHost? host;
}

class GatewayPairController extends Notifier<GatewayPairState> {
  String? _pendingLink;
  GatewayCarrier? _carrier;
  int _epoch = 0;
  int _presentations = 0;
  bool get presented => _presentations > 0;
  void attach() => _presentations++;
  void detach() {
    if (_presentations > 0) _presentations--;
  }

  @override
  GatewayPairState build() {
    final router = ref.read(linkRouterProvider);
    final unregister = router.registerEarlyLinkHandler(isGatewayPairLink, (uri) async {
      _pendingLink = uri.toString();
      reset();
      return true;
    });
    ref.listen(deepClubAccountProvider, (before, after) {
      if (before?.signedIn == true && (!after.signedIn || before?.binding != after.binding)) {
        _pendingLink = null;
        reset();
      }
    });
    ref.onDispose(() {
      unregister();
      unawaited(_carrier?.close());
    });
    return const GatewayPairState();
  }

  void cancel() {
    _epoch++;
    unawaited(_carrier?.close());
    _carrier = null;
  }

  void reset() {
    cancel();
    state = GatewayPairState(hasLink: _pendingLink != null);
  }

  Future<GatewayHost?> pending() async {
    final link = _pendingLink;
    _pendingLink = null;
    return link == null ? null : pair(link);
  }

  Future<GatewayHost?> pair(String input) async {
    if (state.busy) return null;
    final epoch = ++_epoch;
    state = const GatewayPairState(busy: true);
    GatewayCarrier? carrier;
    try {
      final qr = GatewayPairing.parse(input);
      final account = ref.read(deepClubAccountProvider);
      if (!account.signedIn || account.binding.isEmpty) throw const DeepClubFailure('login_required');
      await ref.read(gatewayHostsProvider.notifier).ready;
      final previous = ref.read(gatewayHostsProvider).byId(qr.gatewayId);
      if (previous != null && previous.hostKey != qr.hostKey) throw const GatewayPairingFailure('host_key_mismatch');
      final host = GatewayHost(
        id: qr.gatewayId,
        name: qr.name,
        hostKey: qr.hostKey,
        endpoints: qr.endpoints,
        binding: account.binding,
      );
      String? token;
      carrier = _carrier = ref.read(gatewayCarrierFactoryProvider)(
        host,
        code: qr.code,
        paired: (value) async {
          token = value;
        },
      );
      await carrier.authenticate();
      if (!ref.mounted || epoch != _epoch || ref.read(deepClubAccountProvider).binding != account.binding) return null;
      await ref.read(gatewayHostsProvider.notifier).save(host, token!);
      if (!ref.mounted || epoch != _epoch || ref.read(deepClubAccountProvider).binding != account.binding) return null;
      state = GatewayPairState(host: host);
      return host;
    } catch (error) {
      if (ref.mounted && epoch == _epoch) {
        state = GatewayPairState(
          error: switch (error) {
            GatewayPairingFailure(:final code) => code,
            DeepClubFailure(:final code) => code,
            DshCarrierRefusedException(:final code) => code,
            _ => 'pairing_failed',
          },
        );
      }
      return null;
    } finally {
      await carrier?.close();
      if (identical(_carrier, carrier)) _carrier = null;
    }
  }
}

final gatewayPairProvider = NotifierProvider<GatewayPairController, GatewayPairState>(GatewayPairController.new);
