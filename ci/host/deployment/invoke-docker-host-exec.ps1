$ErrorActionPreference = 'Stop'
$VerbosePreference     = 'SilentlyContinue'
Set-Location $PSScriptRoot

Get-ChildItem -Path '..\includes' -Filter '*.ps1' |% {
    Write-Verbose "Dot-sourcing $($_.FullName)"
    . $_.FullName
}

function Get-Configuration
{
    $hostRoot           = (Get-Item '..').FullName
    $configuration      = Get-Content -Path "$hostRoot\configs\invoke-docker-host-exec.json" -Raw | ConvertFrom-Json
    $sourceRoot         = (Get-Item '..\..\..\src').FullName
    $sourceFolder       = "$sourceRoot\sqlserver"
    $hostMediaFolder    = (Get-Item "$hostRoot\host_bind_mount").FullName
    $logFolderName      = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $logFolder          = "$hostMediaFolder\logs\$logFolderName"

    $configuration | Add-Member -NotePropertyName 'SourceFolder'       -NotePropertyValue $sourceFolder       -Force
    $configuration | Add-Member -NotePropertyName 'HostMediaFolder'    -NotePropertyValue $hostMediaFolder    -Force
    $configuration | Add-Member -NotePropertyName 'LogFolder'          -NotePropertyValue $logFolder          -Force
    return $configuration
}

function Invoke-PreflightCheck($configuration)
{
    $imageName = $configuration.imageName
    $logFolder = $configuration.LogFolder
    $null = New-Item -ItemType Directory -Path $logFolder -Force
    Write-Log "the media this run reads is in $($configuration.HostMediaFolder), its logs go to $logFolder"

    $null = docker image inspect --format '{{.Id}}' $imageName
    if ($LASTEXITCODE -ne 0)
    {
        throw "no image $imageName, so the docker build step did not run"
    }
}

function Invoke-ContainerStart($configuration)
{
    $containerName   = $configuration.containerName
    $imageName       = $configuration.imageName
    $sourceFolder    = $configuration.SourceFolder
    $hostMediaFolder = $configuration.HostMediaFolder
    $containerFolder = $configuration.containerFolder
    $mediaFolder     = $configuration.containerMediaFolder
    $existing        = @(docker container list --all --format '{{.Names}}' |? { $_ -eq $containerName })
    if ($existing.Count -eq 1)
    {
        Write-Log "removing container $containerName, which this pipeline owns"
        $null = docker container rm --force $containerName
    }

    $dockerArguments  = @('run', '--detach', '--name', $containerName)
    $dockerArguments += @('--volume', "${sourceFolder}:${containerFolder}")
    $dockerArguments += @('--volume', "${hostMediaFolder}:${mediaFolder}")
    $dockerArguments += $imageName
    $dockerArguments += @('powershell', '-NoProfile', '-Command', 'while ($true) { Start-Sleep -Seconds 5 }')

    Write-Log "docker $($dockerArguments -join ' ')"
    & docker @dockerArguments
    if ($LASTEXITCODE -ne 0)
    {
        throw "docker run exited with code $LASTEXITCODE"
    }
}

function Invoke-ScriptExecution($configuration)
{
    $containerName   = $configuration.containerName
    $containerFolder = $configuration.containerFolder
    $logFolder       = $configuration.LogFolder
    $scriptPath      = "$containerFolder\scripts\ci-host-bind-mount.ps1"
    $dockerArguments = @('exec', $containerName, 'powershell', '-NoProfile', '-File', $scriptPath)
    $parameters = @{
        FilePath               = 'docker'
        ArgumentList           = $dockerArguments
        RedirectStandardOutput = "$logFolder\docker-exec.log"
        RedirectStandardError  = "$logFolder\docker-exec.error.log"
        PassThru               = $true
        WindowStyle            = 'Hidden'
    }

    Write-Log "docker $($dockerArguments -join ' ')"
    $process = Start-Process @parameters
    $null = $process.Handle
    $exitCode = Wait-LoggedProcess $process $logFolder
    if ($exitCode -ne 0)
    {
        Invoke-LogReport $configuration
        throw "docker exec exited with code $exitCode"
    }
}

function Invoke-LogReport($configuration)
{
    $logFolder = $configuration.LogFolder
    $tailFiles = $configuration.logTailFiles
    $logs = @(Get-ChildItem -Path $logFolder -File | Sort-Object -Property LastWriteTime -Descending)
    $logs | Select-Object -First $tailFiles |% {
        $log = $_
        Write-Log "===== $($log.Name) ====="
        Get-Content -Path $log.FullName |% { Write-Log "$_" }
    }
}

function Invoke-ProductProbe($configuration)
{
    $containerName = $configuration.containerName
    $probes        = $configuration.probes
    $probes |% {
        $probe = $_
        switch ($probe.kind)
        {
            'path'
            {
                $command = "Test-Path -LiteralPath '$($probe.value)'"
            }
            'service'
            {
                $command = "if (Get-Service -Name '$($probe.value)' -ErrorAction SilentlyContinue) { 'True' } else { 'False' }"
            }
        }

        $present = & docker exec $containerName powershell -NoProfile -Command $command
        if ("$present".Trim() -ne 'True')
        {
            Invoke-LogReport $configuration
            throw "$($probe.value) is absent in $containerName, so the install did not happen"
        }

        Write-Log "$($probe.value) is present"
    }
}

function Invoke-ImageCommit($configuration)
{
    $containerName = $configuration.containerName
    $imageName     = $configuration.imageName

    Write-Log "stopping container $containerName, because docker does not commit a running container"
    $null = docker container stop $containerName
    if ($LASTEXITCODE -ne 0)
    {
        throw "docker container stop exited with code $LASTEXITCODE"
    }

    Write-Log "committing $containerName to $imageName"
    $command = 'CMD [\"powershell\",\"-NoProfile\"]'
    $imageId = & docker commit --change $command $containerName $imageName
    if ($LASTEXITCODE -ne 0)
    {
        throw "docker commit exited with code $LASTEXITCODE"
    }

    Write-Log "the commit produced $imageId"
    $committedCommand = & docker image inspect --format '{{json .Config.Cmd}}' $imageName
    Write-Log "the committed image runs $committedCommand"
    if ($committedCommand -match 'cmd /S /C')
    {
        throw "the commit wrote $committedCommand in shell form, so the image would not start powershell directly"
    }
}

function Invoke-ContainerRemoval($configuration)
{
    $containerName = $configuration.containerName
    Write-Log "removing container $containerName"
    $null = docker container rm --force $containerName
}

$configuration = Get-Configuration
Invoke-PreflightCheck $configuration
Invoke-ContainerStart $configuration
Invoke-ScriptExecution $configuration
Invoke-ProductProbe $configuration
Invoke-ImageCommit $configuration
Invoke-ContainerRemoval $configuration
Invoke-ImageCleanup $configuration
Write-Log '=== image provisioned ==='
