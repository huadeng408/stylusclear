$ErrorActionPreference = "Stop"
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$env:WSLENV = "PRIVATE_KEY/u:SEPOLIA_RPC_URL/u:ROBINHOOD_RPC_URL/u"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$WslPath = wsl wslpath -a "$RepoRoot"
wsl bash -lc "cd '$WslPath' && bash scripts/check.sh" 2>&1 | Out-File -FilePath "$RepoRoot\deploy-check.log" -Encoding utf8
Get-Content "$RepoRoot\deploy-check.log"
