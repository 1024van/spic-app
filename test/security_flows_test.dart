import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spic_app/core/access/access_profile_store.dart';
import 'package:spic_app/core/deeplink/deeplink_decoder.dart';
import 'package:spic_app/core/update/spic_update_checker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('tt:// import', () {
    test('decodes valid access link', () {
      final link = _ttLink({
        0x01: 'stop2virus.xyz',
        0x02: '185.236.24.249:443',
        0x05: 'user',
        0x06: 'pass',
        0x07: DateTime.now()
            .add(const Duration(days: 7))
            .toUtc()
            .toIso8601String(),
      });

      final config = TTDecoder.decode(link);

      expect(config.hostname, 'stop2virus.xyz');
      expect(config.address, '185.236.24.249:443');
      expect(config.username, 'user');
      expect(config.password, 'pass');
      expect(config.isValid, isTrue);
      expect(config.isExpired, isFalse);
    });

    test('marks expired access link as expired', () {
      final link = _ttLink({
        0x01: 'stop2virus.xyz',
        0x05: 'user',
        0x06: 'pass',
        0x07: DateTime.now()
            .subtract(const Duration(days: 1))
            .toUtc()
            .toIso8601String(),
      });

      final config = TTDecoder.decode(link);

      expect(config.isValid, isTrue);
      expect(config.isExpired, isTrue);
    });

    test('rejects malformed link', () {
      expect(() => TTDecoder.decode('tt://?not-valid'), throwsException);
    });
  });

  group('secure access profile store', () {
    test(
      'migrates legacy plaintext tt links and removes SharedPreferences keys',
      () async {
        FlutterSecureStorage.setMockInitialValues({});
        final legacyLink = _ttLink({
          0x01: 'stop2virus.xyz',
          0x02: '185.236.24.249:443',
          0x05: 'user',
          0x06: 'pass',
          0x07: DateTime.now()
              .add(const Duration(days: 7))
              .toUtc()
              .toIso8601String(),
        });
        SharedPreferences.setMockInitialValues({
          'spic.access_profile_link': legacyLink,
          'spic.imported_profile_links': [legacyLink],
        });
        final prefs = await SharedPreferences.getInstance();
        final store = AccessProfileStore();

        final profiles = await store.loadProfiles(
          prefs: prefs,
          legacyPrimaryLink: prefs.getString('spic.access_profile_link'),
          legacyProfileLinks:
              prefs.getStringList('spic.imported_profile_links') ?? const [],
          legacyPrimaryLinkKey: 'spic.access_profile_link',
          legacyProfileLinksKey: 'spic.imported_profile_links',
        );

        expect(profiles, hasLength(1));
        expect(profiles.single.username, 'user');
        expect(prefs.getString('spic.access_profile_link'), isNull);
        expect(prefs.getStringList('spic.imported_profile_links'), isNull);
      },
    );
  });

  group('update manifest hardening', () {
    test('canonical payload ignores signature and sorts keys', () {
      final left = SpicUpdateChecker.canonicalManifestPayload({
        'versionCode': 2,
        'version': '1.0.2',
        'signature': 'ignored',
        'notes': ['b', 'a'],
      });
      final right = SpicUpdateChecker.canonicalManifestPayload({
        'notes': ['b', 'a'],
        'version': '1.0.2',
        'versionCode': 2,
      });

      expect(left, right);
    });

    test('rejects unsigned manifest', () async {
      final ok = await SpicUpdateChecker.verifyManifestSignature({
        'versionCode': 2,
        'version': '1.0.2',
      });

      expect(ok, isFalse);
    });
  });
}

String _ttLink(Map<int, String> values) {
  final bytes = <int>[];
  for (final entry in values.entries) {
    final valueBytes = utf8.encode(entry.value);
    bytes
      ..add(entry.key)
      ..add(valueBytes.length)
      ..addAll(valueBytes);
  }
  return 'tt://?${base64Url.encode(bytes).replaceAll('=', '')}';
}
