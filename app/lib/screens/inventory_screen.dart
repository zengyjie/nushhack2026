import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../model/models.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'forms.dart';

/// Stock taking for this facility, a read-only view of other facilities' stock,
/// and supply requests to HQ with their status.
class InventoryScreen extends StatefulWidget {
  const InventoryScreen({super.key});

  @override
  State<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends State<InventoryScreen> {
  bool _stockTab = true;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final t = Theme.of(context).textTheme;
    final items = store.stock.where((i) => _query.isEmpty || i.name.toLowerCase().contains(_query)).toList();
    final low = store.stock.where((i) => i.low).length;
    final open = store.requests.where((r) => r.status == RequestStatus.pending || r.status == RequestStatus.approved);

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'stock-fab',
        onPressed: () => _stockTab ? showStockTake(context) : showSupplyRequest(context),
        icon: Icon(_stockTab ? Icons.playlist_add_check : Icons.local_shipping_outlined),
        label: Text(_stockTab ? 'Stock take' : 'Request'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        children: [
          Row(children: [
            const Icon(Icons.local_hospital_outlined, size: 18, color: Brand.bark),
            const SizedBox(width: 6),
            Expanded(
              child: Text(store.facility.isEmpty ? 'No facility set (Mesh tab)' : store.facility,
                  style: t.titleMedium, overflow: TextOverflow.ellipsis),
            ),
            if (low > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: Brand.ember, borderRadius: BorderRadius.circular(8)),
                child: Text('$low low', style: t.labelMedium?.copyWith(color: Colors.white)),
              ),
          ]),
          const SizedBox(height: 12),
          SegmentedButton<bool>(
            segments: [
              ButtonSegment(value: true, label: Text('Stock · ${store.stock.length}')),
              ButtonSegment(value: false, label: Text('Requests · ${open.length} open')),
            ],
            selected: {_stockTab},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => _stockTab = s.first),
          ),
          const SizedBox(height: 12),
          if (_stockTab) ...[
            TextField(
              decoration: const InputDecoration(hintText: 'Search items', prefixIcon: Icon(Icons.search), isDense: true),
              onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
            ),
            if (store.stock.isEmpty)
              const _Empty('No stock recorded for this facility yet.\nTap Stock take to count an item.')
            else
              for (final cat in StockCategory.values)
                if (items.any((i) => i.category == cat)) ...[
                  SectionLabel(cat.label),
                  Card(
                    child: Column(children: [
                      for (final (i, it) in items.where((i) => i.category == cat).indexed) ...[
                        if (i > 0) const Divider(indent: 14, endIndent: 14),
                        _StockTile(item: it, onTap: () => showStockActions(context, it)),
                      ],
                    ]),
                  ),
                ],
            if (store.otherStock.isNotEmpty) ...[
              const SectionLabel('Other facilities'),
              Card(
                child: Column(children: [
                  for (final (i, it) in store.otherStock.indexed) ...[
                    if (i > 0) const Divider(indent: 14, endIndent: 14),
                    _StockTile(item: it, showFacility: true),
                  ],
                ]),
              ),
            ],
          ] else ...[
            if (store.requests.isEmpty)
              const _Empty('No supply requests yet.\nRequests go to HQ through any phone with an uplink.')
            else
              for (final r in store.requests) ...[_RequestCard(r: r), const SizedBox(height: 10)],
          ],
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: Text(text,
              textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Brand.bark)),
        ),
      );
}

class _StockTile extends StatelessWidget {
  const _StockTile({required this.item, this.onTap, this.showFacility = false});
  final StockItem item;
  final VoidCallback? onTap;
  final bool showFacility;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final it = item;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(children: [
          Icon(it.category.icon, color: Brand.bark),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(it.name, style: t.titleSmall, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(
                [
                  if (showFacility) it.facility,
                  if (it.min > 0) 'min ${it.min}',
                  if (it.updated != null) '${timeAgo(it.updated!)}${it.by == null ? '' : ' · ${it.by!.name}'}',
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.bodySmall?.copyWith(color: Brand.bark),
              ),
            ]),
          ),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('${it.qty}',
                style: t.titleLarge?.copyWith(
                  color: it.low ? Brand.ember : Brand.soil,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                )),
            Text(it.low ? '${it.unit} · LOW' : it.unit,
                style: t.labelSmall?.copyWith(color: it.low ? Brand.ember : Brand.bark)),
          ]),
          if (onTap != null) ...[const SizedBox(width: 6), ReachIcon(it.reach)],
        ]),
      ),
    );
  }
}

