import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trusttunnel/data/model/server.dart';
import 'package:trusttunnel/data/model/vpn_protocol.dart';
import 'package:trusttunnel/data/model/vpn_state.dart';

import '../trust/spic_trust_policy.dart';

enum SpicRouteMode { fastest, stable, secure }

class SpicRouteProbeResult {
  const SpicRouteProbeResult({
    required this.server,
    required this.protocol,
    required this.latency,
  });

  final Server server;
  final VpnProtocol protocol;
  final Duration latency;
}

class SpicRouteSelection {
  const SpicRouteSelection({
    required this.server,
    required this.protocol,
    required this.latency,
  });

  final Server server;
  final VpnProtocol protocol;
  final Duration latency;
}

class SpicDiagnosticsSnapshot {
  const SpicDiagnosticsSnapshot({
    required this.routeMode,
    required this.routeStatusMessage,
    required this.protectionMessage,
    required this.routeHealthy,
    required this.dnsHealthy,
    required this.fallbackPrepared,
    required this.isSelectingSmartRoute,
    required this.isVerifyingConnection,
    required this.lastRouteLatency,
    required this.lastHealthCheckedAt,
    required this.healthFailureStreak,
    required this.coolingDownRoutes,
    required this.policySummary,
    required this.routeTrusted,
  });

  final SpicRouteMode routeMode;
  final String? routeStatusMessage;
  final String protectionMessage;
  final bool routeHealthy;
  final bool dnsHealthy;
  final bool fallbackPrepared;
  final bool isSelectingSmartRoute;
  final bool isVerifyingConnection;
  final Duration? lastRouteLatency;
  final DateTime? lastHealthCheckedAt;
  final int healthFailureStreak;
  final Map<String, DateTime> coolingDownRoutes;
  final String policySummary;
  final bool routeTrusted;

  String toReport({
    required VpnState vpnState,
    required String serverName,
    required VpnProtocol protocol,
    required String appVersion,
    required String subscription,
    required int bypassedAppsCount,
    required bool smartBypassEnabled,
    required bool importedProfile,
    Iterable<String> recentLogs = const [],
  }) {
    final buffer = StringBuffer()
      ..writeln('SPIC diagnostics')
      ..writeln('App: $appVersion')
      ..writeln('VPN state: ${vpnState.name}')
      ..writeln('Server: $serverName')
      ..writeln('Mode: ${routeMode.name}')
      ..writeln('Protocol: ${protocol.name}')
      ..writeln(
        'Route trust: ${routeTrusted ? 'SPIC verified' : 'External unverified'}',
      )
      ..writeln('Policy: $policySummary')
      ..writeln('Route status: ${routeStatusMessage ?? 'none'}')
      ..writeln('Protection: $protectionMessage')
      ..writeln('Route healthy: $routeHealthy')
      ..writeln('DNS healthy: $dnsHealthy')
      ..writeln('Fallback prepared: $fallbackPrepared')
      ..writeln('Latency: ${lastRouteLatency?.inMilliseconds ?? 'n/a'} ms')
      ..writeln(
        'Last health check: ${lastHealthCheckedAt?.toIso8601String() ?? 'never'}',
      )
      ..writeln('Failure streak: $healthFailureStreak')
      ..writeln('Cooldown routes: ${coolingDownRoutes.length}')
      ..writeln('Imported profile: $importedProfile')
      ..writeln('Subscription: $subscription')
      ..writeln('Bypassed apps: $bypassedAppsCount')
      ..writeln('Smart bypass: $smartBypassEnabled');

    final logs = recentLogs.toList(growable: false);
    if (logs.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('Recent VPN events:');
      for (final log in logs) {
        buffer.writeln(log);
      }
    }

    return buffer.toString().trimRight();
  }
}

class SpicConnectionSupervisor extends ChangeNotifier {
  static const String _routeModePrefsKey = 'spic.route_mode';
  static const String _serverCooldownsPrefsKey = 'spic.server_cooldowns';
  static const Duration _serverProbeTimeout = Duration(milliseconds: 1800);
  static const Duration _serverFailureCooldown = Duration(seconds: 90);
  static const Duration dnsCheckTimeout = Duration(seconds: 2);

