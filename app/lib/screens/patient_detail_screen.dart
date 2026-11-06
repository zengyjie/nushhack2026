import 'package:flutter/material.dart';

import '../model/models.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'forms.dart';

class PatientDetailScreen extends StatelessWidget {
  const PatientDetailScreen({super.key, required this.patientId});
  final String patientId;

  static const _stages = ['Triaged', 'Observed', 'Diagnosed', 'Treated', 'Follow-up'];

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final me = store.me!;
    final p = store.patient(patientId);
    if (p == null) return Scaffold(appBar: AppBar(), body: const Center(child: Text('Patient not found')));
    final t = Theme.of(context).textTheme;
    final registered = p.entries.first;

    return Scaffold(
      appBar: AppBar(
        title: Text(p.id),
        bottom: const PreferredSize(preferredSize: Size.fromHeight(1), child: Divider()),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  PriorityChip(p.priority),
                  if (p.voided) ...[const SizedBox(width: 8), const AuditChip(voided: true)],
                  const Spacer(),
                  ReachIcon(p.reach, showLabel: true),
                ]),
                if (p.displayName.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(p.displayName, style: t.titleMedium),
                ],
                const SizedBox(height: 12),
                Text(p.description, style: t.titleMedium?.copyWith(fontWeight: FontWeight.w500, height: 1.35)),
                const SizedBox(height: 14),
                Wrap(spacing: 18, runSpacing: 8, children: [
                  _meta(context, Icons.schedule, 'Arrived ${hhmm(p.arrival)} · ${timeAgo(p.arrival)}'),
                  _meta(context, Icons.local_hospital_outlined, p.facility.isEmpty ? 'Facility not set' : p.facility),
                  _meta(context, Icons.place_outlined, p.location),
                  _meta(context, Icons.person_outline, 'by ${registered.author.name}'),
                ]),
                const SizedBox(height: 16),
                _StageRow(stage: p.stage, labels: _stages),
              ]),
            ),
          ),
          if (p.voided) ...[
            const SizedBox(height: 12),
            _AuditBanner(mark: p.entries.first.audit!, subject: 'This registration'),
          ],
          SectionLabel('Record · ${p.entries.length} signed entries'),
          for (var i = p.entries.length - 1; i >= 0; i--)
            _TimelineEntry(entry: p.entries[i], first: i == p.entries.length - 1, last: i == 0),
        ],
      ),
      bottomNavigationBar: _ActionBar(patient: p, user: me),
    );
  }

  Widget _meta(BuildContext context, IconData icon, String text) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 15, color: Brand.bark),
        const SizedBox(width: 5),
        Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Brand.bark)),
      ]);
}

class _StageRow extends StatelessWidget {
  const _StageRow({required this.stage, required this.labels});
  final int stage;
  final List<String> labels;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (var i = 0; i < labels.length; i++)
        Expanded(
          child: Column(children: [
            Row(children: [
              Expanded(child: Container(height: 2, color: i == 0 ? Colors.transparent : (i <= stage ? Brand.soil : Brand.stone))),
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: i <= stage ? (i == stage ? Brand.ember : Brand.soil) : Brand.paper,
                  shape: BoxShape.circle,
                  border: Border.all(color: i <= stage ? Brand.soil : Brand.stone, width: 2),
                ),
              ),
              Expanded(
                child: Container(
                    height: 2,
                    color: i == labels.length - 1 ? Colors.transparent : (i < stage ? Brand.soil : Brand.stone)),
              ),
            ]),
            const SizedBox(height: 6),
            Text(labels[i],
                style: t.labelSmall?.copyWith(
                  color: i <= stage ? Brand.soil : Brand.bark,
                  fontWeight: i == stage ? FontWeight.w700 : FontWeight.w500,
                )),
          ]),
        ),
    ]);
  }
}

