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
    $configuration = Get-Content -Path "$hostRoot\configs\invoke-docker-host-exec.json" -Raw | ConvertFrom-Json
    $configuration | Add-Member -NotePropertyName 'HostRoot' -NotePropertyValue $hostRoot -Force
    return $configuration
}

function Add-RuntimeConfiguration($configuration)
{
    $hostRoot        = $configuration.HostRoot
    $sourceFolder    = (Get-Item $configuration.payloadRelativePath).FullName
    $hostMediaFolder = "$hostRoot\$($configuration.hostBindMountFolderName)"
    $runStamp        = (Get-Date).ToString($configuration.runStampFormat)
    $logFolder       = "$hostMediaFolder\$($configuration.serviceName)\$runStamp\$($configuration.logFolderName)"
    $execLogFolder   = "$hostRoot\logs\provision-$runStamp"

    $bindMounts = $configuration.bindMounts |% {
        $mount = $_
        switch ($mount.name)
        {
            'logs'    { $mountHostPath = $logFolder }
            'media'   { $mountHostPath = $hostMediaFolder }
            'payload' { $mountHostPath = $sourceFolder }
        }
        [pscustomobject]@{
            Name          = $mount.name
            HostPath      = $mountHostPath
            ContainerPath = $mount.containerPath
            ReadOnly      = [bool]$mount.readOnly
            Tail          = [bool]$mount.tail
            LogFilter     = $mount.logFilter
        }
    }

    $configuration | Add-Member -NotePropertyName 'SourceFolder'  -NotePropertyValue $sourceFolder  -Force
    $configuration | Add-Member -NotePropertyName 'HostMediaFolder' -NotePropertyValue $hostMediaFolder -Force
    $configuration | Add-Member -NotePropertyName 'RunStamp'      -NotePropertyValue $runStamp      -Force
    $configuration | Add-Member -NotePropertyName 'LogFolder'     -NotePropertyValue $logFolder     -Force
    $configuration | Add-Member -NotePropertyName 'ExecLogFolder' -NotePropertyValue $execLogFolder -Force
    $configuration | Add-Member -NotePropertyName 'BindMounts'    -NotePropertyValue $bindMounts    -Force
    return $configuration
}

function Get-TailMounts($configuration)
{
    $tailMounts = $configuration.BindMounts |? { $_.Tail }
    return $tailMounts
}

function Write-BindMountReport($configuration)
{
    $configuration.BindMounts |% {
        $mount = $_
        Write-Log "bind mount $($mount.Name): $($mount.HostPath) over $($mount.ContainerPath) readOnly=$($mount.ReadOnly)"
    }
}

function Invoke-PreflightCheck($configuration)
{
    $imageName     = $configuration.imageName
    $execLogFolder = $configuration.ExecLogFolder
    Write-Log "provisioning run $($configuration.RunStamp) for the $($configuration.serviceName) service"
    Write-BindMountReport $configuration

    $configuration.BindMounts |% {
        $mount = $_
        $null = New-Item -ItemType Directory -Path $mount.HostPath -Force
    }
    $null = New-Item -ItemType Directory -Path $execLogFolder -Force

    $null = docker image inspect --format '{{.Id}}' $imageName
    if ($LASTEXITCODE -ne 0)
    {
        throw "no image $imageName, so the docker build step did not run"
    }
}

function Invoke-ContainerStart($configuration)
{
    $containerName = $configuration.containerName
    $imageName     = $configuration.imageName
    $existing      = @(docker container list --all --format '{{.Names}}' |? { $_ -eq $containerName })
    if ($existing.Count -eq 1 -and (Test-ProductProbes $configuration))
    {
        Write-Log "container $containerName already holds the product, so the installers are not run again"
        return $false
    }

    if ($existing.Count -eq 1)
    {
        Write-Log "removing container $containerName, which this pipeline owns"
        $null = docker container rm --force $containerName
    }

    $mountArguments = @()
    $configuration.BindMounts |% {
        $mount      = $_
        $definition = "type=bind,source=$($mount.HostPath),target=$($mount.ContainerPath)"
        if ($mount.ReadOnly)
        {
            $definition = "$definition,readonly"
        }
        $mountArguments += @('--mount', $definition)
    }

    $dockerArguments  = @('run', '--detach', '--name', $containerName)
    $dockerArguments += $mountArguments
    $dockerArguments += $imageName
    $dockerArguments += @('powershell', '-NoProfile', '-Command', 'while ($true) { Start-Sleep -Seconds 5 }')

    Write-Log "docker $($dockerArguments -join ' ')"
    & docker @dockerArguments
    if ($LASTEXITCODE -ne 0)
    {
        throw "docker run exited with code $LASTEXITCODE"
    }

    return $true
}

function Invoke-ScriptExecution($configuration)
{
    $containerName = $configuration.containerName
    $execLogFolder = $configuration.ExecLogFolder
    $tailMounts    = Get-TailMounts $configuration
    $scriptPath    = $configuration.containerScriptPath
    $dockerArguments = @('exec', $containerName, 'powershell', '-NoProfile', '-File', $scriptPath)
    $parameters = @{
        FilePath               = 'docker'
        ArgumentList           = $dockerArguments
        RedirectStandardOutput = "$execLogFolder\docker-exec.log"
        RedirectStandardError  = "$execLogFolder\docker-exec.error.log"
        PassThru               = $true
        WindowStyle            = 'Hidden'
    }

    Write-Log "docker $($dockerArguments -join ' ')"
    $process = Start-Process @parameters
    $null = $process.Handle
    $exitCode = Wait-TailedProcess $process $execLogFolder $tailMounts
    if ($exitCode -ne 0)
    {
        Invoke-LogReport $configuration
        throw "docker exec exited with code $exitCode"
    }
}

function Invoke-LogReport($configuration)
{
    $tailFiles  = $configuration.logTailFiles
    $tailMounts = Get-TailMounts $configuration
    $tailMounts |% {
        $mount = $_
        $logs  = Get-ChildItem -Path $mount.HostPath -Filter $mount.LogFilter -File -Recurse | Sort-Object -Property LastWriteTime -Descending
        $logs | Select-Object -First $tailFiles |% {
            $log = $_
            Write-Log "===== $($log.FullName) ====="
            Get-Content -Path $log.FullName |% { Write-Log "$_" }
        }
    }
}

function Test-ProductProbe($configuration, $probe)
{
    $containerName = $configuration.containerName
    switch ($probe.probeType)
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
    return "$present".Trim() -eq 'True'
}

function Test-ProductProbes($configuration)
{
    $probes = $configuration.probes
    $absent = $probes |? { !(Test-ProductProbe $configuration $_) }
    return $absent.Count -eq 0
}

function Invoke-ProductProbe($configuration)
{
    $probes = $configuration.probes
    $probes |% {
        $probe = $_
        if (!(Test-ProductProbe $configuration $probe))
        {
            Invoke-LogReport $configuration
            throw "$($probe.value) is absent in $($configuration.containerName), so the install did not happen"
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
$configuration = Add-RuntimeConfiguration $configuration
Invoke-PreflightCheck $configuration
$fresh = Invoke-ContainerStart $configuration
if ($fresh)
{
    Invoke-ScriptExecution $configuration
}
Invoke-ProductProbe $configuration
Invoke-ImageCommit $configuration
Invoke-ContainerRemoval $configuration
Invoke-ImageCleanup $configuration
Write-Log '=== image provisioned ==='
