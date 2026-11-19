$ErrorActionPreference = "Stop"
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$env:WSLENV = "PRIVATE_KEY/u:SEPOLIA_RPC_URL/u:ROBINHOOD_RPC_URL/u"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$WslPath = wsl wslpath -a "$RepoRoot"
wsl bash -lc "cd '$WslPath' && bash scripts/bootstrap-host.sh" 2>&1 | Out-File -FilePath "$RepoRoot\deploy-bootstrap.log" -Encoding utf8
Get-Content "$RepoRoot\deploy-bootstrap.log"
