param(
  [ValidateSet("auto", "docker", "podman")][string]$Engine = $(if ($env:CONTAINER_ENGINE) { $env:CONTAINER_ENGINE } else { "auto" }),
  [switch]$RemoveVolumes
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot/_compose.ps1"

$argsList = @("down", "--remove-orphans")
if ($RemoveVolumes) {
  $argsList += "-v"
}

Invoke-Compose -Engine $Engine -Args $argsList
