import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';

import 'ble_bridge.dart';
import 'ledger.dart';
import 'records.dart';

/// A nearby node seen in BLE scans. Keyed by node ID, since Android rotates the MAC.
class MeshPeer {
  MeshPeer(this.address);

  String address;
  int? nodeId;
  int? stateHash;
  int rssi = 0;
  double? avgRssi; // smoothed, so the signal bars don't flicker
  DateTime lastSeen = DateTime.now();
  DateTime lastSync = DateTime.fromMillisecondsSinceEpoch(0);
  bool busy = false;

  String? get dev => nodeId == null ? null : hex32(nodeId!);
}

/// Packet kinds carried in a BLE blob.
///  - `ev`: one new event, flooded hop by hop (forwarding copied from ble_lab).
///  - `sync`: catch-up bundle sent point to point when beacons disagree. Not forwarded.
class _Packet {
  _Packet(this.kind, this.events, this.certs);
  final String kind;
  final List<SignedEvent> events;
  final Map<String, Certificate> certs;

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode({
        't': kind,
        'e': [for (final e in events) e.toJson()],
        'c': [for (final c in certs.values) c.toJson()],
      })));

  static _Packet decode(Uint8List bytes) {
    final j = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final certs = <String, Certificate>{};
    for (final c in (j['c'] as List)) {
      final cert = Certificate.fromJson(Map<String, dynamic>.from(c as Map));
      certs[cert.uid] = cert;
    }
    return _Packet(
      j['t'] as String,
      [for (final e in (j['e'] as List)) SignedEvent.fromJson(Map<String, dynamic>.from(e as Map))],
      certs,
    );
  }
}

/// LC layer: the ble_lab engine plus signed-event flooding and beacon-driven catch-up.
class MeshService {
  MeshService({
    required this.ledger,
    required this.me,
    required this.onChanged,
    required this.onLog,
    required this.onAccepted,
  });

  final Ledger ledger;
  final Certificate me;
  final void Function() onChanged;
  final void Function(String msg, {bool bad}) onLog;
  final void Function(SignedEvent e) onAccepted;

  final _ble = BleBridge();
  final _rng = Random.secure();
  StreamSubscription? _sub;
  Timer? _ticker;

  bool running = false;
  String? error;
  int inboundLinks = 0;
  int relayed = 0;
  int rejected = 0;
  int received = 0;

  final Map<String, MeshPeer> _peers = {};
  final Set<int> _seenBlobs = {};
  final Map<int, Future<void>> _queues = {};

  int get nodeId => int.parse(me.dev, radix: 16).toSigned(32);

  Iterable<MeshPeer> get peers => _peers.values.where((p) => p.nodeId != null);

  // ------------------------------------------------------------------ lifecycle

  Future<void> start() async {
    _sub ??= _ble.events.listen(_onEvent);
    _ticker ??= Timer.periodic(const Duration(seconds: 2), (_) => _tick());
    for (final e in ledger.events) {
      _seenBlobs.add(e.blobId);
    }
    try {
      if (!await _ble.requestPermissions()) {
        error = 'Nearby devices permission denied. Grant it in Settings, then retry.';
        onChanged();
        return;
      }
      await _ble.startNode(nodeId, ledger.stateHash);
      running = true;
      error = null;
    } on PlatformException catch (e) {
      error = e.message ?? e.code;
      running = false;
    } on MissingPluginException {
      error = 'Bluetooth mesh is only available on Android.';
      running = false;
    }
    onChanged();
  }

  Future<void> stop() async {
    _ticker?.cancel();
    _ticker = null;
    await _sub?.cancel();
    _sub = null;
    if (running) {
      try {
        await _ble.stopNode();
      } catch (_) {}
    }
    running = false;
    _peers.clear();
  }

  // ------------------------------------------------------------------ outbound

  /// Floods a newly signed event to every live peer.
  void broadcast(SignedEvent e) {
    _seenBlobs.add(e.blobId);
    _refreshBeacon();
    final bytes = _Packet('ev', [e], {me.uid: me, ..._certFor(e)}).encode();
    for (final p in _livePeers) {
      _send(p, bytes, e.blobId, nodeId, ids: [e.id]);
    }
  }

  Map<String, Certificate> _certFor(SignedEvent e) {
    final c = ledger.certs[e.uid];
    return c == null ? {} : {c.uid: c};
  }

  /// Sends with up to 3 attempts and a short backoff (from ble_lab), one transfer per peer at a time.
  void _send(MeshPeer p, Uint8List bytes, int blobId, int origin, {List<String> ids = const []}) {
    final key = p.nodeId ?? p.address.hashCode;
    final prev = _queues[key] ?? Future.value();
    final next = prev.then((_) async {
      p.busy = true;
      onChanged();
      try {
        for (var attempt = 1; attempt <= 3; attempt++) {
          final r = await _ble.sendBlob(address: p.address, bytes: bytes, blobId: blobId, origin: origin);
          if (r['ok'] == true) {
            if (ids.isNotEmpty) await ledger.markShared(ids);
            return;
          }
          onLog('tx to ${p.dev} failed (attempt $attempt): ${r['error']}', bad: attempt == 3);
          await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
        }
      } on PlatformException catch (e) {
        onLog('tx error: ${e.message}', bad: true);
      } finally {
        p.busy = false;
        onChanged();
      }
    });
    _queues[key] = next;
  }

  // ------------------------------------------------------------------ inbound

