"""End-to-end tests of /api/sync, verification, conflict detection and the audit downlink."""

import importlib
import os
import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from app import crypto as C  # noqa: E402
from simulate_cluster import Device  # noqa: E402

AUTH = {"Authorization": "Bearer test-token", "X-Auditor": "Tester"}


@pytest.fixture()
def client(tmp_path):
    os.environ["DATABASE_URL"] = f"sqlite:///{tmp_path / 'hq.db'}"
    os.environ["HQ_ADMIN_TOKEN"] = "test-token"
    import app.main as main

    importlib.reload(main)
    return TestClient(main.app)


def sync(client, d: Device, cursor=0):
    ts = C.now_ms()
    auth = {"cert": d.cert, "ts": ts, "sig": C.b64(d.key.sign(C.canonical({"dev": d.dev, "ts": ts})).signature)}
    r = client.post("/api/sync", json={"auth": auth, "events": d.outbox, "certs": [d.cert], "cursor": cursor,
                                       "facility": d.facility})
    return r


def register(d: Device, pid: str, priority: str, ident: str = "", fac: str | None = None):
    return d.sign("PatientRegistered", {"pid": pid, "desc": "x", "priority": priority, "loc": "Bay A",
                                        "fac": fac or d.facility, "name": "", "ident": ident})


def test_valid_events_are_acked_with_hq_signature(client):
    d = Device("A", ["triage"], "FH North")
    e = register(d, "P-1", "t1")
    r = sync(client, d)
    assert r.status_code == 200
    body = r.json()
    assert body["accepted"] == [e["id"]]
    ack = body["ack"]
    raw = C.canonical(ack["body"])
    assert C.sha256_hex(raw) == ack["id"]
    assert C.verify(raw, C.unb64(ack["sig"]), C.HQ_PUBLIC_KEY)
    assert ack["body"]["data"]["ids"] == [e["id"]]
    # Re-sending is idempotent and still acked.
    assert sync(client, d).json()["accepted"] == [e["id"]]


def test_tampered_and_unauthorised_events_are_rejected(client):
    d = Device("A", ["clinician"], "FH North")
    e = d.sign("PatientRegistered", {"pid": "P-1", "desc": "x", "priority": "t1", "loc": "", "fac": "FH North"})
    r = sync(client, d).json()
    assert r["rejected"][0]["reason"].startswith("roles ['clinician'] cannot sign")

    d2 = Device("B", ["triage"], "FH North")
    e2 = register(d2, "P-2", "t2")
    e2["body"]["data"]["priority"] = "t4"  # tampered after signing
    assert sync(client, d2).json()["rejected"][0]["reason"] == "hash mismatch"
    assert e["id"] not in client.get("/api/admin/feed", headers=AUTH).text


def test_gateway_must_prove_its_key(client):
    d = Device("A", ["triage"], "FH North")
    other = Device("B", ["triage"], "FH North")
    ts = C.now_ms()
    auth = {"cert": d.cert, "ts": ts, "sig": C.b64(other.key.sign(C.canonical({"dev": d.dev, "ts": ts})).signature)}
    r = client.post("/api/sync", json={"auth": auth, "events": [], "certs": [], "cursor": 0})
    assert r.status_code == 403


def test_out_of_order_events_wait_for_their_predecessor(client):
    d = Device("A", ["triage"], "FH North")
    e1 = register(d, "P-1", "t1")
    e2 = d.sign("ObservationAdded", {"pid": "P-1", "text": "ok", "fields": {}, "fac": "FH North"})
    d.outbox = [e2]
    assert sync(client, d).json()["pending"] == [e2["id"]]
    d.outbox = [e1]
    assert set(sync(client, d).json()["accepted"]) == {e1["id"], e2["id"]}


def test_conflicts_are_flagged_and_resolution_is_sent_down(client):
    north = Device("N", ["triage"], "FH North")
    south = Device("S", ["triage"], "FH South")
    register(north, "P-1", "t1", ident="S123")
    sync(client, north)
    south.sign("PriorityChanged", {"pid": "P-1", "from": "t1", "to": "t3", "fac": "FH North"})
    register(south, "P-2", "t2", ident="s123 ")  # same person, other venue
    sync(client, south)

    conflicts = client.get("/api/admin/conflicts", headers=AUTH).json()
    kinds = sorted(c["kind"] for c in conflicts)
    assert kinds == ["triage", "venue"]

    triage = next(c for c in conflicts if c["kind"] == "triage")
    r = client.post(f"/api/admin/conflicts/{triage['id']}/resolve", json={"decision": "a", "note": "kept T1"},
                    headers=AUTH)
    assert r.status_code == 200
    assert client.post(f"/api/admin/conflicts/{triage['id']}/resolve", json={"decision": "b"},
                       headers=AUTH).status_code == 409

    p1 = next(p for p in client.get("/api/admin/patients", headers=AUTH).json() if p["pid"] == "P-1")
    assert p1["priority"] == "t1"

    down = sync(client, north).json()["down"]
    res = next(e for e in down if e["body"]["type"] == "ConflictResolved")
    assert res["body"]["data"]["void"] == [triage["events"][1]]
    assert C.verify(C.canonical(res["body"]), C.unb64(res["sig"]), C.HQ_PUBLIC_KEY)


def test_admin_api_needs_token(client):
    assert client.get("/api/admin/overview").status_code == 401
    assert client.post("/api/admin/announcements", json={"title": "t", "body": "b"}).status_code == 401
