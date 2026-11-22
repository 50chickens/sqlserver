$ErrorActionPreference = 'Stop'
$VerbosePreference     = 'SilentlyContinue'
Set-Location $PSScriptRoot

function Write-Log($message)
{
    Write-Host "[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] $message"
}

function Get-Configuration
{
    $hostRoot      = (Get-Item '..').FullName
    $configuration = Get-Content -Path "$hostRoot\configs\invoke-container-command.json" -Raw | ConvertFrom-Json

    return $configuration
}

function Invoke-ContainerCommand($configuration)
{
    $containerName = $configuration.containerName
    $command       = $configuration.command
    $running       = @(docker container list --format '{{.Names}}' |? { $_ -eq $containerName })
    if ($running.Count -ne 1)
    {
        throw "no running container named $containerName"
    }

    $bytes   = [System.Text.Encoding]::Unicode.GetBytes($command)
    $encoded = [Convert]::ToBase64String($bytes)
    Write-Log "running the command in $containerName"
    & docker exec $containerName powershell -NoProfile -EncodedCommand $encoded |% { Write-Log "$_" }
    $exitCode = $LASTEXITCODE
    Write-Log "the command exited with $exitCode"
}

$configuration = Get-Configuration
Invoke-ContainerCommand $configuration