  static const List<String> _defaultDnsUpstreams = ['1.1.1.1', '8.8.8.8'];
  static const List<String> _secureDnsUpstreams = [
    'tls://1.1.1.1',
    'https://cloudflare-dns.com/dns-query',
  ];

  SpicRouteMode _routeMode = SpicRouteMode.fastest;
  Map<String, DateTime> _serverCooldownUntil = const {};
  bool _isSelectingSmartRoute = false;
  bool _isVerifyingConnection = false;
  bool _healthCheckInFlight = false;
  bool _routeHealthy = false;
  bool _dnsHealthy = false;
  bool _fallbackPrepared = false;
  bool _activeRouteTrusted = true;
  String? _routeStatusMessage;
  String _protectionMessage = 'Ready';
  Duration? _lastRouteLatency;
  DateTime? _lastHealthCheckedAt;
  int _healthFailureStreak = 0;
  String _policySummary = 'Fastest: measured route, primary transport';

  SpicRouteMode get routeMode => _routeMode;

  bool get isSelectingSmartRoute => _isSelectingSmartRoute;

  bool get isVerifyingConnection => _isVerifyingConnection;

  bool get routeHealthy => _routeHealthy;

  bool get dnsHealthy => _dnsHealthy;

  bool get fallbackPrepared => _fallbackPrepared;

  bool get activeRouteTrusted => _activeRouteTrusted;

  String? get routeStatusMessage => _routeStatusMessage;

  String get protectionMessage => _protectionMessage;

  Duration? get lastRouteLatency => _lastRouteLatency;

  DateTime? get lastHealthCheckedAt => _lastHealthCheckedAt;

  int get healthFailureStreak => _healthFailureStreak;

