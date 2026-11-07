#!/usr/bin/env bash
# Builds and starts PostgreSQL + the HQ server with Docker. Creates .env on first run.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  token=$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 32)
  dbpass=$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 24)
  sed -e "s|^HQ_ADMIN_TOKEN=.*|HQ_ADMIN_TOKEN=$token|" -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$dbpass|" .env.example > .env
  echo "Created .env with a new admin token."
fi

docker compose up -d --build
port=$(grep -E '^HQ_PORT=' .env | cut -d= -f2); port=${port:-8000}
echo -n "Waiting for HQ"
for _ in $(seq 1 60); do
  if curl -fs "http://localhost:$port/api/health" >/dev/null 2>&1; then echo " ready."; break; fi
  echo -n "."; sleep 1
done
echo
echo "HQ web console:  http://localhost:$port"
echo "Admin token:     $(grep -E '^HQ_ADMIN_TOKEN=' .env | cut -d= -f2)"
echo "Phones on the same network can use http://<this machine's IP>:$port"
echo "For a public URL run: scripts/tunnel.sh"
