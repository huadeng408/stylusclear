$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).ProviderPath
$WslRepo = (wsl wslpath -a "$RepoRoot" 2>$null | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($WslRepo)) {
    Write-Error "Failed to resolve WSL path for '$RepoRoot'. Copy or clone the repository to a local NTFS path (e.g. C:\stylusclear) instead of a virtual Drive mount."
    exit 1
}

$PrevWslEnv = $env:WSLENV
try {
    $WslVars = @("PRIVATE_KEY/u", "RPC_URL/u", "SEPOLIA_RPC_URL/u", "ROBINHOOD_RPC_URL/u", "REQUIRE_STYLUS/u", "USE_ATOMIC_FACTORY/u", "LIVE_CLIP_PATH/p", "STYLUSCLEAR_VIDEO_KIT_DIR/p")
    $Current = if ($env:WSLENV) { $env:WSLENV -split ":" } else { @() }
    foreach ($v in $WslVars) {
        if ($Current -notcontains $v) { $Current += $v }
    }
    $env:WSLENV = ($Current | Where-Object { $_ -ne "" }) -join ":"

    & wsl --cd "$WslRepo" -- bash "scripts/demo-sepolia-live.sh" @args
    exit $LASTEXITCODE
} finally {
    $env:WSLENV = $PrevWslEnv
}
