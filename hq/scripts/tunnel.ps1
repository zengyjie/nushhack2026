# Windows: starts a Cloudflare quick tunnel to HQ and prints its public URL.
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")
docker compose --profile tunnel up -d tunnel
for ($i = 0; $i -lt 60; $i++) {
  $m = (docker compose logs tunnel 2>$null | Select-String -Pattern 'https://[a-z0-9-]+\.trycloudflare\.com' -AllMatches)
  if ($m) { $url = $m.Matches[-1].Value; Write-Host "HQ public URL: $url"; Write-Host "Enter it in the app under Mesh > HQ server."; exit 0 }
  Start-Sleep 1
}
Write-Host "No URL yet. Check: docker compose logs tunnel"; exit 1
