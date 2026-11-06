import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/hq_client.dart';
import '../core/identity.dart';
import '../core/ledger.dart';
import '../core/mesh.dart';
import '../core/records.dart';
import '../core/settings.dart';
import '../model/models.dart';

enum Phase { loading, enrol, locked, ready }

/// App-wide state: identity (SEC), the local signed log (OFF), the BLE mesh (LC)
/// and the HQ uplink (ON). Screens read the projections built here.
class AppState extends ChangeNotifier {
  AppState() {
    _boot();
  }

  Phase phase = Phase.loading;
  Identity? _id;
  Ledger? _ledger;
  MeshService? mesh;
  Settings settings = Settings();

  /// Name on the stored certificate, shown on the lock screen.
  String? lockedName;

  User? get me => _id?.cert.user;
  Certificate? get cert => _id?.cert;
  String get nodeId => _id?.cert.dev ?? '--------';
  String get facility => settings.facility;

  final List<MeshLog> meshLog = [];

  // ------------------------------------------------------------------ lifecycle

  Future<void> _boot() async {
    if (await Identity.exists()) {
      lockedName = (await Identity.storedCertificate())?.name;
      phase = Phase.locked;
    } else {
      phase = Phase.enrol;
    }
    notifyListeners();
  }

  Future<void> enrol(String name, Set<Role> roles, String pin, String facility) async {
    _id = await Identity.enrol(name: name, roles: roles, pin: pin);
    await _open();
    await settings.setFacility(facility);
    _log('certificate issued: ${_id!.cert.user.rolesLabel}, signed by HQ demo key');
  }

  /// Returns false on a wrong PIN.
  Future<bool> unlock(String pin) async {
    final id = await Identity.unlock(pin);
    if (id == null) return false;
    _id = id;
    await _open();
    return true;
  }

  Future<void> _open() async {
    settings = await Settings.load();
    _ledger = await Ledger.open();
    await _ledger!.saveCert(_id!.cert);
    _rebuild();
    phase = Phase.ready;
    notifyListeners();
    mesh = MeshService(
      ledger: _ledger!,
      me: _id!.cert,
      onChanged: _changed,
      onLog: (m, {bad = false}) => _log(m, bad: bad),
      onAccepted: (_) => _dirty = true,
    );
    await mesh!.start();
  }

  Future<void> lock() async {
    await setUplink(false);
    await mesh?.stop();
    mesh = null;
    await _ledger?.close();
    _ledger = null;
    lockedName = _id?.cert.name;
    _id = null;
    phase = Phase.locked;
    notifyListeners();
  }

  /// Wipes the key, certificate, settings and every local record on this phone.
  Future<void> reset() async {
    await lock();
    await Identity.wipe(); // also clears settings (same secure store)
    await Ledger.deleteAll();
    settings = Settings();
    meshLog.clear();
    lockedName = null;
    _clearProjections();
    phase = Phase.enrol;
    notifyListeners();
  }

  Future<void> retryMesh() async {
    await mesh?.stop();
    await mesh?.start();
  }

  Future<void> setFacility(String name) async {
    await settings.setFacility(name);
    _dirty = true; // stock is grouped by facility
    _changed();
  }

  // ------------------------------------------------------------------ writes

  /// Signs, stores and floods one event from this device.
  Future<SignedEvent> _write(String type, Map<String, dynamic> data) async {
    final id = _id!;
    final ledger = _ledger!;
    if (!id.cert.permits(type)) {
      throw StateError('${id.cert.user.rolesLabel} cannot sign $type');
    }
    final head = ledger.head(id.cert.dev);
    final e = await SignedEvent.create(
      key: id.key,
      uid: id.cert.uid,
      dev: id.cert.dev,
      seq: (head?.seq ?? 0) + 1,
      prev: head?.id ?? '',
      type: type,
      data: data,
    );
    final r = await ledger.appendOwn(e, id.cert);
    if (r.verdict != Verdict.accepted) throw StateError('could not store event: ${r.reason}');
    _log('signed $type (seq ${e.seq})');
    mesh?.broadcast(e);
    _dirty = true;
    _changed();
    return e;
  }

