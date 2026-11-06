"""Ed25519 + SHA-256 over canonical JSON, byte-compatible with the app (app/lib/core/crypto.dart)."""

from __future__ import annotations

import base64
import hashlib
import json
import os
import time
from typing import Any

from nacl.exceptions import BadSignatureError
from nacl.signing import SigningKey, VerifyKey

# Same demo seed as the app. Override with HQ_SEED_HEX in production (and rebuild the app with
# the matching public key once enrolment moves to HQ).
DEMO_SEED_HEX = "38bd23a664849492f85d9c72e79901c1b62a856dda6f8a0696e43e9df667d924"

_hq_key = SigningKey(bytes.fromhex(os.environ.get("HQ_SEED_HEX") or DEMO_SEED_HEX))
HQ_PUBLIC_KEY = _hq_key.verify_key.encode()

HQ_ID = "hq"


def canonical(value: Any) -> bytes:
    """Keys sorted at every level, no whitespace, UTF-8. Matches canonicalJson() in Dart."""
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def b64(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


def unb64(s: str) -> bytes:
    return base64.b64decode(s)


def verify(message: bytes, signature: bytes, public_key: bytes) -> bool:
    if len(signature) != 64 or len(public_key) != 32:
        return False
    try:
        VerifyKey(public_key).verify(message, signature)
        return True
    except (BadSignatureError, ValueError):
        return False


def hq_sign(message: bytes) -> bytes:
    return _hq_key.sign(message).signature


def now_ms() -> int:
    return int(time.time() * 1000)


def make_hq_event(type_: str, data: dict) -> dict:
    """An event signed by HQ itself (no certificate, no chain), as the app expects."""
    body = {"v": 1, "uid": HQ_ID, "dev": HQ_ID, "seq": 0, "prev": "", "ts": now_ms(), "type": type_, "data": data}
    raw = canonical(body)
    return {"id": sha256_hex(raw), "body": body, "sig": b64(hq_sign(raw))}


def issue_certificate(uid: str, name: str, roles: list[str], dev: str, public_key: bytes, hours: int = 72) -> dict:
    """Used by the cluster simulator and tests. Phones issue their own demo certificates."""
    now = now_ms()
    body = {
        "v": 1,
        "uid": uid,
        "name": name,
        "roles": roles,
        "dev": dev,
        "pk": b64(public_key),
        "iat": now,
        "exp": now + hours * 3600 * 1000,
    }
    return {**body, "sig": b64(hq_sign(canonical(body)))}
