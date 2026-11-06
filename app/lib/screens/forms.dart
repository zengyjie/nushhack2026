import 'package:flutter/material.dart';

import '../model/models.dart';
import '../theme.dart';
import '../widgets/common.dart';

Future<void> _sheet(BuildContext context, Widget child) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SafeArea(child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(20, 0, 20, 20), child: child)),
      ),
    );

Widget _title(BuildContext context, String title, String sub) => Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 2),
        Text(sub, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Brand.bark)),
      ]),
    );

Widget _signNote(BuildContext context) => Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(children: [
        const Icon(Icons.draw_outlined, size: 15, color: Brand.bark),
        const SizedBox(width: 6),
        Expanded(
          child: Text('Signed with your key, saved on this device, then shared over the mesh.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Brand.bark)),
        ),
      ]),
    );

/// Closes the sheet, signs and stores the event, then reports the outcome.
void _sign(BuildContext context, String done, Future<Object?> Function() action) {
  final messenger = ScaffoldMessenger.of(context);
  Navigator.pop(context);
  action().then(
    (_) => messenger.showSnackBar(SnackBar(content: Text(done))),
    onError: (Object e) => messenger.showSnackBar(SnackBar(content: Text('Not saved: $e'))),
  );
}

// ------------------------------------------------------------------ register patient (triage)

Future<void> showRegisterPatient(BuildContext context) => _sheet(context, const _RegisterForm());

class _RegisterForm extends StatefulWidget {
  const _RegisterForm();

  @override
  State<_RegisterForm> createState() => _RegisterFormState();
}

class _RegisterFormState extends State<_RegisterForm> {
  final _desc = TextEditingController();
  Priority _priority = Priority.t2;
  String _location = 'Tent 1 · Bay A';

  static const _locations = ['Tent 1 · Bay A', 'Tent 1 · Bay B', 'Tent 2 · Bay A', 'Tent 2 · Bay C', 'Holding'];

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final nextId = store.nextPatientId;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _title(context, 'Register patient', '$nextId · arrival ${hhmm(DateTime.now())}'),
      const SectionLabel('Triage priority'),
      Row(children: [
        for (final pr in Priority.values) ...[
          Expanded(child: _PriorityButton(pr: pr, selected: _priority == pr, onTap: () => setState(() => _priority = pr))),
          if (pr != Priority.t4) const SizedBox(width: 6),
        ],
      ]),
      const SizedBox(height: 16),
      TextField(
        controller: _desc,
        minLines: 3,
        maxLines: 5,
        decoration: const InputDecoration(labelText: 'Description', hintText: 'Mechanism of injury, presentation'),
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        initialValue: _location,
        decoration: const InputDecoration(labelText: 'Location', prefixIcon: Icon(Icons.place_outlined)),
        items: [for (final l in _locations) DropdownMenuItem(value: l, child: Text(l))],
        onChanged: (v) => setState(() => _location = v ?? _location),
      ),
      const SizedBox(height: 18),
      FilledButton(
        onPressed: _desc.text.trim().isEmpty
            ? null
            : () {
                _sign(context, 'Patient $nextId registered and signed',
                    () => store.registerPatient(description: _desc.text.trim(), priority: _priority, location: _location));
              },
        child: const Text('Register'),
      ),
      _signNote(context),
    ]);
  }
}

class _PriorityButton extends StatelessWidget {
  const _PriorityButton({required this.pr, required this.selected, required this.onTap});
  final Priority pr;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Material(
      color: selected ? pr.color : Brand.paper,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: selected ? pr.color : Brand.stone, width: 1.5),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(children: [
            Text(pr.code, style: t.titleMedium?.copyWith(color: selected ? Colors.white : pr.color)),
            Text(pr.label, style: t.labelSmall?.copyWith(color: selected ? Colors.white : Brand.bark)),
          ]),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ change priority (triage)

Future<void> showPriorityPicker(BuildContext context, Patient p) => _sheet(
      context,
      Builder(builder: (context) {
        final store = StoreScope.of(context);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _title(context, 'Change priority', '${p.id} · currently ${p.priority.code} ${p.priority.label}'),
          for (final pr in Priority.values) ...[
            _PriorityButton(
              pr: pr,
              selected: p.priority == pr,
              onTap: () {
                if (pr == p.priority) return Navigator.pop(context);
                _sign(context, 'Priority set to ${pr.code} ${pr.label}', () => store.setPriority(p, pr));
              },
            ),
            const SizedBox(height: 8),
          ],
        ]);
      }),
    );

// ------------------------------------------------------------------ clinical entries

Future<void> showEntryForm(BuildContext context, Patient p, EntryType type) =>
    _sheet(context, _EntryForm(patient: p, type: type));

class _EntryForm extends StatefulWidget {
  const _EntryForm({required this.patient, required this.type});
  final Patient patient;
  final EntryType type;

  @override
  State<_EntryForm> createState() => _EntryFormState();
}

class _EntryFormState extends State<_EntryForm> {
  final _text = TextEditingController();
  final Map<String, TextEditingController> _fields = {};
  String _disposition = 'Hold and observe';

  List<(String, String)> get _fieldSpec => switch (widget.type) {
        EntryType.observation => [('HR', 'bpm'), ('BP', 'mmHg'), ('SpO₂', '%'), ('RR', '/min'), ('GCS', '3–15')],
        EntryType.remediation => [('Procedure', ''), ('Meds', 'drug, dose, route')],
        EntryType.followUp => [('Review in', 'e.g. 4 h')],
        _ => [],
      };

