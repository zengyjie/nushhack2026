import 'package:flutter/material.dart';

import '../model/models.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'board_screen.dart';
import 'forms.dart';
import 'mesh_screen.dart';
import 'patients_screen.dart';
import 'unlock_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final me = store.me!;

    final fab = switch (_tab) {
      0 when me.has(Role.triage) => FloatingActionButton.extended(
          onPressed: () => showRegisterPatient(context),
          icon: const Icon(Icons.person_add_alt_1),
          label: const Text('Register'),
        ),
      1 when me.has(Role.admin) => FloatingActionButton.extended(
          onPressed: () => showCompose(context),
          icon: const Icon(Icons.campaign_outlined),
          label: const Text('Broadcast'),
        ),
      _ => null,
    };

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: const Wordmark(size: 22),
        actions: [
          _MeshPill(onTap: () => setState(() => _tab = 2)),
          const SizedBox(width: 6),
          const _ProfileButton(),
          const SizedBox(width: 12),
        ],
        bottom: const PreferredSize(preferredSize: Size.fromHeight(1), child: Divider()),
      ),
      body: IndexedStack(
        index: _tab,
        children: const [PatientsScreen(), BoardScreen(), MeshScreen()],
      ),
      floatingActionButton: fab,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          const NavigationDestination(
              icon: Icon(Icons.personal_injury_outlined),
              selectedIcon: Icon(Icons.personal_injury),
              label: 'Patients'),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: store.announcements.any((a) => a.urgent),
              backgroundColor: Brand.ember,
              smallSize: 8,
              child: const Icon(Icons.campaign_outlined),
            ),
            selectedIcon: const Icon(Icons.campaign),
            label: 'Board',
          ),
          const NavigationDestination(
            icon: MarkIcon(selected: false),
            selectedIcon: MarkIcon(selected: true),
            label: 'Mesh',
          ),
        ],
      ),
    );
  }
}

/// Compact network status: peers in range, and whether HQ is reachable.
class _MeshPill extends StatelessWidget {
  const _MeshPill({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final direct = store.peers.length;
    final meshUp = store.mesh?.running ?? false;
    final hq = store.lastHqSync;
    final hqReachable = store.uplink || (hq != null && DateTime.now().difference(hq).inMinutes < 10);
    final t = Theme.of(context).textTheme;
    return Material(
      color: Brand.paper,
      shape: StadiumBorder(side: BorderSide(color: Brand.stone)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(meshUp ? Icons.bluetooth : Icons.bluetooth_disabled,
                size: 16, color: meshUp ? Brand.bark : Brand.t1),
            Text('$direct', style: t.labelMedium),
            const SizedBox(width: 8),
            Icon(hqReachable ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
                size: 16, color: hqReachable ? Brand.ok : Brand.bark),
          ]),
        ),
      ),
    );
  }
}

class _ProfileButton extends StatelessWidget {
  const _ProfileButton();

  @override
  Widget build(BuildContext context) {
    final me = StoreScope.of(context).me!;
    final initials = me.name.split(' ').where((w) => w.isNotEmpty).map((w) => w[0]).take(2).join();
    return InkWell(
      customBorder: const CircleBorder(),
      onTap: () => showModalBottomSheet<void>(context: context, builder: (_) => const _ProfileSheet()),
      child: CircleAvatar(
        radius: 17,
        backgroundColor: Brand.soil,
        child: Text(initials, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Brand.cream)),
      ),
    );
  }
}

class _ProfileSheet extends StatelessWidget {
  const _ProfileSheet();

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final me = store.me!;
    final cert = store.cert!;
    final t = Theme.of(context).textTheme;
    final expired = DateTime.now().isAfter(cert.expiresAt);
    final exp = cert.expiresAt;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(me.name, style: t.titleLarge),
          const SizedBox(height: 6),
          RoleChips(me),
          const SizedBox(height: 6),
          Text('Device ${store.nodeId}', style: t.bodySmall),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(expired ? Icons.gpp_bad_outlined : Icons.workspace_premium_outlined,
                      color: expired ? Brand.t1 : Brand.ok, size: 20),
                  const SizedBox(width: 8),
                  Text(expired ? 'Certificate expired: reset and enrol again' : 'Certificate valid', style: t.titleSmall),
                ]),
                const SizedBox(height: 10),
                _kv(context, 'User ID', me.id),
                _kv(context, 'Device', store.nodeId),
                _kv(context, me.roles.length > 1 ? 'Roles' : 'Role', me.rolesLabel),
                _kv(context, 'Issued by', 'HQ demo key · Ed25519'),
                _kv(context, 'Expires', '${exp.day}/${exp.month} ${hhmm(exp)}'),
              ]),
            ),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () {
              Navigator.pop(context);
              store.lock();
            },
            icon: const Icon(Icons.lock_outline),
            label: const Text('Lock'),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () async {
              final yes = await confirmReset(context);
              if (!yes) return;
              if (context.mounted) Navigator.pop(context);
              await store.reset();
            },
            style: TextButton.styleFrom(foregroundColor: Brand.t1),
            icon: const Icon(Icons.delete_forever_outlined),
            label: const Text('Reset this device'),
          ),
        ]),
      ),
    );
  }

  Widget _kv(BuildContext context, String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(children: [
          SizedBox(width: 90, child: Text(k, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Brand.bark))),
          Expanded(child: Text(v, style: Theme.of(context).textTheme.bodySmall)),
        ]),
      );
}
