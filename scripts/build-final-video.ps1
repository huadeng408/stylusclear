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
    $WslVars = @("STYLUSCLEAR_VIDEO_KIT_DIR/p", "LIVE_CLIP_PATH/p", "OFFLINE_CRATES_VENDOR/p")
    $Current = if ($env:WSLENV) { $env:WSLENV -split ":" } else { @() }
    foreach ($v in $WslVars) {
        if ($Current -notcontains $v) { $Current += $v }
    }
    $env:WSLENV = ($Current | Where-Object { $_ -ne "" }) -join ":"

$ForwardedArgs = @()
foreach ($a in $args) {
    if ($a -match '^[A-Za-z]:\\') {
        $conv = (wsl wslpath -a "$a" 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($conv)) {
            $ForwardedArgs += $conv
        } else {
            $ForwardedArgs += $a
        }
    } else {
        $ForwardedArgs += $a
    }
}

    & wsl --cd "$WslRepo" -- bash "scripts/build-final-video.sh" @ForwardedArgs
    exit $LASTEXITCODE
} finally {
    $env:WSLENV = $PrevWslEnv
}
