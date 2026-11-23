#requires -Version 5.1

$ErrorActionPreference = 'Stop'
$VerbosePreference     = 'SilentlyContinue'
Set-Location $PSScriptRoot

function Write-Log($message)
{
    Write-Host "[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] $message"
}

function Get-NodeInstallationId($machineName)
{
    $md5  = [System.Security.Cryptography.MD5]::Create()
    $hash = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($machineName.ToUpperInvariant()))
    $guid = [System.Guid]::new($hash)
    return $guid.ToString()
}

function Set-NodeInstallationId($configPath, $installationId)
{
    $text    = Get-Content -LiteralPath $configPath -Raw
    $updated = $text -replace '<InstallationID>[^<]*</InstallationID>', "<InstallationID>{$installationId}</InstallationID>"
    Set-Content -Path $configPath -Value $updated -Encoding UTF8 -NoNewline
}

$settings             = Get-Content -Path "$PSScriptRoot\settings.json" -Raw | ConvertFrom-Json
$reportServerConfig   = $settings.reportServerConfigPath
$serviceName          = $settings.serviceName
$localMachine         = [System.Net.Dns]::GetHostName()
$installationId       = Get-NodeInstallationId $localMachine

$service = Get-Service -Name $serviceName
if ($service.Status -ne 'Stopped')
{
    $service.WaitForStatus('Running', [TimeSpan]::FromSeconds(120))
    Stop-Service -Name $serviceName -Force
    $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(120))
}

Set-NodeInstallationId $reportServerConfig $installationId
Write-Log "$localMachine joins the farm as report server installation $installationId"
Start-Service -Name $serviceName
Set-Content -Path 'C:\node-ready.txt' -Value $installationId
Write-Log "$serviceName is running under installation $installationId"
while ($true)
{
    Start-Sleep -Seconds 60
}
