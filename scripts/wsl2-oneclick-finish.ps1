param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ForwardArgs
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$RepoWin = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).ProviderPath
$RepoWsl = (& wsl.exe wslpath -a "$RepoWin").Trim()
if ($LASTEXITCODE -ne 0 -or -not $RepoWsl) {
    throw "Failed to convert Windows path '$RepoWin' via wslpath"
}

$SkipDeploy = $false
if ($ForwardArgs) {
    foreach ($a in $ForwardArgs) {
        if ($a -eq "--skip-deploy") { $SkipDeploy = $true }
    }
}

$PromptedKey = $false
$BstrPtr = [IntPtr]::Zero
try {
    if (-not $SkipDeploy -and -not $env:PRIVATE_KEY) {
        Write-Host "[wsl2-finish] Enter testnet deployer private key (input is masked and never saved to PowerShell history):" -ForegroundColor Cyan
        $SecKey = Read-Host -AsSecureString "PRIVATE_KEY (0x...)"
        $BstrPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecKey)
        $env:PRIVATE_KEY = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BstrPtr).Trim()
        $PromptedKey = $true
        if (-not $env:PRIVATE_KEY) {
            throw "PRIVATE_KEY is required unless --skip-deploy is specified."
        }
    }

    $WslVars = @(
        "PRIVATE_KEY/u",
        "ARB_SEPOLIA_RPC_URL/u",
        "ROBINHOOD_RPC_URL/u",
        "REQUIRE_STYLUS/u",
        "USE_ATOMIC_FACTORY/u",
        "RUN_FULL_VERIFY/u",
        "SKIP_ROBINHOOD/u",
        "DEPLOY_OUT_NAME/u",
        "CHAIN_ID_EXPECTED/u",
        "STYLUSCLEAR_ENTITY_DIR/p",
        "OFFLINE_CRATES_VENDOR/p",
        "STYLUSCLEAR_VIDEO_KIT_DIR/p"
    )
    if ($env:WSLENV) {
        $env:WSLENV = ($env:WSLENV + ":" + ($WslVars -join ":"))
    } else {
        $env:WSLENV = ($WslVars -join ":")
    }

    $QuotedArgs = ""
    if ($ForwardArgs -and $ForwardArgs.Count -gt 0) {
        $Esc = $ForwardArgs | ForEach-Object { "'" + ($_ -replace "'", "'"'"'") + "'" }
        $QuotedArgs = ($Esc -join " ")
    }
    $Cmd = "cd '$RepoWsl' && bash scripts/wsl2-oneclick-finish.sh $QuotedArgs"
    & wsl.exe bash -lc "$Cmd"
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
} finally {
    if ($BstrPtr -ne [IntPtr]::Zero) {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BstrPtr)
    }
    if ($PromptedKey) {
        Remove-Item Env:PRIVATE_KEY -ErrorAction SilentlyContinue
    }
}
