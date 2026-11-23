#requires -Version 5.1

param(
    [Parameter(Mandatory = $true)]
    [string] $Expected
)

$ErrorActionPreference = 'Stop'
$VerbosePreference     = 'SilentlyContinue'
Set-Location $PSScriptRoot

function Write-Log($message)
{
    Write-Host "[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] $message"
}

$settings             = Get-Content -Path "$PSScriptRoot\settings.json" -Raw | ConvertFrom-Json
$wmiNamespace         = $settings.wmiNamespace
$configurationSetting = Get-CimInstance -Namespace $wmiNamespace -ClassName 'MSReportServer_ConfigurationSetting' | Select-Object -First 1
$result               = Invoke-CimMethod -InputObject $configurationSetting -MethodName 'ListReportServersInDatabase' -Arguments @{}
if ($result.HRESULT -ne 0)
{
    throw "ListReportServersInDatabase returned HRESULT $($result.HRESULT) and $($result.ExtendedErrors)"
}

$localMachine    = [System.Net.Dns]::GetHostName()
$expectedMembers = $Expected.Split(',') |% { $_.ToUpperInvariant() } | Sort-Object
$machines        = $result.MachineNames
$initialized     = $result.IsInitialized
$index           = 0
$localSeen       = $false
$localReady      = $false
$machines |% {
    $member = $_
    Write-Log "$localMachine sees $member initialised $($initialized[$index])"
    if ($member -ieq $localMachine)
    {
        $localSeen  = $true
        $localReady = [bool]$initialized[$index]
    }

    $index = $index + 1
}

$actualMembers = $machines |% { $_.ToUpperInvariant() } | Sort-Object
if (($actualMembers -join ',') -ne ($expectedMembers -join ','))
{
    throw "$localMachine sees the farm as $($actualMembers -join ', ') rather than $($expectedMembers -join ', ')"
}

if (!$localSeen)
{
    throw "$localMachine is not in its own view of the farm"
}

if (!$localReady)
{
    throw "$localMachine is in the farm but not initialised"
}

Write-Log "$localMachine sees the farm as $($actualMembers -join ', ')"
