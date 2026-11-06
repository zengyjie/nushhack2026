"""HQ store: durable event log (PostgreSQL or SQLite), offline-equivalent verification,
conflict detection, auditor resolutions, and the read models behind the web app."""

from __future__ import annotations

import json
import os
import sqlite3
import threading
import time
from typing import Any

from . import crypto as C

# ---------------------------------------------------------------------- event types

PATIENT_REGISTERED = "PatientRegistered"
PRIORITY_CHANGED = "PriorityChanged"
OBSERVATION_ADDED = "ObservationAdded"
DIAGNOSIS_RECORDED = "DiagnosisRecorded"
REMEDIATION_RECORDED = "RemediationRecorded"
FOLLOW_UP_RECOMMENDED = "FollowUpRecommended"
ANNOUNCEMENT_POSTED = "AnnouncementPosted"
MESSAGE_SENT = "MessageSent"
STOCK_COUNTED = "StockCounted"
STOCK_ADJUSTED = "StockAdjusted"
SUPPLY_REQUESTED = "SupplyRequested"
HQ_ACK = "HqAck"
CONFLICT_RESOLVED = "ConflictResolved"
REQUEST_UPDATED = "RequestUpdated"

INVENTORY = {STOCK_COUNTED, STOCK_ADJUSTED, SUPPLY_REQUESTED}
ROLE_PERMISSIONS = {
    "triage": {PATIENT_REGISTERED, PRIORITY_CHANGED, OBSERVATION_ADDED} | INVENTORY,
    "clinician": {DIAGNOSIS_RECORDED, REMEDIATION_RECORDED, FOLLOW_UP_RECOMMENDED} | INVENTORY,
    "admin": {ANNOUNCEMENT_POSTED, MESSAGE_SENT} | INVENTORY,
}
HQ_PERMISSIONS = {HQ_ACK, ANNOUNCEMENT_POSTED, CONFLICT_RESOLVED, REQUEST_UPDATED}

PATIENT_EVENTS = {
    PATIENT_REGISTERED,
    PRIORITY_CHANGED,
    OBSERVATION_ADDED,
    DIAGNOSIS_RECORDED,
    REMEDIATION_RECORDED,
    FOLLOW_UP_RECOMMENDED,
}

ENTRY_LABELS = {
    PATIENT_REGISTERED: "Registered",
    PRIORITY_CHANGED: "Priority changed",
    OBSERVATION_ADDED: "Clinical observation",
    DIAGNOSIS_RECORDED: "Diagnosis",
    REMEDIATION_RECORDED: "Remediation performed",
    FOLLOW_UP_RECOMMENDED: "Recommended follow-up",
}

PRIORITY = {"t1": "T1 Immediate", "t2": "T2 Delayed", "t3": "T3 Minimal", "t4": "T4 Expectant"}
ROLE_LABELS = {"triage": "Triage", "clinician": "Diagnosis & treatment", "admin": "Admin"}
SKEW_MS = 10 * 60 * 1000


def _roles(cert: dict) -> list[str]:
    return list(cert.get("roles") or [cert["role"]])


def _norm(s: str | None) -> str:
    return " ".join((s or "").lower().split())


# ---------------------------------------------------------------------- database


class DB:
    """Tiny wrapper so the same SQL runs on SQLite (local dev) and PostgreSQL (Docker)."""

    def __init__(self, url: str):
        if url.startswith("sqlite:///"):
            path = url[len("sqlite:///"):]
            os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
            self.conn = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
            self.kind = "sqlite"
            serial = "INTEGER PRIMARY KEY AUTOINCREMENT"
        else:
            import psycopg  # only needed for PostgreSQL

            last: Exception | None = None
            for _ in range(60):  # wait for the database container to come up
                try:
                    self.conn = psycopg.connect(url, autocommit=True)
                    break
                except Exception as e:  # noqa: BLE001
                    last = e
                    time.sleep(1)
            else:
                raise RuntimeError(f"cannot connect to database: {last}")
            self.kind = "pg"
            serial = "BIGSERIAL PRIMARY KEY"
        for ddl in (
            "CREATE TABLE IF NOT EXISTS certs (uid TEXT PRIMARY KEY, json TEXT NOT NULL)",
            "CREATE TABLE IF NOT EXISTS events (id TEXT PRIMARY KEY, json TEXT NOT NULL, "
            "received_at BIGINT NOT NULL, gateway TEXT)",
            f"CREATE TABLE IF NOT EXISTS downlink (seq {serial}, id TEXT UNIQUE NOT NULL, json TEXT NOT NULL)",
            "CREATE TABLE IF NOT EXISTS gateways (dev TEXT PRIMARY KEY, json TEXT NOT NULL)",
            f"CREATE TABLE IF NOT EXISTS conflicts (id {serial}, json TEXT NOT NULL)",
        ):
            self.q(ddl)

    def q(self, sql: str, params: tuple = ()):
        if self.kind == "pg":
            sql = sql.replace("?", "%s")
        return self.conn.execute(sql, params)

    def upsert(self, table: str, key: str, value: str, json_text: str):
        self.q(
            f"INSERT INTO {table} ({key}, json) VALUES (?, ?) "
            f"ON CONFLICT ({key}) DO UPDATE SET json = excluded.json",
            (value, json_text),
        )


