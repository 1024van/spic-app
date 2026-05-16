import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:crypto/crypto.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trusttunnel/common/extensions/context_extensions.dart';
import 'package:trusttunnel/data/model/raw/add_server_request.dart';
import 'package:trusttunnel/data/model/server.dart';
import 'package:trusttunnel/data/model/server_data.dart';
import 'package:trusttunnel/data/model/vpn_protocol.dart';
import 'package:trusttunnel/data/model/vpn_state.dart';
import 'package:trusttunnel/data/repository/server_repository.dart';
import 'package:trusttunnel/feature/server/servers/widget/scope/servers_scope.dart';
import 'package:trusttunnel/feature/server/servers/widget/scope/servers_scope_controller.dart';
import 'package:trusttunnel/feature/vpn/models/vpn_controller.dart';
import 'package:trusttunnel/feature/vpn/widgets/vpn_scope.dart';
import 'package:trusttunnel/shared_constants.dart';
// ignore: depend_on_referenced_packages
import 'package:vpn_plugin/vpn_plugin.dart';

import 'widgets/vpn_connect_button.dart';
import 'core/access/access_profile_store.dart';
import 'core/connection/spic_connection_supervisor.dart';
import 'core/subscription/subscription_info.dart';
import 'core/deeplink/deeplink_decoder.dart';
import 'core/deeplink/deeplink_model.dart';
import 'core/trust/spic_trust_policy.dart';
import 'core/update/spic_update_checker.dart';
import 'feature/diagnostics/diagnostics_screen.dart';
import 'server_country.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const String _hasAccessProfileKey = 'spic.has_access_profile';
  static const String _subscriptionExpiresAtKey =
      'spic.subscription_expires_at';
  static const String _accessProfileLinkKey = 'spic.access_profile_link';
  static const String _importedProfileLinksKey = 'spic.imported_profile_links';
  static const String _referralLinkKey = 'spic.referral_link';
  static const String _bypassedAppPackagesPrefsKey =
      'spic.bypassed_app_packages';
  static const String _manualBypassedAppPackagesPrefsKey =
      'spic.manual_bypassed_app_packages';
  static const String _smartBypassEnabledPrefsKey = 'spic.smart_bypass_enabled';
  static const String _smartBypassDisabledPackagesPrefsKey =
      'spic.smart_bypass_disabled_packages';
  static const String _onboardingSeenPrefsKey = 'spic.onboarding_seen';
  static const MethodChannel _deeplinkChannel = MethodChannel('spic/deeplink');
  static const MethodChannel _nativeActionsChannel = MethodChannel(
    'spic/native_actions',
  );
  static const Duration _healthCheckInterval = Duration(seconds: 25);
  static const Duration _connectionVerificationTimeout = Duration(seconds: 8);

  static const Set<VpnState> _busyStates = {
    VpnState.connecting,
    VpnState.waitingForRecovery,
    VpnState.recovering,
    VpnState.waitingForNetwork,
  };

  final TextEditingController _importController = TextEditingController();

  VpnProtocol _selectedProtocol = VpnProtocol.http2;
  bool _isActionInFlight = false;
  bool _isImporting = false;
  bool _showImportInput = false;
  bool _hasImportedProfile = false;
  bool _profileStateLoaded = false;
  bool _updateCheckStarted = false;
  bool _smartBypassEnabled = true;
  bool _isHandlingExternalDeepLink = false;
  bool _showOnboarding = true;
  String? _referralLink;
  TTConfig? _accessProfileConfig;
  String? _pendingExternalDeepLink;
  String? _lastHandledExternalDeepLink;
  String? _pendingNativeAction;
  bool _isHandlingNativeAction = false;

  List<Server> _localServers = const [];
  List<Server> _healthServers = const [];
  Timer? _healthCheckTimer;
  Server? _healthSelectedServer;
  String? _selectedServerId;
  String? _selectedServerKey;

  late SubscriptionInfo _subscription;
  late final AccessProfileStore _accessProfileStore;
  late final SpicConnectionSupervisor _connectionSupervisor;
  late final ServerRepository _serverRepository;
  bool _depsInitialized = false;
  List<String> _bypassedAppPackages = const [];
  List<String> _smartBypassDisabledPackages = const [];
  List<String> _smartRecommendedBypassPackages = const [];

  @override
  void initState() {
    super.initState();

    _subscription = SubscriptionInfo();
    _accessProfileStore = AccessProfileStore();
    _connectionSupervisor = SpicConnectionSupervisor()
      ..addListener(_onConnectionSupervisorChanged);
    unawaited(_connectionSupervisor.load());
    _configureExternalDeepLinks();
    _configureNativeActions();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    if (!_depsInitialized) {
      _serverRepository = context.repositoryFactory.serverRepository;
      _depsInitialized = true;
      _loadAccessProfileState();
      _loadBypassedAppPackages();
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkForUpdate());
    }
  }

  @override
  void dispose() {
    _healthCheckTimer?.cancel();
    _connectionSupervisor
      ..removeListener(_onConnectionSupervisorChanged)
      ..dispose();
    _deeplinkChannel.setMethodCallHandler(null);
    _nativeActionsChannel.setMethodCallHandler(null);
    _importController.dispose();
    super.dispose();
  }

  void _onConnectionSupervisorChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _configureExternalDeepLinks() {
    _deeplinkChannel.setMethodCallHandler((call) async {
      if (call.method != 'onLink') {
        return;
      }

      final link = call.arguments;
      if (link is String) {
        await _handleExternalDeepLink(link);
      }
    });

    unawaited(_readInitialExternalDeepLink());
  }

  void _configureNativeActions() {
    _nativeActionsChannel.setMethodCallHandler((call) async {
      if (call.method != 'onAction') {
        return;
      }

      final action = call.arguments;
      if (action is String) {
        await _handleNativeAction(action);
      }
    });

    unawaited(_readInitialNativeAction());
  }

  Future<void> _readInitialNativeAction() async {
    try {
      final action = await _nativeActionsChannel.invokeMethod<String>(
        'getInitialAction',
      );
      if (!mounted || action == null || action.trim().isEmpty) {
        return;
      }

      await _handleNativeAction(action);
    } on MissingPluginException {
      // Desktop/widget tests do not have the Android bridge.
    } catch (error, stackTrace) {
      debugPrint('Failed to read initial native action: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> _handleNativeAction(String action) async {
    final normalizedAction = action.trim();
    if (normalizedAction != 'open_diagnostics') {
      return;
    }

    if (!_depsInitialized || !_profileStateLoaded) {
      _pendingNativeAction = normalizedAction;
      return;
    }

    if (_isHandlingNativeAction) {
      _pendingNativeAction = normalizedAction;
      return;
    }

    _isHandlingNativeAction = true;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (!mounted) return;
      await _openDiagnosticsHubFromCurrentState();
    } finally {
      _isHandlingNativeAction = false;
      final pendingAction = _pendingNativeAction;
      if (pendingAction != null) {
        _pendingNativeAction = null;
        unawaited(_handleNativeAction(pendingAction));
      }
    }
  }

  Future<void> _readInitialExternalDeepLink() async {
    try {
      final link = await _deeplinkChannel.invokeMethod<String>(
        'getInitialLink',
      );
      if (!mounted || link == null || link.trim().isEmpty) {
        return;
      }

      await _handleExternalDeepLink(link);
    } on MissingPluginException {
      // Desktop/widget tests do not have the Android bridge.
    } catch (error, stackTrace) {
      debugPrint('Failed to read initial tt:// link: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> _handleExternalDeepLink(String link) async {
    final trimmedLink = link.trim();
    if (!trimmedLink.toLowerCase().startsWith('tt://')) {
      return;
    }

    if (!_depsInitialized || !_profileStateLoaded) {
      _pendingExternalDeepLink = trimmedLink;
      return;
    }

    if (_isHandlingExternalDeepLink) {
      _pendingExternalDeepLink = trimmedLink;
      return;
    }

    if (_lastHandledExternalDeepLink == trimmedLink) {
      return;
    }

    _isHandlingExternalDeepLink = true;
    _lastHandledExternalDeepLink = trimmedLink;
    try {
      final importedServer = await _importServerFromLink(link: trimmedLink);
      if (importedServer == null || !mounted) {
        return;
      }

      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text(
            'Imported. Continue in the Android VPN permission dialog.',
          ),
          duration: Duration(seconds: 2),
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (!mounted) return;

      await _connectImportedServer(importedServer);
    } finally {
      _isHandlingExternalDeepLink = false;
      final pendingLink = _pendingExternalDeepLink;
      if (pendingLink != null && pendingLink != trimmedLink) {
        _pendingExternalDeepLink = null;
        unawaited(_handleExternalDeepLink(pendingLink));
      }
    }
  }

  Future<void> _drainPendingExternalDeepLink() async {
    final pendingLink = _pendingExternalDeepLink;
    if (pendingLink == null || !_depsInitialized || !_profileStateLoaded) {
      return;
    }

    _pendingExternalDeepLink = null;
    await _handleExternalDeepLink(pendingLink);
  }

  Future<void> _drainPendingNativeAction() async {
    final pendingAction = _pendingNativeAction;
    if (pendingAction == null || !_depsInitialized || !_profileStateLoaded) {
      return;
    }

    _pendingNativeAction = null;
    await _handleNativeAction(pendingAction);
  }

  void _scheduleHealthMonitorSync({
    required VpnState vpnState,
    required List<Server> effectiveServers,
    required Server? selected,
  }) {
    _healthServers = effectiveServers;
    _healthSelectedServer = selected;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncHealthMonitor(vpnState);
    });
  }

  void _syncHealthMonitor(VpnState vpnState) {
    if (vpnState == VpnState.connected) {
      _healthCheckTimer ??= Timer.periodic(
        _healthCheckInterval,
        (_) => unawaited(_runConnectionHealthCheck()),
      );

      if (_connectionSupervisor.lastHealthCheckedAt == null) {
        if (!_connectionSupervisor.isVerifyingConnection) {
          unawaited(_runConnectionHealthCheck());
        }
      }
      return;
    }

    _healthCheckTimer?.cancel();
    _healthCheckTimer = null;

    if (vpnState == VpnState.disconnected) {
      _connectionSupervisor.resetForDisconnect();
    }
  }

  @override
  Widget build(BuildContext context) {
    final VpnController vpn = VpnScope.vpnControllerOf(context);
    final ServersScopeController servers = ServersScope.controllerOf(context);
    final List<Server> effectiveServers = _effectiveServers(servers);
    final Server? selected = _effectiveSelectedServer(
      servers,
      effectiveServers,
    );
    final VpnState vpnState = vpn.state;
    final VpnState displayVpnState = _displayVpnState(vpnState);
    final bool showImportBanner =
        !_hasImportedProfile || effectiveServers.isEmpty || _showImportInput;

    _scheduleHealthMonitorSync(
      vpnState: vpnState,
      effectiveServers: effectiveServers,
      selected: selected,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('SPIC'),
        actions: [
          IconButton(
            tooltip: 'Connection diagnostics',
            onPressed: () => _openDiagnosticsHub(vpnState, selected),
            icon: const Icon(Icons.health_and_safety_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Column(
                    children: [
                      Text('Server: ${selected?.name ?? 'not selected'}'),
                      const SizedBox(height: 4),
                      Text('Status: ${_labelForState(displayVpnState)}'),
                      const SizedBox(height: 10),
                      _buildRouteModeSelector(),
                      const SizedBox(height: 10),
                      _buildProtectionCard(displayVpnState),
                      const SizedBox(height: 10),
                      if (_showOnboarding) _buildOnboardingCard(),
                      if (_showOnboarding) const SizedBox(height: 10),
                      SizedBox(
                        height: _serverListPanelHeight(effectiveServers),
                        child: _buildServersList(
                          servers,
                          effectiveServers,
                          selected,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Center(
                        child: VpnConnectButton(
                          state: displayVpnState,
                          onPressed: _isActionInFlight
                              ? null
                              : () => _handleConnectionToggle(
                                  context: context,
                                  vpn: vpn,
                                  hasServers: effectiveServers.isNotEmpty,
                                  effectiveServers: effectiveServers,
                                  selected: selected,
                                ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      if (_subscription.isExpired)
                        _buildExpiredSubscriptionPanel(),
                      if (_subscription.isExpired) const SizedBox(height: 10),
                      _buildBypassedAppsTile(vpn, selected),
                      const SizedBox(height: 10),
                      if (showImportBanner) _buildImportPanel(),
                      if (showImportBanner) const SizedBox(height: 10),
                      _buildInviteButton(selected),
                      const SizedBox(height: 8),
                      _buildExpiryText(),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  double _serverListPanelHeight(List<Server> effectiveServers) {
    if (!_hasImportedProfile || effectiveServers.isEmpty) {
      return 118;
    }

    final visibleRows = effectiveServers.length.clamp(1, 3);
    return 54 + (visibleRows * 55);
  }

  Widget _buildInviteButton(Server? selected) {
    return ElevatedButton(
      onPressed: () {
        final link = _generateReferralLink(selected);

        if (link == null) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(content: Text('Import tt:// link first')),
          );
          return;
        }

        Clipboard.setData(ClipboardData(text: link));

        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('Referral link copied')));
      },
      child: const Text('Invite friend'),
    );
  }

  String? _generateReferralLink(Server? selected) {
    final savedLink = _referralLink?.trim();
    if (savedLink != null && savedLink.isNotEmpty) {
      return savedLink;
    }

    final username = selected?.username.trim();
    if (username == null || username.isEmpty) {
      return null;
    }

    final match = RegExp(r'^user_(\d+)_').firstMatch(username);
    if (match != null) {
      return _referralLinkForUserId(match.group(1)!);
    }

    return _referralLinkForTrustTunnelUsername(username);
  }

  Future<void> _openExternalUrl(String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text('Renewal link copied: $url')));
  }

  List<Server> _effectiveServers(ServersScopeController servers) {
    if (!_profileStateLoaded || !_hasImportedProfile) {
      return const [];
    }

    final mergedServers = servers.servers
        .map(_serverWithAccessProfile)
        .toList(growable: true);
    for (final localServer in _localServers) {
      final index = mergedServers.indexWhere(
        (server) => _isSameServerEndpoint(server, localServer),
      );
      if (index == -1) {
        mergedServers.add(localServer);
      } else {
        mergedServers[index] = _mergeCatalogServerWithLocalProfile(
          catalogServer: mergedServers[index],
          localServer: localServer,
        );
      }
    }

    return mergedServers;
  }

  Server? _effectiveSelectedServer(
    ServersScopeController servers,
    List<Server> effectiveServers,
  ) {
    if (effectiveServers.isEmpty) {
      return null;
    }

    final selectedKey = _selectedServerKey;
    if (selectedKey != null && selectedKey.isNotEmpty) {
      for (final server in effectiveServers) {
        if (_serverEndpointKey(server) == selectedKey) {
          return server;
        }
      }
    }

    final String? selectedId = _selectedServerId ?? servers.selectedServer?.id;
    if (selectedId != null) {
      for (final server in effectiveServers) {
        if (server.id == selectedId) {
          return server;
        }
      }
    }

    return effectiveServers.firstWhere(
      (server) => _hasServerCredentials(server) && _isTrustedSpicServer(server),
      orElse: () => effectiveServers.firstWhere(
        _hasServerCredentials,
        orElse: () => effectiveServers.first,
      ),
    );
  }

  bool _hasServerCredentials(Server server) =>
      SpicConnectionSupervisor.hasServerCredentials(server);

  bool _hasAccessProfileCredentials(TTConfig? config) {
    if (config == null || config.isExpired) {
      return false;
    }

    return (config.username?.trim().isNotEmpty ?? false) &&
        (config.password?.trim().isNotEmpty ?? false);
  }

  bool _isTrustedAccessProfileConfig(TTConfig config) {
    return SpicTrustPolicy.isTrustedEndpoint(
      domain: config.hostname ?? '',
      address: config.address ?? '',
    );
  }

  bool _isSameServerEndpoint(Server left, Server right) {
    return SpicConnectionSupervisor.isSameServerEndpoint(left, right);
  }

  String _serverEndpointKey(Server server) {
    return SpicConnectionSupervisor.serverEndpointKey(server);
  }

  bool _isTrustedSpicServer(Server server) {
    return SpicConnectionSupervisor.isTrustedSpicServer(server);
  }

  VpnState _displayVpnState(VpnState state) {
    return _connectionSupervisor.displayVpnState(state);
  }

  int _protectionScore(VpnState vpnState) {
    return _connectionSupervisor.protectionScore(vpnState);
  }

  Server _serverWithAccessProfile(Server server) {
    final config = _accessProfileConfig;
    if (!_isTrustedSpicServer(server) ||
        !_hasAccessProfileCredentials(config)) {
      return server;
    }

    final trustedConfig = config!;
    if (!_isTrustedAccessProfileConfig(trustedConfig)) {
      return server;
    }

    return server.copyWith(
      username: trustedConfig.username!.trim(),
      password: trustedConfig.password!.trim(),
    );
  }

  Server _mergeCatalogServerWithLocalProfile({
    required Server catalogServer,
    required Server localServer,
  }) {
    final localHasCredentials = _hasServerCredentials(localServer);
    final catalogHasCredentials = _hasServerCredentials(catalogServer);
    return catalogServer.copyWith(
      username: catalogHasCredentials
          ? catalogServer.username
          : localHasCredentials
          ? localServer.username
          : catalogServer.username,
      password: catalogHasCredentials
          ? catalogServer.password
          : localHasCredentials
          ? localServer.password
          : catalogServer.password,
      selected: false,
    );
  }

  Widget _buildExpiryText() {
    final style = TextStyle(
      fontSize: 12,
      color: _subscription.isExpired ? Colors.red : null,
      fontWeight: _subscription.isExpired ? FontWeight.w600 : null,
    );
    final text = _subscription.isKnown
        ? '${_subscription.dateLabel} - ${_subscription.label}'
        : _subscription.label;
    return Text(text, style: style);
  }

  Future<void> _loadAccessProfileState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final expiresAtRaw = prefs.getString(_subscriptionExpiresAtKey);
      final expiresAt = expiresAtRaw == null
          ? null
          : DateTime.tryParse(expiresAtRaw);
      final hasImportedProfile = prefs.getBool(_hasAccessProfileKey) ?? false;
      final savedProfileLink = prefs.getString(_accessProfileLinkKey);
      final onboardingSeen = prefs.getBool(_onboardingSeenPrefsKey) ?? false;
      if (!mounted) return;

      setState(() {
        _hasImportedProfile = hasImportedProfile;
        _subscription = SubscriptionInfo(expiresAt: expiresAt);
        _referralLink = prefs.getString(_referralLinkKey);
        _showOnboarding = !onboardingSeen && !hasImportedProfile;
        _profileStateLoaded = true;
      });

      if (hasImportedProfile) {
        final savedProfileLinks =
            prefs.getStringList(_importedProfileLinksKey) ?? const <String>[];
        final savedProfiles = await _accessProfileStore.loadProfiles(
          prefs: prefs,
          legacyPrimaryLink: savedProfileLink,
          legacyProfileLinks: savedProfileLinks,
          legacyPrimaryLinkKey: _accessProfileLinkKey,
          legacyProfileLinksKey: _importedProfileLinksKey,
        );
        await _restoreImportedServersFromConfigs(savedProfiles);
        if (mounted) {
          ServersScope.controllerOf(context, listen: false).fetchServers();
        }
      }

      await _drainPendingExternalDeepLink();
      await _drainPendingNativeAction();
    } catch (error, stackTrace) {
      debugPrint('Failed to load SPIC access profile state: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) return;

      setState(() {
        _hasImportedProfile = false;
        _profileStateLoaded = true;
      });
      await _drainPendingExternalDeepLink();
      await _drainPendingNativeAction();
    }
  }

  Future<void> _checkForUpdate() async {
    if (_updateCheckStarted) {
      return;
    }
    _updateCheckStarted = true;

    final update = await SpicUpdateChecker.findUpdate();
    if (update == null || !mounted) {
      return;
    }

    await showDialog<void>(
      context: context,
      barrierDismissible: !update.mandatory,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Update available'),
        content: Text(_updateDialogText(update)),
        actions: [
          if (!update.mandatory)
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Later'),
            ),
          FilledButton(
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              try {
                await SpicUpdateChecker.openDownload(update);
              } catch (error) {
                if (!mounted) return;
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                  SnackBar(content: Text('Update download error: $error')),
                );
              }
            },
            child: const Text('Download'),
          ),
        ],
      ),
    );
  }

  String _updateDialogText(SpicUpdateInfo update) {
    final buffer = StringBuffer('SPIC ${update.version} is ready to install.');
    if (update.notes.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln()
        ..write(update.notes.join('\n'));
    }
    return buffer.toString();
  }

  Future<void> _persistAccessProfileState({required TTConfig config}) async {
    final prefs = await SharedPreferences.getInstance();
    final trustedProfile = _isTrustedAccessProfileConfig(config);
    final referralLink = trustedProfile ? _referralLinkForConfig(config) : null;
    await prefs.setBool(_hasAccessProfileKey, true);
    await _accessProfileStore.saveProfile(config);
    await prefs.remove(_accessProfileLinkKey);
    await prefs.remove(_importedProfileLinksKey);
    if (config.expiresAt == null) {
      await prefs.remove(_subscriptionExpiresAtKey);
    } else {
      await prefs.setString(
        _subscriptionExpiresAtKey,
        config.expiresAt!.toUtc().toIso8601String(),
      );
    }
    if (!trustedProfile) {
      return;
    }

    if (referralLink == null) {
      await prefs.remove(_referralLinkKey);
    } else {
      await prefs.setString(_referralLinkKey, referralLink);
    }
  }

  Future<void> _markOnboardingSeen() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_onboardingSeenPrefsKey, true);
    if (!mounted) return;

    setState(() {
      _showOnboarding = false;
    });
  }

  Future<void> _restoreImportedServersFromConfigs(
    Iterable<TTConfig> savedProfiles,
  ) async {
    for (final config in savedProfiles) {
      await _restoreImportedServerFromConfig(config);
    }
  }

  Future<void> _restoreImportedServerFromConfig(TTConfig config) async {
    if (!config.isValid || config.isExpired) {
      return;
    }

    try {
      final request = _addServerRequestFromConfig(config);
      final server = await _serverRepository.addNewServer(request: request);
      await _serverRepository.setSelectedServerId(id: server.id);
      if (!mounted) return;

      final trustedProfile = _isTrustedAccessProfileConfig(config);
      setState(() {
        _localServers = [
          ..._localServers.where(
            (item) => !_isSameServerEndpoint(item, server),
          ),
          server,
        ];
        _selectedServerId = server.id;
        _selectedServerKey = _serverEndpointKey(server);
        _selectedProtocol = server.vpnProtocol;
        if (trustedProfile) {
          _accessProfileConfig = config;
          _referralLink = _referralLinkForConfig(config);
        }
      });
    } catch (error, stackTrace) {
      debugPrint('Failed to restore SPIC server from secure profile: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  String? _referralLinkForConfig(TTConfig config) {
    final userId = config.userId?.trim();
    if (userId != null && userId.isNotEmpty) {
      return _referralLinkForUserId(userId);
    }

    final username = config.username?.trim();
    if (username == null || username.isEmpty) {
      return null;
    }

    final match = RegExp(r'^user_(\d+)_').firstMatch(username);
    if (match != null) {
      return _referralLinkForUserId(match.group(1)!);
    }

    return _referralLinkForTrustTunnelUsername(username);
  }

  String _referralLinkForUserId(String userId) {
    final code = _shortSha256Code(prefix: 'spic', value: 'spic:$userId');
    return 'https://stop2virus.xyz/buy.html?ref=$code';
  }

  String _referralLinkForTrustTunnelUsername(String username) {
    final code = _shortSha256Code(
      prefix: 'tt',
      value: 'spic-trusttunnel:$username',
    );
    return 'https://stop2virus.xyz/buy.html?ref=$code';
  }

  String _shortSha256Code({required String prefix, required String value}) {
    final digest = sha256.convert(utf8.encode(value)).toString();
    return '$prefix${digest.substring(0, 10)}';
  }

  Widget _buildExpiredSubscriptionPanel() {
    return Card(
      color: Colors.red.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Subscription expired',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            const Text(
              'Your SPIC access is no longer active. Renew the subscription or enter a new tt:// link.',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: () =>
                      _openExternalUrl('https://stop2virus.xyz/buy.html'),
                  child: const Text('Renew subscription'),
                ),
                OutlinedButton(
                  onPressed: _showImportBottomSheet,
                  child: const Text('Enter new link'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRouteModeSelector() {
    final scheme = Theme.of(context).colorScheme;
    final status = _connectionSupervisor.isSelectingSmartRoute
        ? 'Checking routes...'
        : _connectionSupervisor.routeStatusMessage;

    return Column(
      children: [
        SegmentedButton<SpicRouteMode>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(
              value: SpicRouteMode.fastest,
              label: Text('Fastest'),
              icon: Icon(Icons.bolt, size: 18),
            ),
            ButtonSegment(
              value: SpicRouteMode.stable,
              label: Text('Stable'),
              icon: Icon(Icons.timeline, size: 18),
            ),
            ButtonSegment(
              value: SpicRouteMode.secure,
              label: Text('Secure'),
              icon: Icon(Icons.shield_outlined, size: 18),
            ),
          ],
          selected: {_connectionSupervisor.routeMode},
          onSelectionChanged: _isActionInFlight
              ? null
              : (selection) {
                  final mode = selection.first;
                  unawaited(_connectionSupervisor.setRouteMode(mode));
                },
        ),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: status == null
              ? const SizedBox.shrink()
              : Padding(
                  key: ValueKey(status),
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    status,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildProtectionCard(VpnState vpnState) {
    final connected = vpnState == VpnState.connected;
    final busy = _busyStates.contains(vpnState);
    final externalRoute =
        connected && !_connectionSupervisor.activeRouteTrusted;
    final score = _protectionScore(vpnState);
    final latency = _connectionSupervisor.lastRouteLatency == null
        ? null
        : '${_connectionSupervisor.lastRouteLatency!.inMilliseconds} ms';
    final statusColor = externalRoute ? Colors.deepOrange : Colors.green;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  connected ? Icons.verified_user : Icons.shield_outlined,
                  color: connected ? statusColor : null,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    connected
                        ? 'Protection Score: $score%'
                        : busy
                        ? 'Protection starting...'
                        : 'Protection ready',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _ProtectionChip(
                  label: connected ? 'VPN Active' : 'VPN Ready',
                  tone: connected
                      ? externalRoute
                            ? _ProtectionTone.warning
                            : _ProtectionTone.ok
                      : _ProtectionTone.neutral,
                ),
                _ProtectionChip(
                  label: 'DNS Protected',
                  tone: _protectionTone(
                    active: _connectionSupervisor.dnsHealthy,
                    externalRoute: externalRoute,
                    externalTone: _ProtectionTone.caution,
                  ),
                ),
                _ProtectionChip(
                  label: 'Route Verified',
                  tone: _protectionTone(
                    active: _connectionSupervisor.routeHealthy,
                    externalRoute: externalRoute,
                    externalTone: _ProtectionTone.warning,
                  ),
                ),
                _ProtectionChip(
                  label: 'Leaks Blocked',
                  tone: connected
                      ? externalRoute
                            ? _ProtectionTone.danger
                            : _ProtectionTone.ok
                      : _ProtectionTone.neutral,
                ),
              ],
            ),
            if (externalRoute) ...[
              const SizedBox(height: 8),
              Text(
                'External endpoint: SPIC cannot verify logging, DNS policy, or server-side protections.',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.deepOrange.shade700,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              latency == null
                  ? _connectionSupervisor.protectionMessage
                  : '${_connectionSupervisor.protectionMessage} - route $latency',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  _ProtectionTone _protectionTone({
    required bool active,
    required bool externalRoute,
    required _ProtectionTone externalTone,
  }) {
    if (!active) {
      return _ProtectionTone.neutral;
    }

    return externalRoute ? externalTone : _ProtectionTone.ok;
  }

  Widget _buildOnboardingCard() {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.34),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Start in 3 steps',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            const Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _OnboardingStep(number: '1', text: 'Import access'),
                _OnboardingStep(number: '2', text: 'Tap Connect'),
                _OnboardingStep(number: '3', text: 'You are protected'),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _showImportBottomSheet,
                    icon: const Icon(Icons.add_link),
                    label: const Text('Import access'),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _markOnboardingSeen,
                  child: const Text('Got it'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBypassedAppsTile(VpnController vpn, Server? selectedServer) {
    final count = _bypassedAppPackages.length;
    final smartCount = _smartBypassEnabled
        ? _smartRecommendedBypassPackages
              .where(
                (packageName) =>
                    !_smartBypassDisabledPackages.contains(packageName),
              )
              .length
        : 0;
    final suffix = _smartBypassEnabled
        ? 'Smart on${smartCount == 0 ? '' : ', $smartCount suggested'}'
        : 'Smart off';
    final subtitle = count == 0
        ? 'No apps bypass VPN - $suffix'
        : '$count app${count == 1 ? '' : 's'} bypass VPN - $suffix';

    return Card(
      child: ListTile(
        leading: const Icon(Icons.app_shortcut),
        title: const Text('Apps bypassing VPN'),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: () =>
            _openBypassedAppsScreen(vpn: vpn, selectedServer: selectedServer),
      ),
    );
  }

  Future<void> _openDiagnosticsHub(
    VpnState vpnState,
    Server? selectedServer,
  ) async {
    final packageInfo = await PackageInfo.fromPlatform();
    if (!mounted) return;

    final logs = VpnScope.logsControllerOf(context, listen: false).logs;
    final recentLogs = logs.reversed
        .take(40)
        .map((log) {
          final domain = log.domain == null ? '' : ' (${log.domain})';
          return '${log.timeStamp.toLocal()} ${log.protocol.name.toUpperCase()} ${log.action.name}: '
              '${log.source} -> ${log.destination ?? 'unknown'}$domain';
        })
        .toList(growable: false);

    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => DiagnosticsScreen(
          snapshot: _connectionSupervisor.snapshot(),
          vpnState: vpnState,
          serverName: selectedServer?.name ?? 'not selected',
          protocol: _selectedProtocol,
          appVersion: '${packageInfo.version}+${packageInfo.buildNumber}',
          subscription: _subscription.label,
          bypassedAppsCount: _bypassedAppPackages.length,
          smartBypassEnabled: _smartBypassEnabled,
          importedProfile: _hasImportedProfile,
          recentLogs: recentLogs,
        ),
      ),
    );
  }

  Future<void> _openDiagnosticsHubFromCurrentState() async {
    final vpn = VpnScope.vpnControllerOf(context, listen: false);
    final servers = ServersScope.controllerOf(context, listen: false);
    final effectiveServers = _effectiveServers(servers);
    final selectedServer = _effectiveSelectedServer(servers, effectiveServers);
    await _openDiagnosticsHub(vpn.state, selectedServer);
  }

  Widget _buildImportPanel() {
    return Material(
      color: Colors.orange.shade100,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _isImporting ? null : _showImportBottomSheet,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.orange.shade300),
          ),
          child: Row(
            children: [
              const Icon(Icons.link, color: Colors.orange),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _localServers.isEmpty
                      ? 'Open import form for tt:// link'
                      : 'Import another tt:// link',
                  style: const TextStyle(
                    color: Colors.black87,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              const Icon(Icons.chevron_right, color: Colors.orange),
            ],
          ),
        ),
      ),
    );
  }

  Future<Server?> _importServerFromLink({required String link}) async {
    final trimmedLink = link.trim();

    if (trimmedLink.isEmpty) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('Paste tt:// link first')));
      return null;
    }

    setState(() {
      _isImporting = true;
    });

    try {
      final config = TTDecoder.decode(trimmedLink);

      if (!config.isValid) {
        if (!mounted) return null;
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('Invalid tt:// link')));
        return null;
      }

      if (config.isExpired) {
        if (!mounted) return null;
        setState(() {
          _subscription = SubscriptionInfo(expiresAt: config.expiresAt);
        });
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: Text(
              'This tt:// link has expired. Renew the subscription or paste a new link.',
            ),
          ),
        );
        return null;
      }

      final AddServerRequest request = _addServerRequestFromConfig(config);

      final repository = _serverRepository;
      final server = await repository.addNewServer(request: request);
      await repository.setSelectedServerId(id: server.id);
      await _persistAccessProfileState(config: config);
      await _connectionSupervisor.clearAllServerFailures();
      await _markOnboardingSeen();
      await ImportState.setImported(true);

      if (!mounted) return null;

      final trustedProfile = _isTrustedAccessProfileConfig(config);
      setState(() {
        _localServers = [
          ..._localServers.where(
            (item) => !_isSameServerEndpoint(item, server),
          ),
          server,
        ];
        _selectedServerId = server.id;
        _selectedServerKey = _serverEndpointKey(server);
        _selectedProtocol = server.vpnProtocol;
        if (trustedProfile) {
          _accessProfileConfig = config;
          _referralLink = _referralLinkForConfig(config);
        }
        _subscription = SubscriptionInfo(expiresAt: config.expiresAt);
        _hasImportedProfile = true;
        _profileStateLoaded = true;
        _showImportInput = false;
        _showOnboarding = false;
        _importController.clear();
      });

      ServersScope.controllerOf(context, listen: false).fetchServers();

      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text('Imported ${server.name}')));
      return server;
    } catch (e) {
      if (!mounted) return null;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(_formatImportError(e))));
      return null;
    } finally {
      if (mounted) {
        setState(() {
          _isImporting = false;
        });
      }
    }
  }

  AddServerRequest _addServerRequestFromConfig(TTConfig config) {
    final String name = (config.hostname ?? config.address ?? 'Imported server')
        .trim();
    final String domain = (config.hostname ?? config.address ?? '').trim();
    final String ipAddress = (config.address ?? config.hostname ?? '').trim();

    return ServerData.empty(
      name: name.isEmpty ? 'Imported server' : name,
      ipAddress: ipAddress,
      domain: domain,
      username: config.username!.trim(),
      password: config.password!.trim(),
      vpnProtocol: _selectedProtocol,
      routingProfileId: kDefaultRoutingProfileId,
      dnsServers: const ['1.1.1.1'],
    );
  }

  String _formatImportError(Object error) {
    final text = error.toString();
    return text.startsWith('Exception: ') ? text.substring(11) : text;
  }

  Future<void> _runConnectionHealthCheck() async {
    if (!mounted) {
      return;
    }

    final fallback = await _connectionSupervisor.runConnectionHealthCheck(
      selected: _healthSelectedServer,
      effectiveServers: _healthServers,
    );
    if (fallback != null) {
      await _switchToFallbackRoute(fallback);
    }
  }

  Future<void> _switchToFallbackRoute(Server fallback) async {
    if (!mounted || _isActionInFlight) {
      return;
    }

    final vpn = VpnScope.vpnControllerOf(context);
    if (vpn.state != VpnState.connected) {
      return;
    }

    setState(() => _isActionInFlight = true);
    _connectionSupervisor.markReconnectingSecurely();

    try {
      await vpn.stop();
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (!mounted) return;

      await _connectToServer(vpn: vpn, server: fallback);
      if (!mounted) return;

      _connectionSupervisor.markFallbackVerified();
    } catch (error) {
      await _connectionSupervisor.rememberServerFailure(fallback);
      if (!mounted) return;
      _connectionSupervisor.markProtectingConnection();
      debugPrint('SPIC fallback reconnect failed: $error');
    } finally {
      if (mounted) {
        setState(() => _isActionInFlight = false);
      }
    }
  }

  Future<void> _handleConnectionToggle({
    required BuildContext context,
    required VpnController vpn,
    required bool hasServers,
    required List<Server> effectiveServers,
    required Server? selected,
  }) async {
    final vpnState = vpn.state;
    final isConnected = vpnState == VpnState.connected;
    final isBusy = _busyStates.contains(vpnState);
    Server? targetServer;
    SpicRouteSelection? targetSelection;

    if (isBusy) return;

    if (!isConnected && !_hasImportedProfile) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('Import tt:// link first')));
      _showImportBottomSheet();
      return;
    }

    if (!isConnected && effectiveServers.isEmpty && selected == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            hasServers ? 'Select server first' : 'Open tt:// link first',
          ),
        ),
      );
      return;
    }

    if (!isConnected && _subscription.isExpired) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text(
            'Subscription expired. Renew SPIC or enter a new tt:// link.',
          ),
        ),
      );
      return;
    }

    setState(() => _isActionInFlight = true);

    try {
      if (isConnected) {
        await vpn.stop();
        _connectionSupervisor.resetForDisconnect();
      } else {
        targetSelection = await _connectionSupervisor.selectSmartServer(
          effectiveServers: effectiveServers,
          selected: selected,
          preferredProtocol: _selectedProtocol,
        );
        targetServer = targetSelection?.server;
        if (!mounted) return;

        if (targetServer == null) {
          ScaffoldMessenger.maybeOf(this.context)?.showSnackBar(
            const SnackBar(
              content: Text('No available route. Try again shortly.'),
            ),
          );
          return;
        }

        _selectedProtocol =
            targetSelection?.protocol ?? targetServer.vpnProtocol;
        await _connectToServer(vpn: vpn, server: targetServer);
      }
    } catch (e) {
      if (targetServer != null) {
        await _connectionSupervisor.rememberServerFailure(targetServer);
      }
      if (!mounted) return;

      ScaffoldMessenger.maybeOf(
        this.context,
      )?.showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      if (mounted) {
        setState(() => _isActionInFlight = false);
      }
    }
  }

  Widget _buildServersList(
    ServersScopeController servers,
    List<Server> effectiveServers,
    Server? selected,
  ) {
    final scheme = Theme.of(context).colorScheme;

    if (!_hasImportedProfile) {
      return DecoratedBox(
        decoration: _serverListDecoration(scheme),
        child: Center(
          child: FilledButton.icon(
            onPressed: _showImportBottomSheet,
            icon: const Icon(Icons.add_link),
            label: const Text('Import tt:// to load servers'),
          ),
        ),
      );
    }

    if (effectiveServers.isEmpty && servers.loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (effectiveServers.isEmpty && servers.error != null) {
      return Center(child: Text('Error: ${servers.error}'));
    }

    if (effectiveServers.isEmpty) {
      return DecoratedBox(
        decoration: _serverListDecoration(scheme),
        child: Center(
          child: OutlinedButton.icon(
            onPressed: _showImportBottomSheet,
            icon: const Icon(Icons.add_link),
            label: const Text('Import tt://'),
          ),
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, right: 2, bottom: 6),
          child: Row(
            children: [
              Text(
                'Servers',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _showImportBottomSheet,
                icon: const Icon(Icons.add_link, size: 18),
                label: const Text('Import'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: DecoratedBox(
            decoration: _serverListDecoration(scheme),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Scrollbar(
                thumbVisibility: effectiveServers.length > 4,
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: effectiveServers.length,
                  separatorBuilder: (context, index) => Divider(
                    height: 1,
                    indent: 56,
                    endIndent: 12,
                    color: scheme.outlineVariant.withValues(alpha: 0.5),
                  ),
                  itemBuilder: (context, index) {
                    final server = effectiveServers[index];
                    final isSelected =
                        selected != null &&
                        _isSameServerEndpoint(server, selected);
                    final hasCredentials = _hasServerCredentials(server);
                    final isExternal = !_isTrustedSpicServer(server);
                    final isCoolingDown = _connectionSupervisor
                        .isServerCoolingDown(server);
                    final flag = flagForServer(server);

                    return ListTile(
                      enabled: !isCoolingDown && (hasCredentials || isExternal),
                      dense: true,
                      visualDensity: const VisualDensity(vertical: -2),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                      ),
                      minLeadingWidth: 32,
                      leading: Text(flag, style: const TextStyle(fontSize: 22)),
                      title: Text(
                        server.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        _serverSubtitle(
                          server,
                          hasCredentials,
                          isCoolingDown: isCoolingDown,
                          isExternal: isExternal,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: isSelected
                          ? const Icon(Icons.check, color: Colors.green)
                          : isCoolingDown
                          ? Icon(
                              Icons.timer_outlined,
                              size: 18,
                              color: scheme.onSurfaceVariant,
                            )
                          : isExternal
                          ? Icon(
                              Icons.warning_amber_rounded,
                              size: 18,
                              color: Colors.deepOrange.shade600,
                            )
                          : hasCredentials
                          ? null
                          : Icon(
                              Icons.lock_outline,
                              size: 18,
                              color: scheme.onSurfaceVariant,
                            ),
                      onTap: isCoolingDown || (!hasCredentials && !isExternal)
                          ? null
                          : () {
                              if (!hasCredentials && isExternal) {
                                ScaffoldMessenger.maybeOf(
                                  context,
                                )?.showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Import this external tt:// link first.',
                                    ),
                                  ),
                                );
                                _showImportBottomSheet();
                                return;
                              }

                              setState(() {
                                _selectedServerId = server.id;
                                _selectedServerKey = _serverEndpointKey(server);
                                _selectedProtocol = server.vpnProtocol;
                              });

                              if (servers.servers.any(
                                (item) => item.id == server.id,
                              )) {
                                servers.pickServer(server.id);
                              }
                            },
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  BoxDecoration _serverListDecoration(ColorScheme scheme) {
    return BoxDecoration(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.52),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.68)),
    );
  }

  Future<void> _connectToServer({
    required VpnController vpn,
    required Server server,
  }) async {
    final selectedServerKey = _serverEndpointKey(server);
    final policyServer = _connectionSupervisor.applyPolicy(
      server,
      protocol: _selectedProtocol,
    );
    if (mounted) {
      setState(() {
        _selectedServerId = server.id;
        _selectedServerKey = selectedServerKey;
        _selectedProtocol = policyServer.vpnProtocol;
      });
    }
    _connectionSupervisor.beginConnectionVerification(server: server);

    if (!_isTrustedSpicServer(server) && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('External endpoint: lower trust route.'),
          duration: Duration(seconds: 2),
        ),
      );
    }

    try {
      final routingProfile = server.routingProfile;
      await context.dependencyFactory.vpnPlugin.setBypassedPackages(
        _bypassedAppPackages,
      );
      await vpn.updateConfiguration(
        server: policyServer,
        routingProfile: routingProfile,
        excludedRoutes: const [],
      );
      await vpn.start(
        server: policyServer,
        routingProfile: routingProfile,
        excludedRoutes: const [],
      );
    } catch (_) {
      _connectionSupervisor.markConnectionFailed();
      await _connectionSupervisor.rememberServerFailure(server);
      rethrow;
    }

    if (!mounted) return;

    final connected = await _waitForVpnConnected(selectedServerKey);
    if (!mounted) return;

    final currentVpn = VpnScope.vpnControllerOf(context, listen: false);
    if (!connected) {
      await _connectionSupervisor.rememberServerFailure(server);
      try {
        await currentVpn.stop();
      } catch (_) {
        // The native service may already be stopped after an auth/network error.
      }
      if (!mounted) return;

      _connectionSupervisor.markAccessRejected();
      final rejectionText = _isTrustedSpicServer(server)
          ? 'Access rejected. Import a fresh SPIC tt:// link.'
          : 'External route rejected. Import its fresh tt:// link.';
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(rejectionText)));
      return;
    }

    final routeProbe = await _connectionSupervisor.probeServer(
      server,
      rememberFailure: false,
      protocol: policyServer.vpnProtocol,
    );
    final dnsOk = await _connectionSupervisor.checkDnsHealth();
    if (!mounted) return;

    await _connectionSupervisor.completeConnectionVerification(
      server: server,
      routeProbe: routeProbe,
      dnsOk: dnsOk,
    );
  }

  Future<bool> _waitForVpnConnected(String selectedServerKey) async {
    final deadline = DateTime.now().add(_connectionVerificationTimeout);
    while (mounted && DateTime.now().isBefore(deadline)) {
      if (!context.mounted) {
        return false;
      }

      // ignore: use_build_context_synchronously
      final currentVpn = VpnScope.vpnControllerOf(context, listen: false);
      if (currentVpn.state == VpnState.connected &&
          _selectedServerKey == selectedServerKey) {
        return true;
      }

      await Future<void>.delayed(const Duration(milliseconds: 250));
    }

    return false;
  }

  String _labelForState(VpnState state) {
    switch (state) {
      case VpnState.connected:
        return 'Connected';
      case VpnState.connecting:
        return 'Connecting';
      case VpnState.disconnected:
        return 'Disconnected';
      case VpnState.waitingForRecovery:
        return 'Reconnecting securely';
      case VpnState.recovering:
        return 'Reconnecting securely';
      case VpnState.waitingForNetwork:
        return 'Protecting connection';
    }
  }

  String _serverSubtitle(
    Server server,
    bool hasCredentials, {
    required bool isCoolingDown,
    required bool isExternal,
  }) {
    final endpoint = server.domain.trim().isNotEmpty
        ? server.domain.trim()
        : server.ipAddress.trim();
    if (isCoolingDown) {
      return '$endpoint - cooling down';
    }

    if (isExternal) {
      return hasCredentials
          ? '$endpoint - external, lower trust'
          : '$endpoint - external, import tt://';
    }

    if (hasCredentials) {
      return endpoint;
    }

    return '$endpoint - import tt:// to use';
  }

  Future<void> _loadBypassedAppPackages() async {
    try {
      final vpnPlugin = context.dependencyFactory.vpnPlugin;
      final packages = await _restoreBypassedAppPackages(vpnPlugin);
      if (!mounted) return;

      setState(() {
        _bypassedAppPackages = packages;
      });
    } catch (error, stackTrace) {
      debugPrint('Failed to restore bypassed packages: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) return;

      setState(() {
        _bypassedAppPackages = const [];
      });
    }
  }

  Future<void> _openBypassedAppsScreen({
    required VpnController vpn,
    required Server? selectedServer,
  }) async {
    final vpnPlugin = context.dependencyFactory.vpnPlugin;
    final result = await Navigator.of(context).push<_BypassedAppsResult>(
      MaterialPageRoute<_BypassedAppsResult>(
        builder: (_) => _BypassedAppsScreen(
          initialSelectedPackages: _bypassedAppPackages,
          initialSmartBypassEnabled: _smartBypassEnabled,
          smartRecommendedPackages: _smartRecommendedBypassPackages,
        ),
      ),
    );

    if (result == null || !mounted) {
      return;
    }

    final normalizedPackages = _normalizePackageNames(result.packageNames);
    final smartEnabledChanged =
        result.smartBypassEnabled != _smartBypassEnabled;
    if (listEquals(normalizedPackages, _bypassedAppPackages) &&
        !smartEnabledChanged) {
      return;
    }

    final recommendedPackages = _smartRecommendedBypassPackages.toSet();
    final manualPackages = result.smartBypassEnabled
        ? normalizedPackages
              .where(
                (packageName) => !recommendedPackages.contains(packageName),
              )
              .toList(growable: false)
        : normalizedPackages;
    final disabledSmartPackages = result.smartBypassEnabled
        ? recommendedPackages
              .where((packageName) => !normalizedPackages.contains(packageName))
              .toList(growable: false)
        : const <String>[];

    try {
      await _persistBypassedAppPackages(
        vpnPlugin: vpnPlugin,
        packageNames: normalizedPackages,
        manualPackageNames: manualPackages,
        smartBypassEnabled: result.smartBypassEnabled,
        smartDisabledPackageNames: disabledSmartPackages,
      );
    } catch (error, stackTrace) {
      debugPrint('Failed to save bypassed packages: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Failed to save app exclusions')),
      );
      return;
    }

    if (!mounted) return;

    setState(() {
      _bypassedAppPackages = normalizedPackages;
      _smartBypassEnabled = result.smartBypassEnabled;
      _smartBypassDisabledPackages = _normalizePackageNames(
        disabledSmartPackages,
      );
    });

    if (vpn.state == VpnState.connected && selectedServer != null) {
      await _restartVpnToApplyBypassedApps(
        vpn: vpn,
        selectedServer: selectedServer,
      );
      return;
    }

    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(const SnackBar(content: Text('App exclusions saved')));
  }

  Future<void> _restartVpnToApplyBypassedApps({
    required VpnController vpn,
    required Server selectedServer,
  }) async {
    if (_busyStates.contains(vpn.state)) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('Saved. Reconnect VPN to apply app exclusions.'),
        ),
      );
      return;
    }

    setState(() => _isActionInFlight = true);
    try {
      await vpn.stop();
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (!mounted) return;
      await _connectToServer(vpn: vpn, server: selectedServer);
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('App exclusions applied')));
    } catch (error, stackTrace) {
      debugPrint('Failed to restart VPN after app exclusion change: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('Saved. Reconnect VPN manually: $error')),
      );
    } finally {
      if (mounted) {
        setState(() => _isActionInFlight = false);
      }
    }
  }

  Future<void> _showImportBottomSheet() async {
    _importController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _importController.text.length,
    );

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        return SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              16,
              16,
              16,
              16 + MediaQuery.of(sheetContext).viewInsets.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Import tt:// link',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _importController,
                  autofocus: true,
                  minLines: 2,
                  maxLines: 5,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) async {
                    final importedServer = await _importServerFromLink(
                      link: _importController.text,
                    );
                    if (importedServer != null && sheetContext.mounted) {
                      await _completeImportAndConnect(
                        sheetContext: sheetContext,
                        server: importedServer,
                      );
                    }
                  },
                  decoration: const InputDecoration(
                    labelText: 'tt:// link',
                    hintText: 'tt://?...',
                    border: OutlineInputBorder(),
                    filled: true,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton(
                        onPressed: _isImporting
                            ? null
                            : () async {
                                final importedServer =
                                    await _importServerFromLink(
                                      link: _importController.text,
                                    );
                                if (importedServer != null &&
                                    sheetContext.mounted) {
                                  await _completeImportAndConnect(
                                    sheetContext: sheetContext,
                                    server: importedServer,
                                  );
                                }
                              },
                        child: _isImporting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Import'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton(
                      onPressed: _isImporting
                          ? null
                          : () => Navigator.of(sheetContext).pop(),
                      child: const Text('Cancel'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _completeImportAndConnect({
    required BuildContext sheetContext,
    required Server server,
  }) async {
    if (sheetContext.mounted) {
      Navigator.of(sheetContext).pop();
    }
    if (!mounted) return;

    FocusScope.of(context).unfocus();
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text(
          'Imported. Continue in the Android VPN permission dialog.',
        ),
        duration: Duration(seconds: 2),
      ),
    );

    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (!mounted) return;

    await _connectImportedServer(server);
  }

  Future<void> _connectImportedServer(Server server) async {
    final vpn = VpnScope.vpnControllerOf(context);
    if (_isActionInFlight || _busyStates.contains(vpn.state)) {
      return;
    }

    setState(() => _isActionInFlight = true);

    try {
      if (vpn.state == VpnState.connected) {
        await vpn.stop();
        await Future<void>.delayed(const Duration(milliseconds: 350));
        if (!mounted) return;
      }

      await _connectToServer(vpn: vpn, server: server);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      if (mounted) {
        setState(() => _isActionInFlight = false);
      }
    }
  }

  List<String> _normalizePackageNames(Iterable<String> packageNames) {
    final normalized =
        packageNames
            .map((packageName) => packageName.trim())
            .where((packageName) => packageName.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    return normalized;
  }

  Future<List<String>> _restoreBypassedAppPackages(VpnPlugin vpnPlugin) async {
    List<String> nativePackages = const [];
    final prefsPackages = await _loadStringListFromPrefs(
      _bypassedAppPackagesPrefsKey,
    );
    final manualPackages = await _loadStringListFromPrefs(
      _manualBypassedAppPackagesPrefsKey,
    );
    final disabledSmartPackages = await _loadStringListFromPrefs(
      _smartBypassDisabledPackagesPrefsKey,
    );
    final smartBypassEnabled = await _loadSmartBypassEnabledFromPrefs();
    final smartRecommendedPackages = await _loadSmartRecommendedBypassPackages(
      vpnPlugin,
    );

    try {
      nativePackages = _normalizePackageNames(
        await vpnPlugin.getBypassedPackages(),
      );
    } catch (error, stackTrace) {
      debugPrint('Failed to load bypassed packages from plugin: $error');
      debugPrintStack(stackTrace: stackTrace);
    }

    final effectiveManualPackages = manualPackages.isEmpty
        ? _normalizePackageNames({...nativePackages, ...prefsPackages})
        : manualPackages;
    final packages = _normalizePackageNames({
      ...effectiveManualPackages,
      if (smartBypassEnabled)
        ...smartRecommendedPackages.where(
          (packageName) => !disabledSmartPackages.contains(packageName),
        ),
    });

    if (!listEquals(packages, prefsPackages)) {
      await _saveStringListToPrefs(_bypassedAppPackagesPrefsKey, packages);
    }
    if (!listEquals(effectiveManualPackages, manualPackages)) {
      await _saveStringListToPrefs(
        _manualBypassedAppPackagesPrefsKey,
        effectiveManualPackages,
      );
    }
    if (!listEquals(packages, nativePackages)) {
      await vpnPlugin.setBypassedPackages(packages);
    }

    if (mounted) {
      setState(() {
        _smartBypassEnabled = smartBypassEnabled;
        _smartBypassDisabledPackages = disabledSmartPackages;
        _smartRecommendedBypassPackages = smartRecommendedPackages;
      });
    }

    return packages;
  }

  Future<bool> _loadSmartBypassEnabledFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_smartBypassEnabledPrefsKey) ?? true;
    } catch (error, stackTrace) {
      debugPrint('Failed to load smart bypass state from prefs: $error');
      debugPrintStack(stackTrace: stackTrace);
      return true;
    }
  }

  Future<List<String>> _loadStringListFromPrefs(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = prefs.getString(key);
      if (encoded == null || encoded.isEmpty) {
        return const [];
      }

      final raw = jsonDecode(encoded);
      if (raw is! List) {
        return const [];
      }

      return _normalizePackageNames(raw.whereType<String>());
    } catch (error, stackTrace) {
      debugPrint('Failed to load $key from prefs: $error');
      debugPrintStack(stackTrace: stackTrace);
      return const [];
    }
  }

  Future<void> _saveStringListToPrefs(
    String key,
    List<String> packageNames,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      key,
      jsonEncode(_normalizePackageNames(packageNames)),
    );
  }

  Future<void> _persistBypassedAppPackages({
    required VpnPlugin vpnPlugin,
    required List<String> packageNames,
    required List<String> manualPackageNames,
    required bool smartBypassEnabled,
    required List<String> smartDisabledPackageNames,
  }) async {
    Object? persistError;
    StackTrace? persistStackTrace;

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_smartBypassEnabledPrefsKey, smartBypassEnabled);
      await _saveStringListToPrefs(_bypassedAppPackagesPrefsKey, packageNames);
      await _saveStringListToPrefs(
        _manualBypassedAppPackagesPrefsKey,
        manualPackageNames,
      );
      await _saveStringListToPrefs(
        _smartBypassDisabledPackagesPrefsKey,
        smartDisabledPackageNames,
      );
    } catch (error, stackTrace) {
      debugPrint('Failed to persist bypassed packages in prefs: $error');
      debugPrintStack(stackTrace: stackTrace);
      persistError ??= error;
      persistStackTrace ??= stackTrace;
    }

    try {
      await vpnPlugin.setBypassedPackages(packageNames);
    } catch (error, stackTrace) {
      debugPrint('Failed to persist bypassed packages in plugin: $error');
      debugPrintStack(stackTrace: stackTrace);
      persistError ??= error;
      persistStackTrace ??= stackTrace;
    }

    if (persistError != null) {
      Error.throwWithStackTrace(persistError, persistStackTrace!);
    }
  }

  Future<List<String>> _loadSmartRecommendedBypassPackages(
    VpnPlugin vpnPlugin,
  ) async {
    try {
      final apps = await vpnPlugin.getInstalledApps(includeSystemApps: false);
      return _normalizePackageNames(
        apps.where(_shouldRecommendBypass).map((app) => app.packageName),
      );
    } catch (error, stackTrace) {
      debugPrint('Failed to load smart bypass recommendations: $error');
      debugPrintStack(stackTrace: stackTrace);
      return const [];
    }
  }

  bool _shouldRecommendBypass(InstalledApp app) {
    final text = '${app.appName} ${app.packageName}'.toLowerCase();
    const markers = [
      'bank',
      'банк',
      'sber',
      'сбер',
      'tinkoff',
      'tbank',
      't-bank',
      'alpha',
      'alfabank',
      'alfa',
      'vtb',
      'втб',
      'raiffeisen',
      'gazprombank',
      'otpbank',
      'openbank',
      'pochtabank',
      'rencredit',
      'rshb',
      'yoomoney',
      'paypal',
      'pay',
      'wallet',
      'mirpay',
      'sbpay',
      'gosuslugi',
      'госуслуги',
      'nalog',
      'tax',
      'invest',
      'broker',
      'trading',
      'crypto',
      'binance',
      'bybit',
      'steam',
      'epicgames',
      'riot',
      'battle',
    ];

    return markers.any(text.contains);
  }
}

