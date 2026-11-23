function Invoke-Compose($configuration, $arguments, $logName)
{
    $composePath     = $configuration.composePath
    $composeFilePath = $configuration.ComposeFilePath
    $callFolder      = "$($configuration.LogFolder)\$logName"
    $line            = $arguments -join ' '
    $null = New-Item -ItemType Directory -Path $callFolder -Force
    $parameters = @{
        FilePath               = $composePath
        ArgumentList           = @('--project-name', $configuration.projectName, '--file', $composeFilePath) + $arguments
        RedirectStandardOutput = "$callFolder\$logName.log"
        RedirectStandardError  = "$callFolder\$logName.error.log"
        PassThru               = $true
        WindowStyle            = 'Hidden'
    }

    Write-Log "compose $line"
    $process = Start-Process @parameters
    $null = $process.Handle
    $exitCode = Wait-LoggedProcess $process $callFolder $configuration.commandTimeoutSeconds
    if ($exitCode -ne 0)
    {
        throw "compose $line exited with code $exitCode"
    }
}

function Remove-ForeignContainers($configuration, $containerNames)
{
    $projectName = $configuration.projectName
    $existing    = @(docker ps --all --format '{{.Names}}')
    $containerNames |% {
        $containerName = $_
        if ($existing -contains $containerName)
        {
            $labelsJson = docker inspect --format '{{json .Config.Labels}}' $containerName
            $labels     = $labelsJson | ConvertFrom-Json
            $owner      = $labels.'com.docker.compose.project'
            if ($owner -ne $projectName)
            {
                Write-Log "removing $containerName, which compose project $owner owns rather than $projectName"
                $null = docker container rm --force $containerName
            }
        }
    }
}

function Get-ContainerState($containerName)
{
    $format = '{{.State.Status}}|{{.State.Health.Status}}'
    $line   = docker inspect --format $format $containerName
    $parts  = $line.Split('|')
    return [pscustomobject]@{ Status = $parts[0]; Health = $parts[1] }
}

function Wait-ContainerHealthy($configuration, $containerName)
{
    $timeoutSeconds = $configuration.nodeWaitTimeoutSeconds
    $deadline       = (Get-Date).AddSeconds($timeoutSeconds)
    $heartbeat      = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm')
    $state          = Get-ContainerState $containerName
    Write-Log "$containerName is $($state.Status) and its health is $($state.Health)"
    while ($state.Health -ne 'healthy')
    {
        if ($state.Status -ne 'running')
        {
            throw "$containerName is $($state.Status) rather than running, so it never becomes healthy"
        }

        if ((Get-Date) -gt $deadline)
        {
            throw "$containerName has been $($state.Health) for $timeoutSeconds second(s)"
        }

        Start-Sleep -Seconds 1
        $currentMinute = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm')
        if ($currentMinute -ne $heartbeat)
        {
            Write-Log "$containerName is still $($state.Health)"
            $heartbeat = $currentMinute
        }

        $state = Get-ContainerState $containerName
    }

    Write-Log "$containerName is healthy"
}
