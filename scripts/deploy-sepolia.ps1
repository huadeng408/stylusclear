#Requires -Version 5.1
$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$WslRepo = (& wsl wslpath -a "$RepoRoot" 2>$null | Select-Object -First 1)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($WslRepo)) {
    Write-Error "WSL2 cannot mount '$RepoRoot' (common for Google Drive G:\ virtual drives). Copy the repo to C:\stylusclear or WSL2 ~/stylusclear and re-run."
    exit 1
}
$WslEnvItems = @(
    "PRIVATE_KEY/u",
    "RPC_URL/u",
    "CHAIN_ID_EXPECTED/u",
    "SEPOLIA_RPC_URL/u",
    "ROBINHOOD_RPC_URL/u",
    "ORBIT_RPC_URL/u",
    "ORBIT_CHAIN_ID/u",
    "SKIP_ROBINHOOD/u",
    "REQUIRE_STYLUS/u",
    "LIVE_CLIP_PATH/p",
    "STYLUSCLEAR_ENTITY_DIR/p",
    "STYLUSCLEAR_VIDEO_KIT_DIR/p"
)
$existing = if ($env:WSLENV) { $env:WSLENV.Split(":") | Where-Object { $_ -ne "" } } else { @() }
$merged = ($existing + $WslEnvItems) | Select-Object -Unique
$env:WSLENV = ($merged -join ":")
& wsl --cd "$WslRepo" bash "scripts/deploy-sepolia.sh" @args
exit $LASTEXITCODE
