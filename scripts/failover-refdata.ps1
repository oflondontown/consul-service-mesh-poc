$ErrorActionPreference = "Stop"
Invoke-RestMethod -TimeoutSec 10 -Uri "http://localhost:28082/admin/active?value=false" | ConvertTo-Json
