$ErrorActionPreference = 'Stop'
$VerbosePreference     = 'SilentlyContinue'
Set-Location $PSScriptRoot

Get-ChildItem -Path '..\includes' -Filter '*.ps1' |% {
    Write-Verbose "Dot-sourcing $($_.FullName)"
    . $_.FullName
}

function Get-Configuration
{
    $hostRoot        = (Get-Item '..').FullName
    $configuration   = Get-Content -Path "$hostRoot\configs\invoke-media-copy.json" -Raw | ConvertFrom-Json
    $sourceFolder    = (Get-Item $configuration.mediaSourceFolder).FullName
    $hostMediaFolder = "$hostRoot\$($configuration.hostMediaFolderName)"
    $markerPath      = "$hostMediaFolder\$($configuration.markerFileName)"
    $isoPath         = "$sourceFolder\$($configuration.isoFileName)"
    $setupFolder     = "$hostMediaFolder\$($configuration.setupFolderName)"

    $configuration | Add-Member -NotePropertyName 'SourceFolder'    -NotePropertyValue $sourceFolder    -Force
    $configuration | Add-Member -NotePropertyName 'HostMediaFolder' -NotePropertyValue $hostMediaFolder -Force
    $configuration | Add-Member -NotePropertyName 'MarkerPath'      -NotePropertyValue $markerPath      -Force
    $configuration | Add-Member -NotePropertyName 'IsoPath'         -NotePropertyValue $isoPath         -Force
    $configuration | Add-Member -NotePropertyName 'SetupFolder'     -NotePropertyValue $setupFolder     -Force
    return $configuration
}

function Invoke-PreflightCheck($configuration)
{
    $isoPath = $configuration.IsoPath
    if (!(Test-Path -LiteralPath $isoPath))
    {
        throw "no $isoPath, so the media this pipeline installs from is not on this host"
    }

    $filesToCopy = $configuration.filesToCopy
    $sourceFolder = $configuration.SourceFolder
    $filesToCopy |% {
        $fileName = $_
        $filePath = "$sourceFolder\$fileName"
        if (!(Test-Path -LiteralPath $filePath))
        {
            throw "no $filePath, so the media this pipeline installs from is not on this host"
        }
    }
}

function Test-ShouldSeedMedia($configuration)
{
    $markerPath = $configuration.MarkerPath
    return !(Test-Path -LiteralPath $markerPath)
}

function Invoke-MediaFileCopy($configuration)
{
    if (!(Test-ShouldSeedMedia $configuration))
    {
        return
    }

    $sourceFolder    = $configuration.SourceFolder
    $hostMediaFolder = $configuration.HostMediaFolder
    $filesToCopy     = $configuration.filesToCopy
    $null = New-Item -ItemType Directory -Path $hostMediaFolder -Force
    $filesToCopy |% {
        $fileName = $_
        $filePath = "$sourceFolder\$fileName"
        Write-Log "copying $filePath into $hostMediaFolder"
        Copy-Item -Path $filePath -Destination $hostMediaFolder -Force
    }
}

function Invoke-IsoExtraction($configuration)
{
    if (!(Test-ShouldSeedMedia $configuration))
    {
        return
    }

    $isoPath     = $configuration.IsoPath
    $setupFolder = $configuration.SetupFolder
    Write-Log "mounting $isoPath"
    $null = Mount-DiskImage -ImagePath $isoPath
    $volume = Get-DiskImage -ImagePath $isoPath | Get-Volume
    $drive  = "$($volume.DriveLetter):"
    Write-Log "copying $drive into $setupFolder"
    $null = New-Item -ItemType Directory -Path $setupFolder -Force
    Copy-Item -Path "$drive\*" -Destination $setupFolder -Recurse -Force
    Write-Log "dismounting $isoPath"
    $null = Dismount-DiskImage -ImagePath $isoPath
}

function Invoke-MarkerWrite($configuration)
{
    if (!(Test-ShouldSeedMedia $configuration))
    {
        return
    }

    $markerPath   = $configuration.MarkerPath
    $sourceFolder = $configuration.SourceFolder
    Set-Content -Path $markerPath -Value "media copied from $sourceFolder"
    Write-Log "the media is seeded, and $markerPath records it"
}

$configuration = Get-Configuration
Invoke-PreflightCheck $configuration
Invoke-MediaFileCopy $configuration
Invoke-IsoExtraction $configuration
Invoke-MarkerWrite $configuration
Write-Log '=== media copy complete ==='
