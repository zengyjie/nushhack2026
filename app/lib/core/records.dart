import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../model/models.dart';
import 'crypto.dart';

/// Author ID and device ID used by events that HQ signs directly.
const hqId = 'hq';

/// Stock taking and supply requests are open to every role.
const inventoryPermissions = {EventTypes.stockCounted, EventTypes.stockAdjusted, EventTypes.supplyRequested};

/// What each role may sign. Every phone checks this on receipt as well as when creating.
const rolePermissions = <Role, Set<String>>{
  Role.triage: {
    EventTypes.patientRegistered,
    EventTypes.priorityChanged,
    EventTypes.observationAdded,
    ...inventoryPermissions,
  },
  Role.clinician: {
    EventTypes.diagnosisRecorded,
    EventTypes.remediationRecorded,
    EventTypes.followUpRecommended,
    ...inventoryPermissions,
  },
  Role.admin: {EventTypes.announcementPosted, EventTypes.messageSent, ...inventoryPermissions},
};

/// Events only HQ signs: acknowledgements, broadcasts, audit decisions and supply-request updates.
const hqPermissions = {
  EventTypes.hqAck,
  EventTypes.announcementPosted,
  EventTypes.conflictResolved,
  EventTypes.requestUpdated,
};

abstract class EventTypes {
  static const patientRegistered = 'PatientRegistered';
  static const priorityChanged = 'PriorityChanged';
  static const observationAdded = 'ObservationAdded';
  static const diagnosisRecorded = 'DiagnosisRecorded';
  static const remediationRecorded = 'RemediationRecorded';
  static const followUpRecommended = 'FollowUpRecommended';
  static const announcementPosted = 'AnnouncementPosted';
  static const messageSent = 'MessageSent';
  static const stockCounted = 'StockCounted';
  static const stockAdjusted = 'StockAdjusted';
  static const supplyRequested = 'SupplyRequested';
  static const hqAck = 'HqAck';
  static const conflictResolved = 'ConflictResolved';
  static const requestUpdated = 'RequestUpdated';
}

/// HQ-signed binding of a user ID, name, role and device to that person's public key.
class Certificate {
  Certificate(this.body, this.sig);

  final Map<String, dynamic> body;
  final String sig; // base64 HQ signature over canonicalJson(body)

  String get uid => body['uid'] as String;
  String get name => body['name'] as String;
  /// Roles granted by HQ. Older single-role certificates carry `role` instead of `roles`.
  Set<Role> get roles => {
        for (final r in (body['roles'] as List?)?.cast<String>() ?? [body['role'] as String]) Role.values.byName(r),
      };

  /// True if any of the holder's roles may sign [type].
  bool permits(String type) => roles.any((r) => rolePermissions[r]?.contains(type) ?? false);
  String get dev => body['dev'] as String;
  Uint8List get publicKey => unb64(body['pk'] as String);
  DateTime get issuedAt => DateTime.fromMillisecondsSinceEpoch(body['iat'] as int);
  DateTime get expiresAt => DateTime.fromMillisecondsSinceEpoch(body['exp'] as int);

  User get user => User(id: uid, name: name, roles: roles, deviceId: dev);

  Map<String, dynamic> toJson() => {...body, 'sig': sig};

  factory Certificate.fromJson(Map<String, dynamic> j) =>
      Certificate(Map<String, dynamic>.from(j)..remove('sig'), j['sig'] as String);

  /// Issues a demo certificate with the bundled HQ key (stands in for HQ or a delegate).
  static Future<Certificate> issue({
    required String uid,
    required String name,
    required Set<Role> roles,
    required String dev,
    required List<int> publicKey,
    Duration validFor = const Duration(hours: 72),
  }) async {
    final now = DateTime.now();
    final body = <String, dynamic>{
      'v': 1,
      'uid': uid,
      'name': name,
      'roles': [for (final r in Role.values.where(roles.contains)) r.name],
      'dev': dev,
      'pk': b64(publicKey),
      'iat': now.millisecondsSinceEpoch,
      'exp': now.add(validFor).millisecondsSinceEpoch,
    };
    final sig = await Crypto.sign(canonicalJson(body), await Crypto.hqKeyPair());
    return Certificate(body, b64(sig));
  }

  /// Checks HQ's signature and that the certificate was valid at [at] (default now).
  /// Returns null if valid, else the reason.
  Future<String?> check({DateTime? at, Duration skew = const Duration(minutes: 10)}) async {
    if (!await Crypto.verify(canonicalJson(body), unb64(sig), await Crypto.hqPublicKey())) {
      return 'certificate not signed by HQ';
    }
    final now = at ?? DateTime.now();
    if (now.isAfter(expiresAt.add(skew))) return 'certificate expired';
    if (now.isBefore(issuedAt.subtract(skew))) return 'certificate not yet valid';
    return null;
  }
}

/// One signed, hash-chained record. `id` is the SHA-256 of the canonical body,
/// and `prev` is the id of the same device's previous event.
class SignedEvent {
  SignedEvent(this.id, this.body, this.sig);

  final String id;
  final Map<String, dynamic> body;
  final String sig;

  String get uid => body['uid'] as String;
  String get dev => body['dev'] as String;
  int get seq => body['seq'] as int;
  String get prev => body['prev'] as String;
  DateTime get ts => DateTime.fromMillisecondsSinceEpoch(body['ts'] as int);
  String get type => body['type'] as String;
  Map<String, dynamic> get data => Map<String, dynamic>.from(body['data'] as Map);
  bool get fromHq => dev == hqId;

  /// 64-bit ID used for BLE blob dedupe and the beacon state hash.
  int get blobId {
    final b = fromHex(id.substring(0, 16));
    return ByteData.sublistView(b).getInt64(0);
  }

  Map<String, dynamic> toJson() => {'id': id, 'body': body, 'sig': sig};

  factory SignedEvent.fromJson(Map<String, dynamic> j) =>
      SignedEvent(j['id'] as String, Map<String, dynamic>.from(j['body'] as Map), j['sig'] as String);

  static Future<SignedEvent> create({
    required SimpleKeyPair key,
    required String uid,
    required String dev,
    required int seq,
    required String prev,
    required String type,
    required Map<String, dynamic> data,
  }) async {
    final body = <String, dynamic>{
      'v': 1,
      'uid': uid,
      'dev': dev,
      'seq': seq,
      'prev': prev,
      'ts': DateTime.now().millisecondsSinceEpoch,
      'type': type,
      'data': data,
    };
    final bytes = canonicalJson(body);
    return SignedEvent(await Crypto.sha256Hex(bytes), body, b64(await Crypto.sign(bytes, key)));
  }

  String encode() => jsonEncode(toJson());
}
