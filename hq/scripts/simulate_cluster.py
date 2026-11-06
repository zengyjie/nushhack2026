"""Test harness: acts like uplink phones and posts signed events to an HQ server.

It signs exactly as the app does (same canonical JSON, Ed25519, hash chain), so it exercises
the real /api/sync path, verification and conflict detection without needing phones.

    python scripts/simulate_cluster.py http://localhost:8000
    python scripts/simulate_cluster.py https://<name>.trycloudflare.com --scenario conflicts

Scenarios: basic (patients, notes, stock, a request), conflicts (adds one of each conflict kind),
pull (just syncs and prints what HQ sends down, e.g. broadcasts and audit decisions).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.request

from nacl.signing import SigningKey

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from app import crypto as C  # noqa: E402


class Device:
    def __init__(self, name: str, roles: list[str], facility: str):
        self.key = SigningKey.generate()
        pub = self.key.verify_key.encode()
        self.dev = C.sha256_hex(pub)[:8]
        self.cert = C.issue_certificate(f"u-sim-{self.dev}", name, roles, self.dev, pub)
        self.facility = facility
        self.seq = 0
        self.prev = ""
        self.outbox: list[dict] = []
        self.cursor = 0
        self.n = 0

    def sign(self, type_: str, data: dict, ts_offset_s: int = 0) -> dict:
        self.seq += 1
        body = {"v": 1, "uid": self.cert["uid"], "dev": self.dev, "seq": self.seq, "prev": self.prev,
                "ts": C.now_ms() + ts_offset_s * 1000, "type": type_, "data": data}
        raw = C.canonical(body)
        ev = {"id": C.sha256_hex(raw), "body": body, "sig": C.b64(self.key.sign(raw).signature)}
        self.prev = ev["id"]
        self.outbox.append(ev)
        return ev

    def new_pid(self) -> str:
        self.n += 1
        return f"P-{self.dev[:4].upper()}-{self.n:02d}"

    def sync(self, base: str) -> dict:
        ts = C.now_ms()
        auth = {"cert": self.cert, "ts": ts, "sig": C.b64(self.key.sign(C.canonical({"dev": self.dev, "ts": ts})).signature)}
        req = {"auth": auth, "events": self.outbox, "certs": [self.cert], "cursor": self.cursor, "facility": self.facility}
        r = urllib.request.Request(f"{base}/api/sync", data=json.dumps(req).encode(),
                                   headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(r, timeout=20) as resp:
            out = json.loads(resp.read())
        acked = set(out["accepted"])
        self.outbox = [e for e in self.outbox if e["id"] not in acked]
        self.cursor = out["cursor"]
        print(f"  {self.cert['name']:<22} sent, {len(acked)} acked, {len(out['rejected'])} rejected, "
              f"{len(out['pending'])} pending, {len(out['down'])} down")
        for r in out["rejected"]:
            print(f"    rejected {r['id'][:10]}: {r['reason']}")
        for d in out["down"]:
            print(f"    down: {d['body']['type']} {json.dumps(d['body']['data'])[:90]}")
        return out


def basic(base: str, north: Device, south: Device, medic: Device):
    p1 = north.new_pid()
    north.sign("PatientRegistered", {"pid": p1, "desc": "Blast injury, left leg. Tourniquet applied.",
                                     "priority": "t1", "loc": "Tent 1 · Bay A", "fac": north.facility,
                                     "name": "Cpl R. Tan", "ident": "S1234567A"})
    north.sign("ObservationAdded", {"pid": p1, "text": "Pale, clammy. Tourniquet 0912.",
                                    "fields": {"HR": "128", "BP": "92/58", "SpO₂": "94%"}, "fac": north.facility})
    medic.sign("DiagnosisRecorded", {"pid": p1, "text": "Open tibial fracture with arterial bleed.",
                                     "fields": {}, "fac": north.facility})
    medic.sign("RemediationRecorded", {"pid": p1, "text": "Wound packed and splinted. TXA 1 g IV.",
                                       "fields": {"Meds": "TXA 1 g IV"}, "fac": north.facility})
    p2 = south.new_pid()
    south.sign("PatientRegistered", {"pid": p2, "desc": "Burns to forearms, ~9% TBSA.", "priority": "t2",
                                     "loc": "Tent 2 · Bay C", "fac": south.facility, "name": "Pte A. Lim",
                                     "ident": "S7654321B"})
    north.sign("StockCounted", {"item": "Tourniquet (CAT)", "category": "supply", "qty": 14, "unit": "pcs",
                                "min": 10, "fac": north.facility})
    north.sign("StockCounted", {"item": "O-neg blood", "category": "supply", "qty": 4, "unit": "units",
                                "min": 6, "fac": north.facility})
    north.sign("StockAdjusted", {"item": "Tourniquet (CAT)", "delta": -2, "reason": "Used", "fac": north.facility})
    south.sign("StockCounted", {"item": "Portable ultrasound", "category": "equipment", "qty": 1, "unit": "units",
                                "min": 1, "fac": south.facility})
    north.sign("SupplyRequested", {"rid": f"R-{north.dev[:4].upper()}-01", "item": "O-neg blood", "qty": 10,
                                   "unit": "units", "urgency": "urgent", "note": "Two T1 casualties expected",
                                   "fac": north.facility})
    for d in (north, medic, south):
        d.sync(base)
    return p1, p2


def conflicts(base: str, north: Device, south: Device, medic: Device, p1: str, p2: str):
    # Conflicting triage: a second device sets a different priority for p1 within the window.
    south.sign("PriorityChanged", {"pid": p1, "from": "t1", "to": "t3", "fac": north.facility})
    # Patient at two venues: the south facility reports a diagnosis on p1.
    medic_south = Device("Lt (Dr) Sim South", ["clinician"], south.facility)
    medic_south.sign("DiagnosisRecorded", {"pid": p1, "text": "Assessed in Tent 2: closed fracture only.", "fields": {},
                                          "fac": south.facility})
    # Same ID tag registered again at another facility.
    p3 = south.new_pid()
    south.sign("PatientRegistered", {"pid": p3, "desc": "Leg wound, ambulatory.", "priority": "t3",
                                     "loc": "Holding", "fac": south.facility, "name": "Cpl R. Tan",
                                     "ident": "S1234567A"})
    for d in (south, medic_south):
        d.sync(base)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("base", help="HQ server URL, e.g. http://localhost:8000")
    ap.add_argument("--scenario", default="all", choices=["basic", "conflicts", "all", "pull"])
    a = ap.parse_args()
    base = a.base.rstrip("/")
    north = Device("Sgt Sim North (triage)", ["triage", "admin"], "FH North")
    south = Device("Cpl Sim South (triage)", ["triage"], "FH South")
    medic = Device("Cpt (Dr) Sim North", ["clinician"], "FH North")
    print(f"HQ: {base}")
    if a.scenario == "pull":
        north.sync(base)
        return
    p1, p2 = basic(base, north, south, medic)
    if a.scenario in ("conflicts", "all"):
        time.sleep(0.5)
        conflicts(base, north, south, medic, p1, p2)
    print("done")


if __name__ == "__main__":
    main()