  String _nextId(String prefix, String type) {
    final mine = _ledger?.events.where((e) => e.dev == nodeId && e.type == type).length ?? 0;
    return '$prefix-${nodeId.substring(0, 4).toUpperCase()}-${(mine + 1).toString().padLeft(2, '0')}';
  }

  String get nextPatientId => _nextId('P', EventTypes.patientRegistered);

  Future<String> registerPatient({
    required String description,
    required Priority priority,
    required String location,
    String name = '',
    String ident = '',
  }) async {
    final pid = nextPatientId;
    await _write(EventTypes.patientRegistered, {
      'pid': pid,
      'desc': description,
      'priority': priority.name,
      'loc': location,
      'fac': facility,
      'name': name.trim(),
      'ident': ident.trim(),
    });
    return pid;
  }

  Future<void> setPriority(Patient p, Priority to) =>
      _write(EventTypes.priorityChanged, {'pid': p.id, 'from': p.priority.name, 'to': to.name, 'fac': facility});

  Future<void> addEntry(Patient p, EntryType type, String text, Map<String, String> fields) {
    final t = switch (type) {
      EntryType.observation => EventTypes.observationAdded,
      EntryType.diagnosis => EventTypes.diagnosisRecorded,
      EntryType.remediation => EventTypes.remediationRecorded,
      EntryType.followUp => EventTypes.followUpRecommended,
      _ => throw ArgumentError(type),
    };
    return _write(t, {'pid': p.id, 'text': text, 'fields': fields, 'fac': facility});
  }

  Future<void> postAnnouncement(String title, String body, bool urgent) =>
      _write(EventTypes.announcementPosted, {'title': title, 'body': body, 'urgent': urgent});

  Future<void> sendMessage(Audience to, String body) => _write(EventTypes.messageSent, {
        'to': to.user != null
            ? {'uid': to.user!.id}
            : to.role != null
                ? {'role': to.role!.name}
                : {'all': true},
        'body': body,
      });

  // ------------------------------------------------------------------ inventory

  /// Stock take: sets the on-hand count of an item at this facility.
  Future<void> countStock({
    required String item,
    required StockCategory category,
    required int qty,
    required String unit,
    required int min,
  }) =>
      _write(EventTypes.stockCounted, {
        'item': item.trim(),
        'category': category.name,
        'qty': qty,
        'unit': unit.trim(),
        'min': min,
        'fac': facility,
      });

  /// Use or receipt of stock, recorded as a change so offline edits from several phones add up.
  Future<void> adjustStock(StockItem it, int delta, String reason) =>
      _write(EventTypes.stockAdjusted, {'item': it.name, 'delta': delta, 'reason': reason, 'fac': facility});

  Future<String> requestSupply({
    required String item,
    required int qty,
    required String unit,
    required bool urgent,
    required String note,
  }) async {
    final rid = _nextId('R', EventTypes.supplyRequested);
    await _write(EventTypes.supplyRequested, {
      'rid': rid,
      'item': item.trim(),
      'qty': qty,
      'unit': unit.trim(),
      'urgency': urgent ? 'urgent' : 'routine',
      'note': note.trim(),
      'fac': facility,
    });
    return rid;
  }

  // ------------------------------------------------------------------ ON: HQ uplink

  bool uplink = false;
  bool syncing = false;
  String? hqError;
  DateTime? lastHqContact;
  Timer? _hqDebounce;
  Timer? _hqPoll;
  final Set<String> _hqRejected = {};

  Future<void> setHqUrl(String url) async {
    await settings.setHqUrl(url);
    hqError = null;
    notifyListeners();
    if (uplink) await syncNow();
  }

  Future<void> setUplink(bool on) async {
    if (uplink == on) return;
    uplink = on;
    _hqPoll?.cancel();
    if (on) {
      _log('uplink on: this phone relays the cluster to HQ');
      // Poll even with nothing to send, to pull broadcasts and audit decisions.
      _hqPoll = Timer.periodic(const Duration(seconds: 15), (_) => syncNow());
      notifyListeners();
      await syncNow();
    } else {
      _log('uplink off');
      notifyListeners();
    }
  }

