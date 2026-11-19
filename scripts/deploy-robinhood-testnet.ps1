$ErrorActionPreference = 'Stop'
$extra = 'PRIVATE_KEY/u:SEPOLIA_RPC_URL/u:ROBINHOOD_RPC_URL/u:ETHERSCAN_API_KEY/u'
if ($env:WSLENV) { $env:WSLENV = "$($env:WSLENV):$extra" } else { $env:WSLENV = $extra }
wsl bash scripts/deploy-robinhood-testnet.sh @args
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
