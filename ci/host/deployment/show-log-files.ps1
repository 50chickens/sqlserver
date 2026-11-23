$ErrorActionPreference = 'Stop'
$VerbosePreference     = 'SilentlyContinue'
Set-Location $PSScriptRoot

Get-ChildItem -Path '..\includes' -Filter '*.ps1' |% {
    Write-Verbose "Dot-sourcing $($_.FullName)"
    . $_.FullName
}

function Get-Configuration
{
    $hostRoot      = (Get-Item '..').FullName
    $configuration = Get-Content -Path "$hostRoot\configs\show-log-files.json" -Raw | ConvertFrom-Json
    $configuration | Add-Member -NotePropertyName 'HostRoot' -NotePropertyValue $hostRoot -Force
    return $configuration
}

function Add-RuntimeConfiguration($configuration)
{
    $hostRoot = $configuration.HostRoot
    $sources  = $configuration.logSources |? { $_.enabled } |% {
        $source   = $_
        $rootPath = "$hostRoot\$($source.rootFolder)"
        [pscustomobject]@{
            Description = $source.description
            RootPath    = $rootPath
            SubFolder   = $source.subFolderName
            FileFilter  = $source.fileFilter
        }
    }

    $configuration | Add-Member -NotePropertyName 'LogSources' -NotePropertyValue $sources -Force
    return $configuration
}

function Invoke-PreflightCheck($configuration)
{
    $sources = $configuration.LogSources
    if ($sources.Count -eq 0)
    {
        throw "no log source is enabled in $($configuration.HostRoot)\configs\show-log-files.json"
    }

    $sources |% {
        $source = $_
        if (!(Test-Path -LiteralPath $source.RootPath))
        {
            throw "no folder $($source.RootPath), so there is nothing to read for $($source.Description)"
        }
        $runs = Get-ChildItem -Path $source.RootPath -Directory
        if ($runs.Count -eq 0)
        {
            throw "no run folder under $($source.RootPath), so there is nothing to read for $($source.Description)"
        }
    }
}

function Invoke-LogReport($configuration)
{
    $tailFiles = $configuration.tailFiles
    $tailLines = $configuration.tailLines
    $sources   = $configuration.LogSources

    $sources |% {
        $source = $_
        $run    = Get-ChildItem -Path $source.RootPath -Directory | Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1
        $logPath = $run.FullName
        if ($source.SubFolder -ne '')
        {
            $logPath = "$($run.FullName)\$($source.SubFolder)"
        }

        Write-Log "reading $($source.Description) from $logPath"
        $files = Get-ChildItem -Path $logPath -Filter $source.FileFilter -File -Recurse | Sort-Object -Property LastWriteTime -Descending | Select-Object -First $tailFiles
        if ($files.Count -eq 0)
        {
            Write-Log "no file matching $($source.FileFilter) in $logPath"
        }
        $files |% {
            $file = $_
            Write-Log "===== $($file.FullName) ====="
            Get-Content -Path $file.FullName -Tail $tailLines |% { Write-Log "$_" }
        }
    }
}

$configuration = Get-Configuration
$configuration = Add-RuntimeConfiguration $configuration
Invoke-PreflightCheck $configuration
Invoke-LogReport $configuration
Write-Log '=== log report complete ==='
