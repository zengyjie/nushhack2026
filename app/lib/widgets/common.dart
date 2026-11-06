import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_fonts/google_fonts.dart';

import '../model/models.dart';
import '../state/app_state.dart';
import '../theme.dart';

/// Makes the app state available to the tree and rebuilds dependants on change.
class StoreScope extends InheritedNotifier<AppState> {
  const StoreScope({super.key, required AppState store, required super.child}) : super(notifier: store);

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<StoreScope>()!.notifier!;
}

/// "M#SH" wordmark: Raleway Medium Italic with the lattice mark standing in for the E.
class Wordmark extends StatelessWidget {
  const Wordmark({super.key, this.size = 22});
  final double size;

  @override
  Widget build(BuildContext context) {
    final style = GoogleFonts.raleway(
      fontSize: size,
      fontWeight: FontWeight.w500,
      fontStyle: FontStyle.italic,
      color: Brand.soil,
      height: 1,
      letterSpacing: size * 0.02,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text('M', style: style),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: size * 0.02),
          child: SvgPicture.asset('assets/mark.svg', width: size * 1.05, height: size * 1.05),
        ),
        Text('SH', style: style),
      ],
    );
  }
}

/// The lattice mark as a nav icon: brand colours when selected, a flat brown silhouette otherwise.
class MarkIcon extends StatelessWidget {
  const MarkIcon({super.key, required this.selected, this.size = 26});
  final bool selected;
  final double size;

  @override
  Widget build(BuildContext context) => SvgPicture.asset(
        'assets/mark.svg',
        width: size,
        height: size,
        colorFilter: selected ? null : const ColorFilter.mode(Brand.bark, BlendMode.srcIn),
      );
}

class LogoTile extends StatelessWidget {
  const LogoTile({super.key, this.size = 88});
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Brand.cream,
          borderRadius: BorderRadius.circular(size * 0.33),
          border: Border.all(color: Brand.soil, width: 1.5),
        ),
        padding: EdgeInsets.all(size * 0.12),
        child: SvgPicture.asset('assets/mark.svg'),
      );
}

class PriorityChip extends StatelessWidget {
  const PriorityChip(this.priority, {super.key, this.dense = false});
  final Priority priority;
  final bool dense;

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.symmetric(horizontal: dense ? 7 : 10, vertical: dense ? 3 : 5),
        decoration: BoxDecoration(color: priority.color, borderRadius: BorderRadius.circular(8)),
        child: Text(
          dense ? priority.code : '${priority.code} · ${priority.label}',
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
        ),
      );
}

class RoleChip extends StatelessWidget {
  const RoleChip(this.role, {super.key});
  final Role role;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: Brand.cream,
          border: Border.all(color: Brand.stone),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(role.icon, size: 13, color: Brand.bark),
          const SizedBox(width: 4),
          Text(role.short, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Brand.bark)),
        ]),
      );
}

/// All of a user's roles as chips.
class RoleChips extends StatelessWidget {
  const RoleChips(this.user, {super.key});
  final User user;

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [for (final r in user.sortedRoles) RoleChip(r)],
      );
}

/// Where a record has reached: this phone only, the cluster, or HQ.
class ReachIcon extends StatelessWidget {
  const ReachIcon(this.reach, {super.key, this.showLabel = false});
  final Reach reach;
  final bool showLabel;

  static String label(Reach r) => switch (r) {
        Reach.local => 'On this device',
        Reach.cluster => 'Shared in cluster',
        Reach.hq => 'Synced to HQ',
      };

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (reach) {
      Reach.local => (Icons.smartphone, Brand.ember),
      Reach.cluster => (Icons.hub_outlined, Brand.bark),
      Reach.hq => (Icons.cloud_done_outlined, Brand.ok),
    };
    final i = Icon(icon, size: 16, color: color);
    if (!showLabel) return Tooltip(message: label(reach), child: i);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      i,
      const SizedBox(width: 4),
      Text(label(reach), style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color)),
    ]);
  }
}

class VerifiedTag extends StatelessWidget {
  const VerifiedTag({super.key});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: 'Signature and HQ certificate verified on this device',
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.verified_outlined, size: 14, color: Brand.ok),
          const SizedBox(width: 3),
          Text('Signed', style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Brand.ok)),
        ]),
      );
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
        child: Row(children: [
          Text(
            text.toUpperCase(),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: Brand.bark,
                  letterSpacing: 1.1,
                  fontWeight: FontWeight.w700,
                ),
          ),
          const Spacer(),
          ?trailing,
        ]),
      );
}

String timeAgo(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 45) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}

String hhmm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}${t.minute.toString().padLeft(2, '0')}h';

void toast(BuildContext context, String msg) =>
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