class _RequestCard extends StatelessWidget {
  const _RequestCard({required this.r});
  final SupplyRequest r;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: r.status.color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(8)),
              child: Text(r.status.label,
                  style: t.labelMedium?.copyWith(color: r.status.color, fontWeight: FontWeight.w700)),
            ),
            if (r.urgent) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(color: Brand.ember, borderRadius: BorderRadius.circular(6)),
                child: Text('URGENT', style: t.labelSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
              ),
            ],
            const Spacer(),
            Text(r.rid, style: t.labelSmall?.copyWith(color: Brand.bark)),
          ]),
          const SizedBox(height: 10),
          Text('${r.qty} ${r.unit} ${r.item}'.replaceAll('  ', ' '), style: t.titleMedium),
          if (r.note.isNotEmpty) ...[const SizedBox(height: 4), Text(r.note, style: t.bodyMedium)],
          if (r.hqNote.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: Brand.cream, borderRadius: BorderRadius.circular(10)),
              child: Text('HQ: ${r.hqNote}', style: t.bodySmall),
            ),
          ],
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: Text('${r.facility} · ${r.by.name} · ${timeAgo(r.time)}',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodySmall?.copyWith(color: Brand.bark)),
            ),
            ReachIcon(r.reach),
          ]),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------- sheets

final _digits = [FilteringTextInputFormatter.digitsOnly];

/// Count an item: a new line in the stock list, or a recount of an existing one.
Future<void> showStockTake(BuildContext context, {StockItem? item}) =>
    showFormSheet(context, _StockTakeForm(item: item));

class _StockTakeForm extends StatefulWidget {
  const _StockTakeForm({this.item});
  final StockItem? item;

  @override
  State<_StockTakeForm> createState() => _StockTakeFormState();
}

class _StockTakeFormState extends State<_StockTakeForm> {
  late final _name = TextEditingController(text: widget.item?.name);
  late final _qty = TextEditingController(text: widget.item == null ? '' : '${widget.item!.qty}');
  late final _unit = TextEditingController(text: widget.item?.unit);
  late final _min = TextEditingController(text: widget.item == null || widget.item!.min == 0 ? '' : '${widget.item!.min}');
  late StockCategory _cat = widget.item?.category ?? StockCategory.supply;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final ok = _name.text.trim().isNotEmpty && int.tryParse(_qty.text) != null;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      sheetTitle(context, widget.item == null ? 'Stock take' : 'Recount ${widget.item!.name}',
          'Sets the on-hand count at ${store.facility.isEmpty ? 'this facility' : store.facility}'),
      TextField(
        controller: _name,
        enabled: widget.item == null,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(labelText: 'Item', hintText: 'e.g. Tourniquet, O-neg blood, Ventilator'),
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: 12),
      SegmentedButton<StockCategory>(
        segments: [
          for (final c in StockCategory.values) ButtonSegment(value: c, label: Text(c.label), icon: Icon(c.icon, size: 16)),
        ],
        selected: {_cat},
        showSelectedIcon: false,
        onSelectionChanged: (s) => setState(() => _cat = s.first),
      ),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
          child: TextField(
            controller: _qty,
            keyboardType: TextInputType.number,
            inputFormatters: _digits,
            decoration: const InputDecoration(labelText: 'On hand'),
            onChanged: (_) => setState(() {}),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(child: TextField(controller: _unit, decoration: const InputDecoration(labelText: 'Unit', hintText: 'pcs, units, boxes'))),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: _min,
            keyboardType: TextInputType.number,
            inputFormatters: _digits,
            decoration: const InputDecoration(labelText: 'Minimum', hintText: 'alert at'),
          ),
        ),
      ]),
      const SizedBox(height: 18),
      FilledButton(
        onPressed: !ok
            ? null
            : () => signAndClose(
                  context,
                  'Stock count saved',
                  () => store.countStock(
                    item: _name.text,
                    category: _cat,
                    qty: int.parse(_qty.text),
                    unit: _unit.text,
                    min: int.tryParse(_min.text) ?? 0,
                  ),
                ),
        child: const Text('Sign and save'),
      ),
      signNote(context),
    ]);
  }
}

/// Use, receive, recount or request more of one item.
Future<void> showStockActions(BuildContext context, StockItem item) => showFormSheet(context, _AdjustForm(item: item));

class _AdjustForm extends StatefulWidget {
  const _AdjustForm({required this.item});
  final StockItem item;

  @override
  State<_AdjustForm> createState() => _AdjustFormState();
}

class _AdjustFormState extends State<_AdjustForm> {
  bool _use = true;
  final _amount = TextEditingController(text: '1');
  String? _reason;

