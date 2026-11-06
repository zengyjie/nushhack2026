import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/crypto.dart';
import '../core/identity.dart';
import '../core/ledger.dart';
import '../core/mesh.dart';
import '../core/records.dart';
import '../model/models.dart';

enum Phase { loading, enrol, locked, ready }

/// App-wide state: identity (SEC), the local signed log (OFF), the BLE mesh (LC)
/// and the mock HQ uplink (ON). Screens read the projections built here.
class AppState extends ChangeNotifier {
  AppState() {
    _boot();
  }

  Phase phase = Phase.loading;
  Identity? _id;
  Ledger? _ledger;
  MeshService? mesh;
  MockHqStore? _hq;

  /// Name on the stored certificate, shown on the lock screen.
  String? lockedName;

  User? get me => _id?.cert.user;
  Certificate? get cert => _id?.cert;
  String get nodeId => _id?.cert.dev ?? '--------';

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

  Future<void> enrol(String name, Set<Role> roles, String pin) async {
    _id = await Identity.enrol(name: name, roles: roles, pin: pin);
    await _open();
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
    await mesh?.stop();
    mesh = null;
    await _ledger?.close();
    _ledger = null;
    lockedName = _id?.cert.name;
    _id = null;
    uplink = false;
    phase = Phase.locked;
    notifyListeners();
  }

