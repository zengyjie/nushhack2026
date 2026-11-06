# MESH HQ server

HQ is the ON part of MESH. It provides:

- a **sync API**, which uplink phones call to send their signed events and pull HQ-signed events;
- a **web console** for HQ staff, with these pages:
  - **Overview**: the live report feed;
  - **Patients**: every patient reported by any cluster, with their full record;
  - **Conflicts**: the human audit queue;
  - **Broadcast**: HQ announcements;
  - **Inventory**: stock and supply requests.

It uses FastAPI and PostgreSQL, and needs no build step.

## Run it on another machine (Docker)

You need Docker with the Compose plugin: Docker Desktop on Windows or macOS, or `docker-ce` on Linux. Copy this `hq/` folder to the machine, then:

```bash
cd hq
scripts/start.sh          # Windows: powershell -ExecutionPolicy Bypass -File scripts\start.ps1
```

On first run this creates `.env` with a random admin token and database password. It then builds the image, starts PostgreSQL and HQ, and prints:

- the console URL, `http://localhost:8000`;
- the **admin token**. Sign in with your name and this token. Your name is recorded on every audit decision.

### Make it reachable from phones (Cloudflare tunnel)

```bash
scripts/tunnel.sh         # Windows: scripts\tunnel.ps1
```

This prints a public `https://<random>.trycloudflare.com` URL. In the app, open **Mesh**, then **HQ server**, paste the URL, and switch on **Uplink to HQ** on any phone that has internet. Quick tunnels need no Cloudflare account, but the URL changes whenever the tunnel container restarts.

If the phones are on the same Wi-Fi as the server, you can use `http://<server-ip>:8000` instead.

### Other commands

| | |
|---|---|
| `scripts/stop.sh` | Stop everything. Data is kept in the `pgdata` volume. |
| `docker compose down -v` | Stop and **wipe** all HQ data. |
| `docker compose logs -f hq` | Follow the server logs. |
| `scripts/run-local.sh` | Run without Docker, using a Python venv and SQLite in `./data/`. |
| `python scripts/simulate_cluster.py <url>` | Send signed test traffic from simulated phones, including one of each conflict type. Needs `pip install -r requirements.txt`. |

Settings are in `.env`; see `.env.example`. `CONFLICT_WINDOW_MIN` and `VENUE_WINDOW_H` tune the conflict rules.

## How it works

- **Sync.** `POST /api/sync`: an uplink phone authenticates with its HQ-signed certificate plus a signature over a fresh timestamp. It sends every event that HQ hasn't acknowledged yet.
  - HQ verifies each event exactly as the phones do: hash, the HQ signature on the author's certificate, the author's signature, the role permission, and the per-device hash chain.
  - HQ then replies with an **HQ-signed acknowledgement**, which the phone floods over Bluetooth so every phone marks those records as synced. The reply also carries any **HQ-signed events** that phone hasn't pulled yet: announcements, audit decisions and supply-request updates.
- **Broadcasts reach phones without internet.** The uplink phone floods HQ events over the BLE mesh like any other event. Every phone checks them against the HQ public key.
- **Conflicts** are flagged automatically when reports arrive:
  - **Conflicting triage:** two different devices set different priorities for the same patient within `CONFLICT_WINDOW_MIN`.
  - **Patient at two venues:** the same patient is reported from two facilities within `VENUE_WINDOW_H`, or the same ID tag is registered as patients at two facilities.
  - **Duplicate registration:** the same ID tag is registered twice at one facility.

  The auditor compares the two reports side by side and chooses **Keep A**, **Keep B** or **Keep both**, with a note. The decision goes out as an HQ-signed `ConflictResolved` event. Every phone then shows the overruled report as struck through and stops using it, for example when working out the current priority.
- **Inventory:** phones send stock counts, adjustments and supply requests. HQ approves, denies or marks requests dispatched, and those updates flow back down the same way.

## Prototype limits

- The demo HQ signing key matches the one compiled into the app. For anything beyond a demo, generate a new seed (`HQ_SEED_HEX`), move enrolment to HQ, and remove the key from the app.
- There's a single admin token, with no per-user accounts.
- Only one server worker can run, because the verified log is cached in memory.