class _OnboardingStep extends StatelessWidget {
  const _OnboardingStep({required this.number, required this.text});

  final String number;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minHeight: 34),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 10,
            backgroundColor: scheme.primary,
            foregroundColor: scheme.onPrimary,
            child: Text(
              number,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(width: 7),
          Text(text, style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

enum _ProtectionTone { neutral, ok, caution, warning, danger }

class _ProtectionChip extends StatelessWidget {
  const _ProtectionChip({required this.label, required this.tone});

  final String label;
  final _ProtectionTone tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (tone) {
      _ProtectionTone.neutral => scheme.onSurfaceVariant,
      _ProtectionTone.ok => Colors.green.shade700,
      _ProtectionTone.caution => Colors.amber.shade800,
      _ProtectionTone.warning => Colors.deepOrange.shade700,
      _ProtectionTone.danger => Colors.red.shade700,
    };
    final backgroundColor = switch (tone) {
      _ProtectionTone.neutral => scheme.surfaceContainerHighest.withValues(
        alpha: 0.64,
      ),
      _ProtectionTone.ok => Colors.green.withValues(alpha: 0.12),
      _ProtectionTone.caution => Colors.amber.withValues(alpha: 0.15),
      _ProtectionTone.warning => Colors.deepOrange.withValues(alpha: 0.13),
      _ProtectionTone.danger => Colors.red.withValues(alpha: 0.12),
    };
    final borderColor = switch (tone) {
      _ProtectionTone.neutral => scheme.outlineVariant,
      _ProtectionTone.ok => Colors.green.withValues(alpha: 0.45),
      _ProtectionTone.caution => Colors.amber.withValues(alpha: 0.52),
      _ProtectionTone.warning => Colors.deepOrange.withValues(alpha: 0.50),
      _ProtectionTone.danger => Colors.red.withValues(alpha: 0.50),
    };
    final icon = switch (tone) {
      _ProtectionTone.neutral => Icons.radio_button_unchecked,
      _ProtectionTone.ok => Icons.check_circle,
      _ProtectionTone.caution => Icons.error_outline,
      _ProtectionTone.warning => Icons.warning_amber_rounded,
      _ProtectionTone.danger => Icons.report_gmailerrorred_outlined,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class ImportState {
  static bool _imported = false;

  static bool get imported => _imported;

  static Future<void> setImported(bool value) async {
    _imported = value;
  }
}

class _BypassedAppsResult {
  const _BypassedAppsResult({
    required this.packageNames,
    required this.smartBypassEnabled,
  });

  final List<String> packageNames;
  final bool smartBypassEnabled;
}

class _BypassedAppsScreen extends StatefulWidget {
  const _BypassedAppsScreen({
    required this.initialSelectedPackages,
    required this.initialSmartBypassEnabled,
    required this.smartRecommendedPackages,
  });

  final List<String> initialSelectedPackages;
  final bool initialSmartBypassEnabled;
  final List<String> smartRecommendedPackages;

  @override
  State<_BypassedAppsScreen> createState() => _BypassedAppsScreenState();
}

class _BypassedAppsScreenState extends State<_BypassedAppsScreen> {
  final TextEditingController _searchController = TextEditingController();
  late final Set<String> _selectedPackages = widget.initialSelectedPackages
      .toSet();
  late final Set<String> _smartRecommendedPackages = widget
      .smartRecommendedPackages
      .toSet();
  late bool _smartBypassEnabled = widget.initialSmartBypassEnabled;

  List<InstalledApp> _apps = const [];
  bool _isLoading = true;
  bool _showSystemApps = false;
  String _query = '';
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _loadApps();
    _searchController.addListener(() {
      setState(() {
        _query = _searchController.text.trim().toLowerCase();
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filteredApps = _filteredApps();
    final selectedCount = _selectedPackages.length;

    return PopScope<_BypassedAppsResult>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          _finishSelection();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            selectedCount == 0
                ? 'Apps bypassing VPN'
                : 'Apps bypassing VPN ($selectedCount)',
          ),
          actions: [
            TextButton(
              onPressed: _selectedPackages.isEmpty
                  ? null
                  : () {
                      setState(() {
                        _selectedPackages.clear();
                      });
                    },
              child: const Text('Clear all'),
            ),
            TextButton(onPressed: _finishSelection, child: const Text('Save')),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              SwitchListTile(
                title: const Text('Smart exclusions'),
                subtitle: Text(
                  _smartRecommendedPackages.isEmpty
                      ? 'No suggested apps found'
                      : '${_smartRecommendedPackages.length} suggested app${_smartRecommendedPackages.length == 1 ? '' : 's'}',
                ),
                value: _smartBypassEnabled,
                onChanged: (value) {
                  setState(() {
                    _smartBypassEnabled = value;
                    if (value) {
                      _selectedPackages.addAll(_smartRecommendedPackages);
                    }
                  });
                },
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: TextField(
                  controller: _searchController,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Search apps',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              SwitchListTile(
                title: const Text('Show system apps'),
                value: _showSystemApps,
                onChanged: (value) {
                  setState(() {
                    _showSystemApps = value;
                    _isLoading = true;
                    _apps = const [];
                  });
                  _loadApps();
                },
              ),
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : filteredApps.isEmpty
                    ? const Center(child: Text('No apps found'))
                    : ListView.builder(
                        itemCount: filteredApps.length,
                        itemBuilder: (context, index) {
                          final app = filteredApps[index];
                          final selected = _selectedPackages.contains(
                            app.packageName,
                          );
                          final recommended = _smartRecommendedPackages
                              .contains(app.packageName);

                          return CheckboxListTile(
                            value: selected,
                            onChanged: (_) {
                              setState(() {
                                if (selected) {
                                  _selectedPackages.remove(app.packageName);
                                } else {
                                  _selectedPackages.add(app.packageName);
                                }
                              });
                            },
                            secondary: _AppIcon(iconBytes: app.iconBytes),
                            title: Row(
                              children: [
                                Expanded(child: Text(app.appName)),
                                if (recommended) const _SmartBadge(),
                              ],
                            ),
                            subtitle: Text(app.packageName),
                            controlAffinity: ListTileControlAffinity.trailing,
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _finishSelection() {
    final result = _selectedPackages.toList()..sort();
    Navigator.of(context).pop(
      _BypassedAppsResult(
        packageNames: result,
        smartBypassEnabled: _smartBypassEnabled,
      ),
    );
  }

  Future<void> _loadApps() async {
    final loadGeneration = ++_loadGeneration;
    try {
      final apps = await context.dependencyFactory.vpnPlugin.getInstalledApps(
        includeSystemApps: _showSystemApps,
      );

      if (!mounted || loadGeneration != _loadGeneration) return;

      setState(() {
        _apps = apps;
        _isLoading = false;
      });
    } catch (error, stackTrace) {
      debugPrint('Failed to load installed apps: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted || loadGeneration != _loadGeneration) return;

      setState(() {
        _apps = const [];
        _isLoading = false;
      });

      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Failed to load installed apps')),
      );
    }
  }

  List<InstalledApp> _filteredApps() {
    if (_query.isEmpty) {
      return _apps;
    }

    return _apps
        .where((app) {
          return app.appName.toLowerCase().contains(_query) ||
              app.packageName.toLowerCase().contains(_query);
        })
        .toList(growable: false);
  }
}

class _SmartBadge extends StatelessWidget {
  const _SmartBadge();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Container(
      margin: const EdgeInsets.only(left: 8),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: color.withValues(alpha: 0.12),
      ),
      child: Text(
        'Smart',
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _AppIcon extends StatelessWidget {
  const _AppIcon({this.iconBytes});

  final Uint8List? iconBytes;

  @override
  Widget build(BuildContext context) {
    if (iconBytes == null || iconBytes!.isEmpty) {
      return const CircleAvatar(child: Icon(Icons.android));
    }

    return CircleAvatar(backgroundImage: MemoryImage(iconBytes!));
  }
}
