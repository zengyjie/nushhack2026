"""Checks the server agrees with the app byte for byte (fixture written by app/test/interop_fixture_test.dart)."""

import json
from pathlib import Path

from app import crypto as C

FIXTURE = json.loads((Path(__file__).parent / "fixtures" / "dart_signed.json").read_text(encoding="utf-8"))


def test_same_hq_key():
    assert C.b64(C.HQ_PUBLIC_KEY) == FIXTURE["hq_public_key_b64"]


def test_canonical_json_matches_dart():
    assert C.canonical(FIXTURE["event"]["body"]) == C.unb64(FIXTURE["canonical_body_b64"])


def test_dart_event_hash_and_signature_verify():
    ev, cert = FIXTURE["event"], FIXTURE["cert"]
    raw = C.canonical(ev["body"])
    assert C.sha256_hex(raw) == ev["id"]
    assert C.verify(raw, C.unb64(ev["sig"]), C.unb64(cert["pk"]))


def test_dart_certificate_verifies_against_hq_key():
    cert = dict(FIXTURE["cert"])
    sig = cert.pop("sig")
    assert C.verify(C.canonical(cert), C.unb64(sig), C.HQ_PUBLIC_KEY)
