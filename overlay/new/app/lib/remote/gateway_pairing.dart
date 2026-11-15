import 'dart:convert';
import 'dart:io';

/// Public QR metadata. The one-use code is kept only for the pairing attempt.
/// Neither a URL nor this object is suitable for diagnostics.
class GatewayPairing {
  const GatewayPairing({
    required this.gatewayId,
    required this.name,
    required this.hostKey,
    required this.endpoints,
    required this.code,
    required this.expiresAt,
  });

  static const protocol = 'deepclub-native-v1';
  final String gatewayId, name, hostKey, code;
  final List<Uri> endpoints;
  final DateTime expiresAt;

  factory GatewayPairing.parse(String input, {DateTime? now}) {
    try {
      var encoded = input.trim();
      if (encoded.length > 16384) throw const GatewayPairingFailure('invalid_pairing');
      final uri = Uri.tryParse(encoded);
      if (uri != null && uri.hasScheme) {
        final universal = uri.scheme == 'https' && uri.host == 'deepclub.net' && uri.path == '/pair';
        final app = uri.scheme == 'deepclub' && uri.host == 'pair' && uri.path.isEmpty;
        if ((!universal && !app) || uri.userInfo.isNotEmpty || uri.hasPort || uri.hasQuery || !uri.hasFragment) {
          throw const GatewayPairingFailure('invalid_pairing');
        }
        encoded = uri.fragment;
      }
      final value = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(encoded))));
      if (value is! Map<String, dynamic> || value['version'] != 2) {
        throw const GatewayPairingFailure('version_incompatible');
      }
      String text(String key) {
        final valueOf = value[key];
        if (valueOf is! String || valueOf.isEmpty) throw const GatewayPairingFailure('invalid_pairing');
        return valueOf;
      }

      final id = text('gatewayId');
      final key = text('hostKey');
      final name = text('gatewayName').trim();
      final code = text('pairingCode');
      if (!RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$')
              .hasMatch(id) ||
          !validGatewayHostKey(key) ||
          name.isEmpty ||
          name.length > 128 ||
          !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(code)) {
        throw const GatewayPairingFailure('invalid_pairing');
      }
      if (value['protocols'] is! List || !(value['protocols'] as List).contains(protocol)) {
        throw const GatewayPairingFailure('version_incompatible');
      }
      final expiry = value['expiresAt'];
      final expiresAt = expiry is num
          ? DateTime.fromMillisecondsSinceEpoch(expiry.toInt(), isUtc: true)
          : DateTime.parse(text('expiresAt')).toUtc();
      final clock = (now ?? DateTime.now()).toUtc();
      if (!expiresAt.isAfter(clock)) throw const GatewayPairingFailure('pairing_expired');
      if (expiresAt.difference(clock) > const Duration(minutes: 10)) {
        throw const GatewayPairingFailure('invalid_pairing');
      }
      final candidates = <String>[];
      final raw = value['endpoints'];
      if (raw is List) {
        for (final endpoint in raw) {
          if (endpoint is String) candidates.add(endpoint);
          if (endpoint is Map && endpoint['url'] is String) candidates.add(endpoint['url'] as String);
        }
      }
      if (value['publicUrl'] is String) candidates.add(value['publicUrl'] as String);
      final endpoints = candidates.map((url) => gatewayEndpoint(url, id)).toSet().toList();
      if (endpoints.isEmpty) throw const GatewayPairingFailure('invalid_pairing');
      // Direct LAN before the fixed DeepClub relay. Never forward a phone session to LAN.
      endpoints.sort((a, b) => (isGatewayRelay(a) ? 1 : 0).compareTo(isGatewayRelay(b) ? 1 : 0));
      return GatewayPairing(
        gatewayId: id,
        name: name,
        hostKey: key,
        endpoints: endpoints,
        code: code,
        expiresAt: expiresAt,
      );
    } on GatewayPairingFailure {
      rethrow;
    } catch (_) {
      throw const GatewayPairingFailure('invalid_pairing');
    }
  }
}

bool validGatewayHostKey(String key) => RegExp(r'^sha256:[0-9a-f]{64}$').hasMatch(key);
bool isGatewayRelay(Uri uri) => uri.scheme == 'wss' && uri.host == 'deepclub.net' && (!uri.hasPort || uri.port == 443);

Uri gatewayEndpoint(String raw, String gatewayId) {
  final uri = Uri.parse(raw);
  final address = InternetAddress.tryParse(uri.host);
  final bytes = address?.rawAddress;
  final lan =
      uri.host == 'localhost' ||
      uri.host.endsWith('.local') ||
      address?.isLoopback == true ||
      address?.isLinkLocal == true ||
      (bytes != null &&
          (address!.type == InternetAddressType.IPv4
              ? bytes[0] == 10 ||
                    bytes[0] == 192 && bytes[1] == 168 ||
                    bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31 ||
                    bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127
              : (bytes[0] & 0xfe) == 0xfc));
  if (uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      !const {'ws', 'wss'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      !(isGatewayRelay(uri) ? uri.path == '/ws/mobile/$gatewayId' : lan && uri.path == '/ws/mobile')) {
    throw const GatewayPairingFailure('invalid_pairing');
  }
  return uri;
}

class GatewayPairingFailure implements Exception {
  const GatewayPairingFailure(this.code);
  final String code;
  @override
  String toString() => 'GatewayPairingFailure($code)';
}

/// Saved metadata contains no pairing code, account session or gateway token.
class GatewayHost {
  const GatewayHost({
    required this.id,
    required this.name,
    required this.hostKey,
    required this.endpoints,
    required this.binding,
  });
  final String id, name, hostKey, binding;
  final List<Uri> endpoints;
  factory GatewayHost.fromJson(Map<String, dynamic> value) {
    final id = value['id'] as String;
    final key = value['hostKey'] as String;
    if (!validGatewayHostKey(key)) throw const FormatException('host key');
    return GatewayHost(
      id: id,
      name: value['name'] as String,
      hostKey: key,
      binding: value['binding'] as String,
      endpoints: (value['endpoints'] as List).cast<String>().map((e) => gatewayEndpoint(e, id)).toList(),
    );
  }
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'hostKey': hostKey,
    'binding': binding,
    'endpoints': endpoints.map((e) => e.toString()).toList(),
  };
  static String tokenKey(String id) => 'gateway.$id.token';
}
