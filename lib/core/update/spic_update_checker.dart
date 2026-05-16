import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

class SpicUpdateInfo {
  final String version;
  final int versionCode;
  final Uri apkUri;
  final String? sha256;
  final bool mandatory;
  final List<String> notes;

  const SpicUpdateInfo({
    required this.version,
    required this.versionCode,
    required this.apkUri,
    required this.sha256,
    required this.mandatory,
    required this.notes,
  });
}

class SpicUpdateChecker {
  static final Uri _manifestUri = Uri.parse(
    'https://stop2virus.xyz/api/android-latest.json',
  );
  static const String _manifestPublicKeyBase64 =
      '8DuygBi2yrqqvwsnVU08hTTuIqCqLfyMLQARkiWrw78=';
  static const MethodChannel _apkInstallerChannel = MethodChannel(
    'spic/apk_installer',
  );

  static Future<SpicUpdateInfo?> findUpdate() async {
    final packageInfo = await PackageInfo.fromPlatform();
    final currentVersionCode = int.tryParse(packageInfo.buildNumber) ?? 0;
    final manifest = await _loadManifest();
    if (manifest == null) {
      return null;
    }

    final remoteVersionCode = _readInt(
      manifest['versionCode'] ?? manifest['version_code'],
    );
    if (remoteVersionCode <= currentVersionCode) {
      return null;
    }

    final apkUrl = '${manifest['apkUrl'] ?? manifest['url'] ?? ''}'.trim();
    final apkUri = Uri.tryParse(apkUrl);
    if (apkUri == null || apkUri.scheme != 'https') {
      return null;
    }

    return SpicUpdateInfo(
      version: '${manifest['version'] ?? remoteVersionCode}'.trim(),
      versionCode: remoteVersionCode,
      apkUri: apkUri,
      sha256: '${manifest['sha256'] ?? ''}'.trim().isEmpty
          ? null
          : '${manifest['sha256']}'.trim(),
      mandatory: manifest['mandatory'] == true,
      notes: _readNotes(manifest['notes']),
    );
  }

  static Future<void> openDownload(SpicUpdateInfo update) async {
    final apk = await downloadAndVerify(update);
    await _apkInstallerChannel.invokeMethod<void>('installApk', {
      'path': apk.path,
    });
  }

  static Future<File> downloadAndVerify(SpicUpdateInfo update) async {
    final expectedSha256 = update.sha256?.trim().toLowerCase();
    if (expectedSha256 == null ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(expectedSha256)) {
      throw Exception('Update manifest does not contain a valid SHA256');
    }

    final tempDir = await getTemporaryDirectory();
    final apk = File(
      '${tempDir.path}${Platform.pathSeparator}spic-update-${update.versionCode}.apk',
    );
    if (await apk.exists()) {
      await apk.delete();
    }

    final client = HttpClient();
    try {
      final request = await client
          .getUrl(update.apkUri)
          .timeout(const Duration(seconds: 12));
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != HttpStatus.ok) {
        throw Exception('Update download failed: HTTP ${response.statusCode}');
      }

      final sink = apk.openWrite();
      try {
        await response.pipe(sink);
      } finally {
        await sink.close();
      }
    } finally {
      client.close(force: true);
    }

    final actualSha256 = await sha256.bind(apk.openRead()).first;
    if (actualSha256.toString().toLowerCase() != expectedSha256) {
      try {
        await apk.delete();
      } catch (_) {
        // Best-effort cleanup after a failed integrity check.
      }
      throw Exception('Update SHA256 mismatch');
    }

    return apk;
  }

  static Future<Map<String, dynamic>?> _loadManifest() async {
    final client = HttpClient();
    try {
      final request = await client
          .getUrl(_manifestUri)
          .timeout(const Duration(seconds: 8));
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      final response = await request.close().timeout(
        const Duration(seconds: 8),
      );
      if (response.statusCode != HttpStatus.ok) {
        return null;
      }

      final body = await response.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      return await verifyManifestSignature(decoded) ? decoded : null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static Future<bool> verifyManifestSignature(
    Map<String, dynamic> manifest,
  ) async {
    final signatureBase64 = '${manifest['signature'] ?? ''}'.trim();
    if (signatureBase64.isEmpty) {
      return false;
    }

    try {
      final algorithm = Ed25519();
      final publicKey = SimplePublicKey(
        base64Decode(_manifestPublicKeyBase64),
        type: KeyPairType.ed25519,
      );
      final signature = Signature(
        base64Decode(signatureBase64),
        publicKey: publicKey,
      );
      final payload = utf8.encode(canonicalManifestPayload(manifest));
      return algorithm.verify(payload, signature: signature);
    } catch (_) {
      return false;
    }
  }

  static String canonicalManifestPayload(Map<String, dynamic> manifest) {
    final filtered = Map<String, dynamic>.from(manifest)..remove('signature');
    return _canonicalJson(filtered);
  }

  static String _canonicalJson(Object? value) {
    if (value == null) return 'null';
    if (value is String) return jsonEncode(value);
    if (value is num || value is bool) return jsonEncode(value);
    if (value is List) {
      return '[${value.map(_canonicalJson).join(',')}]';
    }
    if (value is Map) {
      final entries =
          value.entries
              .map((entry) => MapEntry('${entry.key}', entry.value))
              .toList(growable: false)
            ..sort((left, right) => left.key.compareTo(right.key));
      return '{${entries.map((entry) => '${jsonEncode(entry.key)}:${_canonicalJson(entry.value)}').join(',')}}';
    }
    return jsonEncode('$value');
  }

  static int _readInt(Object? value) {
    if (value is int) return value;
    return int.tryParse('$value') ?? 0;
  }

  static List<String> _readNotes(Object? value) {
    if (value is List) {
      return value
          .map((item) => '$item'.trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    }

    final text = '$value'.trim();
    return text.isEmpty || text == 'null' ? const [] : [text];
  }
}
