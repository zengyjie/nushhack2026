#!/usr/bin/env bash
# Stops everything. Data stays in the pgdata volume (add -v to `docker compose down` to wipe it).
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose --profile tunnel down