  void _onEvent(Map<String, dynamic> e) {
    switch (e['type']) {
      case 'peer':
        _onPeer(e);
      case 'serverConn':
        inboundLinks = e['count'] as int;
      case 'blob':
        _onBlob(e);
      case 'log':
        final msg = e['msg'] as String;
        if (msg.contains('FAILED')) onLog(msg, bad: true);
    }
    onChanged();
  }

  void _onPeer(Map<String, dynamic> e) {
    final addr = e['address'] as String;
    final id = e['nodeId'] as int?;
    final MeshPeer p;
    if (id != null) {
      final fromAddr = _peers.remove('a:$addr'); // promote an address-only entry
      p = _peers.putIfAbsent('n:$id', () => fromAddr ?? MeshPeer(addr));
      p.nodeId = id;
      p.address = addr;
      p.stateHash = e['stateHash'] as int? ?? p.stateHash;
    } else {
      p = _peers.values.firstWhere((x) => x.address == addr,
          orElse: () => _peers.putIfAbsent('a:$addr', () => MeshPeer(addr)));
    }
    p.rssi = e['rssi'] as int;
    p.avgRssi = p.avgRssi == null ? p.rssi.toDouble() : p.avgRssi! * 0.7 + p.rssi * 0.3;
    p.lastSeen = DateTime.now();
  }

  Future<void> _onBlob(Map<String, dynamic> e) async {
    final blobId = e['blobId'] as int;
    final origin = e['origin'] as int;
    final sender = e['sender'] as int;
    if (e['ok'] != true) {
      onLog('corrupt blob from ${hex32(sender)} (size/CRC mismatch)', bad: true);
      return;
    }
    if (!_seenBlobs.add(blobId)) return; // duplicate, already handled

    final bytes = e['bytes'] as Uint8List;
    final _Packet packet;
    try {
      packet = _Packet.decode(bytes);
    } catch (_) {
      rejected++;
      onLog('unreadable packet from ${hex32(sender)}', bad: true);
      return;
    }

    var accepted = 0, failed = 0;
    for (final ev in packet.events) {
      final r = await ledger.receive(ev, packet.certs, onAccepted: (a) {
        accepted++;
        _seenBlobs.add(a.blobId);
        onAccepted(a);
      });
      if (r.verdict == Verdict.rejected) {
        failed++;
        rejected++;
        final who = packet.certs[ev.uid]?.name ?? ledger.certs[ev.uid]?.name ?? ev.dev;
        onLog('rejected ${ev.type} from $who: ${r.reason}', bad: true);
      }
    }
    received += accepted;
    if (accepted > 0) {
      onLog(packet.kind == 'sync'
          ? 'caught up $accepted events from ${_name(sender)}'
          : 'received ${packet.events.first.type} from ${_name(origin)}${origin != sender ? ' via ${_name(sender)}' : ''}');
      _refreshBeacon();
    }

    // Forwarding from ble_lab: push to every live peer except the origin and sender.
    // Only verified, new single events are flooded; bad or catch-up packets stop here.
    if (packet.kind == 'ev' && accepted > 0 && failed == 0) {
      final targets = _livePeers.where((p) => p.nodeId != origin && p.nodeId != sender).toList();
      for (final p in targets) {
        relayed++;
        _send(p, bytes, blobId, origin);
      }
      if (targets.isNotEmpty) onLog('forwarded to ${targets.length} peer${targets.length == 1 ? '' : 's'}');
    }
    onChanged(); // rebuild projections now that verification is done
  }

  String _name(int node) => ledger.certByDev(hex32(node))?.name ?? hex32(node);

  // ------------------------------------------------------------------ catch-up and housekeeping

  void _tick() {
    _peers.removeWhere((_, p) => DateTime.now().difference(p.lastSeen).inSeconds > 60);
    if (!running) return;
    final mine = ledger.stateHash;
    final now = DateTime.now();
    for (final p in _livePeers) {
      if (p.stateHash == null || p.stateHash == mine || p.busy) continue;
      if (now.difference(p.lastSync).inSeconds < 12) continue;
      if (ledger.events.isEmpty) continue;
      p.lastSync = now;
      // Beacons disagree: push everything we hold. The peer does the same towards us.
      final events = ledger.chainOrdered;
      final certs = {for (final c in ledger.certs.values) c.uid: c, me.uid: me};
      final blobId = (_rng.nextInt(1 << 32) << 31) ^ _rng.nextInt(1 << 31);
      _seenBlobs.add(blobId);
      _send(p, _Packet('sync', events, certs).encode(), blobId, nodeId,
          ids: [for (final e in events) if (ledger.reachOf(e.id) == 0) e.id]);
    }
    onChanged();
  }

  DateTime _lastBeacon = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _beaconTimer;

  /// Re-advertises the state hash, at most every 2 s (each restart rotates the MAC).
  void _refreshBeacon() {
    if (!running) return;
    final wait = const Duration(seconds: 2) - DateTime.now().difference(_lastBeacon);
    _beaconTimer?.cancel();
    _beaconTimer = Timer(wait.isNegative ? Duration.zero : wait, () {
      _lastBeacon = DateTime.now();
      _ble.updateBeacon(ledger.stateHash).catchError((_) {});
    });
  }

  bool _fresh(MeshPeer p) => DateTime.now().difference(p.lastSeen).inSeconds <= 10;

  /// Peers we can send to: identified and seen in the last 10 s.
  Iterable<MeshPeer> get _livePeers => _peers.values.where((p) => p.nodeId != null && _fresh(p));

  List<MeshPeer> get livePeers => _livePeers.toList();

  bool inSync(MeshPeer p) => p.stateHash == ledger.stateHash;
}
