import 'package:flutter/material.dart';

import '../model/models.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'patient_detail_screen.dart';

class PatientsScreen extends StatefulWidget {
  const PatientsScreen({super.key});

  @override
  State<PatientsScreen> createState() => _PatientsScreenState();
}

class _PatientsScreenState extends State<PatientsScreen> {
  Priority? _filter;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final t = Theme.of(context).textTheme;
    final list = store.patients
        .where((p) => _filter == null || p.priority == _filter)
        .where((p) => _query.isEmpty ||
            [p.id, p.description, p.name, p.ident].any((s) => s.toLowerCase().contains(_query)))
        .toList()
      ..sort((a, b) {
        if (a.voided != b.voided) return a.voided ? 1 : -1; // overruled records sink to the bottom
        final c = a.priority.index.compareTo(b.priority.index);
        return c != 0 ? c : b.arrival.compareTo(a.arrival);
      });

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      children: [
        Row(children: [
          for (final pr in Priority.values) ...[
            Expanded(child: _CountTile(
              priority: pr,
              count: store.patients.where((p) => p.priority == pr && !p.voided).length,
              selected: _filter == pr,
              onTap: () => setState(() => _filter = _filter == pr ? null : pr),
            )),
            if (pr != Priority.t4) const SizedBox(width: 8),
          ],
        ]),
        const SizedBox(height: 12),
        TextField(
          decoration: const InputDecoration(
            hintText: 'Search by patient ID, name, ID tag or description',
            prefixIcon: Icon(Icons.search),
            isDense: true,
          ),
          onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
        ),
        SectionLabel(
          _filter == null ? 'In care · ${list.length}' : '${_filter!.label} · ${list.length}',
          trailing: _filter == null
              ? null
              : TextButton(onPressed: () => setState(() => _filter = null), child: const Text('Clear')),
        ),
        if (list.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Center(
              child: Text(
                store.patients.isEmpty
                    ? 'No patients yet.\nTriage registers new arrivals; records from nearby phones appear here.'
                    : 'No patients match',
                textAlign: TextAlign.center,
                style: t.bodyMedium?.copyWith(color: Brand.bark),
              ),
            ),
          ),
        for (final p in list) ...[
          _PatientCard(patient: p),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

class _CountTile extends StatelessWidget {
  const _CountTile({required this.priority, required this.count, required this.selected, required this.onTap});
  final Priority priority;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Material(
      color: selected ? priority.color : Brand.paper,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: selected ? priority.color : Brand.stone),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(children: [
            Text('$count', style: t.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: selected ? Colors.white : priority.color,
            )),
            Text(priority.code, style: t.labelMedium?.copyWith(
              color: selected ? Colors.white : Brand.bark,
              fontWeight: FontWeight.w700,
            )),
          ]),
        ),
      ),
    );
  }
}

class _PatientCard extends StatelessWidget {
  const _PatientCard({required this.patient});
  final Patient patient;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final p = patient;
    final latest = p.latest;
    return Opacity(
      opacity: p.voided ? 0.55 : 1,
      child: Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute<void>(builder: (_) => PatientDetailScreen(patientId: p.id)),
        ),
        child: IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(width: 6, color: p.priority.color),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text(p.id, style: t.titleMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                    const SizedBox(width: 8),
                    PriorityChip(p.priority, dense: true),
                    if (p.voided) ...[const SizedBox(width: 6), const AuditChip(voided: true)],
                    const Spacer(),
                    ReachIcon(p.reach),
                  ]),
                  if (p.displayName.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(p.displayName, style: t.labelLarge),
                  ],
                  const SizedBox(height: 6),
                  Text(p.description, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.bodyMedium),
                  const SizedBox(height: 10),
                  _StageStrip(stage: p.stage),
                  const SizedBox(height: 8),
                  Row(children: [
                    Icon(latest.type.icon, size: 14, color: Brand.bark),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        '${latest.type.label} · ${timeAgo(latest.time)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.bodySmall?.copyWith(color: Brand.bark),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Icon(Icons.place_outlined, size: 14, color: Brand.bark),
                    const SizedBox(width: 2),
                    Text(p.location, style: t.bodySmall?.copyWith(color: Brand.bark)),
                  ]),
                ]),
              ),
            ),
          ]),
        ),
      ),
      ),
    );
  }
}

/// Triaged → Observed → Diagnosed → Treated → Follow-up.
class _StageStrip extends StatelessWidget {
  const _StageStrip({required this.stage});
  final int stage;

  @override
  Widget build(BuildContext context) => Row(children: [
        for (var i = 0; i < 5; i++) ...[
          Expanded(
            child: Container(
              height: 4,
              decoration: BoxDecoration(
                color: i <= stage ? Brand.soil : Brand.stone,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          if (i < 4) const SizedBox(width: 3),
        ],
      ]);
}
