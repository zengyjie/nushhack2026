import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'crypto.dart';
import 'records.dart';

enum Verdict { accepted, duplicate, pending, rejected }

class VerifyResult {
  const VerifyResult(this.verdict, [this.reason]);
  final Verdict verdict;
  final String? reason;
}

/// Append-only event log in SQLite, plus the offline verification pipeline:
/// HQ cert signature → author signature → hash chain and sequence → role permission.
class Ledger {
  Ledger._(this._db);

  final Database _db;

  /// In-memory mirror of the log, in arrival order. Small enough for a field cluster.
  final List<SignedEvent> events = [];
  final Map<String, Certificate> certs = {}; // by uid
  final Map<String, int> _reach = {}; // id → 0 on this device only, 1 shared
  final Map<String, ({int seq, String id})> _heads = {}; // dev → latest
  final Set<String> _ids = {};

  /// Events that arrived ahead of their predecessor, keyed by "dev:seq".
  final Map<String, (SignedEvent, Map<String, Certificate>)> _pending = {};

  static Future<Ledger> open() async {
    final db = await openDatabase(
      p.join(await getDatabasesPath(), 'mesh.db'),
      version: 1,
      onCreate: (db, _) async {
        await db.execute('CREATE TABLE events (id TEXT PRIMARY KEY, dev TEXT, seq INTEGER, '
            'type TEXT, json TEXT NOT NULL, reach INTEGER NOT NULL, rx_at INTEGER NOT NULL)');
        await db.execute('CREATE TABLE certs (uid TEXT PRIMARY KEY, dev TEXT, json TEXT NOT NULL)');
      },
    );
    final l = Ledger._(db);
    for (final r in await db.query('certs')) {
      final c = Certificate.fromJson(jsonDecode(r['json'] as String) as Map<String, dynamic>);
      l.certs[c.uid] = c;
    }
    for (final r in await db.query('events', orderBy: 'rx_at')) {
      final e = SignedEvent.fromJson(jsonDecode(r['json'] as String) as Map<String, dynamic>);
      l._index(e, r['reach'] as int);
    }
    return l;
  }

  static Future<void> deleteAll() async => deleteDatabase(p.join(await getDatabasesPath(), 'mesh.db'));

  bool has(String id) => _ids.contains(id);

  int reachOf(String id) => _reach[id] ?? 1;

  ({int seq, String id})? head(String dev) => _heads[dev];

  Certificate? certByDev(String dev) => certs.values.where((c) => c.dev == dev).firstOrNull;

  void _index(SignedEvent e, int reach) {
    events.add(e);
    _ids.add(e.id);
    _reach[e.id] = reach;
    if (!e.fromHq) {
      final h = _heads[e.dev];
      if (h == null || e.seq > h.seq) _heads[e.dev] = (seq: e.seq, id: e.id);
    }
  }

  Future<void> _insert(SignedEvent e, int reach) async {
    await _db.insert('events', {
      'id': e.id,
      'dev': e.dev,
      'seq': e.fromHq ? 0 : e.seq,
      'type': e.type,
      'json': e.encode(),
      'reach': reach,
      'rx_at': DateTime.now().microsecondsSinceEpoch,
    });
    _index(e, reach);
  }

