import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ble_bridge.dart';

void main() => runApp(const BleLabApp());

class BleLabApp extends StatelessWidget {
  const BleLabApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'BLE Lab',
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        home: const LabPage(),
      );
}

class Peer {
  Peer(this.address);

  /// Latest MAC seen for this node. Android rotates its private address
  /// whenever advertising restarts, so this changes; nodeId is the stable key.
  String address;
  int? nodeId;
  int? stateHash;
  int rssi = 0;

  /// Exponentially smoothed RSSI, so the simulated range edge doesn't flicker.
  double? avgRssi;
  DateTime lastSeen = DateTime.now();
}

class LabPage extends StatefulWidget {
  const LabPage({super.key});

  @override
  State<LabPage> createState() => _LabPageState();
}

class _LabPageState extends State<LabPage> {
  final _ble = BleBridge();
  final _rng = Random.secure();
  StreamSubscription? _sub;
  Timer? _ticker;

  Map<String, dynamic> _info = {};
  int _nodeId = 0;
  bool _running = false;
  bool _autoForward = true;
  bool _noResponse = false;
  int _blobSize = 5 * 1024;
  int _inboundLinks = 0;

  // Simulated range limit for hop tests (phones on one desk all see each other).
  bool _rangeLimit = false;
  int _rssiLimit = -65;

  final Map<String, Peer> _peers = {};
  final Set<int> _seenBlobs = {};
  final List<String> _log = [];
  final Set<Peer> _busy = {};

