param(
  [ValidateSet("auto", "docker", "podman")][string]$Engine = $(if ($env:CONTAINER_ENGINE) { $env:CONTAINER_ENGINE } else { "auto" }),
  [switch]$NoBuild
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot/_compose.ps1"

$argsList = @("up", "-d")
if (-not $NoBuild) {
  $argsList += "--build"
}

Invoke-Compose -Engine $Engine -Args $argsList
