import 'package:flutter/material.dart';
import 'package:trusttunnel/common/extensions/context_extensions.dart';
import 'package:trusttunnel/common/localization/localization.dart';
import 'package:spic_app/feature/home/spic_home_screen.dart';

class SpicApp extends StatelessWidget {
  const SpicApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: context.dependencyFactory.lightThemeData,
      home: const SpicHomeScreen(),
      onGenerateTitle: (context) => 'SPIC VPN Client',
      locale: Localization.defaultLocale,
      localizationsDelegates: Localization.localizationDelegates,
      supportedLocales: Localization.supportedLocales,
    );
  }
}
