import 'dart:async';

import 'package:flutter/material.dart';
import 'package:trusttunnel/di/model/initialization_helper.dart';
import 'package:trusttunnel/di/widgets/dependency_scope.dart';

import 'feature/app/spic_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await runZonedGuarded<Future<void>>(
    () async {
      final initResult = await InitializationHelperIo().init();

      runApp(
        DependencyScope(
          dependenciesFactory: initResult.dependenciesFactory,
          repositoryFactory: initResult.repositoryFactory,
          child: SpicApp(
            vpnRepository: initResult.repositoryFactory.vpnRepository,
            initialVpnState: initResult.initialVpnState,
          ),
        ),
      );
    },
    (error, stackTrace) {
      // TODO: add logging
      debugPrint('Unhandled error: $error');
      debugPrintStack(stackTrace: stackTrace);
    },
  );
}
