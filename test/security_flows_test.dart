import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spic_app/core/access/access_profile_store.dart';
import 'package:spic_app/core/connection/spic_connection_supervisor.dart';
import 'package:spic_app/core/deeplink/deeplink_decoder.dart';
import 'package:spic_app/core/update/spic_update_checker.dart';
import 'package:trusttunnel/data/model/server.dart';
import 'package:trusttunnel/data/model/server_data.dart';
import 'package:trusttunnel/data/model/vpn_protocol.dart';

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
        0x0D: '198.18.53.1:53',
      });

      final config = TTDecoder.decode(link);

      expect(config.hostname, 'stop2virus.xyz');
      expect(config.address, '185.236.24.249:443');
      expect(config.username, 'user');
      expect(config.password, 'pass');
      expect(config.dnsUpstreams, ['198.18.53.1:53']);
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

    test(
      'keeps profiles with the same TLS host but different relay ports',
      () async {
        FlutterSecureStorage.setMockInitialValues({});
        final now = DateTime.now().add(const Duration(days: 7));
        final store = AccessProfileStore();

        await store.saveProfile(
          TTDecoder.decode(
            _ttLink({
              0x01: 'home.stop2virus.xyz',
              0x02: '185.236.24.249:8443',
              0x05: 'user-a',
              0x06: 'pass-a',
              0x07: now.toUtc().toIso8601String(),
            }),
          ),
        );
        await store.saveProfile(
          TTDecoder.decode(
            _ttLink({
              0x01: 'home.stop2virus.xyz',
              0x02: '185.236.24.249:18445',
              0x05: 'user-b',
              0x06: 'pass-b',
              0x07: now.toUtc().toIso8601String(),
            }),
          ),
        );

        final profiles = await store.loadProfiles(
          legacyPrimaryLinkKey: 'legacy',
          legacyProfileLinksKey: 'legacy_list',
        );

        expect(profiles, hasLength(2));
        expect(
          profiles.map((profile) => profile.address),
          containsAll(['185.236.24.249:8443', '185.236.24.249:18445']),
        );
      },
    );

    test('refreshes only the matching payment-plan endpoint', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final now = DateTime.now().add(const Duration(days: 7));
      final store = AccessProfileStore();

      await store.saveProfile(
        TTDecoder.decode(
          _ttLink({
            0x01: 'home.stop2virus.xyz',
            0x02: '185.236.24.249:8443',
            0x05: 'bw-user',
            0x06: 'bw-pass',
            0x07: now.toUtc().toIso8601String(),
          }),
        ),
      );
      await store.saveProfile(
        TTDecoder.decode(
          _ttLink({
            0x01: 'stop2virus.xyz',
            0x02: '185.236.24.249:443',
            0x05: 'standard-old',
            0x06: 'standard-old-pass',
            0x07: now.toUtc().toIso8601String(),
          }),
        ),
      );
      await store.saveProfile(
        TTDecoder.decode(
          _ttLink({
            0x01: 'stop2virus.xyz',
            0x02: '185.236.24.249:443',
            0x05: 'standard-new',
            0x06: 'standard-new-pass',
            0x07: now.toUtc().toIso8601String(),
          }),
        ),
      );

      final profiles = await store.loadProfiles(
        legacyPrimaryLinkKey: 'legacy',
        legacyProfileLinksKey: 'legacy_list',
      );

      expect(profiles, hasLength(2));
      expect(
        profiles
            .singleWhere((profile) => profile.address == '185.236.24.249:8443')
            .username,
        'bw-user',
      );
      expect(
        profiles
            .singleWhere((profile) => profile.address == '185.236.24.249:443')
            .username,
        'standard-new',
      );
    });
  });

  group('BtW endpoint identity', () {
    test('keys routes by connect address and port before TLS hostname', () {
      final standard = _server(
        hostname: 'stop2virus.xyz',
        address: '185.236.24.249:443',
      );
      final btw = _server(
        hostname: 'home.stop2virus.xyz',
        address: '185.236.24.249:8443',
      );

      expect(
        SpicConnectionSupervisor.serverEndpointKey(standard),
        'address:185.236.24.249:443',
      );
      expect(
        SpicConnectionSupervisor.serverEndpointKey(btw),
        'address:185.236.24.249:8443',
      );
      expect(
        SpicConnectionSupervisor.isSameServerEndpoint(standard, btw),
        isFalse,
      );
    });

    test('trusted SPIC routes use internal tunnel DNS', () {
      final server = _server(
        hostname: 'home.stop2virus.xyz',
        address: '185.236.24.249:8443',
        dnsServers: const ['1.1.1.1'],
      );

      final protected = SpicConnectionSupervisor().applyPolicy(
        server,
        protocol: VpnProtocol.http2,
      );

      expect(
        protected.dnsServers,
        SpicConnectionSupervisor.spicTunnelDnsUpstreams,
      );
    });

    test('BtW policy is fixed to HTTP2 IPv4 without post quantum', () {
      final server = _server(
        hostname: 'home.stop2virus.xyz',
        address: '185.236.24.249:8443',
      );

      final protected = SpicConnectionSupervisor().applyPolicy(
        server,
        protocol: VpnProtocol.quic,
      );

      expect(protected.vpnProtocol, VpnProtocol.http2);
      expect(protected.serverData.ipv6, isFalse);
      expect(protected.upstreamFallbackProtocol, isNull);
      expect(protected.postQuantumGroupEnabled, isFalse);
    });

    test(
      'direct profile with BtW TLS host is not marked as BtW on port 443',
      () {
        final server = _server(
          hostname: 'home.stop2virus.xyz',
          address: '185.236.24.249:443',
        );

        expect(SpicConnectionSupervisor.isBtwServer(server), isFalse);
      },
    );

    test('computer and router BtW gateways are separate PRO endpoints', () {
      final computerGateway = _server(
        hostname: 'home.stop2virus.xyz',
        address: '185.236.24.249:8443',
      );
      final routerGateway = _server(
        hostname: 'home.stop2virus.xyz',
        address: '185.236.24.249:18445',
      );

      expect(SpicConnectionSupervisor.isBtwServer(computerGateway), isTrue);
      expect(SpicConnectionSupervisor.isBtwServer(routerGateway), isTrue);
      expect(
        SpicConnectionSupervisor.isSameServerEndpoint(
          computerGateway,
          routerGateway,
        ),
        isFalse,
      );
    });
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

Server _server({
  required String hostname,
  required String address,
  List<String> dnsServers = const [],
}) {
  return Server(
    id: '$hostname-$address',
    serverData: ServerData.empty(
      name: hostname,
      ipAddress: address,
      domain: hostname,
      username: 'user',
      password: 'pass',
      dnsServers: dnsServers,
    ),
  );
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
