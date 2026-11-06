import 'package:flutter_test/flutter_test.dart';
import 'package:mesh/core/crypto.dart';
import 'package:mesh/core/records.dart';
import 'package:mesh/model/models.dart';

void main() {
  test('canonical JSON sorts keys at every level', () {
    final a = canonicalJson({'b': 1, 'a': {'d': [1, 2], 'c': 'x'}});
    final b = canonicalJson({'a': {'c': 'x', 'd': [1, 2]}, 'b': 1});
    expect(a, b);
    expect(String.fromCharCodes(a), '{"a":{"c":"x","d":[1,2]},"b":1}');
  });

  test('HQ-issued certificate verifies, and a forged one does not', () async {
    final kp = await Crypto.keyPairFromSeed(List.filled(32, 7));
    final pub = await Crypto.publicKeyOf(kp);
    final cert = await Certificate.issue(uid: 'u-1', name: 'Test', roles: {Role.triage}, dev: 'aabbccdd', publicKey: pub);
    expect(await cert.check(), isNull);

    // Same body with the role raised: HQ signature no longer matches.
    final forged = Certificate({...cert.body, 'roles': [Role.triage.name, Role.admin.name]}, cert.sig);
    expect(await forged.check(), 'certificate not signed by HQ');

    // Round-trips through JSON.
    expect(await Certificate.fromJson(cert.toJson()).check(), isNull);
  });

  test('expired certificate is rejected', () async {
    final kp = await Crypto.keyPairFromSeed(List.filled(32, 8));
    final cert = await Certificate.issue(
      uid: 'u-2',
      name: 'Old',
      roles: {Role.clinician},
      dev: '01020304',
      publicKey: await Crypto.publicKeyOf(kp),
      validFor: const Duration(hours: -1),
    );
    expect(await cert.check(), 'certificate expired');
  });

  test('certificate validity is judged at the event time', () async {
    final kp = await Crypto.keyPairFromSeed(List.filled(32, 10));
    final cert = await Certificate.issue(
        uid: 'u-4', name: 'Now', roles: {Role.admin}, dev: '05060708', publicKey: await Crypto.publicKeyOf(kp));
    expect(await cert.check(at: DateTime.now().add(const Duration(hours: 1))), isNull);
    expect(await cert.check(at: DateTime.now().add(const Duration(hours: 80))), 'certificate expired');
  });

  test('event id is the body hash and the author signature verifies', () async {
    final kp = await Crypto.keyPairFromSeed(List.filled(32, 9));
    final pub = await Crypto.publicKeyOf(kp);
    final e = await SignedEvent.create(
      key: kp,
      uid: 'u-3',
      dev: '0a0b0c0d',
      seq: 1,
      prev: '',
      type: EventTypes.patientRegistered,
      data: {'pid': 'P-0A0B-01', 'desc': 'x', 'priority': 't1', 'loc': 'Holding'},
    );
    final bytes = canonicalJson(e.body);
    expect(await Crypto.sha256Hex(bytes), e.id);
    expect(await Crypto.verify(bytes, unb64(e.sig), pub), isTrue);

    // Tampering with the payload breaks both the hash and the signature.
    final tampered = SignedEvent.fromJson(e.toJson())..body['data'] = {'pid': 'P-0A0B-01', 'desc': 'changed'};
    final tb = canonicalJson(tampered.body);
    expect(await Crypto.sha256Hex(tb), isNot(e.id));
    expect(await Crypto.verify(tb, unb64(e.sig), pub), isFalse);

    // Wire round trip keeps the 64-bit blob ID stable.
    expect(SignedEvent.fromJson(e.toJson()).blobId, e.blobId);
  });

  test('a certificate with several roles permits the union of their actions', () async {
    final kp = await Crypto.keyPairFromSeed(List.filled(32, 11));
    final cert = await Certificate.issue(
        uid: 'u-5', name: 'Both', roles: {Role.clinician, Role.triage}, dev: '0d0e0f10', publicKey: await Crypto.publicKeyOf(kp));
    expect(await Certificate.fromJson(cert.toJson()).check(), isNull);
    expect(cert.roles, {Role.triage, Role.clinician});
    expect(cert.body['roles'], ['triage', 'clinician']); // stable order for signing
    expect(cert.permits(EventTypes.observationAdded), isTrue);
    expect(cert.permits(EventTypes.diagnosisRecorded), isTrue);
    expect(cert.permits(EventTypes.announcementPosted), isFalse);
  });

  test('role permissions match the three roles', () {
    expect(rolePermissions[Role.triage], contains(EventTypes.observationAdded));
    expect(rolePermissions[Role.triage], isNot(contains(EventTypes.announcementPosted)));
    expect(rolePermissions[Role.clinician], contains(EventTypes.remediationRecorded));
    expect(rolePermissions[Role.admin], {EventTypes.announcementPosted, EventTypes.messageSent});
  });
}
