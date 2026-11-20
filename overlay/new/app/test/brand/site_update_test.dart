import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_app/update/site_update.dart';
import 'package:dsh_app/update/version.dart';

void main() {
  test('reads published site version and a DeepClub HTTPS download only', () {
    final info = SiteUpdate.parse({
      'success': true,
      'data': {
        'platform': 'android',
        'latest_version': '1.2.3',
        'min_supported_version': '1.1.0',
        'download_url': 'https://deepclub.net/download/agent.apk',
      },
    });
    expect(info.version?.name, '1.2.3');
    expect(info.minimumSupportedVersion?.name, '1.1.0');
    expect(info.download?.host, 'deepclub.net');
  });

  test('missing site release fields stay unknown', () {
    final info = SiteUpdate.parse({
      'success': true,
      'data': {'platform': 'android'},
    });
    expect(info.version, isNull);
    expect(info.minimumSupportedVersion, isNull);
    expect(info.isBelowMinimum(const AppVersion(0, 1, 0)), isFalse);
    expect(info.download, isNull);
  });

  test('minimum support compares semantic versions without requiring a latest release', () {
    final info = SiteUpdate.parse({
      'success': true,
      'data': {'platform': 'android', 'min_supported_version': '0.2.0'},
    });
    expect(info.version, isNull);
    expect(info.isBelowMinimum(const AppVersion(0, 1, 0)), isTrue);
    expect(info.isBelowMinimum(const AppVersion(0, 2, 0, build: 100)), isFalse);
    expect(info.isBelowMinimum(const AppVersion(0, 3, 0)), isFalse);
    expect(info.isBelowMinimum(const AppVersion(0, 2, 0, preRelease: ['beta', '1'])), isTrue);
  });

  test('blank, invalid or non-string minimum versions remain unknown', () {
    for (final minimum in ['', 'unknown', 200]) {
      final info = SiteUpdate.parse({
        'success': true,
        'data': {'platform': 'android', 'min_supported_version': minimum},
      });
      expect(info.minimumSupportedVersion, isNull);
      expect(info.isBelowMinimum(const AppVersion(0, 1, 0)), isFalse);
    }
  });

  test('rejects off-site and credential-bearing download URLs', () {
    for (final value in [
      'https://github.com/upstream/release.apk',
      'https://deepclub.net.example.com/release.apk',
      'http://deepclub.net/release.apk',
      'https://user:password@deepclub.net/release.apk',
      'https://deepclub.net:8443/release.apk',
    ]) {
      expect(
        SiteUpdate.parse({
          'success': true,
          'data': {'platform': 'android', 'download_url': value},
        }).download,
        isNull,
      );
    }
  });

  test('older or desktop site responses never offer a mobile update', () {
    for (final platform in [null, 'desktop', 'Android']) {
      final info = SiteUpdate.parse({
        'success': true,
        'data': {
          'platform': ?platform,
          'latest_version': '99.0.0',
          'min_supported_version': '98.0.0',
          'download_url': 'https://deepclub.net/download/desktop.dmg',
        },
      });
      expect(info.version, isNull);
      expect(info.minimumSupportedVersion, isNull);
      expect(info.isBelowMinimum(const AppVersion(0, 1, 0)), isFalse);
      expect(info.download, isNull);
    }
  });

  test('a failed site response cannot masquerade as an unpublished version', () {
    expect(() => SiteUpdate.parse({'success': false, 'data': {}}), throwsFormatException);
  });
}
