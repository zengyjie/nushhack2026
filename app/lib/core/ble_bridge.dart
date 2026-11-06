import 'package:flutter/services.dart';

/// Thin wrapper over the native Kotlin BLE engine (android/.../BleEngine.kt),
/// ported from ble_lab with the same channel shape.
class BleBridge {
  static const _methods = MethodChannel('mesh/methods');
  static const _events = EventChannel('mesh/events');

  Stream<Map<String, dynamic>>? _stream;

  /// Native events: `log`, `peer`, `serverConn`, `blob`.
  Stream<Map<String, dynamic>> get events => _stream ??= _events
      .receiveBroadcastStream()
      .map((e) => Map<String, dynamic>.from(e as Map));

  Future<bool> requestPermissions() async =>
      await _methods.invokeMethod<bool>('requestPermissions') ?? false;

  Future<Map<String, dynamic>> info() async => _map(await _methods.invokeMethod('info'));

  Future<void> startNode(int nodeId, int stateHash) =>
      _methods.invokeMethod('startNode', {'nodeId': nodeId, 'stateHash': stateHash});

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

  static Map<String, dynamic> _map(Object? o) =>
      o == null ? <String, dynamic>{} : Map<String, dynamic>.from(o as Map);
}

String hex32(int v) => v.toUnsigned(32).toRadixString(16).padLeft(8, '0');
