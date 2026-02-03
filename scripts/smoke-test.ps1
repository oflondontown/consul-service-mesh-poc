param(
  [int]$MaxWaitSeconds = 120
)

$ErrorActionPreference = "Stop"

function Wait-HttpOk {
  param(
    [Parameter(Mandatory=$true)][string]$Url,
    [int]$TimeoutSeconds = 120
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 -Uri $Url
      if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300) {
        return
      }
    } catch {
      Start-Sleep -Seconds 2
    }
  }

  throw "Timed out waiting for HTTP 2xx: $Url"
}

function Wait-RefDataFailover {
  param(
    [Parameter(Mandatory=$true)][string]$Url,
    [Parameter(Mandatory=$true)][string]$ExpectedDatacenter,
    [int]$TimeoutSeconds = 120
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    try {
      $resp = Invoke-RestMethod -TimeoutSec 10 -Uri $Url
      $dc = $resp.refdata.datacenter
      if ($dc -eq $ExpectedDatacenter) {
        return $resp
      }
    } catch {
      # ignore and retry
    }
    Start-Sleep -Seconds 2
  }

  throw "Timed out waiting for refdata datacenter=$ExpectedDatacenter via $Url"
}

Write-Host "Waiting for webservice..."
Wait-HttpOk -Url "http://localhost:8080/actuator/health" -TimeoutSeconds $MaxWaitSeconds

Write-Host ""
Write-Host "== Baseline (should be dc1 refdata) =="
$baseline = Invoke-RestMethod -TimeoutSec 10 -Uri "http://localhost:8080/api/refdata/demo"
$baseline | ConvertTo-Json -Depth 10

Write-Host ""
Write-Host "== Order path (webservice -> ordermanager -> refdata) =="
$order = Invoke-RestMethod -TimeoutSec 10 -Uri "http://localhost:8080/api/orders/123"
$order | ConvertTo-Json -Depth 10

Write-Host ""
Write-Host "Disabling primary refdata (dc1)..."
Invoke-RestMethod -TimeoutSec 10 -Uri "http://localhost:28082/admin/active?value=false" | Out-Null
Write-Host "Waiting for Consul health hysteresis + failover..."

Write-Host ""
Write-Host "== After failover (should be dc2 refdata) =="
$after = Wait-RefDataFailover -Url "http://localhost:8080/api/refdata/demo" -ExpectedDatacenter "dc2" -TimeoutSeconds $MaxWaitSeconds
$after | ConvertTo-Json -Depth 10

Write-Host ""
Write-Host "Re-enabling primary refdata (dc1)..."
Invoke-RestMethod -TimeoutSec 10 -Uri "http://localhost:28082/admin/active?value=true" | Out-Null

Write-Host "Done."