  /// Wipes the key, certificate and every local record on this phone.
  Future<void> reset() async {
    await lock();
    await Identity.wipe();
    await Ledger.deleteAll();
    await MockHqStore.deleteAll();
    _hq = null;
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

  String get nextPatientId {
    final mine = _ledger?.events.where((e) => e.dev == nodeId && e.type == EventTypes.patientRegistered).length ?? 0;
    return 'P-${nodeId.substring(0, 4).toUpperCase()}-${(mine + 1).toString().padLeft(2, '0')}';
  }

  Future<String> registerPatient({required String description, required Priority priority, required String location}) async {
    final pid = nextPatientId;
    await _write(EventTypes.patientRegistered, {'pid': pid, 'desc': description, 'priority': priority.name, 'loc': location});
    return pid;
  }

  Future<void> setPriority(Patient p, Priority to) =>
      _write(EventTypes.priorityChanged, {'pid': p.id, 'from': p.priority.name, 'to': to.name});

  Future<void> addEntry(Patient p, EntryType type, String text, Map<String, String> fields) {
    final t = switch (type) {
      EntryType.observation => EventTypes.observationAdded,
      EntryType.diagnosis => EventTypes.diagnosisRecorded,
      EntryType.remediation => EventTypes.remediationRecorded,
      EntryType.followUp => EventTypes.followUpRecommended,
      _ => throw ArgumentError(type),
    };
    return _write(t, {'pid': p.id, 'text': text, 'fields': fields});
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

  // ------------------------------------------------------------------ ON: mock HQ uplink

  bool uplink = false;
  bool syncing = false;
  Timer? _hqDebounce;

  Future<void> setUplink(bool on) async {
    uplink = on;
    _log(on ? 'uplink on: this phone forwards the cluster to HQ' : 'uplink off');
    notifyListeners();
    if (on) await syncNow();
  }

  /// Uploads every event HQ hasn't acknowledged to the mock HQ store, then
  /// floods an HQ-signed acknowledgement so every phone can show "synced to HQ".
  Future<void> syncNow() async {
    final ledger = _ledger;
    if (ledger == null || syncing || !uplink) return;
    final todo = ledger.events.where((e) => !e.fromHq && !_acked.contains(e.id)).toList();
    if (todo.isEmpty) return;
    syncing = true;
    notifyListeners();
    try {
      _hq ??= await MockHqStore.open();
      await _hq!.upload(todo);
      final ack = await SignedEvent.create(
        key: await Crypto.hqKeyPair(),
        uid: hqId,
        dev: hqId,
        seq: 0,
        prev: '',
        type: EventTypes.hqAck,
        data: {'ids': [for (final e in todo) e.id], 'gw': nodeId},
      );
      await ledger.appendOwn(ack, _id!.cert);
      mesh?.broadcast(ack);
      _log('HQ acknowledged ${todo.length} events');
      _dirty = true;
    } catch (e) {
      _log('HQ sync failed: $e', bad: true);
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
    _acked = {};
    lastHqSync = null;
    lastGateway = null;
  }

  void _rebuild() {
    _dirty = false;
    final l = _ledger;
    if (l == null) return;
    User author(SignedEvent e) =>
        l.certs[e.uid]?.user ?? User(id: e.uid, name: 'Unknown ${e.dev}', roles: const {}, deviceId: e.dev);

    _acked = {};
    lastHqSync = null;
    for (final e in l.events.where((e) => e.type == EventTypes.hqAck)) {
      _acked.addAll((e.data['ids'] as List).cast<String>());
      if (lastHqSync == null || e.ts.isAfter(lastHqSync!)) {
        lastHqSync = e.ts;
        lastGateway = e.data['gw'] as String?;
      }
    }
    Reach reach(SignedEvent e) =>
        e.fromHq || _acked.contains(e.id) ? Reach.hq : (l.reachOf(e.id) == 0 ? Reach.local : Reach.cluster);

    final sorted = [...l.events]..sort((a, b) => a.ts.compareTo(b.ts));
    final byPid = <String, Patient>{};
    final orphans = <SignedEvent>[];
    final anns = <Announcement>[];
    final msgs = <Message>[];

    Entry entryOf(SignedEvent e, EntryType type, String text, Map<String, String> fields) =>
        Entry(type: type, author: author(e), time: e.ts, text: text, fields: fields, reach: reach(e));

    void clinical(SignedEvent e) {
      final d = e.data;
      final p = byPid[d['pid']];
      if (p == null) return orphans.add(e);
      final type = switch (e.type) {
        EventTypes.observationAdded => EntryType.observation,
        EventTypes.diagnosisRecorded => EntryType.diagnosis,
        EventTypes.remediationRecorded => EntryType.remediation,
        _ => EntryType.followUp,
      };
      p.entries.add(entryOf(e, type, d['text'] as String, Map<String, String>.from(d['fields'] as Map? ?? {})));
    }

    for (final e in sorted) {
      final d = e.data;
      switch (e.type) {
        case EventTypes.patientRegistered:
          final pr = Priority.values.byName(d['priority'] as String);
          byPid[d['pid'] as String] = Patient(
            id: d['pid'] as String,
            arrival: e.ts,
            description: d['desc'] as String,
            priority: pr,
            location: d['loc'] as String,
            entries: [
              entryOf(e, EntryType.registered, d['desc'] as String,
                  {'Priority': '${pr.code} ${pr.label}', 'Location': d['loc'] as String}),
            ],
          );
        case EventTypes.priorityChanged:
          final p = byPid[d['pid']];
          if (p == null) {
            orphans.add(e);
            break;
          }
          final from = Priority.values.byName(d['from'] as String);
          final to = Priority.values.byName(d['to'] as String);
          p.priority = to;
          p.entries.add(entryOf(e, EntryType.priority, '${from.code} → ${to.code} ${to.label}', const {}));
        case EventTypes.observationAdded ||
              EventTypes.diagnosisRecorded ||
              EventTypes.remediationRecorded ||
              EventTypes.followUpRecommended:
          clinical(e);
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
      }
    }
    // Clinical entries that arrived before the patient was registered on this phone.
    for (final e in orphans) {
      if (byPid.containsKey(e.data['pid']) && e.type != EventTypes.priorityChanged) clinical(e);
    }
    for (final p in byPid.values) {
      p.entries.sort((a, b) => a.time.compareTo(b.time));
    }
    patients = byPid.values.toList();
    announcements = anns.reversed.toList();
    messages = msgs.reversed.toList();
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
    mesh?.stop();
    super.dispose();
  }
}
