import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:trusttunnel/data/model/vpn_protocol.dart';
import 'package:trusttunnel/data/model/vpn_state.dart';

import '../../core/connection/spic_connection_supervisor.dart';

class DiagnosticsScreen extends StatelessWidget {
  const DiagnosticsScreen({
    super.key,
    required this.snapshot,
    required this.vpnState,
    required this.serverName,
    required this.protocol,
    required this.appVersion,
    required this.subscription,
    required this.bypassedAppsCount,
    required this.smartBypassEnabled,
    required this.importedProfile,
    required this.recentLogs,
  });

  final SpicDiagnosticsSnapshot snapshot;
  final VpnState vpnState;
  final String serverName;
  final VpnProtocol protocol;
  final String appVersion;
  final String subscription;
  final int bypassedAppsCount;
  final bool smartBypassEnabled;
  final bool importedProfile;
  final List<String> recentLogs;

  @override
  Widget build(BuildContext context) {
    final report = snapshot.toReport(
      vpnState: vpnState,
      serverName: serverName,
      protocol: protocol,
      appVersion: appVersion,
      subscription: subscription,
      bypassedAppsCount: bypassedAppsCount,
      smartBypassEnabled: smartBypassEnabled,
      importedProfile: importedProfile,
      recentLogs: recentLogs,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostics'),
        actions: [
          IconButton(
            tooltip: 'Copy diagnostics',
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: report));
              if (!context.mounted) return;
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                const SnackBar(content: Text('Diagnostics copied')),
              );
            },
            icon: const Icon(Icons.copy_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            _DiagnosticsSection(
              title: 'Connection',
              children: [
                _DiagnosticsRow(
                  label: 'VPN status',
                  value: _vpnStateLabel(vpnState),
                ),
                _DiagnosticsRow(label: 'Server', value: serverName),
                _DiagnosticsRow(label: 'Mode', value: snapshot.routeMode.name),
                _DiagnosticsRow(
                  label: 'Protocol',
                  value: SpicConnectionSupervisor.protocolLabel(protocol),
                ),
                _DiagnosticsRow(
                  label: 'Route trust',
                  value: snapshot.routeTrusted
                      ? 'SPIC verified'
                      : 'External unverified',
                ),
                _DiagnosticsRow(label: 'Policy', value: snapshot.policySummary),
                _DiagnosticsRow(
                  label: 'Route status',
                  value: snapshot.routeStatusMessage ?? 'None',
                ),
              ],
            ),
            const SizedBox(height: 12),
            _DiagnosticsSection(
              title: 'Protection',
              children: [
                _DiagnosticsRow(
                  label: 'Protection',
                  value: snapshot.protectionMessage,
                ),
                _DiagnosticsRow(
                  label: 'Route verified',
                  value: _yesNo(snapshot.routeHealthy),
                ),
                _DiagnosticsRow(
                  label: 'DNS protected',
                  value: _yesNo(snapshot.dnsHealthy),
                ),
                _DiagnosticsRow(
                  label: 'Fallback ready',
                  value: _yesNo(snapshot.fallbackPrepared),
                ),
                _DiagnosticsRow(
                  label: 'Latency',
                  value: snapshot.lastRouteLatency == null
                      ? 'Not measured'
                      : '${snapshot.lastRouteLatency!.inMilliseconds} ms',
                ),
                _DiagnosticsRow(
                  label: 'Last check',
                  value: snapshot.lastHealthCheckedAt == null
                      ? 'Never'
                      : snapshot.lastHealthCheckedAt!.toLocal().toString(),
                ),
                _DiagnosticsRow(
                  label: 'Failure streak',
                  value: '${snapshot.healthFailureStreak}',
                ),
                _DiagnosticsRow(
                  label: 'Cooling routes',
                  value: '${snapshot.coolingDownRoutes.length}',
                ),
              ],
            ),
            const SizedBox(height: 12),
            _DiagnosticsSection(
              title: 'App',
              children: [
                _DiagnosticsRow(label: 'Version', value: appVersion),
                _DiagnosticsRow(
                  label: 'Imported access',
                  value: _yesNo(importedProfile),
                ),
                _DiagnosticsRow(label: 'Subscription', value: subscription),
                _DiagnosticsRow(
                  label: 'Bypassed apps',
                  value: '$bypassedAppsCount',
                ),
                _DiagnosticsRow(
                  label: 'Smart exclusions',
                  value: smartBypassEnabled ? 'On' : 'Off',
                ),
              ],
            ),
            if (recentLogs.isNotEmpty) ...[
              const SizedBox(height: 12),
              _DiagnosticsSection(
                title: 'Recent VPN Events',
                children: recentLogs
                    .map(
                      (log) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: SelectableText(
                          log,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    )
                    .toList(growable: false),
              ),
            ],
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: report));
                if (!context.mounted) return;
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                  const SnackBar(content: Text('Diagnostics copied')),
                );
              },
              icon: const Icon(Icons.content_copy),
              label: const Text('Copy diagnostics'),
            ),
          ],
        ),
      ),
    );
  }

  String _vpnStateLabel(VpnState state) => switch (state) {
    VpnState.connected => 'Connected',
    VpnState.connecting => 'Connecting',
    VpnState.disconnected => 'Disconnected',
    VpnState.waitingForRecovery => 'Waiting for recovery',
    VpnState.recovering => 'Recovering',
    VpnState.waitingForNetwork => 'Waiting for network',
  };

  String _yesNo(bool value) => value ? 'Yes' : 'No';
}

class _DiagnosticsSection extends StatelessWidget {
  const _DiagnosticsSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _DiagnosticsRow extends StatelessWidget {
  const _DiagnosticsRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 128,
            child: Text(
              label,
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
