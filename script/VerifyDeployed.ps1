param(
    [string]$ChainId,
    [string]$VerifierUrl = "https://testnet.arcscan.app/api/",
    [string]$RegistryAddress,
    [string]$ReputationAddress,
    [string]$EscrowAddress,
    [string]$ManagerAddress,
    [string]$BidBoardAddress,
    [string]$UsdcAddress,
    [string]$ArcIdentityRegistryAddress,
    [string]$ProjectRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Parse-DotEnv {
    param([string]$Path)

    $map = @{}
    if (-not (Test-Path -LiteralPath $Path)) {
        return $map
    }

    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        if ($trimmed.StartsWith("#")) { continue }

        $idx = $trimmed.IndexOf("=")
        if ($idx -lt 1) { continue }

        $k = $trimmed.Substring(0, $idx).Trim()
        $v = $trimmed.Substring($idx + 1).Trim()
        $map[$k] = $v
    }

    return $map
}

function Get-Setting {
    param(
        [hashtable]$EnvMap,
        [string]$CurrentValue,
        [string[]]$Keys,
        [string]$Label,
        [switch]$Required
    )

    if (-not [string]::IsNullOrWhiteSpace($CurrentValue)) {
        return $CurrentValue
    }

    foreach ($key in $Keys) {
        if ($EnvMap.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace($EnvMap[$key])) {
            return $EnvMap[$key]
        }
    }

    if ($Required) {
        throw "Missing required setting: $Label"
    }

    return ""
}

function Ensure-Command {
    param([string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $Name"
    }
}

function Verify-Contract {
    param(
        [string]$Chain,
        [string]$Url,
        [string]$Address,
        [string]$Contract,
        [string]$ConstructorArgs
    )

    Write-Host ""
    Write-Host "Verifying $Contract at $Address"

    $cmd = @(
        "verify-contract",
        "--chain-id", $Chain,
        "--verifier", "blockscout",
        "--verifier-url", $Url,
        $Address,
        $Contract
    )

    if (-not [string]::IsNullOrWhiteSpace($ConstructorArgs)) {
        $cmd += @("--constructor-args", $ConstructorArgs)
    }

    $cmd += "--watch"

    & forge @cmd
    if ($LASTEXITCODE -ne 0) {
        throw "Verification failed for $Contract"
    }
}

Ensure-Command -Name "forge"
Ensure-Command -Name "cast"

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}

$envPath = Join-Path $ProjectRoot ".env"
$envMap = Parse-DotEnv -Path $envPath

$ChainId = Get-Setting -EnvMap $envMap -CurrentValue $ChainId -Keys @("EXPECTED_CHAIN_ID", "CHAIN_ID") -Label "ChainId" -Required
$RegistryAddress = Get-Setting -EnvMap $envMap -CurrentValue $RegistryAddress -Keys @("MARKETPLACE_REGISTRY_ADDRESS", "AGENT_REGISTRY_ADDRESS", "REGISTRY_ADDRESS") -Label "RegistryAddress" -Required
$ReputationAddress = Get-Setting -EnvMap $envMap -CurrentValue $ReputationAddress -Keys @("REPUTATION_ADDRESS") -Label "ReputationAddress" -Required
$EscrowAddress = Get-Setting -EnvMap $envMap -CurrentValue $EscrowAddress -Keys @("JOB_ESCROW_ADDRESS", "ESCROW_ADDRESS") -Label "EscrowAddress" -Required
$ManagerAddress = Get-Setting -EnvMap $envMap -CurrentValue $ManagerAddress -Keys @("JOB_MANAGER_ADDRESS", "MANAGER_ADDRESS") -Label "ManagerAddress" -Required
$BidBoardAddress = Get-Setting -EnvMap $envMap -CurrentValue $BidBoardAddress -Keys @("BID_BOARD_ADDRESS", "BIDBOARD_ADDRESS") -Label "BidBoardAddress" -Required
$UsdcAddress = Get-Setting -EnvMap $envMap -CurrentValue $UsdcAddress -Keys @("USDC_ADDRESS") -Label "UsdcAddress" -Required
$ArcIdentityRegistry = Get-Setting -EnvMap $envMap -CurrentValue $ArcIdentityRegistryAddress -Keys @("ARC_IDENTITY_REGISTRY") -Label "ArcIdentityRegistry" -Required

Write-Host "Project root: $ProjectRoot"
Write-Host "Chain ID: $ChainId"
Write-Host "Verifier URL: $VerifierUrl"

Push-Location $ProjectRoot
try {
    $escrowArgs = (& cast abi-encode "constructor(address)" $UsdcAddress).Trim()
    if ($LASTEXITCODE -ne 0) { throw "Failed to encode JobEscrow constructor args" }

    $managerArgs = (& cast abi-encode "constructor(address,address,address,address)" $RegistryAddress $EscrowAddress $ReputationAddress $ArcIdentityRegistry).Trim()
    if ($LASTEXITCODE -ne 0) { throw "Failed to encode JobManager constructor args" }

    $bidBoardArgs = (& cast abi-encode "constructor(address,address,address)" $ManagerAddress $RegistryAddress $ReputationAddress).Trim()
    if ($LASTEXITCODE -ne 0) { throw "Failed to encode BidBoard constructor args" }

    Verify-Contract -Chain $ChainId -Url $VerifierUrl -Address $RegistryAddress -Contract "src/MarketplaceRegistry.sol:MarketplaceRegistry"
    Verify-Contract -Chain $ChainId -Url $VerifierUrl -Address $ReputationAddress -Contract "src/ReputationOracle.sol:ReputationOracle"
    Verify-Contract -Chain $ChainId -Url $VerifierUrl -Address $EscrowAddress -Contract "src/JobEscrow.sol:JobEscrow" -ConstructorArgs $escrowArgs
    Verify-Contract -Chain $ChainId -Url $VerifierUrl -Address $ManagerAddress -Contract "src/JobManager.sol:JobManager" -ConstructorArgs $managerArgs
    Verify-Contract -Chain $ChainId -Url $VerifierUrl -Address $BidBoardAddress -Contract "src/BidBoard.sol:BidBoard" -ConstructorArgs $bidBoardArgs

    Write-Host ""
    Write-Host "All contract verifications completed successfully."
}
finally {
    Pop-Location
}
