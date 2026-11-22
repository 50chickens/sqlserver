$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$VerbosePreference     = 'SilentlyContinue'
Set-Location $PSScriptRoot

function Write-Log($message)
{
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Write-Host "[$stamp] $message"
}

function Get-Configuration
{
    $scriptFolder     = (Get-Item '.').FullName
    $installerFolder  = (Get-Item "$scriptFolder\..\installer").FullName
    $scriptsToExecute = @(
        [pscustomobject]@{ Enabled = $true; FilePath = "$installerFolder\sql-server\install.ps1" }
        [pscustomobject]@{ Enabled = $true; FilePath = "$installerFolder\report-server\install.ps1" }
    )

    return [pscustomobject]@{
        InstallerFolder  = $installerFolder
        ScriptsToExecute = $scriptsToExecute
    }
}

function Invoke-PreflightCheck($configuration)
{
    $enabled = @($configuration.ScriptsToExecute |? { $_.Enabled })
    $enabled |% {
        $entry = $_
        if (!(Test-Path -Path $entry.FilePath))
        {
            throw "build step not found: $($entry.FilePath)"
        }
    }
}

function Invoke-BuildSteps($configuration)
{
    $scriptsToExecute = $configuration.ScriptsToExecute
    Write-Log "Found $(@($scriptsToExecute |? { $_.Enabled }).Count) enabled script(s) of $($scriptsToExecute.Count)"
    $scriptsToExecute |? { $_.Enabled } |% {
        $script = $_
        Write-Log "=== $($script.FilePath) ==="
        & $script.FilePath
    }
}

$configuration = Get-Configuration
Invoke-PreflightCheck $configuration
Invoke-BuildSteps $configuration
Write-Log '=== CI complete ==='
