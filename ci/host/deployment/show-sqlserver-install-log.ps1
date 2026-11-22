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
    $configuration = Get-Content -Path "$hostRoot\configs\invoke-docker-host-exec.json" -Raw | ConvertFrom-Json
    $command       = 'Get-Service | Where-Object { $_.Name -match "Report|MSSQL|MsDts|SQL" } | ForEach-Object { "$($_.Name) $($_.Status)" }'

    $configuration | Add-Member -NotePropertyName 'DiagnosticCommand' -NotePropertyValue $command -Force
    return $configuration
}

function Invoke-ScriptReport($configuration)
{
    $containerName = $configuration.containerName
    $command       = $configuration.DiagnosticCommand
    $running       = @(docker container list --format '{{.Names}}' |? { $_ -eq $containerName })
    if ($running.Count -ne 1)
    {
        throw "no running container named $containerName, so there is nothing to read"
    }

    $bytes   = [System.Text.Encoding]::Unicode.GetBytes($command)
    $encoded = [Convert]::ToBase64String($bytes)
    Write-Log "=== $command ==="
    & docker exec $containerName powershell -NoProfile -EncodedCommand $encoded |% { Write-Log "$_" }
    $exitCode = $LASTEXITCODE
    Write-Log "the command exited with $exitCode"
}

$configuration = Get-Configuration
Invoke-ScriptReport $configuration
