import 'package:flutter/material.dart';
import 'package:trusttunnel/common/extensions/context_extensions.dart';
import 'package:trusttunnel/common/localization/localization.dart';
import 'package:trusttunnel/data/model/vpn_state.dart';
import 'package:trusttunnel/data/repository/vpn_repository.dart';
import 'package:trusttunnel/feature/server/servers/widget/scope/servers_scope.dart';
import 'package:trusttunnel/feature/vpn/widgets/vpn_scope.dart';

import '../../home_screen.dart';

class SpicApp extends StatelessWidget {
  const SpicApp({
    super.key,
    required this.vpnRepository,
    required this.initialVpnState,
  });

  final VpnRepository vpnRepository;
  final VpnState initialVpnState;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: context.dependencyFactory.lightThemeData,
      onGenerateTitle: (context) => 'SPIC VPN Client',
      locale: Localization.defaultLocale,
      localizationsDelegates: Localization.localizationDelegates,
      supportedLocales: Localization.supportedLocales,
      home: ServersScope(
        child: VpnScope(
          vpnRepository: vpnRepository,
          initialState: initialVpnState,
          child: const HomeScreen(),
        ),
      ),
    );
  }
}
