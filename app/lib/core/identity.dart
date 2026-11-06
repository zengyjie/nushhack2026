import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../model/models.dart';
import 'crypto.dart';
import 'records.dart';

/// This phone's signing key and certificate. The private key seed lives in
/// flutter_secure_storage (encrypted with an Android Keystore key) and is only
/// loaded after the PIN check.
class Identity {
  Identity._(this.cert, this.key);

  final Certificate cert;
  final SimpleKeyPair key;

  static const _store = FlutterSecureStorage();
  static const _kSeed = 'seed', _kCert = 'cert', _kPinSalt = 'pin_salt', _kPinHash = 'pin_hash';

  static Future<bool> exists() async => (await _store.read(key: _kCert)) != null;

  /// The stored certificate, readable before unlocking (for the lock screen).
  static Future<Certificate?> storedCertificate() async {
    final c = await _store.read(key: _kCert);
    return c == null ? null : Certificate.fromJson(jsonDecode(c) as Map<String, dynamic>);
  }

  static Future<Identity> enrol({required String name, required Set<Role> roles, required String pin}) async {
    final rng = Random.secure();
    final seed = List<int>.generate(32, (_) => rng.nextInt(256));
    final key = await Crypto.keyPairFromSeed(seed);
    final pub = await Crypto.publicKeyOf(key);
    final fp = await Crypto.sha256(pub);
    final cert = await Certificate.issue(
      uid: 'u-${toHex(List<int>.generate(4, (_) => rng.nextInt(256)))}',
      name: name,
      roles: roles,
      dev: toHex(fp.sublist(0, 4)), // device ID doubles as the BLE node ID
      publicKey: pub,
    );
    final salt = List<int>.generate(16, (_) => rng.nextInt(256));
    await _store.write(key: _kSeed, value: toHex(seed));
    await _store.write(key: _kCert, value: jsonEncode(cert.toJson()));
    await _store.write(key: _kPinSalt, value: toHex(salt));
    await _store.write(key: _kPinHash, value: await _pinHash(salt, pin));
    return Identity._(cert, key);
  }

  /// Returns null when the PIN is wrong.
  static Future<Identity?> unlock(String pin) async {
    final salt = await _store.read(key: _kPinSalt);
    final hash = await _store.read(key: _kPinHash);
    final seed = await _store.read(key: _kSeed);
    final cert = await storedCertificate();
    if (salt == null || hash == null || seed == null || cert == null) return null;
    if (await _pinHash(fromHex(salt), pin) != hash) return null;
    return Identity._(cert, await Crypto.keyPairFromSeed(fromHex(seed)));
  }

  static Future<void> wipe() => _store.deleteAll();

  static Future<String> _pinHash(List<int> salt, String pin) async =>
      Crypto.sha256Hex([...salt, ...utf8.encode(pin)]);
}
