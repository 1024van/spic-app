import 'package:flutter/material.dart';
import 'package:trusttunnel/feature/vpn/models/vpn_controller.dart';
import 'package:trusttunnel/feature/vpn/widgets/vpn_scope.dart';
import 'package:trusttunnel/feature/server/servers/widget/scope/servers_scope.dart';
import 'package:trusttunnel/feature/server/servers/widget/scope/servers_scope_controller.dart';

class SpicHomeScreen extends StatelessWidget {
  const SpicHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final vpn = VpnScope.vpnControllerOf(context);
    final servers = ServersScope.controllerOf(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('SPIC VPN'),
      ),
      body: Column(
        children: [
          const SizedBox(height: 16),
          Text('VPN state: ${vpn.state}'),
          const SizedBox(height: 16),
          Expanded(
            child: ListView.builder(
              itemCount: servers.servers.length,
              itemBuilder: (context, index) {
                final server = servers.servers[index];
                final selected =
                    servers.selectedServer?.id == server.id;
                return ListTile(
                  title: Text(server.name),
                  subtitle: Text(server.location ?? ''),
                  selected: selected,
                  onTap: () => servers.pickServer(server.id),
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton(
                onPressed: () async {
                  final server = servers.selectedServer;
                  if (server == null) return;

                  // TODO: получить реальный routingProfile и excludedRoutes из RoutingScope/ExcludedRoutesScope
                  // Пока можно заглушку, если есть дефолтный профиль:
                  // final routingProfile = ...;

                  // await vpn.start(
                  //   server: server,
                  //   routingProfile: routingProfile,
                  //   excludedRoutes: const [],
                  // );
                },
                child: const Text('Connect'),
              ),
              const SizedBox(width: 16),
              ElevatedButton(
                onPressed: () => vpn.stop(),
                child: const Text('Disconnect'),
              ),
            ],
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