  static const _useReasons = ['Used on patient', 'Expired or damaged', 'Sent to another facility'];
  static const _receiveReasons = ['Resupply received', 'Returned unused', 'Found in recount'];

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final t = Theme.of(context).textTheme;
    final it = widget.item;
    final n = int.tryParse(_amount.text) ?? 0;
    final reasons = _use ? _useReasons : _receiveReasons;
    final reason = reasons.contains(_reason) ? _reason! : reasons.first;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      sheetTitle(context, it.name, '${it.qty} ${it.unit} on hand${it.min > 0 ? ' · minimum ${it.min}' : ''}'),
      SegmentedButton<bool>(
        segments: const [
          ButtonSegment(value: true, label: Text('Use'), icon: Icon(Icons.remove)),
          ButtonSegment(value: false, label: Text('Receive'), icon: Icon(Icons.add)),
        ],
        selected: {_use},
        showSelectedIcon: false,
        onSelectionChanged: (s) => setState(() => _use = s.first),
      ),
      const SizedBox(height: 14),
      Row(children: [
        IconButton.outlined(
          onPressed: n > 1 ? () => setState(() => _amount.text = '${n - 1}') : null,
          icon: const Icon(Icons.remove),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: _amount,
            textAlign: TextAlign.center,
            keyboardType: TextInputType.number,
            inputFormatters: _digits,
            style: t.headlineSmall,
            decoration: InputDecoration(suffixText: it.unit),
            onChanged: (_) => setState(() {}),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.outlined(onPressed: () => setState(() => _amount.text = '${n + 1}'), icon: const Icon(Icons.add)),
      ]),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final r in reasons)
          ChoiceChip(label: Text(r), selected: r == reason, onSelected: (_) => setState(() => _reason = r)),
      ]),
      const SizedBox(height: 16),
      FilledButton(
        onPressed: n <= 0
            ? null
            : () => signAndClose(
                  context,
                  '${_use ? 'Used' : 'Received'} $n ${it.unit} ${it.name}',
                  () => store.adjustStock(it, _use ? -n : n, reason),
                ),
        child: Text(_use ? 'Record use of $n' : 'Record receipt of $n'),
      ),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
          child: OutlinedButton(
            onPressed: () {
              Navigator.pop(context);
              showStockTake(context, item: it);
            },
            child: const Text('Recount'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton(
            onPressed: () {
              Navigator.pop(context);
              showSupplyRequest(context, item: it);
            },
            child: const Text('Request more'),
          ),
        ),
      ]),
      signNote(context),
    ]);
  }
}

/// Ask HQ for supplies, equipment or other resources.
Future<void> showSupplyRequest(BuildContext context, {StockItem? item}) =>
    showFormSheet(context, _RequestForm(item: item));

class _RequestForm extends StatefulWidget {
  const _RequestForm({this.item});
  final StockItem? item;

  @override
  State<_RequestForm> createState() => _RequestFormState();
}

class _RequestFormState extends State<_RequestForm> {
  late final _item = TextEditingController(text: widget.item?.name);
  late final _qty = TextEditingController(
      text: widget.item != null && widget.item!.min > 0 ? '${(widget.item!.min * 2 - widget.item!.qty).clamp(1, 9999)}' : '');
  late final _unit = TextEditingController(text: widget.item?.unit);
  final _note = TextEditingController();
  bool _urgent = false;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final ok = _item.text.trim().isNotEmpty && (int.tryParse(_qty.text) ?? 0) > 0;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      sheetTitle(context, 'Request from HQ',
          'Sent through the mesh to HQ from ${store.facility.isEmpty ? 'this facility' : store.facility}'),
      TextField(
        controller: _item,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(labelText: 'Item or resource', hintText: 'e.g. O-neg blood, generator fuel, surgeon'),
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
          child: TextField(
            controller: _qty,
            keyboardType: TextInputType.number,
            inputFormatters: _digits,
            decoration: const InputDecoration(labelText: 'Quantity'),
            onChanged: (_) => setState(() {}),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(child: TextField(controller: _unit, decoration: const InputDecoration(labelText: 'Unit'))),
      ]),
      const SizedBox(height: 12),
      TextField(
        controller: _note,
        minLines: 2,
        maxLines: 4,
        decoration: const InputDecoration(labelText: 'Reason / notes'),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _urgent,
        onChanged: (v) => setState(() => _urgent = v),
        title: const Text('Urgent'),
        subtitle: const Text('Flagged at the top of HQ\'s queue'),
      ),
      const SizedBox(height: 8),
      FilledButton.icon(
        onPressed: !ok
            ? null
            : () => signAndClose(
                  context,
                  'Request signed and on its way to HQ',
                  () => store.requestSupply(
                    item: _item.text,
                    qty: int.parse(_qty.text),
                    unit: _unit.text,
                    urgent: _urgent,
                    note: _note.text,
                  ),
                ),
        icon: const Icon(Icons.send),
        label: const Text('Sign and send'),
      ),
      signNote(context),
    ]);
  }
}
