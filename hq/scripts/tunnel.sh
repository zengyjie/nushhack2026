#!/usr/bin/env bash
# Starts a Cloudflare quick tunnel to the HQ server and prints its public URL.
# Paste that URL into the app: Mesh tab > HQ server.
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose --profile tunnel up -d tunnel
echo -n "Waiting for the tunnel URL"
for _ in $(seq 1 60); do
  url=$(docker compose logs tunnel 2>/dev/null | grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1 || true)
  if [ -n "${url:-}" ]; then echo; echo; echo "HQ public URL: $url"; echo "Enter it in the app under Mesh > HQ server."; exit 0; fi
  echo -n "."; sleep 1
done
echo; echo "No URL yet. Check: docker compose logs tunnel" >&2; exit 1
