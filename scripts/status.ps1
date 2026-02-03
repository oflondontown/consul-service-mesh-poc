param(
  [ValidateSet("auto", "docker", "podman")][string]$Engine = $(if ($env:CONTAINER_ENGINE) { $env:CONTAINER_ENGINE } else { "auto" })
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot/_compose.ps1"
Invoke-Compose -Engine $Engine -Args @("ps")
