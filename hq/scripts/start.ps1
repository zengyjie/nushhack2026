# Windows: builds and starts PostgreSQL + the HQ server with Docker Desktop. Creates .env on first run.
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")
if (-not (Test-Path .env)) {
  $rand = { -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 32 | ForEach-Object { [char]$_ }) }
  (Get-Content .env.example) `
    -replace '^HQ_ADMIN_TOKEN=.*', ("HQ_ADMIN_TOKEN=" + (& $rand)) `
    -replace '^POSTGRES_PASSWORD=.*', ("POSTGRES_PASSWORD=" + (& $rand)) | Set-Content -Encoding ascii .env
  Write-Host "Created .env with a new admin token."
}
docker compose up -d --build
$port = ((Select-String -Path .env -Pattern '^HQ_PORT=(.*)').Matches.Groups[1].Value); if (-not $port) { $port = 8000 }
for ($i = 0; $i -lt 60; $i++) {
  try { Invoke-WebRequest -UseBasicParsing "http://localhost:$port/api/health" | Out-Null; break } catch { Start-Sleep 1 }
}
Write-Host "HQ web console: http://localhost:$port"
Write-Host ("Admin token:    " + (Select-String -Path .env -Pattern '^HQ_ADMIN_TOKEN=(.*)').Matches.Groups[1].Value)
Write-Host "For a public URL run: scripts\tunnel.ps1"
