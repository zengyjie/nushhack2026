import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

import 'crypto.dart';
import 'records.dart';

class HqSyncResult {
  HqSyncResult({required this.ack, required this.down, required this.cursor, required this.rejected, required this.pending});

  /// HQ-signed acknowledgement of everything HQ now holds (null if nothing new).
  final SignedEvent? ack;

  /// HQ-signed events this phone hadn't pulled yet: broadcasts, audit decisions, request updates.
  final List<SignedEvent> down;
  final int cursor;
  final Map<String, String> rejected; // event id → reason
  final int pending;
}

/// ON layer: talks to the HQ server's /api/sync (hq/app/main.py).
class HqClient {
  static const batch = 300;

  static Future<HqSyncResult> sync({
    required String baseUrl,
    required Certificate cert,
    required SimpleKeyPair key,
    required List<SignedEvent> events,
    required Iterable<Certificate> certs,
    required int cursor,
    required String facility,
  }) async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final sig = await Crypto.sign(canonicalJson({'dev': cert.dev, 'ts': ts}), key);
    final body = jsonEncode({
      'auth': {'cert': cert.toJson(), 'ts': ts, 'sig': b64(sig)},
      'events': [for (final e in events.take(batch)) e.toJson()],
      'certs': [for (final c in certs) c.toJson()],
      'cursor': cursor,
      'facility': facility,
    });
    final res = await http
        .post(Uri.parse('$baseUrl/api/sync'), headers: {'Content-Type': 'application/json'}, body: body)
        .timeout(const Duration(seconds: 25));
    if (res.statusCode != 200) {
      var detail = res.reasonPhrase ?? 'HTTP ${res.statusCode}';
      try {
        detail = (jsonDecode(res.body) as Map)['detail']?.toString() ?? detail;
      } catch (_) {}
      throw HqException('HQ refused sync (${res.statusCode}): $detail');
    }
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return HqSyncResult(
      ack: j['ack'] == null ? null : SignedEvent.fromJson(Map<String, dynamic>.from(j['ack'] as Map)),
      down: [for (final e in (j['down'] as List)) SignedEvent.fromJson(Map<String, dynamic>.from(e as Map))],
      cursor: j['cursor'] as int,
      rejected: {
        for (final r in (j['rejected'] as List)) (r as Map)['id'] as String: r['reason'] as String,
      },
      pending: (j['pending'] as List).length,
    );
  }
}

class HqException implements Exception {
  HqException(this.message);
  final String message;
  @override
  String toString() => message;
}
