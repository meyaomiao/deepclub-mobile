import 'dart:convert';
import 'dart:io';

import '../state/app_info.dart';
import 'version.dart';

/// Public site metadata only. Missing release fields mean no published download.
class SiteUpdate {
  const SiteUpdate({this.version, this.minimumSupportedVersion, this.download});
  final AppVersion? version;
  final AppVersion? minimumSupportedVersion;
  final Uri? download;

  bool isBelowMinimum(AppVersion installed) => minimumSupportedVersion?.isNewerThan(installed) ?? false;

  factory SiteUpdate.parse(Object? json) {
    if (json is! Map || json['success'] != true || json['data'] is! Map) {
      throw const FormatException('invalid_site_response');
    }
    final data = json['data'] as Map;
    // Older servers return desktop launcher metadata. Never offer it as an APK.
    if (data['platform'] != 'android') return const SiteUpdate();
    final version = data['latest_version'];
    final minimum = data['min_supported_version'];
    final download = data['download_url'];
    final uri = download is String ? Uri.tryParse(download) : null;
    return SiteUpdate(
      version: version is String ? AppVersion.tryParse(version) : null,
      minimumSupportedVersion: minimum is String ? AppVersion.tryParse(minimum) : null,
      download:
          uri != null &&
              uri.scheme == 'https' &&
              (uri.host == 'deepclub.net' || uri.host.endsWith('.deepclub.net')) &&
              uri.userInfo.isEmpty &&
              (!uri.hasPort || uri.port == 443)
          ? uri
          : null,
    );
  }
}

Future<SiteUpdate> fetchSiteUpdate() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
  try {
    final request = await client.getUrl(Uri.parse(AppInfo.siteInfoUrl));
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close().timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) throw const HttpException('site_update_unavailable');
    final buffer = StringBuffer();
    await for (final part in response.transform(utf8.decoder).timeout(const Duration(seconds: 12))) {
      buffer.write(part);
      if (buffer.length > 64 * 1024) throw const FormatException('site_response_too_large');
    }
    return SiteUpdate.parse(jsonDecode(buffer.toString()));
  } finally {
    client.close(force: true);
  }
}
