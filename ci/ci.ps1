$ErrorActionPreference = 'Stop'
$VerbosePreference     = 'SilentlyContinue'
Set-Location $PSScriptRoot

Get-ChildItem -Path '.\host\includes' -Filter '*.ps1' |% {
    Write-Verbose "Dot-sourcing $($_.FullName)"
    . $_.FullName
}

function Get-Configuration
{
    $hostRoot         = (Get-Item '.\host').FullName
    $buildConfig      = Get-Content -Path "$hostRoot\configs\invoke-docker-build.json" -Raw | ConvertFrom-Json
    $deploymentRoot   = "$hostRoot\deployment"
    $scriptsToExecute = @(
        [pscustomobject]@{ Enabled = $true; FilePath = "$deploymentRoot\invoke-media-copy.ps1" }
        [pscustomobject]@{ Enabled = $true; FilePath = "$deploymentRoot\invoke-stage.ps1" }
        [pscustomobject]@{ Enabled = $true; FilePath = "$deploymentRoot\invoke-docker-build.ps1" }
        [pscustomobject]@{ Enabled = $true; FilePath = "$deploymentRoot\invoke-docker-host-exec.ps1" }
    )

    $configuration = [pscustomobject]@{}
    $configuration | Add-Member -MemberType NoteProperty -Name 'ImageName' -Value $buildConfig.imageName
    $configuration | Add-Member -MemberType NoteProperty -Name 'ScriptsToExecute' -Value $scriptsToExecute
    return $configuration
}

function Invoke-PreflightCheck($configuration)
{
    $configuration.ScriptsToExecute |? { $_.Enabled } |% {
        $entry = $_
        if (!(Test-Path -Path $entry.FilePath))
        {
            throw "not found: $($entry.FilePath)"
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
