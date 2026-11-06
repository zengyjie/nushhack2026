import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Ed25519 signatures and SHA-256 hashing over canonical JSON.
final _ed = Ed25519();
final _sha = Sha256();

/// Demo trust root. In production only HQ holds this seed, and phones ship
/// with just the public key. Here every build carries it so a phone can issue
/// its own demo certificate at enrolment (standing in for an HQ delegate).
const _hqDemoSeedHex = '38bd23a664849492f85d9c72e79901c1b62a856dda6f8a0696e43e9df667d924';

class Crypto {
  static SimpleKeyPair? _hq;
  static Uint8List? _hqPub;

  static Future<SimpleKeyPair> hqKeyPair() async => _hq ??= await _ed.newKeyPairFromSeed(fromHex(_hqDemoSeedHex));

  static Future<Uint8List> hqPublicKey() async =>
      _hqPub ??= Uint8List.fromList((await (await hqKeyPair()).extractPublicKey()).bytes);

  static Future<SimpleKeyPair> keyPairFromSeed(List<int> seed) => _ed.newKeyPairFromSeed(seed);

  static Future<Uint8List> publicKeyOf(SimpleKeyPair kp) async =>
      Uint8List.fromList((await kp.extractPublicKey()).bytes);

  static Future<Uint8List> sign(List<int> message, SimpleKeyPair kp) async =>
      Uint8List.fromList((await _ed.sign(message, keyPair: kp)).bytes);

  static Future<bool> verify(List<int> message, List<int> signature, List<int> publicKey) async {
    if (signature.length != 64 || publicKey.length != 32) return false;
    try {
      return await _ed.verify(
        message,
        signature: Signature(signature, publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519)),
      );
    } catch (_) {
      return false;
    }
  }

  static Future<Uint8List> sha256(List<int> data) async => Uint8List.fromList((await _sha.hash(data)).bytes);

  static Future<String> sha256Hex(List<int> data) async => toHex(await sha256(data));
}

/// Deterministic JSON: object keys sorted at every level, no whitespace.
/// Signatures are computed over these bytes, so every phone must produce the same output.
Uint8List canonicalJson(Object? value) => Uint8List.fromList(utf8.encode(_canon(value)));

String _canon(Object? v) {
  if (v is Map) {
    final keys = v.keys.map((k) => k.toString()).toList()..sort();
    return '{${keys.map((k) => '${jsonEncode(k)}:${_canon(v[k])}').join(',')}}';
  }
  if (v is List) return '[${v.map(_canon).join(',')}]';
  return jsonEncode(v);
}

String toHex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List fromHex(String h) =>
    Uint8List.fromList([for (var i = 0; i + 1 < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);

String b64(List<int> b) => base64Encode(b);
Uint8List unb64(String s) => base64Decode(s);
