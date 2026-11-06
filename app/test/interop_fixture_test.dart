import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh/core/crypto.dart';
import 'package:mesh/core/records.dart';
import 'package:mesh/model/models.dart';

/// Writes a Dart-signed certificate and event for the HQ server's Python tests
/// (hq/tests/test_interop.py), so both sides are checked to agree byte for byte.
void main() {
  test('write interop fixture', () async {
    final kp = await Crypto.keyPairFromSeed(List.filled(32, 42));
    final cert = await Certificate.issue(
      uid: 'u-fixture',
      name: 'Fixture "Medic" – Ünïcode',
      roles: {Role.triage, Role.clinician},
      dev: '2a2a2a2a',
      publicKey: await Crypto.publicKeyOf(kp),
      validFor: const Duration(days: 3650),
    );
    final e = await SignedEvent.create(
      key: kp,
      uid: cert.uid,
      dev: cert.dev,
      seq: 1,
      prev: '',
      type: EventTypes.patientRegistered,
      data: {
        'pid': 'P-2A2A-01',
        'desc': 'Line one\nline "two" \\ tab\t SpO₂ 94% – émigré',
        'priority': 't1',
        'loc': 'Tent 1 · Bay A',
        'fac': 'FH North',
        'nested': {'z': [3, 2, 1], 'a': true, 'm': null},
      },
    );
    final out = File('../hq/tests/fixtures/dart_signed.json');
    out.parent.createSync(recursive: true);
    out.writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
      'cert': cert.toJson(),
      'event': e.toJson(),
      'canonical_body_b64': b64(canonicalJson(e.body)),
      'hq_public_key_b64': b64(await Crypto.hqPublicKey()),
    }));
  });
}
