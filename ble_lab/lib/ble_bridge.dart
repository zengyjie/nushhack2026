
import 'package:flutter/services.dart';

/// Thin wrapper over the native Kotlin BLE engine (android/.../BleLab.kt).
///
/// The same method/event channel shape is what Phase 3 will put behind the
/// real transport interface, so keep it small and boring.
class BleBridge {
  static const _methods = MethodChannel('ble_lab/methods');
  static const _events = EventChannel('ble_lab/events');

  Stream<Map<String, dynamic>>? _stream;

  /// Native events: `log`, `peer`, `serverConn`, `blob`.
  Stream<Map<String, dynamic>> get events => _stream ??= _events
      .receiveBroadcastStream()
      .map((e) => Map<String, dynamic>.from(e as Map));

  Future<bool> requestPermissions() async =>
      await _methods.invokeMethod<bool>('requestPermissions') ?? false;

  Future<Map<String, dynamic>> info() async => _map(await _methods.invokeMethod('info'));

  Future<void> startNode(int stateHash) =>
      _methods.invokeMethod('startNode', {'stateHash': stateHash});

  Future<void> stopNode() => _methods.invokeMethod('stopNode');

  Future<void> updateBeacon(int stateHash) =>
      _methods.invokeMethod('updateBeacon', {'stateHash': stateHash});

  Future<Map<String, dynamic>> sendBlob({
    required String address,
    required Uint8List bytes,
    required int blobId,
    required int origin,
    bool noResponse = false,
  }) async =>
      _map(await _methods.invokeMethod('sendBlob', {
        'address': address,
        'bytes': bytes,
        'blobId': blobId,
        'origin': origin,
        'noResponse': noResponse,
      }));

  /// When [enabled], the native server rejects blobs from senders not in [allowed].
  Future<void> setRangeFilter(bool enabled, List<int> allowed) =>
      _methods.invokeMethod('setRangeFilter', {'enabled': enabled, 'allowed': allowed});

  Future<Map<String, dynamic>> testExtendedAdvertising() async =>
      _map(await _methods.invokeMethod('testExtendedAdvertising'));

  Future<Map<String, dynamic>> testMultiAdvertising(int count) async =>
      _map(await _methods.invokeMethod('testMultiAdvertising', {'count': count}));

  Future<Map<String, dynamic>> testConnectAll(List<String> addresses, {int holdMs = 6000}) async =>
      _map(await _methods.invokeMethod('testConnectAll', {'addresses': addresses, 'holdMs': holdMs}));

  static Map<String, dynamic> _map(Object? o) =>
      o == null ? <String, dynamic>{} : Map<String, dynamic>.from(o as Map);
}

String hex32(int v) => v.toUnsigned(32).toRadixString(16).padLeft(8, '0');
