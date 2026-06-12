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
  static const String _antiDpiEnabledPrefsKey = 'spic.anti_dpi_enabled';
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
  bool _antiDpiEnabled = false;
  bool _isHandlingExternalDeepLink = false;
  bool _showOnboarding = true;
  String? _referralLink;
  List<TTConfig> _accessProfileConfigs = const [];
  String? _pendingExternalDeepLink;
  String? _lastHandledExternalDeepLink;
  String? _pendingNativeAction;
  bool _isHandlingNativeAction = false;
  DateTime? _lastBackPressedAt;

  List<Server> _localServers = const [];
  List<Server> _healthServers = const [];
  Timer? _healthCheckTimer;
  Server? _healthSelectedServer;
  String? _selectedServerId;
  String? _selectedServerKey;
  int _postConnectVerificationGeneration = 0;

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

  void _handleMainBackPress() {
    final now = DateTime.now();
    final shouldExit =
        _lastBackPressedAt != null &&
        now.difference(_lastBackPressedAt!) < const Duration(seconds: 2);
    if (shouldExit) {
      SystemNavigator.pop();
      return;
    }

    _lastBackPressedAt = now;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('Чтобы выключить приложение нажмите "назад" ещё раз.'),
          duration: Duration(seconds: 2),
        ),
      );
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

    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          _handleMainBackPress();
        }
      },
      child: Scaffold(
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
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: Column(
                      children: [
                        Text(
                          'Server: ${selected == null ? 'not selected' : _serverDisplayName(selected)}',
                        ),
                        const SizedBox(height: 4),
                        Text('Status: ${_labelForState(displayVpnState)}'),
                        const SizedBox(height: 10),
                        _buildRouteModeSelector(),
                        const SizedBox(height: 10),
                        _buildAntiDpiTile(vpn, selected),
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
                        if (_subscriptionForServer(selected).isExpired)
                          _buildExpiredSubscriptionPanel(),
                        if (_subscriptionForServer(selected).isExpired)
                          const SizedBox(height: 10),
                        _buildBypassedAppsTile(vpn, selected),
                        const SizedBox(height: 10),
                        if (showImportBanner) _buildImportPanel(),
                        if (showImportBanner) const SizedBox(height: 10),
                        _buildInviteButton(selected),
                        const SizedBox(height: 8),
                        _buildExpiryText(selected),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
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
            const SnackBar(content: Text('Import access link first')),
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

    return _dedupeServersForDisplay(mergedServers);
  }

  List<Server> _dedupeServersForDisplay(Iterable<Server> servers) {
    final keyedServers = <String, Server>{};
    for (final server in servers) {
      keyedServers[_serverEndpointKey(server)] = server;
    }

    return keyedServers.values.toList(growable: false);
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

  TTConfig? _accessProfileConfigForServer(Server server) {
    for (final config in _accessProfileConfigs.reversed) {
      if (_isAccessProfileForServer(config, server)) {
        return config;
      }
    }

    return null;
  }

  bool _isAccessProfileForServer(TTConfig config, Server server) {
    if (!config.isValid || config.isExpired) {
      return false;
    }

    final profileAddress = SpicConnectionSupervisor.normalizedEndpointAddress(
      config.address ?? '',
    );
    final serverAddress = SpicConnectionSupervisor.normalizedEndpointAddress(
      server.ipAddress,
    );
    if (profileAddress.isNotEmpty || serverAddress.isNotEmpty) {
      return profileAddress.isNotEmpty &&
          serverAddress.isNotEmpty &&
          profileAddress == serverAddress;
    }

    final profileHostname = SpicConnectionSupervisor.normalizedEndpointHost(
      config.hostname ?? '',
    );
    final serverHostname = SpicConnectionSupervisor.normalizedEndpointHost(
      server.domain,
    );
    return profileHostname.isNotEmpty && profileHostname == serverHostname;
  }

  bool _isSameAccessProfileEndpoint(TTConfig left, TTConfig right) {
    final leftAddress = SpicConnectionSupervisor.normalizedEndpointAddress(
      left.address ?? '',
    );
    final rightAddress = SpicConnectionSupervisor.normalizedEndpointAddress(
      right.address ?? '',
    );
    if (leftAddress.isNotEmpty || rightAddress.isNotEmpty) {
      return leftAddress.isNotEmpty &&
          rightAddress.isNotEmpty &&
          leftAddress == rightAddress;
    }

    final leftHostname = SpicConnectionSupervisor.normalizedEndpointHost(
      left.hostname ?? '',
    );
    final rightHostname = SpicConnectionSupervisor.normalizedEndpointHost(
      right.hostname ?? '',
    );
    return leftHostname.isNotEmpty && leftHostname == rightHostname;
  }

  SubscriptionInfo _subscriptionForServer(Server? server) {
    if (server == null) {
      return _subscription;
    }

    final config = _accessProfileConfigForServer(server);
    return config == null
        ? _subscription
        : SubscriptionInfo(expiresAt: config.expiresAt);
  }

  Server _serverWithAccessProfile(Server server) {
    final config = _accessProfileConfigForServer(server);
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

  Widget _buildExpiryText(Server? selected) {
    final subscription = _subscriptionForServer(selected);
    final style = TextStyle(
      fontSize: 12,
      color: subscription.isExpired ? Colors.red : null,
      fontWeight: subscription.isExpired ? FontWeight.w600 : null,
    );
    final text = subscription.isKnown
        ? '${subscription.dateLabel} - ${subscription.label}'
        : subscription.label;
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
      final antiDpiEnabled = prefs.getBool(_antiDpiEnabledPrefsKey) ?? false;
      if (!mounted) return;

      setState(() {
        _hasImportedProfile = hasImportedProfile;
        _subscription = SubscriptionInfo(expiresAt: expiresAt);
        _referralLink = prefs.getString(_referralLinkKey);
        _showOnboarding = !onboardingSeen && !hasImportedProfile;
        _antiDpiEnabled = antiDpiEnabled;
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
        if (mounted) {
          setState(() {
            _accessProfileConfigs = savedProfiles;
          });
        }
        await _restoreImportedServersFromConfigs(savedProfiles);
        await _deduplicatePersistedServers();
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
                  const SnackBar(
                    content: Text('Could not open update. Try again later.'),
                  ),
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

  Future<List<TTConfig>> _persistAccessProfileState({
    required TTConfig config,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final trustedProfile = _isTrustedAccessProfileConfig(config);
    final referralLink = trustedProfile ? _referralLinkForConfig(config) : null;
    await prefs.setBool(_hasAccessProfileKey, true);
    final profiles = await _accessProfileStore.saveProfile(config);
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
      return profiles;
    }

    if (referralLink == null) {
      await prefs.remove(_referralLinkKey);
    } else {
      await prefs.setString(_referralLinkKey, referralLink);
    }

    return profiles;
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
    final validProfiles = savedProfiles
        .where((config) => config.isValid && !config.isExpired)
        .toList(growable: false);

    for (final config in validProfiles) {
      await _restoreImportedServerFromConfig(config);
    }
  }

  Future<void> _restoreImportedServerFromConfig(TTConfig config) async {
    if (!config.isValid || config.isExpired) {
      return;
    }

    try {
      final request = _addServerRequestFromConfig(config);
      final server = await _upsertImportedServer(request);
      await _serverRepository.setSelectedServerId(id: server.id);
      if (!mounted) return;

      final trustedProfile = _isTrustedAccessProfileConfig(config);
      setState(() {
        _accessProfileConfigs = [
          ..._accessProfileConfigs.where(
            (item) => !_isSameAccessProfileEndpoint(item, config),
          ),
          config,
        ];
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
              'Your SPIC access is no longer active. Renew the subscription or enter a new access link.',
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
              label: Text('Fast'),
              icon: Icon(Icons.bolt, size: 18),
            ),
            ButtonSegment(
              value: SpicRouteMode.stable,
              label: Text('Stable'),
              icon: Icon(Icons.timeline, size: 18),
            ),
            ButtonSegment(
              value: SpicRouteMode.secure,
              label: Text('Safe'),
              icon: Icon(Icons.shield_outlined, size: 18),
            ),
            ButtonSegment(value: SpicRouteMode.manual, label: Text('Manual')),
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

  Widget _buildAntiDpiTile(VpnController vpn, Server? selectedServer) {
    final vpnIsBusy = _busyStates.contains(vpn.state);
    return Card(
      child: SwitchListTile(
        secondary: const Icon(Icons.visibility_off_outlined),
        title: const Text('Anti-DPI'),
        subtitle: Text(
          _antiDpiEnabled
              ? 'Reconnects with anti-DPI enabled'
              : 'Standard tunnel fingerprint',
        ),
        value: _antiDpiEnabled,
        onChanged: _isActionInFlight || vpnIsBusy
            ? null
            : (value) => _setAntiDpiEnabled(
                enabled: value,
                vpn: vpn,
                selectedServer: selectedServer,
              ),
      ),
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
                'External server: SPIC protection is not guaranteed.',
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
            Text(
              'We protect your privacy. SPIC does not sell your data, tamper with websites, or expose your DNS queries to your provider.',
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
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
        ? 'No apps outside VPN - $suffix'
        : '$count app${count == 1 ? '' : 's'} outside VPN - $suffix';

    return Card(
      child: ListTile(
        leading: const Icon(Icons.app_shortcut),
        title: const Text('Apps outside VPN'),
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
          subscription: _subscriptionForServer(selectedServer).label,
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
                      ? 'Add access link'
                      : 'Import another access link',
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
      )?.showSnackBar(const SnackBar(content: Text('Paste access link first')));
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
        )?.showSnackBar(const SnackBar(content: Text('Invalid access link')));
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
              'This access link has expired. Renew the subscription or paste a new link.',
            ),
          ),
        );
        return null;
      }

      final AddServerRequest request = _addServerRequestFromConfig(config);

      final repository = _serverRepository;
      final server = await _upsertImportedServer(request);
      await repository.setSelectedServerId(id: server.id);
      final savedProfiles = await _persistAccessProfileState(config: config);
      await _connectionSupervisor.clearAllServerFailures();
      await _markOnboardingSeen();
      await ImportState.setImported(true);

      if (!mounted) return null;

      final trustedProfile = _isTrustedAccessProfileConfig(config);
      setState(() {
        _accessProfileConfigs = savedProfiles;
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
    final String hostname = (config.hostname ?? '').trim();
    final String address = (config.address ?? '').trim();
    final String connectAddress = address.isNotEmpty ? address : hostname;
    final String tlsHostname = hostname.isNotEmpty
        ? hostname
        : _hostOnly(connectAddress);
    final String name = _importedServerNameForConfig(
      hostname: tlsHostname,
      address: connectAddress,
    );
    final bool trusted = SpicTrustPolicy.isTrustedEndpoint(
      domain: tlsHostname,
      address: connectAddress,
    );
    final bool btw = _isBtwEndpoint(
      hostname: tlsHostname,
      address: connectAddress,
    );
    final profileDns = config.dnsUpstreams
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    final dnsServers = trusted
        ? profileDns.isNotEmpty
              ? profileDns
              : SpicConnectionSupervisor.spicTunnelDnsUpstreams
        : profileDns;

    return ServerData.empty(
      name: name.isEmpty ? 'Imported server' : name,
      ipAddress: connectAddress,
      domain: tlsHostname,
      username: config.username!.trim(),
      password: config.password!.trim(),
      vpnProtocol: btw ? VpnProtocol.http2 : _selectedProtocol,
      routingProfileId: kDefaultRoutingProfileId,
      dnsServers: dnsServers,
      ipv6: !btw,
      postQuantumGroupEnabled: !btw,
    );
  }

  Future<Server> _upsertImportedServer(ServerData request) async {
    final allServers = await _serverRepository.getAllServers();
    final requestServer = Server(id: '_import', serverData: request);
    final matchingServers = allServers
        .where((server) => _isSameServerEndpoint(server, requestServer))
        .toList(growable: false);

    if (matchingServers.isNotEmpty) {
      final existingServer = _serverToKeepForDuplicateGroup(matchingServers);
      await _serverRepository.setNewServer(
        id: existingServer.id,
        request: request,
      );
      await _removeDuplicateServers(
        matchingServers,
        keepServerId: existingServer.id,
      );
      return existingServer.copyWith(serverData: request);
    }

    final server = await _serverRepository.addNewServer(request: request);
    await _deduplicatePersistedServers(keepServerId: server.id);
    return server;
  }

  Future<void> _deduplicatePersistedServers({String? keepServerId}) async {
    final allServers = await _serverRepository.getAllServers();
    final groupedServers = <String, List<Server>>{};
    for (final server in allServers) {
      final key = _serverEndpointKey(server);
      if (key.startsWith('id:')) {
        continue;
      }
      (groupedServers[key] ??= <Server>[]).add(server);
    }

    for (final duplicateGroup in groupedServers.values) {
      if (duplicateGroup.length < 2) {
        continue;
      }

      final serverToKeep = keepServerId == null
          ? _serverToKeepForDuplicateGroup(duplicateGroup)
          : duplicateGroup.firstWhere(
              (server) => server.id == keepServerId,
              orElse: () => _serverToKeepForDuplicateGroup(duplicateGroup),
            );
      await _removeDuplicateServers(
        duplicateGroup,
        keepServerId: serverToKeep.id,
      );
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _localServers = _dedupeServersForDisplay(_localServers);
    });
  }

  Server _serverToKeepForDuplicateGroup(List<Server> duplicateGroup) {
    return duplicateGroup.firstWhere(
      (server) => server.selected || server.id == _selectedServerId,
      orElse: () => duplicateGroup.last,
    );
  }

  Future<void> _removeDuplicateServers(
    Iterable<Server> servers, {
    required String keepServerId,
  }) async {
    for (final server in servers) {
      if (server.id == keepServerId) {
        continue;
      }

      try {
        await _serverRepository.removeServer(serverId: server.id);
      } catch (error, stackTrace) {
        debugPrint('Failed to remove duplicate server ${server.id}: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
    }
  }

  String _importedServerNameForConfig({
    required String hostname,
    required String address,
  }) {
    final hostnameLower = hostname.toLowerCase();
    final addressLower = SpicConnectionSupervisor.normalizedEndpointAddress(
      address,
    );
    if (addressLower == '185.236.24.249:18445' ||
        hostnameLower == 'home.stop2virus.xyz' &&
            addressLower.endsWith(':18445')) {
      return 'BW Router Gateway';
    }

    if (addressLower == '185.236.24.249:8443' ||
        hostnameLower == 'home.stop2virus.xyz' &&
            addressLower.endsWith(':8443')) {
      return 'BW Pro Gateway';
    }

    final display = hostname.isNotEmpty ? hostname : address;
    return display.isEmpty ? 'Imported server' : display;
  }

  bool _isBtwEndpoint({required String hostname, required String address}) {
    final normalizedAddress =
        SpicConnectionSupervisor.normalizedEndpointAddress(address);
    final normalizedHostname = hostname.trim().toLowerCase();
    return normalizedAddress == '185.236.24.249:8443' ||
        normalizedAddress == '185.236.24.249:18445' ||
        normalizedHostname == 'home.stop2virus.xyz' &&
            (normalizedAddress.endsWith(':8443') ||
                normalizedAddress.endsWith(':18445'));
  }

  bool _isBtwServer(Server server) {
    return SpicConnectionSupervisor.isBtwServer(server);
  }

  String _serverDisplayName(Server server) {
    if (!_isBtwServer(server)) {
      return server.name;
    }

    final name = server.name.trim();
    if (name.toUpperCase().contains('PRO')) {
      return name;
    }

    if (name == 'BtW Home Gateway' || name == 'BtW PRO Home Gateway') {
      return 'BW Pro Gateway';
    }

    return name.isEmpty ? 'BW Pro Gateway' : name;
  }

  Widget _serverLeading(Server server, String flag, ColorScheme scheme) {
    if (!_isBtwServer(server)) {
      return Text(flag, style: const TextStyle(fontSize: 22));
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(7),
        gradient: const LinearGradient(
          colors: [Color(0xFF121826), Color(0xFF1BA784)],
        ),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.35)),
      ),
      child: const Text(
        'PRO',
        style: TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 0,
        ),
      ),
    );
  }

  String _hostOnly(String endpoint) {
    final raw = endpoint.trim();
    if (raw.isEmpty) return '';

    final uri = Uri.tryParse('tcp://$raw');
    if (uri != null && uri.host.isNotEmpty) {
      return uri.host;
    }

    return raw.split(':').first.trim();
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

  Future<void> _hotSwitchToServer({
    required VpnController vpn,
    required Server server,
  }) async {
    if (!mounted || _isActionInFlight) {
      return;
    }

    if (_busyStates.contains(vpn.state)) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Route saved. Reconnect in progress.')),
      );
      return;
    }

    setState(() => _isActionInFlight = true);
    _connectionSupervisor.markReconnectingSecurely();

    try {
      await vpn.stop();
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (!mounted) return;

      await _connectToServer(vpn: vpn, server: server);
      if (!mounted) return;

      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text('Switched to ${server.name}')));
    } catch (error, stackTrace) {
      await _connectionSupervisor.rememberServerFailure(server);
      debugPrint('SPIC hot server switch failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) return;

      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Could not switch server. Try again.')),
      );
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
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Import access link first')),
      );
      _showImportBottomSheet();
      return;
    }

    if (!isConnected && effectiveServers.isEmpty && selected == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            hasServers ? 'Select server first' : 'Add access link first',
          ),
        ),
      );
      return;
    }

    setState(() => _isActionInFlight = true);

    try {
      if (isConnected) {
        _postConnectVerificationGeneration++;
        await vpn.stop();
        _connectionSupervisor.resetForDisconnect();
      } else {
        targetSelection = _connectionSupervisor.selectImmediateServer(
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

        if (_subscriptionForServer(targetServer).isExpired) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(
              content: Text(
                'Subscription expired. Renew SPIC or enter a new access link.',
              ),
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

      ScaffoldMessenger.maybeOf(this.context)?.showSnackBar(
        const SnackBar(content: Text('Could not connect. Try again.')),
      );
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
            label: const Text('Import access link to load servers'),
          ),
        ),
      );
    }

    if (effectiveServers.isEmpty && servers.loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (effectiveServers.isEmpty && servers.error != null) {
      return const Center(child: Text('Could not load servers'));
    }

    if (effectiveServers.isEmpty) {
      return DecoratedBox(
        decoration: _serverListDecoration(scheme),
        child: Center(
          child: OutlinedButton.icon(
            onPressed: _showImportBottomSheet,
            icon: const Icon(Icons.add_link),
            label: const Text('Import access link'),
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
                      leading: _serverLeading(server, flag, scheme),
                      title: Text(
                        _serverDisplayName(server),
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
                          : () async {
                              if (!hasCredentials && isExternal) {
                                ScaffoldMessenger.maybeOf(
                                  context,
                                )?.showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Import this external access link first.',
                                    ),
                                  ),
                                );
                                _showImportBottomSheet();
                                return;
                              }

                              final vpn = VpnScope.vpnControllerOf(
                                context,
                                listen: false,
                              );
                              final wasConnected =
                                  vpn.state == VpnState.connected;
                              setState(() {
                                _selectedServerId = server.id;
                                _selectedServerKey = _serverEndpointKey(server);
                                _selectedProtocol = server.vpnProtocol;
                              });
                              await _connectionSupervisor.setRouteMode(
                                SpicRouteMode.manual,
                              );

                              if (servers.servers.any(
                                (item) => item.id == server.id,
                              )) {
                                servers.pickServer(server.id);
                              }

                              if (wasConnected && mounted) {
                                await _hotSwitchToServer(
                                  vpn: vpn,
                                  server: server,
                                );
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
    final verificationGeneration = ++_postConnectVerificationGeneration;
    final policyServer = _connectionSupervisor.applyPolicy(
      server,
      protocol: _selectedProtocol,
      antiDpiEnabled: _antiDpiEnabled,
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
          ? 'Access rejected. Import a fresh SPIC access link.'
          : 'External route rejected. Import its fresh access link.';
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(rejectionText)));
      return;
    }

    unawaited(
      _runPostConnectVerification(
        generation: verificationGeneration,
        server: server,
        policyServer: policyServer,
        selectedServerKey: selectedServerKey,
      ),
    );
  }

  Future<void> _runPostConnectVerification({
    required int generation,
    required Server server,
    required Server policyServer,
    required String selectedServerKey,
  }) async {
    final routeProbeFuture = _connectionSupervisor.probeServer(
      server,
      rememberFailure: false,
      protocol: policyServer.vpnProtocol,
    );
    final dnsOkFuture = _connectionSupervisor.checkDnsHealth();
    final routeProbe = await routeProbeFuture;
    final dnsOk = await dnsOkFuture;
    if (!mounted) return;

    final vpn = VpnScope.vpnControllerOf(context, listen: false);
    if (generation != _postConnectVerificationGeneration ||
        vpn.state != VpnState.connected ||
        _selectedServerKey != selectedServerKey) {
      return;
    }

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
    if (isCoolingDown) {
      return 'Temporarily cooling down';
    }

    if (isExternal) {
      return hasCredentials
          ? 'External route - lower trust'
          : 'External route - import access link';
    }

    if (hasCredentials) {
      return 'SPIC verified route';
    }

    return 'Import access link to use';
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
        const SnackBar(
          content: Text('Saved. Reconnect VPN manually to apply.'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isActionInFlight = false);
      }
    }
  }

  Future<void> _setAntiDpiEnabled({
    required bool enabled,
    required VpnController vpn,
    required Server? selectedServer,
  }) async {
    final previousValue = _antiDpiEnabled;
    setState(() => _antiDpiEnabled = enabled);

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_antiDpiEnabledPrefsKey, enabled);

      if (vpn.state == VpnState.connected && selectedServer != null) {
        await _restartVpnToApplyConfigChange(
          vpn: vpn,
          selectedServer: selectedServer,
          message: enabled ? 'Anti-DPI enabled' : 'Anti-DPI disabled',
        );
      } else if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(
              enabled
                  ? 'Anti-DPI will apply on next connect'
                  : 'Anti-DPI disabled',
            ),
          ),
        );
      }
    } catch (error, stackTrace) {
      debugPrint('Failed to update Anti-DPI: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) return;

      setState(() => _antiDpiEnabled = previousValue);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Could not update Anti-DPI. Try again.')),
      );
    }
  }

  Future<void> _restartVpnToApplyConfigChange({
    required VpnController vpn,
    required Server selectedServer,
    required String message,
  }) async {
    if (_busyStates.contains(vpn.state)) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Saved. Reconnect VPN to apply.')),
      );
      return;
    }

    setState(() => _isActionInFlight = true);
    _connectionSupervisor.markReconnectingSecurely();

    try {
      await vpn.stop();
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (!mounted) return;

      await _connectToServer(vpn: vpn, server: selectedServer);
      if (!mounted) return;

      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(message)));
    } catch (error, stackTrace) {
      debugPrint('Failed to restart VPN after config change: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) return;

      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('Saved. Reconnect VPN manually to apply.'),
        ),
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
                  'Import access link',
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
                    labelText: 'Access link',
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
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Could not reconnect. Try again.')),
      );
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
                ? 'Apps outside VPN'
                : 'Apps outside VPN ($selectedCount)',
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