class _TimelineEntry extends StatelessWidget {
  const _TimelineEntry({required this.entry, required this.first, required this.last});
  final Entry entry;
  final bool first;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final e = entry;
    final clinical = e.type.author == Role.clinician;
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          width: 40,
          child: Column(children: [
            Container(width: 2, height: 8, color: first ? Colors.transparent : Brand.stone),
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: clinical ? Brand.soil : Brand.paper,
                shape: BoxShape.circle,
                border: Border.all(color: clinical ? Brand.soil : Brand.stone),
              ),
              child: Icon(e.type.icon, size: 17, color: clinical ? Brand.cream : Brand.bark),
            ),
            Expanded(child: Container(width: 2, color: last ? Colors.transparent : Brand.stone)),
          ]),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12, top: 4),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text(e.type.label, style: t.titleSmall)),
                    Text(hhmm(e.time), style: t.labelSmall?.copyWith(color: Brand.bark)),
                  ]),
                  if (e.audit != null) ...[const SizedBox(height: 6), AuditChip(voided: e.voided)],
                  const SizedBox(height: 6),
                  Text(e.text,
                      style: t.bodyMedium?.copyWith(
                        height: 1.35,
                        decoration: e.voided ? TextDecoration.lineThrough : null,
                        color: e.voided ? Brand.bark : null,
                      )),
                  if (e.audit != null && e.audit!.note.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text('HQ: ${e.audit!.note}', style: t.bodySmall?.copyWith(fontStyle: FontStyle.italic)),
                  ],
                  if (e.fields.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Wrap(spacing: 6, runSpacing: 6, children: [
                      for (final f in e.fields.entries) _Field(k: f.key, v: f.value),
                    ]),
                  ],
                  const SizedBox(height: 10),
                  const Divider(),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(
                      child: Text(e.author.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: t.labelMedium?.copyWith(color: Brand.bark)),
                    ),
                    RoleChip(e.type.author), // the role this entry was signed under
                    const SizedBox(width: 8),
                    const VerifiedTag(),
                    const SizedBox(width: 8),
                    ReachIcon(e.reach),
                  ]),
                ]),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

/// Explains an HQ audit decision that overruled this patient's registration.
class _AuditBanner extends StatelessWidget {
  const _AuditBanner({required this.mark, required this.subject});
  final AuditMark mark;
  final String subject;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Brand.stone.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(Brand.radius)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.gavel, size: 20, color: Brand.soil),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('$subject was overruled by HQ (${mark.kindLabel})', style: t.titleSmall),
            if (mark.note.isNotEmpty) ...[const SizedBox(height: 4), Text(mark.note, style: t.bodyMedium)],
            const SizedBox(height: 4),
            Text('Decided by ${mark.by}', style: t.bodySmall?.copyWith(color: Brand.bark)),
          ]),
        ),
      ]),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.k, required this.v});
  final String k;
  final String v;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(color: Brand.cream, borderRadius: BorderRadius.circular(8)),
      child: Text.rich(TextSpan(children: [
        TextSpan(text: '$k ', style: t.labelSmall?.copyWith(color: Brand.bark)),
        TextSpan(text: v, style: t.labelMedium?.copyWith(fontWeight: FontWeight.w700)),
      ])),
    );
  }
}

/// Role-gated actions, one row per clinical role the user holds.
/// Someone who is only Admin gets read-only access.
class _ActionBar extends StatelessWidget {
  const _ActionBar({required this.patient, required this.user});
  final Patient patient;
  final User user;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final rows = <Widget>[
      if (user.has(Role.triage))
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => showPriorityPicker(context, patient),
              icon: const Icon(Icons.flag_outlined),
              label: const Text('Priority'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 2,
            child: FilledButton.icon(
              onPressed: () => showEntryForm(context, patient, EntryType.observation),
              icon: const Icon(Icons.monitor_heart_outlined),
              label: const Text('Add observation'),
            ),
          ),
        ]),
      if (user.has(Role.clinician))
        Row(children: [
          for (final (type, label) in [
            (EntryType.diagnosis, 'Diagnosis'),
            (EntryType.remediation, 'Remediation'),
            (EntryType.followUp, 'Follow-up'),
          ]) ...[
            Expanded(
              child: _next(patient, type)
                  ? FilledButton(
                      onPressed: () => showEntryForm(context, patient, type),
                      style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 6)),
                      child: Text(label),
                    )
                  : OutlinedButton(
                      onPressed: () => showEntryForm(context, patient, type),
                      style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 6)),
                      child: Text(label),
                    ),
            ),
            if (type != EntryType.followUp) const SizedBox(width: 8),
          ],
        ]),
    ];
    if (rows.isEmpty) {
      rows.add(Row(children: [
        const Icon(Icons.visibility_outlined, size: 18, color: Brand.bark),
        const SizedBox(width: 8),
        Expanded(
          child: Text('Admin has read-only access to clinical records.',
              style: t.bodySmall?.copyWith(color: Brand.bark)),
        ),
      ]));
    }
    return Container(
      decoration: const BoxDecoration(
        color: Brand.paper,
        border: Border(top: BorderSide(color: Brand.stone)),
      ),
      padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + MediaQuery.paddingOf(context).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < rows.length; i++) ...[if (i > 0) const SizedBox(height: 8), rows[i]],
      ]),
    );
  }

  /// Highlights the clinician's next expected step.
  static bool _next(Patient p, EntryType type) => switch (type) {
        EntryType.diagnosis => !p.has(EntryType.diagnosis),
        EntryType.remediation => p.has(EntryType.diagnosis) && !p.has(EntryType.remediation),
        EntryType.followUp => p.has(EntryType.remediation) && !p.has(EntryType.followUp),
        _ => false,
      };
}
