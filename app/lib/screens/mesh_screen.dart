import 'package:flutter/material.dart';

import '../model/models.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Cluster status (LC), the HQ uplink (ON) and verification counts (SEC).
class MeshScreen extends StatelessWidget {
  const MeshScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final mesh = store.mesh;
    final t = Theme.of(context).textTheme;
    final peers = store.peers;
    final inRangeIds = peers.map((p) => p.nodeId).toSet();
    final others = store.knownUsers.where((u) => !inRangeIds.contains(u.deviceId)).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    final running = mesh?.running ?? false;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        // ---------------------------------------------------------------- this node
        Card(
          color: Brand.soil,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Brand.radius)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(running ? Icons.hub : Icons.bluetooth_disabled, color: running ? Brand.ember : Brand.stone),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(running ? 'Mesh node running' : 'Mesh node stopped',
                      style: t.titleMedium?.copyWith(color: Brand.cream)),
                ),
                Text('node ${store.nodeId}', style: t.labelSmall?.copyWith(color: Brand.stone)),
              ]),
              const SizedBox(height: 4),
              Text(
                running
                    ? '${peers.length} in range · ${mesh?.inboundLinks ?? 0} inbound links · ${others.length} more known'
                    : (mesh?.error ?? 'Starting…'),
                style: t.bodySmall?.copyWith(color: running ? Brand.stone : const Color(0xFFFFB59A)),
              ),
              if (!running) ...[
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: store.retryMesh,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry Bluetooth'),
                ),
              ],
              const SizedBox(height: 16),
              Row(children: [
                _Stat(value: '${store.eventsHeld}', label: 'Signed events held', color: Brand.cream),
                _Stat(value: '${store.relayed}', label: 'Relayed', color: Brand.cream),
                _Stat(value: '${store.rejected}', label: 'Rejected', color: Brand.ember),
              ]),
            ]),
          ),
        ),

        // ---------------------------------------------------------------- HQ uplink
        const SectionLabel('HQ sync'),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: store.uplink,
                onChanged: store.setUplink,
                title: Text('Uplink to HQ', style: t.titleSmall),
                subtitle: Text(store.uplink
                    ? 'This phone forwards the cluster\'s records to HQ (mock HQ store on this device).'
                    : 'Turn on when this phone has internet.'),
                secondary: Icon(store.uplink ? Icons.cloud_done : Icons.cloud_off_outlined,
                    color: store.uplink ? Brand.ok : Brand.bark),
              ),
              const Divider(),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(
                        store.pendingHq == 0
                            ? (store.eventsHeld == 0 ? 'Nothing to sync yet' : 'Everything is at HQ')
                            : '${store.pendingHq} records waiting for HQ',
                        style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        store.lastHqSync == null
                            ? 'No HQ acknowledgement received yet'
                            : 'Last HQ ack ${timeAgo(store.lastHqSync!)} via ${store.nameOfDevice(store.lastGateway) ?? 'uplink'}',
                        style: t.bodySmall?.copyWith(color: Brand.bark),
                      ),
                    ]),
                  ),
                  if (store.uplink)
                    FilledButton(
                      onPressed: store.syncing || store.pendingHq == 0 ? null : store.syncNow,
                      child: store.syncing
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Text('Sync now'),
                    ),
                ]),
              ),
            ]),
          ),
        ),

        // ---------------------------------------------------------------- peers
        SectionLabel('In range · ${peers.length}'),
        if (peers.isEmpty)
          _EmptyCard(running
              ? 'No MESH phones in Bluetooth range yet. Open the app on another enrolled phone nearby.'
              : 'Bluetooth mesh is not running.')
        else
          Card(child: Column(children: [for (final p in peers) _PeerTile(peer: p, divider: p != peers.last)])),
        if (others.isNotEmpty) ...[
          SectionLabel('Known in cluster · ${others.length}'),
          Card(
            child: Column(children: [
              for (final u in others)
                ListTile(
                  dense: true,
                  leading: Icon(u.sortedRoles.firstOrNull?.icon ?? Icons.person_outline, color: Brand.bark),
                  title: Text(u.name, style: t.titleSmall),
                  subtitle: Text('${u.rolesLabel} · ${u.deviceId} · reached by hopping or earlier contact'),
                ),
            ]),
          ),
        ],

        // ---------------------------------------------------------------- activity
        const SectionLabel('Activity'),
        if (store.meshLog.isEmpty)
          const _EmptyCard('No activity yet.')
        else
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(children: [
                for (final l in store.meshLog.take(25))
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Icon(l.bad ? Icons.block : Icons.chevron_right,
                            size: 15, color: l.bad ? Brand.t1 : Brand.bark),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(l.text,
                            style: t.bodySmall?.copyWith(color: l.bad ? Brand.t1 : Brand.soil, height: 1.35)),
                      ),
                      const SizedBox(width: 8),
                      Text(hhmm(l.time), style: t.labelSmall?.copyWith(color: Brand.bark)),
                    ]),
                  ),
              ]),
            ),
          ),
      ],
    );
  }
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(text, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Brand.bark)),
        ),
      );
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label, required this.color});
  final String value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Expanded(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(value, style: t.headlineSmall?.copyWith(color: color, fontWeight: FontWeight.w700)),
        Text(label, style: t.labelSmall?.copyWith(color: Brand.stone)),
      ]),
    );
  }
}

class _PeerTile extends StatelessWidget {
  const _PeerTile({required this.peer, required this.divider});
  final PeerView peer;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final p = peer;
    final bars = p.rssi > -60 ? 4 : p.rssi > -70 ? 3 : p.rssi > -80 ? 2 : 1;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(children: [
          _SignalBars(bars: bars),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.user?.name ?? 'Unknown device', style: t.titleSmall, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 3),
              Row(children: [
                if (p.user != null) ...[Flexible(child: RoleChips(p.user!)), const SizedBox(width: 8)],
                Text('${p.nodeId} · ${p.rssi} dBm', style: t.labelSmall?.copyWith(color: Brand.bark)),
              ]),
            ]),
          ),
          _SyncBadge(inSync: p.inSync, busy: p.busy),
        ]),
      ),
      if (divider) const Divider(indent: 14, endIndent: 14),
    ]);
  }
}

class _SyncBadge extends StatelessWidget {
  const _SyncBadge({required this.inSync, required this.busy});
  final bool inSync;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final ok = inSync && !busy;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: ok ? Brand.ok.withValues(alpha: 0.12) : Brand.ember.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (ok)
          const Icon(Icons.check, size: 13, color: Brand.ok)
        else
          const SizedBox(width: 11, height: 11, child: CircularProgressIndicator(strokeWidth: 1.6, color: Brand.ember)),
        const SizedBox(width: 4),
        Text(busy ? 'Sending' : (inSync ? 'In sync' : 'Syncing'),
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: ok ? Brand.ok : Brand.ember, fontWeight: FontWeight.w700)),
      ]),
    );
  }
}

class _SignalBars extends StatelessWidget {
  const _SignalBars({required this.bars});
  final int bars;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 22,
        height: 18,
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          for (var i = 0; i < 4; i++) ...[
            Container(
              width: 4,
              height: 6.0 + i * 4,
              decoration: BoxDecoration(
                color: i < bars ? Brand.soil : Brand.stone,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
            if (i < 3) const SizedBox(width: 2),
          ],
        ]),
      );
}
