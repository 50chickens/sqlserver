$ErrorActionPreference = 'Stop'
$VerbosePreference     = 'SilentlyContinue'
Set-Location $PSScriptRoot

Get-ChildItem -Path '..\includes' -Filter '*.ps1' |% {
    Write-Verbose "Dot-sourcing $($_.FullName)"
    . $_.FullName
}

function Get-Configuration
{
    $configuration     = Get-Content -Path '..\configs\invoke-stage.json' -Raw | ConvertFrom-Json
    $dockerBuildFolder = (Get-Item $configuration.dockerBuildFolder).FullName
    $sourceRoot        = (Get-Item '..\..\..\src').FullName

    $configuration | Add-Member -NotePropertyName 'DockerBuildFolder' -NotePropertyValue $dockerBuildFolder -Force
    $configuration | Add-Member -NotePropertyName 'SourceRoot'        -NotePropertyValue $sourceRoot        -Force
    return $configuration
}

function Invoke-PreflightCheck($configuration)
{
    $sourceRoot       = $configuration.SourceRoot
    $stageFolderNames = $configuration.stageFolderNames
    $stageFolderNames |% {
        $folderName   = $_
        $sourceFolder = "$sourceRoot\$folderName"
        if (!(Test-Path -Path $sourceFolder))
        {
            throw "no container source at $sourceFolder"
        }
    }
}

function Invoke-SourceCopy($configuration)
{
    $sourceRoot        = $configuration.SourceRoot
    $dockerBuildFolder = $configuration.DockerBuildFolder
    $stageFolderNames  = $configuration.stageFolderNames
    $stageFolderNames |% {
        $folderName        = $_
        $sourceFolder      = "$sourceRoot\$folderName"
        $destinationFolder = "$dockerBuildFolder\$folderName"
        if (Test-Path -Path $destinationFolder)
        {
            Write-Log "emptying $destinationFolder"
            Remove-Item -Path $destinationFolder -Recurse -Force
        }

        Write-Log "copying $sourceFolder into $destinationFolder"
        Copy-Item -Path $sourceFolder -Destination $destinationFolder -Recurse -Force
    }
}

$configuration = Get-Configuration
Invoke-PreflightCheck $configuration
Invoke-SourceCopy $configuration
Write-Log '=== stage complete ==='
