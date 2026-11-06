import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mesh/core/crypto.dart';
import 'package:mesh/core/hq_client.dart';
import 'package:mesh/core/records.dart';
import 'package:mesh/model/models.dart';

/// Drives the app's real HqClient against a running HQ server.
/// Skipped unless HQ_URL is set, e.g.:
///   HQ_URL=http://localhost:8010 HQ_TOKEN=test-token flutter test test/hq_sync_integration_test.dart
void main() {
  final base = Platform.environment['HQ_URL'];
  final token = Platform.environment['HQ_TOKEN'] ?? 'test-token';

  Future<(Certificate, dynamic)> device(String name, Set<Role> roles, int seed) async {
    final kp = await Crypto.keyPairFromSeed(List.generate(32, (i) => (i * 7 + seed) % 256));
    final pub = await Crypto.publicKeyOf(kp);
    final dev = toHex((await Crypto.sha256(pub)).sublist(0, 4));
    final cert = await Certificate.issue(
        uid: 'u-it-$dev-${DateTime.now().millisecondsSinceEpoch}', name: name, roles: roles, dev: dev, publicKey: pub);
    return (cert, kp);
  }

  test('app HqClient syncs, gets an HQ-signed ack, and HQ flags a triage conflict', () async {
    final seed = DateTime.now().millisecondsSinceEpoch % 200;
    final (aCert, aKey) = await device('IT Triage A', {Role.triage}, seed);
    final (bCert, bKey) = await device('IT Triage B', {Role.triage, Role.clinician}, seed + 13);
    final pid = 'P-${aCert.dev.substring(0, 4).toUpperCase()}-IT';

    final reg = await SignedEvent.create(
      key: aKey, uid: aCert.uid, dev: aCert.dev, seq: 1, prev: '',
      type: EventTypes.patientRegistered,
      data: {'pid': pid, 'desc': 'Integration test', 'priority': 't1', 'loc': 'Bay 1', 'fac': 'IT North', 'name': '', 'ident': ''},
    );
    final stock = await SignedEvent.create(
      key: aKey, uid: aCert.uid, dev: aCert.dev, seq: 2, prev: reg.id,
      type: EventTypes.stockCounted,
      data: {'item': 'IT gauze', 'category': 'supply', 'qty': 3, 'unit': 'pcs', 'min': 5, 'fac': 'IT North'},
    );
    final r1 = await HqClient.sync(
        baseUrl: base!, cert: aCert, key: aKey, events: [reg, stock], certs: [aCert], cursor: 0, facility: 'IT North');
    expect(r1.rejected, isEmpty);
    expect(r1.ack, isNotNull);
    final ack = r1.ack!;
    expect(ack.fromHq, isTrue);
    expect(await Crypto.sha256Hex(canonicalJson(ack.body)), ack.id);
    expect(await Crypto.verify(canonicalJson(ack.body), unb64(ack.sig), await Crypto.hqPublicKey()), isTrue);
    expect((ack.data['ids'] as List), containsAll([reg.id, stock.id]));

    // A second device sets a different priority within the window: HQ should flag it.
    final change = await SignedEvent.create(
      key: bKey, uid: bCert.uid, dev: bCert.dev, seq: 1, prev: '',
      type: EventTypes.priorityChanged,
      data: {'pid': pid, 'from': 't1', 'to': 't3', 'fac': 'IT North'},
    );
    final r2 = await HqClient.sync(
        baseUrl: base, cert: bCert, key: bKey, events: [change], certs: [bCert], cursor: r1.cursor, facility: 'IT North');
    expect(r2.rejected, isEmpty);

    final res = await http.get(Uri.parse('$base/api/admin/conflicts'), headers: {'Authorization': 'Bearer $token'});
    final conflicts = (jsonDecode(res.body) as List).cast<Map<String, dynamic>>();
    expect(conflicts.any((c) => c['kind'] == 'triage' && (c['summary'] as String).contains(pid)), isTrue);
  }, skip: base == null ? 'set HQ_URL to run against a live HQ server' : null);
}
