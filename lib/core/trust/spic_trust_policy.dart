import 'dart:convert';
import 'dart:io';

import 'package:trusttunnel/data/model/server.dart';

import '../update/spic_update_checker.dart';

class SpicTrustPolicy {
  SpicTrustPolicy._();

  static final Uri defaultCatalogUri = Uri.parse(
    'https://stop2virus.xyz/api/server-trust.json',
  );

  static Set<String> _trustedDomains = {'stop2virus.xyz'};
  static Set<String> _trustedHosts = {'185.236.24.249'};

  static bool isTrustedServer(Server server) {
    return isTrustedEndpoint(domain: server.domain, address: server.ipAddress);
  }

  static bool isTrustedEndpoint({
    required String domain,
    required String address,
  }) {
    final normalizedDomain = domain.trim().toLowerCase();
    final host = normalizedEndpointHost(address);
    return normalizedDomain.isNotEmpty &&
            _trustedDomains.contains(normalizedDomain) ||
        host.isNotEmpty && _trustedHosts.contains(host);
  }

  static bool isPreferredSecureServer(Server server) {
    if (isTrustedServer(server)) {
      return true;
    }

    final text = [
      server.name,
      server.domain,
      server.ipAddress,
    ].join(' ').toLowerCase();
    return text.contains('stop2virus') || text.contains('finland');
  }

  static Future<void> refresh({Uri? catalogUri}) async {
    final client = HttpClient();
    try {
      final request = await client
          .getUrl(catalogUri ?? defaultCatalogUri)
          .timeout(const Duration(seconds: 5));
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      if (response.statusCode != HttpStatus.ok) {
        return;
      }

      final body = await response.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        return;
      }
      if (!await SpicUpdateChecker.verifyManifestSignature(decoded)) {
        return;
      }

      final domains = _readStringSet(decoded['trustedDomains']);
      final hosts = _readStringSet(
        decoded['trustedHosts'],
      ).map(normalizedEndpointHost).where((host) => host.isNotEmpty).toSet();
      if (domains.isEmpty && hosts.isEmpty) {
        return;
      }

      _trustedDomains = domains;
      _trustedHosts = hosts;
    } catch (_) {
      // Keep bundled fallback trust anchors.
    } finally {
      client.close(force: true);
    }
  }

  static String normalizedEndpointHost(String value) {
    final raw = value.trim().toLowerCase();
    if (raw.isEmpty) {
      return '';
    }

    final uri = Uri.tryParse('tcp://$raw');
    if (uri != null && uri.host.isNotEmpty) {
      return uri.host.toLowerCase();
    }

    return raw.split(':').first;
  }

  static Set<String> _readStringSet(Object? value) {
    if (value is! List) {
      return const {};
    }

    return value
        .map((item) => '$item'.trim().toLowerCase())
        .where((item) => item.isNotEmpty)
        .toSet();
  }
}
