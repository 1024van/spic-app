import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../deeplink/deeplink_decoder.dart';
import '../deeplink/deeplink_model.dart';

class AccessProfileStore {
  AccessProfileStore({FlutterSecureStorage? secureStorage})
    : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  static const String secureProfilesKey = 'spic.secure.access_profiles.v1';
  static const int maxProfiles = 8;

  final FlutterSecureStorage _secureStorage;

  Future<List<TTConfig>> loadProfiles({
    SharedPreferences? prefs,
    String? legacyPrimaryLink,
    Iterable<String> legacyProfileLinks = const [],
    required String legacyPrimaryLinkKey,
    required String legacyProfileLinksKey,
  }) async {
    final profiles = await _readSecureProfiles();
    final migratedProfiles = _decodeLegacyLinks([
      ?legacyPrimaryLink,
      ...legacyProfileLinks,
    ]);

    if (migratedProfiles.isEmpty) {
      return profiles;
    }

    final mergedProfiles = _mergeProfiles([...profiles, ...migratedProfiles]);
    await _writeSecureProfiles(mergedProfiles);

    final actualPrefs = prefs ?? await SharedPreferences.getInstance();
    await actualPrefs.remove(legacyPrimaryLinkKey);
    await actualPrefs.remove(legacyProfileLinksKey);

    return mergedProfiles;
  }

  Future<List<TTConfig>> saveProfile(TTConfig config) async {
    final profiles = await _readSecureProfiles();
    final mergedProfiles = _mergeProfiles([...profiles, config]);
    await _writeSecureProfiles(mergedProfiles);
    return mergedProfiles;
  }

  Future<List<TTConfig>> _readSecureProfiles() async {
    final raw = await _secureStorage.read(key: secureProfilesKey);
    if (raw == null || raw.trim().isEmpty) {
      return const [];
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return const [];
      }

      return decoded
          .whereType<Map>()
          .map((item) => TTConfig.fromJson(Map<String, dynamic>.from(item)))
          .where((config) => config.isValid && !config.isExpired)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<void> _writeSecureProfiles(List<TTConfig> profiles) async {
    final encoded = jsonEncode(
      profiles.map((profile) => profile.toJson()).toList(growable: false),
    );
    await _secureStorage.write(key: secureProfilesKey, value: encoded);
  }

  List<TTConfig> _decodeLegacyLinks(Iterable<String> links) {
    final profiles = <TTConfig>[];
    for (final link in links) {
      final trimmed = link.trim();
      if (trimmed.isEmpty) {
        continue;
      }

      try {
        final config = TTDecoder.decode(trimmed);
        if (config.isValid && !config.isExpired) {
          profiles.add(config);
        }
      } catch (_) {
        // Ignore old malformed values instead of preserving plaintext secrets.
      }
    }

    return profiles;
  }

  List<TTConfig> _mergeProfiles(List<TTConfig> profiles) {
    final keyedProfiles = <String, TTConfig>{};
    for (final profile in profiles) {
      if (!profile.isValid || profile.isExpired) {
        continue;
      }
      keyedProfiles[_profileKey(profile)] = profile;
    }

    final merged = keyedProfiles.values.toList(growable: false);
    return merged.length <= maxProfiles
        ? merged
        : merged.sublist(merged.length - maxProfiles);
  }

  String _profileKey(TTConfig config) {
    final address = config.address?.trim().toLowerCase();
    if (address != null && address.isNotEmpty) {
      return 'address:${_normalizeEndpointAddress(address)}';
    }

    final hostname = config.hostname?.trim().toLowerCase();
    if (hostname != null && hostname.isNotEmpty) {
      return 'tls:$hostname';
    }

    return 'unknown';
  }

  String _normalizeEndpointAddress(String value) {
    final raw = value.trim().toLowerCase();
    if (raw.isEmpty) {
      return raw;
    }

    final uri = Uri.tryParse('tcp://$raw');
    if (uri != null && uri.host.isNotEmpty) {
      final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
      return '$host:${uri.hasPort ? uri.port : 443}';
    }

    return raw;
  }
}
