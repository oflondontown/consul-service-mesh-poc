param(
  [ValidateSet("auto", "docker", "podman")][string]$Engine = $(if ($env:CONTAINER_ENGINE) { $env:CONTAINER_ENGINE } else { "auto" })
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot/_compose.ps1"

Invoke-Compose -Engine $Engine -Args @("stop", "itch-feed-primary")
Write-Host "Stopped itch-feed-primary. Watch consumer logs with: (docker|podman) compose logs -f itch-consumer"