  /// Sends every event HQ hasn't acknowledged, then floods HQ's signed acknowledgement
  /// and any HQ-signed downlink events (broadcasts, audit decisions, request updates)
  /// over the mesh so phones without internet get them too.
  Future<void> syncNow() async {
    final ledger = _ledger;
    final id = _id;
    if (ledger == null || id == null || syncing || !uplink) return;
    if (settings.hqUrl.isEmpty) {
      hqError = 'Set the HQ server address below.';
      notifyListeners();
      return;
    }
    syncing = true;
    notifyListeners();
    try {
      final todo = ledger.chainOrdered
          .where((e) => !e.fromHq && !_acked.contains(e.id) && !_hqRejected.contains(e.id))
          .toList();
      final r = await HqClient.sync(
        baseUrl: settings.hqUrl,
        cert: id.cert,
        key: id.key,
        events: todo,
        certs: ledger.certs.values,
        cursor: settings.cursor,
        facility: facility,
      );
      var applied = 0;
      for (final e in [?r.ack, ...r.down]) {
        final v = await ledger.receive(e, const {});
        if (v.verdict == Verdict.accepted) {
          applied++;
          mesh?.broadcast(e);
        } else if (v.verdict == Verdict.rejected) {
          _log('HQ event rejected: ${v.reason}', bad: true);
        }
      }
      await settings.setCursor(r.cursor);
      r.rejected.forEach((eid, reason) {
        _hqRejected.add(eid);
        _log('HQ rejected an event: $reason', bad: true);
      });
      final sent = todo.length.clamp(0, HqClient.batch);
      if (sent > 0 || r.down.isNotEmpty) {
        _log('HQ sync: sent $sent, ${r.down.length} from HQ'
            '${r.pending > 0 ? ', ${r.pending} waiting at HQ' : ''}');
      }
      if (applied > 0) _dirty = true;
      hqError = null;
      lastHqContact = DateTime.now();
    } catch (e) {
      hqError = e is TimeoutException ? 'HQ did not answer in time.' : e.toString();
      _log('HQ sync failed: $hqError', bad: true);
    } finally {
      syncing = false;
      _changed();
    }
  }

  // ------------------------------------------------------------------ projections

  bool _dirty = true;
  List<Patient> patients = [];
  List<Announcement> announcements = [];
  List<Message> messages = [];
  List<StockItem> stock = []; // this facility
  List<StockItem> otherStock = []; // other facilities, as seen over the mesh
  List<SupplyRequest> requests = [];
  Set<String> _acked = {};
  DateTime? lastHqSync;
  String? lastGateway;

  int get eventsHeld => _ledger?.events.length ?? 0;
  int get relayed => mesh?.relayed ?? 0;
  int get rejected => mesh?.rejected ?? 0;

  int get pendingHq => _ledger?.events.where((e) => !e.fromHq && !_acked.contains(e.id)).length ?? 0;

  List<User> get knownUsers =>
      _ledger?.certs.values.map((c) => c.user).where((u) => u.id != me?.id).toList() ?? const [];

  Iterable<Message> get inbox {
    final u = me;
    if (u == null) return const [];
    return messages.where((m) => u.has(Role.admin) || m.from.id == u.id || m.to.includes(u));
  }

  Patient? patient(String id) => patients.where((p) => p.id == id).firstOrNull;

  List<PeerView> get peers {
    final m = mesh;
    final l = _ledger;
    if (m == null || l == null) return const [];
    return [
      for (final p in m.peers.where((p) => DateTime.now().difference(p.lastSeen).inSeconds <= 10))
        PeerView(
          user: l.certByDev(p.dev!)?.user,
          nodeId: p.dev!,
          rssi: p.avgRssi?.round() ?? p.rssi,
          inSync: m.inSync(p),
          busy: p.busy,
        ),
    ]..sort((a, b) => b.rssi.compareTo(a.rssi));
  }

  void _changed() {
    if (_dirty) _rebuild();
    if (uplink) _scheduleHq();
    notifyListeners();
  }

  void _scheduleHq() {
    if (pendingHq == 0 || syncing || (_hqDebounce?.isActive ?? false)) return;
    _hqDebounce = Timer(const Duration(seconds: 2), syncNow);
  }

  void _clearProjections() {
    patients = [];
    announcements = [];
    messages = [];
    stock = [];
    otherStock = [];
    requests = [];
    _acked = {};
    _hqRejected.clear();
    lastHqSync = null;
    lastGateway = null;
    lastHqContact = null;
    hqError = null;
  }