  Future<void> saveCert(Certificate c) async {
    final known = certs[c.uid];
    if (known != null && known.sig == c.sig) return;
    certs[c.uid] = c;
    await _db.insert('certs', {'uid': c.uid, 'dev': c.dev, 'json': jsonEncode(c.toJson())},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Marks this device's own events as having reached at least one peer.
  Future<void> markShared(Iterable<String> ids) async {
    final local = ids.where((id) => _reach[id] == 0).toList();
    if (local.isEmpty) return;
    for (final id in local) {
      _reach[id] = 1;
    }
    await _db.update('events', {'reach': 1},
        where: 'id IN (${List.filled(local.length, '?').join(',')})', whereArgs: local);
  }

  /// Appends an event this device just signed. It is checked like any other.
  Future<VerifyResult> appendOwn(SignedEvent e, Certificate mine) => _accept(e, {mine.uid: mine}, reach: 0);

  /// Verifies a received event and stores it if it passes. Returns the accepted
  /// events (it may unblock events that were waiting on it) via [onAccepted].
  Future<VerifyResult> receive(
    SignedEvent e,
    Map<String, Certificate> bundled, {
    void Function(SignedEvent)? onAccepted,
  }) async {
    final r = await _accept(e, bundled, reach: 1);
    if (r.verdict == Verdict.accepted) {
      onAccepted?.call(e);
      // Release any successor that arrived early.
      var next = _pending.remove('${e.dev}:${e.seq + 1}');
      while (next != null) {
        final (pe, pc) = next;
        final pr = await _accept(pe, pc, reach: 1);
        if (pr.verdict != Verdict.accepted) break;
        onAccepted?.call(pe);
        next = _pending.remove('${pe.dev}:${pe.seq + 1}');
      }
    }
    return r;
  }

  Future<VerifyResult> _accept(SignedEvent e, Map<String, Certificate> bundled, {required int reach}) async {
    // Integrity: the ID is the hash of the body.
    final bytes = canonicalJson(e.body);
    if (await Crypto.sha256Hex(bytes) != e.id) return const VerifyResult(Verdict.rejected, 'hash mismatch');
    if (has(e.id)) return const VerifyResult(Verdict.duplicate);

    // HQ-signed events: verified directly against the HQ public key.
    if (e.fromHq) {
      if (!await Crypto.verify(bytes, unb64(e.sig), await Crypto.hqPublicKey())) {
        return const VerifyResult(Verdict.rejected, 'bad HQ signature');
      }
      if (!hqPermissions.contains(e.type)) return VerifyResult(Verdict.rejected, 'HQ cannot sign ${e.type}');
      await _insert(e, reach);
      return const VerifyResult(Verdict.accepted);
    }

    // 1. Author's certificate: from the local store, or the copy bundled by the neighbour.
    final cert = bundled[e.uid] ?? certs[e.uid];
    if (cert == null) return const VerifyResult(Verdict.rejected, 'no certificate for author');
    // 2. HQ signature, and the certificate was valid when the event was signed.
    if (e.ts.isAfter(DateTime.now().add(const Duration(minutes: 10)))) {
      return const VerifyResult(Verdict.rejected, 'timestamp in the future');
    }
    final certErr = await cert.check(at: e.ts);
    if (certErr != null) return VerifyResult(Verdict.rejected, certErr);
    if (cert.dev != e.dev) return const VerifyResult(Verdict.rejected, 'device does not match certificate');
    // 3. Author's signature on the event.
    if (!await Crypto.verify(bytes, unb64(e.sig), cert.publicKey)) {
      return const VerifyResult(Verdict.rejected, 'bad author signature');
    }
    // 4. Role allows this action.
    if (!cert.permits(e.type)) {
      return VerifyResult(Verdict.rejected, '${cert.user.rolesLabel} cannot sign ${e.type}');
    }
    // 5. Hash chain and sequence number for this device.
    final h = _heads[e.dev];
    final expectedSeq = (h?.seq ?? 0) + 1;
    if (e.seq < expectedSeq) return const VerifyResult(Verdict.rejected, 'sequence replayed or forked');
    if (e.seq > expectedSeq) {
      _pending['${e.dev}:${e.seq}'] = (e, bundled);
      return const VerifyResult(Verdict.pending, 'waiting for earlier event');
    }
    if (e.prev != (h?.id ?? '')) return const VerifyResult(Verdict.rejected, 'hash chain broken');

    await saveCert(cert);
    await _insert(e, reach);
    return const VerifyResult(Verdict.accepted);
  }

  /// Order-independent digest of the events held (FNV-1a over sorted blob IDs, as in ble_lab).
  /// Two phones advertising the same value hold the same events.
  int get stateHash {
    final ids = events.map((e) => e.blobId).toList()..sort();
    var h = 0x811c9dc5;
    for (final id in ids) {
      for (var i = 0; i < 8; i++) {
        h ^= (id >> (i * 8)) & 0xff;
        h = (h * 0x01000193) & 0xffffffff;
      }
    }
    return h.toSigned(32);
  }

  /// Events in chain order, for catch-up bundles.
  List<SignedEvent> get chainOrdered => [...events]..sort((a, b) {
        final d = a.dev.compareTo(b.dev);
        if (d != 0) return d;
        return (a.fromHq ? a.ts.millisecondsSinceEpoch : a.seq).compareTo(b.fromHq ? b.ts.millisecondsSinceEpoch : b.seq);
      });

  Future<void> close() => _db.close();
}
