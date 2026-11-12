import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../links/app_links.dart';
import '../runtime/runtime_bridge.dart';
import '../runtime/runtime_state.dart';
import '../state/app_info.dart';
import '../state/connection_state.dart';
import 'account_service.dart';
import 'agent_config.dart';
import 'client_api.dart';
import 'secure_store.dart';

export 'account_service.dart' show DeepClubAccountState;

final deepClubStoreProvider = Provider<DeepClubStore>((ref) => const SecureDeepClubStore());
final deepClubApiProvider = Provider<DeepClubApi>((ref) {
  final api = DeepClubApi();
  ref.onDispose(api.close);
  return api;
});
final deepClubLocalEngineProvider = Provider<DeepClubEngine?>((ref) {
  final connection = ref.watch(localConnectionProvider);
  if (connection.isLoading || connection.hasError || connection.value == null) return null;
  return LocalDeepClubEngine(connection.value!);
});

Future<void> _clearStoppedEngine(Ref ref) async {
  final stopped = Completer<void>();
  bool isStopped() {
    final phase = ref.read(localRuntimeProvider).status.phase;
    return phase != RuntimePhase.running && phase != RuntimePhase.starting && phase != RuntimePhase.stopping;
  }

  final listener = ref.container.listen(localRuntimeProvider, (_, next) {
    if (isStopped() && !stopped.isCompleted) stopped.complete();
  });
  try {
    if (!isStopped()) {
      await ref.read(localRuntimeProvider.notifier).stop();
      if (!isStopped()) await stopped.future.timeout(const Duration(seconds: 20));
    }
    final result = await const MethodChannel('dsh/runtime')
        .invokeMapMethod<String, Object?>('clearDeepClubCredentials');
    if (result?['cleared'] != true) throw const DeepClubFailure('cleanup_failed');
  } finally {
    listener.close();
  }
}

class DeepClubAccountController extends Notifier<DeepClubAccountState> {
  late DeepClubAccountService service;
  @override
  DeepClubAccountState build() {
    service = DeepClubAccountService(
      api: ref.read(deepClubApiProvider),
      store: ref.read(deepClubStoreProvider),
      localEngine: () => ref.read(deepClubLocalEngineProvider),
      clearStoppedEngine: () => _clearStoppedEngine(ref),
      appVersion: AppInfo.version,
    );
    final subscription = service.changes.listen((value) {
      if (ref.mounted) state = value;
    });
    // Restore is queued before a cold-start callback can arrive.
    unawaited(service.restore().catchError((Object _) {}));
    // Keep the regular router listening, but auth callbacks have their own early
    // path and do not wait for the home shell to appear.
    final router = ref.read(linkRouterProvider);
    final unregisterAuth = router.registerEarlyLinkHandler((uri) => uri.scheme == 'deepclub' && uri.host == 'auth', (
      uri,
    ) async {
      try {
        await service.acceptCallback(uri);
      } catch (_) {
        /* Public account state carries the safe error. */
      }
      return true;
    });
    ref.listen(deepClubLocalEngineProvider, (before, after) {
      if (after != null) unawaited(service.localEngineConnected().catchError((Object _) {}));
    });
    ref.onDispose(() {
      unawaited(subscription.cancel());
      unregisterAuth();
      unawaited(service.close());
    });
    return service.state;
  }

  Future<void> browserLogin() async {
    final uri = await service.beginBrowserLogin();
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw const DeepClubFailure('browser_unavailable');
      }
    } catch (_) {
      await service.cancelBrowserLogin();
      throw const DeepClubFailure('browser_unavailable');
    }
  }

  Future<void> synchronize() => service.synchronize();
}

final deepClubAccountProvider = NotifierProvider<DeepClubAccountController, DeepClubAccountState>(
  DeepClubAccountController.new,
);
