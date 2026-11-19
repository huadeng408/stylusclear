#Requires -Version 5.1
$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$WslEnvItems = @(
    "PRIVATE_KEY/u",
    "SEPOLIA_RPC_URL/u",
    "ROBINHOOD_RPC_URL/u",
    "ORBIT_RPC_URL/u",
    "ORBIT_CHAIN_ID/u",
    "SKIP_ROBINHOOD/u",
    "LIVE_CLIP_PATH/p",
    "STYLUSCLEAR_ENTITY_DIR/p",
    "STYLUSCLEAR_VIDEO_KIT_DIR/p"
)
$existing = if ($env:WSLENV) { $env:WSLENV.Split(":") | Where-Object { $_ -ne "" } } else { @() }
$merged = ($existing + $WslEnvItems) | Select-Object -Unique
$env:WSLENV = ($merged -join ":")
Push-Location $RepoRoot
try {
    & wsl bash "scripts/demo-sepolia-live.sh" @args
    exit $LASTEXITCODE
} finally {
    Pop-Location
}