  void _rebuild() {
    _dirty = false;
    final l = _ledger;
    if (l == null) return;
    User author(SignedEvent e) =>
        l.certs[e.uid]?.user ?? User(id: e.uid, name: 'Unknown ${e.dev}', roles: const {}, deviceId: e.dev);

    // HQ acknowledgements and audit decisions.
    _acked = {};
    lastHqSync = null;
    final audits = <String, AuditMark>{};
    final statusUpdates = <SignedEvent>[];
    for (final e in l.events.where((e) => e.fromHq)) {
      final d = e.data;
      switch (e.type) {
        case EventTypes.hqAck:
          _acked.addAll((d['ids'] as List).cast<String>());
          if (lastHqSync == null || e.ts.isAfter(lastHqSync!)) {
            lastHqSync = e.ts;
            lastGateway = d['gw'] as String?;
          }
        case EventTypes.conflictResolved:
          AuditMark mark(bool voided) => AuditMark(
                voided: voided,
                note: d['note'] as String? ?? '',
                by: d['by'] as String? ?? 'HQ',
                kind: d['kind'] as String? ?? '',
              );
          for (final id in (d['keep'] as List).cast<String>()) {
            audits.putIfAbsent(id, () => mark(false));
          }
          for (final id in (d['void'] as List).cast<String>()) {
            audits[id] = mark(true);
          }
        case EventTypes.requestUpdated:
          statusUpdates.add(e);
      }
    }
    Reach reach(SignedEvent e) =>
        e.fromHq || _acked.contains(e.id) ? Reach.hq : (l.reachOf(e.id) == 0 ? Reach.local : Reach.cluster);

    final sorted = [...l.events]..sort((a, b) => a.ts.compareTo(b.ts));
    final byPid = <String, Patient>{};
    final later = <SignedEvent>[];
    final anns = <Announcement>[];
    final msgs = <Message>[];
    final items = <String, StockItem>{}; // "facility|item"
    final reqs = <String, SupplyRequest>{};

    Entry entryOf(SignedEvent e, EntryType type, String text, Map<String, String> fields, [Priority? pr]) => Entry(
          type: type,
          author: author(e),
          time: e.ts,
          text: text,
          fields: fields,
          reach: reach(e),
          facility: e.data['fac'] as String? ?? '',
          audit: audits[e.id],
          priority: pr,
        );

    for (final e in sorted) {
      final d = e.data;
      switch (e.type) {
        case EventTypes.patientRegistered:
          final pr = Priority.values.byName(d['priority'] as String);
          final name = d['name'] as String? ?? '';
          final ident = d['ident'] as String? ?? '';
          byPid[d['pid'] as String] = Patient(
            id: d['pid'] as String,
            arrival: e.ts,
            description: d['desc'] as String,
            priority: pr,
            location: d['loc'] as String,
            name: name,
            ident: ident,
            facility: d['fac'] as String? ?? '',
            entries: [
              entryOf(e, EntryType.registered, d['desc'] as String, {
                'Priority': '${pr.code} ${pr.label}',
                'Location': d['loc'] as String,
                if (name.isNotEmpty) 'Name': name,
                if (ident.isNotEmpty) 'ID tag': ident,
              }, pr),
            ],
          );
        case EventTypes.priorityChanged ||
              EventTypes.observationAdded ||
              EventTypes.diagnosisRecorded ||
              EventTypes.remediationRecorded ||
              EventTypes.followUpRecommended:
          later.add(e); // applied once every registration is known
        case EventTypes.announcementPosted:
          anns.add(Announcement(
            title: d['title'] as String,
            body: d['body'] as String,
            author: e.fromHq ? null : author(e),
            time: e.ts,
            urgent: d['urgent'] == true,
            fromHq: e.fromHq,
            reach: reach(e),
          ));
        case EventTypes.messageSent:
          final to = Map<String, dynamic>.from(d['to'] as Map);
          final Audience aud;
          if (to['uid'] != null) {
            final u = l.certs[to['uid']]?.user;
            aud = u == null ? const Audience.all() : Audience.user(u);
          } else if (to['role'] != null) {
            aud = Audience.role(Role.values.byName(to['role'] as String));
          } else {
            aud = const Audience.all();
          }
          msgs.add(Message(from: author(e), to: aud, body: d['body'] as String, time: e.ts, reach: reach(e)));
        case EventTypes.stockCounted || EventTypes.stockAdjusted:
          final fac = d['fac'] as String? ?? '';
          final name = d['item'] as String;
          final key = '${fac.toLowerCase()}|${name.trim().toLowerCase()}';
          final it = items.putIfAbsent(
              key, () => StockItem(name: name, category: StockCategory.supply, unit: '', facility: fac));
          if (e.type == EventTypes.stockCounted) {
            it
              ..name = name
              ..category = StockCategory.values.asNameMap()[d['category']] ?? StockCategory.supply
              ..unit = d['unit'] as String? ?? ''
              ..qty = (d['qty'] as num).toInt()
              ..min = (d['min'] as num? ?? 0).toInt();
          } else {
            it.qty += (d['delta'] as num).toInt();
          }
          it
            ..updated = e.ts
            ..by = author(e)
            ..reach = reach(e);
        case EventTypes.supplyRequested:
          reqs[d['rid'] as String] = SupplyRequest(
            rid: d['rid'] as String,
            item: d['item'] as String,
            qty: (d['qty'] as num).toInt(),
            unit: d['unit'] as String? ?? '',
            urgent: d['urgency'] == 'urgent',
            note: d['note'] as String? ?? '',
            facility: d['fac'] as String? ?? '',
            by: author(e),
            time: e.ts,
            reach: reach(e),
          );
      }
    }

    for (final e in later) {
      final d = e.data;
      final p = byPid[d['pid']];
      if (p == null) continue; // registration not received yet
      if (e.type == EventTypes.priorityChanged) {
        final from = Priority.values.byName(d['from'] as String);
        final to = Priority.values.byName(d['to'] as String);
        p.entries.add(entryOf(e, EntryType.priority, '${from.code} → ${to.code} ${to.label}', const {}, to));
        continue;
      }
      final type = switch (e.type) {
        EventTypes.observationAdded => EntryType.observation,
        EventTypes.diagnosisRecorded => EntryType.diagnosis,
        EventTypes.remediationRecorded => EntryType.remediation,
        _ => EntryType.followUp,
      };
      p.entries.add(entryOf(e, type, d['text'] as String, Map<String, String>.from(d['fields'] as Map? ?? {})));
    }

    for (final p in byPid.values) {
      p.entries.sort((a, b) => a.time.compareTo(b.time));
      // Current priority: the registration, then each priority change, skipping overruled ones.
      for (final en in p.entries.where((x) => !x.voided && x.priority != null)) {
        p.priority = en.priority!;
      }
    }

    for (final e in statusUpdates..sort((a, b) => a.ts.compareTo(b.ts))) {
      final r = reqs[e.data['rid']];
      if (r == null) continue;
      r
        ..status = RequestStatus.values.asNameMap()[e.data['status']] ?? r.status
        ..hqNote = e.data['note'] as String? ?? ''
        ..updated = e.ts;
    }

    patients = byPid.values.toList();
    announcements = anns.reversed.toList();
    messages = msgs.reversed.toList();
    final mine = facility.toLowerCase();
    int byName(StockItem a, StockItem b) {
      final c = a.category.index.compareTo(b.category.index);
      return c != 0 ? c : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    }

    stock = items.values.where((i) => i.facility.toLowerCase() == mine).toList()..sort(byName);
    otherStock = items.values.where((i) => i.facility.toLowerCase() != mine).toList()
      ..sort((a, b) => a.facility.compareTo(b.facility) != 0 ? a.facility.compareTo(b.facility) : byName(a, b));
    requests = reqs.values.toList()..sort((a, b) => b.time.compareTo(a.time));
  }

  String? nameOfDevice(String? dev) => dev == null ? null : (_ledger?.certByDev(dev)?.name ?? dev);

  // ------------------------------------------------------------------ log

  void _log(String text, {bool bad = false}) {
    meshLog.insert(0, MeshLog(DateTime.now(), text, bad: bad));
    if (meshLog.length > 60) meshLog.removeLast();
    notifyListeners();
  }

  @override
  void dispose() {
    _hqDebounce?.cancel();
    _hqPoll?.cancel();
    mesh?.stop();
    super.dispose();
  }
}