  @override
  void initState() {
    super.initState();
    _sub = _ble.events.listen(_onEvent);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      _peers.removeWhere((_, p) => DateTime.now().difference(p.lastSeen).inSeconds > 60);
      _syncRangeFilter();
      if (mounted) setState(() {});
    });
    _init();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _init() async {
    final granted = await _ble.requestPermissions();
    _add(granted ? 'permissions granted' : 'PERMISSIONS DENIED – grant Nearby devices in settings');
    final info = await _ble.info();
    setState(() {
      _info = info;
      _nodeId = (info['nodeId'] as int?) ?? 0;
    });
  }

  // ------------------------------------------------------------------ state hash

  /// Order-independent digest of the blobs this node holds; advertised in the beacon.
  int get _stateHash {
    final ids = _seenBlobs.toList()..sort();
    var h = 0x811c9dc5;
    for (final id in ids) {
      for (var i = 0; i < 8; i++) {
        h ^= (id >> (i * 8)) & 0xff;
        h = (h * 0x01000193) & 0xffffffff;
      }
    }
    return h.toSigned(32);
  }

  // ------------------------------------------------------------------ events

  void _onEvent(Map<String, dynamic> e) {
    switch (e['type']) {
      case 'log':
        _add(e['msg'] as String);
      case 'peer':
        // Key peers by node ID so a rotated MAC updates the same entry
        // instead of adding a duplicate.
        final addr = e['address'] as String;
        final id = e['nodeId'] as int?;
        final Peer p;
        if (id != null) {
          final fromAddr = _peers.remove('a:$addr'); // promote an address-only entry
          p = _peers.putIfAbsent('n:$id', () => fromAddr ?? Peer(addr));
          p.nodeId = id;
          p.address = addr;
          p.stateHash = e['stateHash'] as int? ?? p.stateHash;
        } else {
          // No scan response yet: reuse whichever entry last used this MAC.
          p = _peers.values.firstWhere((x) => x.address == addr,
              orElse: () => _peers.putIfAbsent('a:$addr', () => Peer(addr)));
        }
        p.rssi = e['rssi'] as int;
        p.avgRssi = p.avgRssi == null ? p.rssi.toDouble() : p.avgRssi! * 0.7 + p.rssi * 0.3;
        p.lastSeen = DateTime.now();
      case 'serverConn':
        _inboundLinks = e['count'] as int;
        _add('server: ${e['address']} ${e['connected'] == true ? 'connected' : 'disconnected'} '
            '(status ${e['status']}, links ${e['count']})');
      case 'blob':
        _onBlob(e);
    }
    if (mounted) setState(() {});
  }

  Future<void> _onBlob(Map<String, dynamic> e) async {
    final blobId = e['blobId'] as int;
    final origin = e['origin'] as int;
    final sender = e['sender'] as int;
    if (e['ok'] != true) {
      _add('rx blob ${_short(blobId)} from ${hex32(sender)}: CORRUPT (size/CRC mismatch)');
      return;
    }
    if (!_seenBlobs.add(blobId)) {
      _add('rx blob ${_short(blobId)} from ${hex32(sender)}: duplicate, ignored');
      return;
    }
    _add('rx blob ${_short(blobId)} ✓ ${e['size']} B, origin ${hex32(origin)} via ${hex32(sender)}, ${e['ms']} ms');
    if (_running) await _ble.updateBeacon(_stateHash);

    if (_autoForward) {
      final bytes = e['bytes'] as Uint8List;
      final targets = _livePeers.where((p) => p.nodeId != null && p.nodeId != origin && p.nodeId != sender);
      for (final p in targets) {
        _add('forwarding ${_short(blobId)} → ${hex32(p.nodeId!)}');
        unawaited(_send(p, bytes, blobId, origin));
      }
    }
  }

  // ------------------------------------------------------------------ actions

  Future<void> _toggleNode(bool on) async {
    try {
      if (on) {
        await _ble.startNode(_stateHash);
      } else {
        await _ble.stopNode();
        _peers.clear();
      }
      setState(() => _running = on);
    } on PlatformException catch (e) {
      _add('start failed: ${e.message}');
      setState(() {});
    }
  }

  Future<void> _sendNew(Peer p) async {
    final bytes = Uint8List.fromList(List.generate(_blobSize, (_) => _rng.nextInt(256)));
    final blobId = (_rng.nextInt(1 << 32) << 31) ^ _rng.nextInt(1 << 31);
    _seenBlobs.add(blobId);
    if (_running) await _ble.updateBeacon(_stateHash);
    _add('new blob ${_short(blobId)} (${bytes.length} B) → ${p.nodeId == null ? p.address : hex32(p.nodeId!)}');
    await _send(p, bytes, blobId, _nodeId);
  }

  /// Sends with up to 3 attempts and a short backoff between them.
  Future<void> _send(Peer p, Uint8List bytes, int blobId, int origin) async {
    setState(() => _busy.add(p));
    try {
      for (var attempt = 1; attempt <= 3; attempt++) {
        final r = await _ble.sendBlob(
          address: p.address,
          bytes: bytes,
          blobId: blobId,
          origin: origin,
          noResponse: _noResponse,
        );
        if (r['ok'] == true) {
          _add('tx ✓ ${r['bytes']} B → ${p.address} | MTU ${r['mtu']}, ${r['frames']} frames, '
              'setup ${r['setupMs']} ms, xfer ${r['transferMs']} ms '
              '(${(r['kBps'] as num).toStringAsFixed(1)} kB/s), total ${r['totalMs']} ms');
          return;
        }
        _add('tx ✗ attempt $attempt → ${p.address}: ${r['error']} (frames sent ${r['framesSent']}, ${r['totalMs']} ms)');
        await Future.delayed(Duration(milliseconds: 400 * attempt));
      }
    } on PlatformException catch (e) {
      _add('tx error: ${e.message}');
    } finally {
      if (mounted) setState(() => _busy.remove(p));
    }
  }

  Future<void> _testExtAdv() async {
    final r = await _ble.testExtendedAdvertising();
    _add('ext adv test: $r');
    setState(() {});
  }

  Future<void> _testMultiAdv() async {
    final r = await _ble.testMultiAdvertising(4);
    _add('multi adv test: started ${r['started']}/${r['requested']} extra '
        '(beacon running: ${r['beaconRunning']}) ${r['results']}');
    setState(() {});
  }

  Future<void> _testConnectAll() async {
    final addrs = _livePeers.map((p) => p.address).toList();
    if (addrs.isEmpty) return _add('connect-all: no live peers');
    _add('connect-all: opening ${addrs.length} links…');
    setState(() {});
    final r = await _ble.testConnectAll(addrs);
    _add('connect-all: ${r['connected']}/${r['attempted']} outbound held, '
        '${r['alsoServingInbound']} inbound; failures ${r['failedStatus']}');
    setState(() {});
  }

  // ------------------------------------------------------------------ helpers

  bool _fresh(Peer p) => DateTime.now().difference(p.lastSeen).inSeconds <= 10;

  /// False when the range limit is on and this peer's smoothed RSSI is below the threshold.
  bool _inRange(Peer p) => !_rangeLimit || (p.avgRssi ?? -999) >= _rssiLimit;

  /// Peers we can send to: recently seen and inside the simulated range.
  Iterable<Peer> get _livePeers => _peers.values.where((p) => _fresh(p) && _inRange(p));

  /// Tells the native server which senders to accept, so the limit applies in both directions.
  void _syncRangeFilter() {
    final allowed = _livePeers.where((p) => p.nodeId != null).map((p) => p.nodeId!).toList();
    _ble.setRangeFilter(_rangeLimit, allowed).catchError((_) {});
  }

  String _short(int blobId) => blobId.toUnsigned(64).toRadixString(16).padLeft(16, '0').substring(0, 6);

  void _add(String s) {
    final t = DateTime.now();
    final ts = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}.${t.millisecond.toString().padLeft(3, '0')}';
    _log.insert(0, '$ts  $s');
    if (_log.length > 400) _log.removeLast();
  }

  // ------------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final peers = _peers.values.toList()..sort((a, b) => b.rssi.compareTo(a.rssi));
    return Scaffold(
      appBar: AppBar(
        title: Text('BLE Lab · ${_nodeId == 0 ? '…' : hex32(_nodeId)}'),
        actions: [
          IconButton(
            tooltip: 'Copy log',
            icon: const Icon(Icons.copy_all),
            onPressed: () {
              final caps = _info.entries.map((e) => '${e.key}: ${e.value}').join('\n');
              Clipboard.setData(ClipboardData(text: '$caps\n\n${_log.reversed.join('\n')}'));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Capabilities + log copied')));
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _section('Capabilities', [
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final e in _info.entries)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text('${e.key}: ${e.value}', style: const TextStyle(fontSize: 12)),
                    backgroundColor: e.value == false ? Colors.red.shade100 : null,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              OutlinedButton(onPressed: _testExtAdv, child: const Text('Ext adv test')),
              OutlinedButton(onPressed: _testMultiAdv, child: const Text('Multi adv test')),
              OutlinedButton(onPressed: _running ? _testConnectAll : null, child: const Text('Connect-all test')),
            ]),
          ]),
          _section('Node', [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Run node (server + beacon + scan)'),
              subtitle: Text('inbound links: $_inboundLinks · blobs held: ${_seenBlobs.length} · '
                  'state ${hex32(_stateHash)}'),
              value: _running,
              onChanged: _toggleNode,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Auto-forward received blobs (relay)'),
              value: _autoForward,
              onChanged: (v) => setState(() => _autoForward = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Write without response (faster, less safe)'),
              value: _noResponse,
              onChanged: (v) => setState(() => _noResponse = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Simulate range limit (for hop tests)'),
              subtitle: Text('Ignore peers weaker than $_rssiLimit dBm (smoothed), for both sending and receiving'),
              value: _rangeLimit,
              onChanged: (v) {
                setState(() => _rangeLimit = v);
                _add(v ? 'range limit ON at $_rssiLimit dBm' : 'range limit OFF');
                _syncRangeFilter();
              },
            ),
            if (_rangeLimit)
              Row(children: [
                const Text('-90'),
                Expanded(
                  child: Slider(
                    value: _rssiLimit.toDouble(),
                    min: -90,
                    max: -30,
                    divisions: 60,
                    label: '$_rssiLimit dBm',
                    onChanged: (v) => setState(() => _rssiLimit = v.round()),
                    onChangeEnd: (_) {
                      _add('range limit set to $_rssiLimit dBm');
                      _syncRangeFilter();
                    },
                  ),
                ),
                const Text('-30'),
              ]),
            Row(children: [
              const Text('Blob size  '),
              DropdownButton<int>(
                value: _blobSize,
                items: const [1024, 5 * 1024, 20 * 1024, 100 * 1024]
                    .map((s) => DropdownMenuItem(value: s, child: Text('${s ~/ 1024} KB')))
                    .toList(),
                onChanged: (v) => setState(() => _blobSize = v!),
              ),
            ]),
          ]),
          _section('Peers (${_livePeers.length} live)', [
            if (peers.isEmpty) const Text('None yet. Start the node on 2 or more phones.'),
            for (final p in peers) _peerTile(p),
          ]),
          _section('Log', [
            for (final l in _log.take(150))
              Text(l, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
          ]),
        ],
      ),
    );
  }

  Widget _peerTile(Peer p) {
    final age = DateTime.now().difference(p.lastSeen).inSeconds;
    final outOfRange = !_inRange(p);
    final stale = age > 10 || outOfRange;
    final avg = p.avgRssi?.round();
    return ListTile(
      contentPadding: EdgeInsets.zero,
      enabled: !stale,
      leading: Icon(outOfRange ? Icons.bluetooth_disabled : Icons.bluetooth,
          color: stale ? Colors.grey : Colors.teal),
      title: Text('${p.nodeId == null ? '(no scan response)' : 'node ${hex32(p.nodeId!)}'}'
          '${outOfRange ? '  (out of sim range)' : ''}'),
      subtitle: Text('${p.address} · ${p.rssi} dBm (avg $avg) · ${age}s ago'
          '${p.stateHash == null ? '' : ' · state ${hex32(p.stateHash!)}'}'
          '${p.stateHash != null && p.stateHash == _stateHash ? ' (in sync)' : ''}'),
      trailing: _busy.contains(p)
          ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
          : FilledButton.tonal(
              onPressed: stale || !_running ? null : () => _sendNew(p),
              child: Text('Send ${_blobSize ~/ 1024}K'),
            ),
    );
  }

  Widget _section(String title, List<Widget> children) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ...children,
          ]),
        ),
      );
}
