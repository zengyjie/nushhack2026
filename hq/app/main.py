"""MESH HQ server: sync endpoint for uplink phones, admin API and the HQ web app."""

from __future__ import annotations

import hmac
import os
from pathlib import Path

from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from .store import Store

ADMIN_TOKEN = os.environ.get("HQ_ADMIN_TOKEN", "change-me")
store = Store(
    os.environ.get("DATABASE_URL", "sqlite:///./data/hq.db"),
    conflict_window_min=int(os.environ.get("CONFLICT_WINDOW_MIN", "10")),
    venue_window_h=int(os.environ.get("VENUE_WINDOW_H", "12")),
)

app = FastAPI(title="MESH HQ", docs_url="/api/docs", openapi_url="/api/openapi.json")
STATIC = Path(__file__).parent / "static"


def admin(authorization: str = Header(default=""), x_auditor: str = Header(default="")) -> str:
    """Bearer token for the web app. Returns the auditor's name for the audit trail."""
    token = authorization.removeprefix("Bearer ").strip()
    if not hmac.compare_digest(token, ADMIN_TOKEN):
        raise HTTPException(401, "invalid admin token")
    return x_auditor.strip() or "HQ auditor"


# ---------------------------------------------------------------------- phones


@app.get("/api/health")
def health():
    return {"ok": True, "events": len(store.events)}


@app.post("/api/sync")
def sync(req: dict):
    """Uplink phones post unacknowledged signed events and pull HQ-signed events.
    Authenticated by the phone's HQ certificate and a signed timestamp, not the admin token."""
    try:
        return store.sync(req)
    except PermissionError as e:
        raise HTTPException(403, str(e)) from e
    except (KeyError, TypeError, ValueError) as e:
        raise HTTPException(400, f"malformed sync request: {e}") from e


# ---------------------------------------------------------------------- web app


class Announcement(BaseModel):
    title: str = Field(min_length=1, max_length=120)
    body: str = Field(min_length=1, max_length=2000)
    urgent: bool = False


class Resolution(BaseModel):
    decision: str = Field(pattern="^(a|b|both)$")
    note: str = Field(default="", max_length=1000)


class RequestStatus(BaseModel):
    status: str = Field(pattern="^(approved|dispatched|denied|pending)$")
    note: str = Field(default="", max_length=1000)


@app.get("/api/admin/check")
def check(auditor: str = Depends(admin)):
    return {"ok": True, "auditor": auditor}


@app.get("/api/admin/overview")
def overview(_: str = Depends(admin)):
    return store.overview()


@app.get("/api/admin/feed")
def feed(limit: int = 60, _: str = Depends(admin)):
    return store.feed(min(max(limit, 1), 500))


@app.get("/api/admin/patients")
def patients(_: str = Depends(admin)):
    return store.patients()


@app.get("/api/admin/conflicts")
def conflicts(_: str = Depends(admin)):
    return store.conflict_list()


@app.post("/api/admin/conflicts/{cid}/resolve")
def resolve(cid: int, body: Resolution, auditor: str = Depends(admin)):
    try:
        return store.resolve(cid, body.decision, body.note, auditor)
    except KeyError as e:
        raise HTTPException(404, "conflict not found") from e
    except ValueError as e:
        raise HTTPException(409, str(e)) from e


@app.get("/api/admin/announcements")
def announcements(_: str = Depends(admin)):
    return store.announcements()


@app.post("/api/admin/announcements")
def broadcast(body: Announcement, _: str = Depends(admin)):
    return store.broadcast(body.title, body.body, body.urgent)


@app.get("/api/admin/inventory")
def inventory(_: str = Depends(admin)):
    return store.inventory()


@app.post("/api/admin/requests/{rid}/status")
def request_status(rid: str, body: RequestStatus, auditor: str = Depends(admin)):
    try:
        return store.update_request(rid, body.status, body.note, auditor)
    except KeyError as e:
        raise HTTPException(404, "request not found") from e


app.mount("/static", StaticFiles(directory=STATIC), name="static")


@app.get("/")
def index():
    return FileResponse(STATIC / "index.html")
