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
    $configuration   = Get-Content -Path "$hostRoot\configs\invoke-docker-compose.json" -Raw | ConvertFrom-Json
    $composeFilePath = (Get-Item "$hostRoot\$($configuration.composeFilePath)").FullName
    $logStamp        = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $logFolder       = "$hostRoot\logs\compose-$logStamp"

    $configuration | Add-Member -NotePropertyName 'ComposeFilePath' -NotePropertyValue $composeFilePath -Force
    $configuration | Add-Member -NotePropertyName 'LogFolder'       -NotePropertyValue $logFolder       -Force
    return $configuration
}

function Invoke-PreflightCheck($configuration)
{
    $composePath    = $configuration.ComposePath
    $logFolder      = $configuration.LogFolder
    $composeVersion = & $composePath version --short
    if ($LASTEXITCODE -ne 0)
    {
        throw "$composePath did not answer on this host"
    }

    $null = New-Item -ItemType Directory -Path $logFolder -Force
    Write-Log "$composePath $composeVersion, its output goes to $logFolder"
}

function Invoke-ComposeUp($configuration)
{
    $composePath     = $configuration.ComposePath
    $composeFilePath = $configuration.ComposeFilePath
    $projectName     = $configuration.projectName
    $logFolder       = $configuration.LogFolder
    $parameters = @{
        FilePath               = $composePath
        ArgumentList           = @('--project-name', $projectName, '--file', $composeFilePath, 'up', '--detach', '--remove-orphans')
        RedirectStandardOutput = "$logFolder\compose.log"
        RedirectStandardError  = "$logFolder\compose.error.log"
        PassThru               = $true
        WindowStyle            = 'Hidden'
    }

    Write-Log "starting project $projectName from $composeFilePath"
    $process = Start-Process @parameters
    $null = $process.Handle
    $exitCode = Wait-LoggedProcess $process $logFolder
    if ($exitCode -ne 0)
    {
        throw "compose up exited with code $exitCode"
    }
}

function Wait-ComposeRunning($configuration)
{
    $projectName    = $configuration.projectName
    $expected       = $configuration.expectedRunningCount
    $timeoutSeconds = $configuration.waitTimeoutSeconds
    $deadline       = (Get-Date).AddSeconds($timeoutSeconds)
    $heartbeat      = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm')
    $running        = @(docker ps --filter "label=com.docker.compose.project=$projectName" --format '{{.Names}}')
    Write-Log "waiting for $expected running container(s), $($running.Count) now"

    while ($running.Count -lt $expected)
    {
        if ((Get-Date) -gt $deadline)
        {
            throw "$($running.Count) of $expected container(s) running after $timeoutSeconds second(s)"
        }

        Start-Sleep -Seconds 1
        $currentMinute = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm')
        if ($currentMinute -ne $heartbeat)
        {
            Write-Log "still waiting at $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')), $($running.Count) of $expected running"
            $heartbeat = $currentMinute
        }

        $running = @(docker ps --filter "label=com.docker.compose.project=$projectName" --format '{{.Names}}')
    }

    Write-Log "$($running.Count) container(s) running: $($running -join ', ')"
}

function Invoke-ContainerReport($configuration)
{
    $projectName = $configuration.projectName

    docker ps --filter "label=com.docker.compose.project=$projectName" --format '{{.Names}} {{.Image}} {{.Status}}' |% { Write-Log "$_" }
}

$configuration = Get-Configuration
Invoke-PreflightCheck $configuration
Invoke-ComposeUp $configuration
Wait-ComposeRunning $configuration
Invoke-ContainerReport $configuration
Write-Log '=== compose stack up ==='