# ---------------------------------------------------------------------- store


class Store:
    def __init__(self, db_url: str, conflict_window_min: int = 10, venue_window_h: int = 12):
        self.db = DB(db_url)
        self.lock = threading.RLock()
        self.window_ms = conflict_window_min * 60 * 1000
        self.venue_window_ms = venue_window_h * 3600 * 1000

        self.events: dict[str, dict] = {}  # id -> {id, body, sig, received_at, gateway}
        self.order: list[str] = []  # arrival order
        self.certs: dict[str, dict] = {}  # uid -> cert
        self.heads: dict[str, tuple[int, str]] = {}  # dev -> (seq, id)
        self.pending: dict[str, tuple[dict, dict]] = {}  # "dev:seq" -> (event, bundled certs)
        self.downlink: list[tuple[int, dict]] = []  # (seq, HQ-signed event)
        self.gateways: dict[str, dict] = {}
        self.conflicts: dict[int, dict] = {}
        self._conflict_keys: set[str] = set()
        self._load()

    # ------------------------------------------------------------------ load

    def _load(self):
        for (j,) in self.db.q("SELECT json FROM certs").fetchall():
            c = json.loads(j)
            self.certs[c["uid"]] = c
        rows = self.db.q("SELECT json, received_at, gateway FROM events ORDER BY received_at").fetchall()
        for j, received_at, gateway in rows:
            self._index({**json.loads(j), "received_at": received_at, "gateway": gateway})
        for seq, j in self.db.q("SELECT seq, json FROM downlink ORDER BY seq").fetchall():
            self.downlink.append((seq, json.loads(j)))
        for (j,) in self.db.q("SELECT json FROM gateways").fetchall():
            g = json.loads(j)
            self.gateways[g["dev"]] = g
        for cid, j in self.db.q("SELECT id, json FROM conflicts ORDER BY id").fetchall():
            c = json.loads(j)
            c["id"] = cid
            self.conflicts[cid] = c
            self._conflict_keys.add(c["key"])

    def _index(self, ev: dict):
        self.events[ev["id"]] = ev
        self.order.append(ev["id"])
        b = ev["body"]
        h = self.heads.get(b["dev"])
        if h is None or b["seq"] > h[0]:
            self.heads[b["dev"]] = (b["seq"], ev["id"])

    # ------------------------------------------------------------------ verification

    def check_cert(self, cert: dict, at_ms: int) -> str | None:
        body = {k: v for k, v in cert.items() if k != "sig"}
        if not C.verify(C.canonical(body), C.unb64(cert.get("sig", "")), C.HQ_PUBLIC_KEY):
            return "certificate not signed by HQ"
        if at_ms > body["exp"] + SKEW_MS:
            return "certificate expired"
        if at_ms < body["iat"] - SKEW_MS:
            return "certificate not yet valid"
        return None

    def _accept(self, ev: dict, bundled: dict, gateway: str | None) -> tuple[str, str | None]:
        """Same pipeline as the phones: hash, certificate, signature, role, chain."""
        body = ev["body"]
        raw = C.canonical(body)
        if C.sha256_hex(raw) != ev["id"]:
            return "rejected", "hash mismatch"
        if ev["id"] in self.events:
            return "duplicate", None
        if body["dev"] == C.HQ_ID:
            return "rejected", "HQ events are issued here, not uploaded"
        cert = bundled.get(body["uid"]) or self.certs.get(body["uid"])
        if cert is None:
            return "rejected", "no certificate for author"
        if body["ts"] > C.now_ms() + SKEW_MS:
            return "rejected", "timestamp in the future"
        err = self.check_cert(cert, body["ts"])
        if err:
            return "rejected", err
        if cert["dev"] != body["dev"]:
            return "rejected", "device does not match certificate"
        if not C.verify(raw, C.unb64(ev["sig"]), C.unb64(cert["pk"])):
            return "rejected", "bad author signature"
        if not any(body["type"] in ROLE_PERMISSIONS.get(r, set()) for r in _roles(cert)):
            return "rejected", f"roles {_roles(cert)} cannot sign {body['type']}"
        head = self.heads.get(body["dev"])
        expected = (head[0] if head else 0) + 1
        if body["seq"] < expected:
            return "rejected", "sequence replayed or forked"
        if body["seq"] > expected:
            self.pending[f"{body['dev']}:{body['seq']}"] = (ev, bundled)
            return "pending", "waiting for earlier event"
        if body["prev"] != (head[1] if head else ""):
            return "rejected", "hash chain broken"

        known = self.certs.get(cert["uid"])
        if known is None or known.get("sig") != cert.get("sig"):
            self.certs[cert["uid"]] = cert
            self.db.upsert("certs", "uid", cert["uid"], json.dumps(cert))
        rec = {"id": ev["id"], "body": body, "sig": ev["sig"], "received_at": C.now_ms(), "gateway": gateway}
        self.db.q(
            "INSERT INTO events (id, json, received_at, gateway) VALUES (?, ?, ?, ?)",
            (ev["id"], json.dumps({"id": ev["id"], "body": body, "sig": ev["sig"]}), rec["received_at"], gateway),
        )
        self._index(rec)
        self._detect(rec)
        return "accepted", None

    # ------------------------------------------------------------------ sync (uplink phones)

    def sync(self, req: dict) -> dict:
        auth = req.get("auth") or {}
        gw_cert = auth.get("cert") or {}
        ts = int(auth.get("ts", 0))
        if abs(C.now_ms() - ts) > SKEW_MS:
            raise PermissionError("request timestamp out of range; check the phone's clock")
        err = self.check_cert(gw_cert, C.now_ms())
        if err:
            raise PermissionError(f"gateway {err}")
        if not C.verify(C.canonical({"dev": gw_cert["dev"], "ts": ts}), C.unb64(auth.get("sig", "")),
                        C.unb64(gw_cert["pk"])):
            raise PermissionError("bad gateway signature")
        dev = gw_cert["dev"]

        with self.lock:
            bundled = {c["uid"]: c for c in req.get("certs", [])}
            bundled[gw_cert["uid"]] = gw_cert
            incoming = [e for e in req.get("events", []) if e.get("body", {}).get("dev") != C.HQ_ID]
            incoming.sort(key=lambda e: (e["body"]["dev"], e["body"]["seq"]))
            acked, rejected, pending = [], [], []
            for ev in incoming:
                verdict, reason = self._accept(ev, bundled, dev)
                if verdict in ("accepted", "duplicate"):
                    acked.append(ev["id"])
                    if verdict == "accepted":
                        acked.extend(self._release(ev, dev))
                elif verdict == "pending":
                    pending.append(ev["id"])
                else:
                    rejected.append({"id": ev["id"], "reason": reason})

            cursor = int(req.get("cursor", 0))
            down = [e for seq, e in self.downlink if seq > cursor][:500]
            new_cursor = max([seq for seq, _ in self.downlink if seq > cursor][:500], default=cursor)

            g = self.gateways.get(dev, {"dev": dev, "uploads": 0})
            g.update({
                "name": gw_cert["name"],
                "roles": _roles(gw_cert),
                "fac": req.get("facility") or g.get("fac") or "",
                "last_seen": C.now_ms(),
                "uploads": g.get("uploads", 0) + len(acked),
                "cursor": max(g.get("cursor", 0), new_cursor),
            })
            self.gateways[dev] = g
            self.db.upsert("gateways", "dev", dev, json.dumps(g))

        ack = C.make_hq_event(HQ_ACK, {"ids": sorted(set(acked)), "gw": dev}) if acked else None
        return {
            "ack": ack,
            "accepted": sorted(set(acked)),
            "rejected": rejected,
            "pending": pending,
            "down": down,
            "cursor": new_cursor,
            "server_time": C.now_ms(),
        }

    def _release(self, ev: dict, gateway: str | None) -> list[str]:
        out = []
        b = ev["body"]
        nxt = self.pending.pop(f"{b['dev']}:{b['seq'] + 1}", None)
        while nxt:
            pe, pc = nxt
            verdict, _ = self._accept(pe, pc, gateway)
            if verdict != "accepted":
                break
            out.append(pe["id"])
            nxt = self.pending.pop(f"{pe['body']['dev']}:{pe['body']['seq'] + 1}", None)
        return out

    # ------------------------------------------------------------------ HQ-issued events (downlink)

    def _emit(self, type_: str, data: dict) -> dict:
        ev = C.make_hq_event(type_, data)
        row = self.db.q("INSERT INTO downlink (id, json) VALUES (?, ?) RETURNING seq",
                        (ev["id"], json.dumps(ev))).fetchone()
        self.downlink.append((row[0], ev))
        return ev

    def broadcast(self, title: str, body: str, urgent: bool) -> dict:
        with self.lock:
            return self._emit(ANNOUNCEMENT_POSTED, {"title": title, "body": body, "urgent": bool(urgent)})

    def update_request(self, rid: str, status: str, note: str, auditor: str) -> dict:
        if status not in ("approved", "dispatched", "denied", "pending"):
            raise ValueError("bad status")
        with self.lock:
            if not any(e["body"]["type"] == SUPPLY_REQUESTED and e["body"]["data"].get("rid") == rid
                       for e in self.events.values()):
                raise KeyError(rid)
            return self._emit(REQUEST_UPDATED, {"rid": rid, "status": status, "note": note, "by": auditor})

    # ------------------------------------------------------------------ conflicts

    def _priority_of(self, ev: dict) -> str | None:
        b = ev["body"]
        if b["type"] == PATIENT_REGISTERED:
            return b["data"].get("priority")
        if b["type"] == PRIORITY_CHANGED:
            return b["data"].get("to")
        return None

    def _new_conflict(self, key: str, kind: str, a: dict, b: dict, summary: str, subject: str):
        if key in self._conflict_keys:
            return
        a, b = sorted([a, b], key=lambda e: e["body"]["ts"])
        c = {
            "key": key,
            "kind": kind,
            "subject": subject,
            "summary": summary,
            "events": [a["id"], b["id"]],
            "status": "open",
            "created_at": C.now_ms(),
        }
        row = self.db.q("INSERT INTO conflicts (json) VALUES (?) RETURNING id", (json.dumps(c),)).fetchone()
        c["id"] = row[0]
        self.conflicts[c["id"]] = c
        self._conflict_keys.add(key)

    def _detect(self, ev: dict):
        b = ev["body"]
        t, d = b["type"], b["data"]
        if t not in PATIENT_EVENTS:
            return
        pid = d.get("pid")
        others = [e for e in self.events.values()
                  if e["id"] != ev["id"] and e["body"]["type"] in PATIENT_EVENTS]

        # 1. Conflicting triage: different devices set different priorities for one patient within the window.
        pr = self._priority_of(ev)
        if pr:
            for o in others:
                op = self._priority_of(o)
                if (o["body"]["data"].get("pid") == pid and op and op != pr
                        and o["body"]["dev"] != b["dev"]
                        and abs(o["body"]["ts"] - b["ts"]) <= self.window_ms):
                    mins = max(1, round(abs(o["body"]["ts"] - b["ts"]) / 60000))
                    self._new_conflict(
                        f"triage:{pid}:{':'.join(sorted([o['id'], ev['id']]))}", "triage", o, ev,
                        f"{pid} triaged as {PRIORITY.get(op, op)} and {PRIORITY.get(pr, pr)} within {mins} min",
                        pid,
                    )

        # 2. One patient at two venues: the same patient reported from different facilities.
        fac = _norm(d.get("fac"))
        if fac:
            for o in others:
                ofac = _norm(o["body"]["data"].get("fac"))
                if (o["body"]["data"].get("pid") == pid and ofac and ofac != fac
                        and abs(o["body"]["ts"] - b["ts"]) <= self.venue_window_ms):
                    self._new_conflict(
                        f"venue:{pid}:{':'.join(sorted([fac, ofac]))}", "venue", o, ev,
                        f"{pid} reported at {o['body']['data'].get('fac')} and {d.get('fac')}",
                        pid,
                    )

        # 3. Same person (service number / ID tag) registered as two patients.
        ident = _norm(d.get("ident")) if t == PATIENT_REGISTERED else ""
        if ident:
            for o in others:
                od = o["body"]["data"]
                if (o["body"]["type"] == PATIENT_REGISTERED and _norm(od.get("ident")) == ident
                        and od.get("pid") != pid
                        and abs(o["body"]["ts"] - b["ts"]) <= self.venue_window_ms):
                    same_fac = _norm(od.get("fac")) == fac
                    kind = "duplicate" if same_fac else "venue"
                    where = (f"twice at {d.get('fac') or 'the same facility'}" if same_fac
                             else f"at {od.get('fac')} and {d.get('fac')}")
                    self._new_conflict(
                        f"ident:{ident}:{':'.join(sorted([od.get('pid', ''), pid]))}", kind, o, ev,
                        f"ID {d.get('ident')} registered {where} ({od.get('pid')}, {pid})",
                        f"{od.get('pid')} / {pid}",
                    )

    def resolve(self, cid: int, decision: str, note: str, auditor: str) -> dict:
        with self.lock:
            c = self.conflicts.get(cid)
            if c is None:
                raise KeyError(cid)
            if c["status"] != "open":
                raise ValueError("already resolved")
            a, b = c["events"]
            keep, void = {"a": ([a], [b]), "b": ([b], [a]), "both": ([a, b], [])}[decision]
            ev = self._emit(CONFLICT_RESOLVED, {
                "cid": cid, "kind": c["kind"], "decision": decision,
                "keep": keep, "void": void, "note": note, "by": auditor,
            })
            c.update({"status": "resolved", "decision": decision, "note": note, "by": auditor,
                      "resolved_at": C.now_ms(), "resolution_event": ev["id"]})
            self.db.q("UPDATE conflicts SET json = ? WHERE id = ?",
                      (json.dumps({k: v for k, v in c.items() if k != "id"}), cid))
            return c

    # ------------------------------------------------------------------ read models

    def _author(self, ev: dict) -> dict:
        b = ev["body"]
        c = self.certs.get(b["uid"])
        if c is None:
            return {"uid": b["uid"], "name": f"Unknown {b['dev']}", "roles": []}
        return {"uid": c["uid"], "name": c["name"], "roles": [ROLE_LABELS.get(r, r) for r in _roles(c)]}

    def _voided(self) -> set[str]:
        out: set[str] = set()
        for _, e in self.downlink:
            if e["body"]["type"] == CONFLICT_RESOLVED:
                out.update(e["body"]["data"].get("void", []))
        return out

    def _summary(self, ev: dict) -> str:
        b = ev["body"]
        t, d = b["type"], b["data"]
        pid = d.get("pid", "")
        if t == PATIENT_REGISTERED:
            who = " · ".join(x for x in [d.get("name"), d.get("ident")] if x)
            return f"New patient {pid} ({PRIORITY.get(d.get('priority'), '?')}){' · ' + who if who else ''}: {d.get('desc', '')}"
        if t == PRIORITY_CHANGED:
            return f"{pid} priority {PRIORITY.get(d.get('from'), '?')} → {PRIORITY.get(d.get('to'), '?')}"
        if t in ENTRY_LABELS:
            return f"{ENTRY_LABELS[t]} for {pid}: {d.get('text', '')}"
        if t == STOCK_COUNTED:
            return f"Stock count: {d.get('item')} = {d.get('qty')} {d.get('unit', '')}"
        if t == STOCK_ADJUSTED:
            delta = d.get("delta", 0)
            return f"Stock {'+' if delta >= 0 else ''}{delta} {d.get('item')} ({d.get('reason', '')})"
        if t == SUPPLY_REQUESTED:
            return f"Supply request: {d.get('qty')} {d.get('unit', '')} {d.get('item')} ({d.get('urgency', 'routine')})"
        if t == ANNOUNCEMENT_POSTED:
            return f"Announcement: {d.get('title')}"
        if t == MESSAGE_SENT:
            return f"Message: {d.get('body', '')}"
        return t

    def feed(self, limit: int = 60) -> list[dict]:
        with self.lock:
            out = []
            for eid in reversed(self.order[-limit:]):
                e = self.events[eid]
                b = e["body"]
                gw = self.gateways.get(e.get("gateway") or "", {})
                out.append({
                    "id": eid,
                    "type": b["type"],
                    "summary": self._summary(e),
                    "author": self._author(e),
                    "fac": b["data"].get("fac", ""),
                    "pid": b["data"].get("pid"),
                    "ts": b["ts"],
                    "received_at": e["received_at"],
                    "gateway": gw.get("name") or e.get("gateway"),
                })
            return out

    def _entry(self, e: dict, voided: set[str]) -> dict:
        b = e["body"]
        d = b["data"]
        text = d.get("text") or d.get("desc") or ""
        fields = dict(d.get("fields") or {})
        if b["type"] == PATIENT_REGISTERED:
            fields = {k: v for k, v in {
                "Priority": PRIORITY.get(d.get("priority")),
                "Location": d.get("loc"),
                "Name": d.get("name"),
                "ID tag": d.get("ident"),
            }.items() if v}
        if b["type"] == PRIORITY_CHANGED:
            text = f"{PRIORITY.get(d.get('from'), '?')} → {PRIORITY.get(d.get('to'), '?')}"
        return {
            "id": e["id"],
            "type": b["type"],
            "label": ENTRY_LABELS.get(b["type"], b["type"]),
            "ts": b["ts"],
            "seq": b["seq"],
            "dev": b["dev"],
            "fac": d.get("fac", ""),
            "author": self._author(e),
            "text": text,
            "fields": fields,
            "voided": e["id"] in voided,
        }

    def patients(self) -> list[dict]:
        with self.lock:
            voided = self._voided()
            evs = sorted((e for e in self.events.values() if e["body"]["type"] in PATIENT_EVENTS),
                         key=lambda e: e["body"]["ts"])
            out: dict[str, dict] = {}
            for e in evs:
                d = e["body"]["data"]
                if e["body"]["type"] == PATIENT_REGISTERED:
                    out[d["pid"]] = {
                        "pid": d["pid"], "name": d.get("name", ""), "ident": d.get("ident", ""),
                        "desc": d.get("desc", ""), "fac": d.get("fac", ""), "loc": d.get("loc", ""),
                        "arrival": e["body"]["ts"], "priority": d.get("priority"),
                        "voided": e["id"] in voided, "entries": [],
                    }
            for e in evs:
                d = e["body"]["data"]
                p = out.get(d.get("pid"))
                if p is None:
                    continue
                p["entries"].append(self._entry(e, voided))
                if e["id"] in voided:
                    continue
                if e["body"]["type"] == PRIORITY_CHANGED:
                    p["priority"] = d.get("to")
            open_by_pid: dict[str, int] = {}
            for c in self.conflicts.values():
                if c["status"] == "open":
                    for eid in c["events"]:
                        pid = self.events.get(eid, {}).get("body", {}).get("data", {}).get("pid")
                        if pid:
                            open_by_pid[pid] = open_by_pid.get(pid, 0) + 1
            for p in out.values():
                types = {x["type"] for x in p["entries"] if not x["voided"]}
                p["stage"] = (4 if FOLLOW_UP_RECOMMENDED in types else 3 if REMEDIATION_RECORDED in types
                              else 2 if DIAGNOSIS_RECORDED in types else 1 if OBSERVATION_ADDED in types else 0)
                p["facilities"] = sorted({x["fac"] for x in p["entries"] if x["fac"]})
                p["updated"] = max(x["ts"] for x in p["entries"])
                p["open_conflicts"] = open_by_pid.get(p["pid"], 0)
            return sorted(out.values(), key=lambda p: p["updated"], reverse=True)

    def conflict_list(self) -> list[dict]:
        with self.lock:
            voided = self._voided()
            out = []
            for c in sorted(self.conflicts.values(), key=lambda c: c["id"], reverse=True):
                reports = []
                for eid in c["events"]:
                    e = self.events.get(eid)
                    if e:
                        r = self._entry(e, voided)
                        r["pid"] = e["body"]["data"].get("pid")
                        r["gateway"] = self.gateways.get(e.get("gateway") or "", {}).get("name")
                        r["received_at"] = e["received_at"]
                        reports.append(r)
                out.append({**c, "reports": reports})
            return out

    def inventory(self) -> dict:
        with self.lock:
            evs = sorted((e for e in self.events.values() if e["body"]["type"] in INVENTORY),
                         key=lambda e: e["body"]["ts"])
            facilities: dict[str, dict[str, dict]] = {}
            requests: dict[str, dict] = {}
            for e in evs:
                b = e["body"]
                d = b["data"]
                fac = d.get("fac") or "Unassigned"
                if b["type"] in (STOCK_COUNTED, STOCK_ADJUSTED):
                    items = facilities.setdefault(fac, {})
                    key = _norm(d.get("item"))
                    it = items.setdefault(key, {"item": d.get("item"), "category": "supply", "unit": "",
                                                "qty": 0, "min": 0, "updated": 0, "by": ""})
                    if b["type"] == STOCK_COUNTED:
                        it.update({"item": d.get("item"), "category": d.get("category", it["category"]),
                                   "unit": d.get("unit", it["unit"]), "qty": int(d.get("qty", 0)),
                                   "min": int(d.get("min", it["min"]) or 0)})
                    else:
                        it["qty"] += int(d.get("delta", 0))
                    it["updated"] = b["ts"]
                    it["by"] = self._author(e)["name"]
                else:
                    requests[d["rid"]] = {
                        "rid": d["rid"], "item": d.get("item"), "qty": d.get("qty"), "unit": d.get("unit", ""),
                        "urgency": d.get("urgency", "routine"), "note": d.get("note", ""), "fac": fac,
                        "by": self._author(e)["name"], "ts": b["ts"], "status": "pending", "history": [],
                    }
            for _, e in self.downlink:
                if e["body"]["type"] == REQUEST_UPDATED:
                    d = e["body"]["data"]
                    r = requests.get(d["rid"])
                    if r:
                        r["status"] = d["status"]
                        r["history"].append({"status": d["status"], "note": d.get("note", ""),
                                             "by": d.get("by", "HQ"), "ts": e["body"]["ts"]})
            return {
                "facilities": {f: sorted(items.values(), key=lambda i: (i["category"], i["item"].lower()))
                               for f, items in sorted(facilities.items())},
                "requests": sorted(requests.values(), key=lambda r: r["ts"], reverse=True),
            }

    def announcements(self) -> list[dict]:
        with self.lock:
            out = []
            for seq, e in self.downlink:
                if e["body"]["type"] == ANNOUNCEMENT_POSTED:
                    delivered = [g["name"] for g in self.gateways.values() if g.get("cursor", 0) >= seq]
                    out.append({"id": e["id"], "from_hq": True, "ts": e["body"]["ts"], **e["body"]["data"],
                                "delivered_via": delivered})
            for e in self.events.values():
                if e["body"]["type"] == ANNOUNCEMENT_POSTED:
                    out.append({"id": e["id"], "from_hq": False, "ts": e["body"]["ts"], **e["body"]["data"],
                                "author": self._author(e)})
            return sorted(out, key=lambda a: a["ts"], reverse=True)

    def overview(self) -> dict:
        with self.lock:
            pts = [p for p in self.patients() if not p["voided"]]
            by_pr = {k: sum(1 for p in pts if p["priority"] == k) for k in PRIORITY}
            inv = self.inventory()
            low = sum(1 for items in inv["facilities"].values() for i in items if i["min"] and i["qty"] <= i["min"])
            now = C.now_ms()
            gws = sorted(self.gateways.values(), key=lambda g: g.get("last_seen", 0), reverse=True)
            for g in gws:
                g["online"] = now - g.get("last_seen", 0) < 2 * 60 * 1000
            return {
                "patients": len(pts),
                "by_priority": by_pr,
                "open_conflicts": sum(1 for c in self.conflicts.values() if c["status"] == "open"),
                "pending_requests": sum(1 for r in inv["requests"] if r["status"] == "pending"),
                "low_stock": low,
                "events": len(self.events),
                "devices": len(self.certs),
                "gateways": gws,
                "facilities": sorted({p["fac"] for p in pts if p["fac"]} | set(inv["facilities"].keys())),
                "server_time": now,
            }