  String get policySummary => _policySummary;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _routeMode = routeModeFromName(prefs.getString(_routeModePrefsKey));
    _serverCooldownUntil = _decodeServerCooldowns(
      prefs.getString(_serverCooldownsPrefsKey),
    );
    await SpicTrustPolicy.refresh();
    _policySummary = _policySummaryForMode(_routeMode);
    notifyListeners();
  }

  Future<void> setRouteMode(SpicRouteMode mode) async {
    if (_routeMode == mode) {
      return;
    }

    _routeMode = mode;
    _routeStatusMessage = routeModeHint(mode);
    _policySummary = _policySummaryForMode(mode);
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_routeModePrefsKey, mode.name);
  }

  SpicDiagnosticsSnapshot snapshot() => SpicDiagnosticsSnapshot(
    routeMode: _routeMode,
    routeStatusMessage: _routeStatusMessage,
    protectionMessage: _protectionMessage,
    routeHealthy: _routeHealthy,
    dnsHealthy: _dnsHealthy,
    fallbackPrepared: _fallbackPrepared,
    isSelectingSmartRoute: _isSelectingSmartRoute,
    isVerifyingConnection: _isVerifyingConnection,
    lastRouteLatency: _lastRouteLatency,
    lastHealthCheckedAt: _lastHealthCheckedAt,
    healthFailureStreak: _healthFailureStreak,
    coolingDownRoutes: Map.unmodifiable(_activeCooldowns()),
    policySummary: _policySummary,
    routeTrusted: _activeRouteTrusted,
  );

  VpnState displayVpnState(VpnState state) {
    if (state == VpnState.connected &&
        (_isVerifyingConnection || !_routeHealthy || !_dnsHealthy)) {
      return VpnState.connecting;
    }

    return state;
  }

  int protectionScore(VpnState vpnState) {
    if (vpnState == VpnState.disconnected) {
      return 0;
    }

    if (_isBusy(vpnState)) {
      return 74;
    }

    if (!_activeRouteTrusted) {
      var score = 28;
      if (!_routeHealthy) score -= 5;
      if (!_dnsHealthy) score -= 4;
      if (_healthFailureStreak > 0) {
        score -= (_healthFailureStreak * 3).clamp(0, 8);
      }
      return score.clamp(20, 30);
    }

    var score = 98;
    if (!_routeHealthy) score -= 24;
    if (!_dnsHealthy) score -= 18;
    if (_lastRouteLatency != null &&
        _lastRouteLatency! > const Duration(milliseconds: 1200)) {
      score -= 8;
    }
    if (_healthFailureStreak > 0) {
      score -= (_healthFailureStreak * 6).clamp(0, 18);
    }

    return score.clamp(0, 98);
  }

  bool isServerCoolingDown(Server server) {
    final until = _serverCooldownUntil[serverEndpointKey(server)];
    return until != null && until.isAfter(DateTime.now());
  }

  Future<void> rememberServerFailure(Server server) async {
    final key = serverEndpointKey(server);
    final until = DateTime.now().add(_serverFailureCooldown);
    _serverCooldownUntil = {..._serverCooldownUntil, key: until};
    notifyListeners();
    await _persistServerCooldowns();
  }

  Future<void> clearServerFailure(Server server) async {
    final key = serverEndpointKey(server);
    if (!_serverCooldownUntil.containsKey(key)) {
      return;
    }

    _serverCooldownUntil = Map<String, DateTime>.of(_serverCooldownUntil)
      ..remove(key);
    notifyListeners();
    await _persistServerCooldowns();
  }

  Future<void> clearAllServerFailures() async {
    if (_serverCooldownUntil.isEmpty) {
      return;
    }

    _serverCooldownUntil = const {};
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_serverCooldownsPrefsKey);
  }

  Future<SpicRouteProbeResult?> probeServer(
    Server server, {
    bool rememberFailure = true,
    VpnProtocol? protocol,
  }) async {
    final endpoint = _serverProbeEndpoint(server);
    if (endpoint == null) {
      if (rememberFailure) {
        await rememberServerFailure(server);
      }
      return null;
    }

    final effectiveProtocol = protocol ?? server.vpnProtocol;
    final stopwatch = Stopwatch()..start();
    Socket? socket;
    try {
      socket = await Socket.connect(
        endpoint.host,
        endpoint.port,
        timeout: _serverProbeTimeout,
      );
      stopwatch.stop();
      return SpicRouteProbeResult(
        server: server,
        protocol: effectiveProtocol,
        latency: stopwatch.elapsed,
      );
    } catch (error) {
      debugPrint('SPIC route probe failed for ${server.name}: $error');
      if (rememberFailure) {
        await rememberServerFailure(server);
      }
      return null;
    } finally {
      socket?.destroy();
    }
  }

  Future<bool> checkDnsHealth() async {
    try {
      final result = await InternetAddress.lookup(
        'stop2virus.xyz',
      ).timeout(dnsCheckTimeout);
      return result.isNotEmpty;
    } catch (error) {
      debugPrint('SPIC DNS health check failed: $error');
      return false;
    }
  }

  Future<SpicRouteSelection?> selectSmartServer({
    required List<Server> effectiveServers,
    required Server? selected,
    required VpnProtocol preferredProtocol,
  }) async {
    final candidates = _eligibleSmartServers(effectiveServers, selected);
    if (candidates.isEmpty) {
      _routeStatusMessage = 'No available route. Try again shortly.';
      notifyListeners();
      return null;
    }

    _isSelectingSmartRoute = true;
    _routeStatusMessage = routeTestingMessage(_routeMode);
    notifyListeners();

    try {
      if (selected != null &&
          !isTrustedSpicServer(selected) &&
          candidates.any((server) => isSameServerEndpoint(server, selected))) {
        final result = await probeServer(
          selected,
          protocol: _fastestProtocolFor(selected, preferredProtocol),
        );
        return result == null
            ? null
            : SpicRouteSelection(
                server: result.server,
                protocol: result.protocol,
                latency: result.latency,
              );
      }

      switch (_routeMode) {
        case SpicRouteMode.fastest:
          final results = await Future.wait(
            candidates.map(
              (server) => probeServer(
                server,
                protocol: _fastestProtocolFor(server, preferredProtocol),
              ),
            ),
          );
          final reachable = results.whereType<SpicRouteProbeResult>().toList()
            ..sort((left, right) => left.latency.compareTo(right.latency));
          final best = reachable.isEmpty ? null : reachable.first;
          return best == null
              ? null
              : SpicRouteSelection(
                  server: best.server,
                  protocol: best.protocol,
                  latency: best.latency,
                );

        case SpicRouteMode.stable:
          final ordered = _selectedFirst(candidates, selected);
          for (final server in ordered) {
            final protocol = server.vpnProtocol == VpnProtocol.quic
                ? VpnProtocol.quic
                : preferredProtocol;
            final result = await probeServer(server, protocol: protocol);
            if (result != null) {
              return SpicRouteSelection(
                server: result.server,
                protocol: result.protocol,
                latency: result.latency,
              );
            }
          }
          return null;

        case SpicRouteMode.secure:
          final ordered = [
            ...candidates.where(isPreferredSecureServer),
            ...candidates.where((server) => !isPreferredSecureServer(server)),
          ];
          for (final server in ordered) {
            final result = await probeServer(
              server,
              protocol: server.vpnProtocol,
            );
            if (result != null) {
              return SpicRouteSelection(
                server: result.server,
                protocol: result.protocol,
                latency: result.latency,
              );
            }
          }
          return null;
      }
    } finally {
      _isSelectingSmartRoute = false;
      notifyListeners();
    }
  }

  Server applyPolicy(Server server, {required VpnProtocol protocol}) {
    final trusted = isTrustedSpicServer(server);
    final cleanDns = server.dnsServers
        .where((value) => value.trim().isNotEmpty)
        .toList(growable: false);
    final baseDns = cleanDns.isEmpty ? _defaultDnsUpstreams : cleanDns;
    final fallback = oppositeProtocol(protocol);

    switch (_routeMode) {
      case SpicRouteMode.fastest:
        _policySummary = trusted
            ? 'Fastest: measured route, ${protocolLabel(protocol)}, kill switch on'
            : 'External route: endpoint and logging policy unverified';
        notifyListeners();
        return server.copyWith(
          vpnProtocol: protocol,
          clearUpstreamFallbackProtocol: true,
          dnsServers: baseDns,
          killSwitchEnabled: true,
          antiDpi: false,
          postQuantumGroupEnabled: true,
        );

      case SpicRouteMode.stable:
        _policySummary = trusted
            ? 'Stable: ${protocolLabel(protocol)} with ${protocolLabel(fallback)} fallback, kill switch on'
            : 'External route: fallback depends on third-party endpoint';
        notifyListeners();
        return server.copyWith(
          vpnProtocol: protocol,
          upstreamFallbackProtocol: fallback,
          dnsServers: baseDns,
          killSwitchEnabled: true,
          antiDpi: false,
          postQuantumGroupEnabled: true,
        );

      case SpicRouteMode.secure:
        _policySummary = trusted
            ? 'Secure: encrypted DNS, fallback transport, anti-DPI, kill switch on'
            : 'External route: SPIC cannot verify endpoint security';
        notifyListeners();
        return server.copyWith(
          vpnProtocol: protocol,
          upstreamFallbackProtocol: fallback,
          dnsServers: _secureDnsUpstreams,
          killSwitchEnabled: true,
          antiDpi: true,
          postQuantumGroupEnabled: true,
        );
    }
  }

  void beginConnectionVerification({required Server server}) {
    _activeRouteTrusted = isTrustedSpicServer(server);
    _routeStatusMessage = _activeRouteTrusted
        ? 'Verifying route...'
        : 'Verifying external route...';
    _routeHealthy = false;
    _dnsHealthy = false;
    _fallbackPrepared = false;
    _isVerifyingConnection = true;
    _lastRouteLatency = null;
    _lastHealthCheckedAt = null;
    _healthFailureStreak = 0;
    _protectionMessage = _activeRouteTrusted
        ? 'Checking access'
        : 'Checking external endpoint';
    notifyListeners();
  }

  void markConnectionFailed() {
    _isVerifyingConnection = false;
    _routeHealthy = false;
    _dnsHealthy = false;
    _fallbackPrepared = false;
    _routeStatusMessage = 'Connection failed';
    _protectionMessage = 'Connection failed';
    notifyListeners();
  }

  void markPreviewRouteUnavailable() {
    _routeStatusMessage = 'Preview route is not available';
    _protectionMessage = 'Select a SPIC route';
    notifyListeners();
  }

  void markAccessRejected() {
    _isVerifyingConnection = false;
    _routeHealthy = false;
    _dnsHealthy = false;
    _fallbackPrepared = false;
    _routeStatusMessage = 'Access check failed';
    _protectionMessage = 'Import SPIC access again';
    notifyListeners();
  }

  Future<void> completeConnectionVerification({
    required Server server,
    required SpicRouteProbeResult? routeProbe,
    required bool dnsOk,
  }) async {
    final routeOk = routeProbe != null;
    if (routeOk && dnsOk) {
      await clearServerFailure(server);
    } else {
      await rememberServerFailure(server);
    }

    _isVerifyingConnection = false;
    _activeRouteTrusted = isTrustedSpicServer(server);
    _routeStatusMessage = routeOk && dnsOk
        ? _activeRouteTrusted
              ? routeSelectedMessage(_routeMode)
              : 'External route connected'
        : 'Connected, checking route';
    _routeHealthy = routeOk;
    _dnsHealthy = dnsOk;
    _lastRouteLatency = routeProbe?.latency;
    _lastHealthCheckedAt = DateTime.now();
    _protectionMessage = routeOk && dnsOk
        ? _activeRouteTrusted
              ? 'Route verified'
              : 'External endpoint not verified'
        : 'Protecting connection';
    notifyListeners();
  }

  Future<Server?> runConnectionHealthCheck({
    required Server? selected,
    required List<Server> effectiveServers,
  }) async {
    if (_healthCheckInFlight ||
        selected == null ||
        !hasServerCredentials(selected)) {
      return null;
    }

    _healthCheckInFlight = true;
    try {
      final routeProbe = await probeServer(selected, rememberFailure: false);
      final dnsOk = await checkDnsHealth();
      final routeOk = routeProbe != null;
      final unhealthy = !routeOk || !dnsOk;
      final trusted = isTrustedSpicServer(selected);
      final fallback = await _prepareFallbackServer(
        current: selected,
        effectiveServers: effectiveServers,
      );
      final failureStreak = unhealthy ? _healthFailureStreak + 1 : 0;

      _routeHealthy = routeOk;
      _dnsHealthy = dnsOk;
      _fallbackPrepared = fallback != null;
      _activeRouteTrusted = trusted;
      _lastRouteLatency = routeProbe?.latency;
      _lastHealthCheckedAt = DateTime.now();
      _healthFailureStreak = failureStreak;
      _protectionMessage = !trusted
          ? 'External endpoint not verified'
          : unhealthy
          ? fallback == null
                ? 'Protecting connection'
                : 'Preparing fallback route'
          : fallback == null
          ? 'Route verified'
          : 'Route verified, fallback ready';
      notifyListeners();

      if (failureStreak >= 2 && fallback != null) {
        return fallback;
      }

      return null;
    } finally {
      _healthCheckInFlight = false;
    }
  }

  void markReconnectingSecurely() {
    _routeStatusMessage = 'Reconnecting securely';
    _protectionMessage = 'Reconnecting securely';
    notifyListeners();
  }

  void markFallbackVerified() {
    _healthFailureStreak = 0;
    _protectionMessage = 'Fallback route verified';
    notifyListeners();
  }

  void markProtectingConnection() {
    _protectionMessage = 'Protecting connection';
    notifyListeners();
  }

  void resetForDisconnect() {
    if (!_routeHealthy &&
        !_dnsHealthy &&
        !_fallbackPrepared &&
        _activeRouteTrusted &&
        !_isVerifyingConnection &&
        _healthFailureStreak == 0 &&
        _lastRouteLatency == null &&
        _lastHealthCheckedAt == null &&
        _routeStatusMessage == null &&
        _protectionMessage == 'Ready') {
      return;
    }

    _routeStatusMessage = null;
    _routeHealthy = false;
    _dnsHealthy = false;
    _fallbackPrepared = false;
    _activeRouteTrusted = true;
    _healthFailureStreak = 0;
    _lastRouteLatency = null;
    _lastHealthCheckedAt = null;
    _isVerifyingConnection = false;
    _protectionMessage = 'Ready';
    notifyListeners();
  }

  static SpicRouteMode routeModeFromName(String? value) =>
      SpicRouteMode.values.firstWhere(
        (mode) => mode.name == value,
        orElse: () => SpicRouteMode.fastest,
      );

  static String routeModeHint(SpicRouteMode mode) => switch (mode) {
    SpicRouteMode.fastest => 'Fastest route selected',
    SpicRouteMode.stable => 'Stable route selected',
    SpicRouteMode.secure => 'Secure route selected',
  };

  static String routeSelectedMessage(SpicRouteMode mode) => switch (mode) {
    SpicRouteMode.fastest => 'Fastest route selected',
    SpicRouteMode.stable => 'Stable route selected',
    SpicRouteMode.secure => 'Secure route selected',
  };

  static String routeTestingMessage(SpicRouteMode mode) => switch (mode) {
    SpicRouteMode.fastest => 'Checking fastest route...',
    SpicRouteMode.stable => 'Checking stable route...',
    SpicRouteMode.secure => 'Checking secure route...',
  };

  static VpnProtocol oppositeProtocol(VpnProtocol protocol) =>
      switch (protocol) {
        VpnProtocol.http2 => VpnProtocol.quic,
        VpnProtocol.quic => VpnProtocol.http2,
      };

  static String protocolLabel(VpnProtocol protocol) => switch (protocol) {
    VpnProtocol.http2 => 'HTTP/2',
    VpnProtocol.quic => 'QUIC',
  };

  static bool hasServerCredentials(Server server) =>
      server.username.trim().isNotEmpty && server.password.trim().isNotEmpty;

  static bool isSameServerEndpoint(Server left, Server right) {
    final leftDomain = left.domain.trim().toLowerCase();
    final rightDomain = right.domain.trim().toLowerCase();
    if (leftDomain.isNotEmpty && leftDomain == rightDomain) {
      return true;
    }

    final leftAddress = normalizedEndpointHost(left.ipAddress);
    final rightAddress = normalizedEndpointHost(right.ipAddress);
    return leftAddress.isNotEmpty && leftAddress == rightAddress;
  }

  static String normalizedEndpointHost(String value) {
    return SpicTrustPolicy.normalizedEndpointHost(value);
  }

  static String serverEndpointKey(Server server) {
    final domain = server.domain.trim().toLowerCase();
    if (domain.isNotEmpty) {
      return 'domain:$domain';
    }

    final host = normalizedEndpointHost(server.ipAddress);
    return host.isNotEmpty ? 'host:$host' : 'id:${server.id}';
  }

  static bool isTrustedSpicServer(Server server) {
    return SpicTrustPolicy.isTrustedServer(server);
  }

  static bool isPreferredSecureServer(Server server) {
    return SpicTrustPolicy.isPreferredSecureServer(server);
  }

  static bool _isBusy(VpnState state) =>
      state == VpnState.connecting ||
      state == VpnState.waitingForRecovery ||
      state == VpnState.recovering ||
      state == VpnState.waitingForNetwork;

  String _policySummaryForMode(SpicRouteMode mode) => switch (mode) {
    SpicRouteMode.fastest => 'Fastest: measured route, primary transport',
    SpicRouteMode.stable => 'Stable: fallback transport enabled',
    SpicRouteMode.secure => 'Secure: encrypted DNS, anti-DPI, kill switch',
  };

  VpnProtocol _fastestProtocolFor(
    Server server,
    VpnProtocol preferredProtocol,
  ) {
    if (server.vpnProtocol == preferredProtocol) {
      return preferredProtocol;
    }

    return server.vpnProtocol;
  }

  List<Server> _eligibleSmartServers(
    List<Server> effectiveServers,
    Server? selected,
  ) {
    final credentialed = effectiveServers
        .where(hasServerCredentials)
        .where((server) => !isServerCoolingDown(server))
        .toList(growable: true);

    if (selected != null &&
        hasServerCredentials(selected) &&
        !isServerCoolingDown(selected) &&
        !credentialed.any((server) => isSameServerEndpoint(server, selected))) {
      credentialed.insert(0, selected);
    }

    return credentialed;
  }

  List<Server> _selectedFirst(List<Server> candidates, Server? selected) {
    final useSelectedFirst =
        selected != null &&
        candidates.any((server) => isSameServerEndpoint(server, selected));
    return useSelectedFirst
        ? [
            selected,
            ...candidates.where(
              (server) => !isSameServerEndpoint(server, selected),
            ),
          ]
        : candidates;
  }

  Future<Server?> _prepareFallbackServer({
    required Server current,
    required List<Server> effectiveServers,
  }) async {
    final candidates = _eligibleSmartServers(effectiveServers, current)
        .where((server) => !isSameServerEndpoint(server, current))
        .toList(growable: false);
    if (candidates.isEmpty) {
      return null;
    }

    switch (_routeMode) {
      case SpicRouteMode.fastest:
        final results = await Future.wait(
          candidates.map(
            (server) => probeServer(server, rememberFailure: false),
          ),
        );
        final reachable = results.whereType<SpicRouteProbeResult>().toList()
          ..sort((left, right) => left.latency.compareTo(right.latency));
        return reachable.isEmpty ? null : reachable.first.server;

      case SpicRouteMode.stable:
        for (final server in candidates) {
          final result = await probeServer(server, rememberFailure: false);
          if (result != null) return result.server;
        }
        return null;

      case SpicRouteMode.secure:
        final ordered = [
          ...candidates.where(isPreferredSecureServer),
          ...candidates.where((server) => !isPreferredSecureServer(server)),
        ];
        for (final server in ordered) {
          final result = await probeServer(server, rememberFailure: false);
          if (result != null) return result.server;
        }
        return null;
    }
  }

  ({String host, int port})? _serverProbeEndpoint(Server server) {
    final domain = server.domain.trim();
    if (domain.isNotEmpty) {
      return (host: domain, port: 443);
    }

    final rawAddress = server.ipAddress.trim();
    if (rawAddress.isEmpty) {
      return null;
    }

    final uri = Uri.tryParse('tcp://$rawAddress');
    if (uri != null && uri.host.isNotEmpty) {
      return (host: uri.host, port: uri.hasPort ? uri.port : 443);
    }

    final host = rawAddress.split(':').first.trim();
    return host.isEmpty ? null : (host: host, port: 443);
  }

  Map<String, DateTime> _activeCooldowns() {
    final now = DateTime.now();
    return Map.fromEntries(
      _serverCooldownUntil.entries.where((entry) => entry.value.isAfter(now)),
    );
  }

  Map<String, DateTime> _decodeServerCooldowns(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return const {};
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return const {};
      }

      final now = DateTime.now();
      return Map.fromEntries(
        decoded.entries.map((entry) {
          final millis = entry.value;
          if (millis is! int) return null;
          final until = DateTime.fromMillisecondsSinceEpoch(millis);
          if (!until.isAfter(now)) return null;
          return MapEntry(entry.key, until);
        }).whereType<MapEntry<String, DateTime>>(),
      );
    } catch (error) {
      debugPrint('Failed to decode SPIC route cooldowns: $error');
      return const {};
    }
  }

  Future<void> _persistServerCooldowns() async {
    final prefs = await SharedPreferences.getInstance();
    final active = _activeCooldowns();
    _serverCooldownUntil = active;

    if (active.isEmpty) {
      await prefs.remove(_serverCooldownsPrefsKey);
      return;
    }

    await prefs.setString(
      _serverCooldownsPrefsKey,
      jsonEncode(
        active.map((key, value) => MapEntry(key, value.millisecondsSinceEpoch)),
      ),
    );
  }
}
