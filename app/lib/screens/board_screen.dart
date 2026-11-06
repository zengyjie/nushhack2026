import 'package:flutter/material.dart';

import '../model/models.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Announcements (cluster-wide) and messages (to a role or a person).
class BoardScreen extends StatefulWidget {
  const BoardScreen({super.key});

  @override
  State<BoardScreen> createState() => _BoardScreenState();
}

class _BoardScreenState extends State<BoardScreen> {
  bool _announcements = true;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final me = store.me!;
    final t = Theme.of(context).textTheme;
    final anns = [...store.announcements]..sort((a, b) {
        if (a.urgent != b.urgent) return a.urgent ? -1 : 1;
        return b.time.compareTo(a.time);
      });
    final inbox = store.inbox.toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      children: [
        SegmentedButton<bool>(
          segments: [
            ButtonSegment(value: true, label: Text('Announcements · ${anns.length}')),
            ButtonSegment(value: false, label: Text('Messages · ${inbox.length}')),
          ],
          selected: {_announcements},
          showSelectedIcon: false,
          onSelectionChanged: (s) => setState(() => _announcements = s.first),
        ),
        const SizedBox(height: 4),
        if (!me.has(Role.admin))
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(children: [
              const Icon(Icons.lock_outline, size: 14, color: Brand.bark),
              const SizedBox(width: 6),
              Expanded(
                child: Text('Only Admin can broadcast. Broadcasts from other roles are rejected.',
                    style: t.bodySmall?.copyWith(color: Brand.bark)),
              ),
            ]),
          ),
        const SizedBox(height: 8),
        if (_announcements) ...[
          if (anns.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(child: Text('No announcements yet', style: t.bodyMedium?.copyWith(color: Brand.bark))),
            ),
          for (final a in anns) ...[_AnnouncementCard(a: a), const SizedBox(height: 10)],
        ]
        else ...[
          if (inbox.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(child: Text('No messages for you', style: t.bodyMedium?.copyWith(color: Brand.bark))),
            ),
          for (final m in inbox) ...[_MessageCard(m: m), const SizedBox(height: 10)],
        ],
      ],
    );
  }
}

class _AnnouncementCard extends StatelessWidget {
  const _AnnouncementCard({required this.a});
  final Announcement a;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Brand.radius),
        side: BorderSide(color: a.urgent ? Brand.ember : Brand.stone, width: a.urgent ? 1.5 : 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            if (a.urgent) ...[
              _Tag('URGENT', bg: Brand.ember, fg: Colors.white),
              const SizedBox(width: 6),
            ],
            if (a.fromHq) ...[
              _Tag('HQ', bg: Brand.soil, fg: Brand.cream, icon: Icons.cloud_outlined),
              const SizedBox(width: 6),
            ],
            const Spacer(),
            Text(timeAgo(a.time), style: t.labelSmall?.copyWith(color: Brand.bark)),
          ]),
          const SizedBox(height: 10),
          Text(a.title, style: t.titleMedium),
          const SizedBox(height: 4),
          Text(a.body, style: t.bodyMedium?.copyWith(height: 1.4)),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: Text(
                a.fromHq ? 'HQ · relayed via uplink' : a.author!.name,
                style: t.labelMedium?.copyWith(color: Brand.bark),
              ),
            ),
            const VerifiedTag(),
            const SizedBox(width: 8),
            ReachIcon(a.reach),
          ]),
        ]),
      ),
    );
  }
}

class _MessageCard extends StatelessWidget {
  const _MessageCard({required this.m});
  final Message m;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            CircleAvatar(
              radius: 14,
              backgroundColor: Brand.soil,
              child: Icon(Role.admin.icon, size: 15, color: Brand.cream),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(m.from.name, style: t.titleSmall)),
            Text(timeAgo(m.time), style: t.labelSmall?.copyWith(color: Brand.bark)),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            const Icon(Icons.subdirectory_arrow_right, size: 15, color: Brand.bark),
            const SizedBox(width: 4),
            Text('To ${m.to.label}', style: t.labelMedium?.copyWith(color: Brand.bark)),
          ]),
          const SizedBox(height: 6),
          Text(m.body, style: t.bodyMedium?.copyWith(height: 1.4)),
          const SizedBox(height: 10),
          Row(children: [const Spacer(), const VerifiedTag(), const SizedBox(width: 8), ReachIcon(m.reach)]),
        ]),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text, {required this.bg, required this.fg, this.icon});
  final String text;
  final Color bg;
  final Color fg;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 12, color: fg), const SizedBox(width: 3)],
          Text(text,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: fg, fontWeight: FontWeight.w800, letterSpacing: 0.8)),
        ]),
      );
}
