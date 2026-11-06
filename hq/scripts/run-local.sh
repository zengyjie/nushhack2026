#!/usr/bin/env bash
# Runs HQ without Docker: Python venv + SQLite in ./data. Good for a laptop demo.
# Pair with `cloudflared tunnel --url http://localhost:8000` for a public URL.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -m venv .venv
. .venv/bin/activate
pip install -q -r requirements.txt
export HQ_ADMIN_TOKEN="${HQ_ADMIN_TOKEN:-change-me}"
export DATABASE_URL="${DATABASE_URL:-sqlite:///./data/hq.db}"
echo "HQ on http://localhost:8000 (admin token: $HQ_ADMIN_TOKEN)"
exec uvicorn app.main:app --host 0.0.0.0 --port 8000