  (String, String) get _copy => switch (widget.type) {
        EntryType.observation => ('Clinical note', 'Findings, interventions at triage'),
        EntryType.diagnosis => ('Diagnosis', 'Working diagnosis and reasoning'),
        EntryType.remediation => ('Notes', 'What was done and how the patient responded'),
        EntryType.followUp => ('Recommendation', 'Next steps, monitoring, evacuation'),
        _ => ('Note', ''),
      };

  static const _dispositions = ['Hold and observe', 'Return to duty', 'Evacuate · Echelon 4', 'Surgery queue'];

  @override
  void initState() {
    super.initState();
    for (final (k, _) in _fieldSpec) {
      _fields[k] = TextEditingController();
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final (label, hint) = _copy;
    final numeric = widget.type == EntryType.observation;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _title(context, widget.type.label, '${widget.patient.id} · ${widget.patient.priority.code} · ${widget.patient.location}'),
      if (numeric)
        LayoutBuilder(builder: (context, c) => Wrap(spacing: 8, runSpacing: 8, children: [
          for (final (k, unit) in _fieldSpec)
            SizedBox(
              width: (c.maxWidth - 16) / 3,
              child: TextField(
                controller: _fields[k],
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: k, helperText: unit, isDense: true),
              ),
            ),
        ]))
      else
        for (final (k, h) in _fieldSpec) ...[
          TextField(controller: _fields[k], decoration: InputDecoration(labelText: k, hintText: h)),
          const SizedBox(height: 12),
        ],
      if (widget.type == EntryType.followUp) ...[
        DropdownButtonFormField<String>(
          initialValue: _disposition,
          decoration: const InputDecoration(labelText: 'Disposition'),
          items: [for (final d in _dispositions) DropdownMenuItem(value: d, child: Text(d))],
          onChanged: (v) => setState(() => _disposition = v ?? _disposition),
        ),
        const SizedBox(height: 12),
      ],
      if (numeric) const SizedBox(height: 12),
      TextField(
        controller: _text,
        minLines: 3,
        maxLines: 6,
        decoration: InputDecoration(labelText: label, hintText: hint),
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: 18),
      FilledButton(
        onPressed: _text.text.trim().isEmpty
            ? null
            : () {
                final fields = <String, String>{
                  if (widget.type == EntryType.followUp) 'Disposition': _disposition,
                  for (final e in _fields.entries)
                    if (e.value.text.trim().isNotEmpty) e.key: e.value.text.trim(),
                };
                _sign(context, '${widget.type.label} recorded for ${widget.patient.id}',
                    () => store.addEntry(widget.patient, widget.type, _text.text.trim(), fields));
              },
        child: const Text('Sign and save'),
      ),
      _signNote(context),
    ]);
  }
}

// ------------------------------------------------------------------ admin broadcast

Future<void> showCompose(BuildContext context) => _sheet(context, const _ComposeForm());

class _ComposeForm extends StatefulWidget {
  const _ComposeForm();

  @override
  State<_ComposeForm> createState() => _ComposeFormState();
}

class _ComposeFormState extends State<_ComposeForm> {
  bool _announcement = true;
  bool _urgent = false;
  final _titleCtl = TextEditingController();
  final _body = TextEditingController();
  int _audience = 0; // 0 everyone, 1 triage, 2 dx&tx, 3+ person

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final people = store.knownUsers.toList()..sort((a, b) => a.name.compareTo(b.name));
    final audiences = <Audience>[
      const Audience.all(),
      const Audience.role(Role.triage),
      const Audience.role(Role.clinician),
      for (final u in people) Audience.user(u),
    ];
    final ok = _body.text.trim().isNotEmpty && (!_announcement || _titleCtl.text.trim().isNotEmpty);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _title(context, 'Broadcast', 'Floods to every device in the cluster, then to HQ via any uplink'),
      SegmentedButton<bool>(
        segments: const [
          ButtonSegment(value: true, label: Text('Announcement'), icon: Icon(Icons.campaign_outlined)),
          ButtonSegment(value: false, label: Text('Message'), icon: Icon(Icons.forum_outlined)),
        ],
        selected: {_announcement},
        showSelectedIcon: false,
        onSelectionChanged: (s) => setState(() => _announcement = s.first),
      ),
      const SizedBox(height: 16),
      if (_announcement) ...[
        TextField(
          controller: _titleCtl,
          decoration: const InputDecoration(labelText: 'Title'),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
      ] else ...[
        DropdownButtonFormField<int>(
          initialValue: _audience,
          decoration: const InputDecoration(labelText: 'To', prefixIcon: Icon(Icons.group_outlined)),
          items: [
            for (var i = 0; i < audiences.length; i++)
              DropdownMenuItem(value: i, child: Text(i >= 3 ? audiences[i].label : 'All ${audiences[i].label.toLowerCase()}')),
          ],
          onChanged: (v) => setState(() => _audience = v ?? 0),
        ),
        const SizedBox(height: 12),
      ],
      TextField(
        controller: _body,
        minLines: 3,
        maxLines: 6,
        decoration: const InputDecoration(labelText: 'Message'),
        onChanged: (_) => setState(() {}),
      ),
      if (_announcement)
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _urgent,
          onChanged: (v) => setState(() => _urgent = v),
          title: const Text('Mark as urgent'),
          subtitle: const Text('Pinned and highlighted on every device'),
        ),
      const SizedBox(height: 12),
      FilledButton.icon(
        onPressed: !ok
            ? null
            : () {
                _sign(
                  context,
                  _announcement ? 'Announcement broadcast to cluster' : 'Message sent',
                  () => _announcement
                      ? store.postAnnouncement(_titleCtl.text.trim(), _body.text.trim(), _urgent)
                      : store.sendMessage(audiences[_audience], _body.text.trim()),
                );
              },
        icon: const Icon(Icons.send),
        label: const Text('Sign and broadcast'),
      ),
      _signNote(context),
    ]);
  }

}
