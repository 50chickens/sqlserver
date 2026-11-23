function Write-NewLogLines($logFolder, $linesSeen)
{
    $files = Get-ChildItem -Path $logFolder -File
    $files |% {
        $file     = $_
        $fullName = $file.FullName
        $seen     = 0
        if ($linesSeen.ContainsKey($fullName))
        {
            $seen = $linesSeen[$fullName]
        }

        $lines = Get-Content -Path $fullName
        if ($lines.Count -gt $seen)
        {
            $lines | Select-Object -Skip $seen |% { Write-Log "$($file.Name): $_" }
            $linesSeen[$fullName] = $lines.Count
        }
    }
}

function Write-NewMountLogLines($tailMounts, $linesSeen)
{
    $tailMounts |% {
        $mount = $_
        $files = Get-ChildItem -Path $mount.HostPath -Filter $mount.LogFilter -File -Recurse
        $files |% {
            $file     = $_
            $fullName = $file.FullName
            $seen     = 0
            if ($linesSeen.ContainsKey($fullName))
            {
                $seen = $linesSeen[$fullName]
            }

            $lines = Get-Content -Path $fullName
            if ($lines.Count -gt $seen)
            {
                $lines | Select-Object -Skip $seen |% { Write-Log "$($mount.Name)/$($file.Name): $_" }
                $linesSeen[$fullName] = $lines.Count
            }
        }
    }
}

function Wait-TailedProcess($process, $logFolder, $tailMounts)
{
    $linesSeen  = @{}
    $lastMinute = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm')
    while (!$process.HasExited)
    {
        Write-NewLogLines $logFolder $linesSeen
        Write-NewMountLogLines $tailMounts $linesSeen
        $currentMinute = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm')
        if ($currentMinute -ne $lastMinute)
        {
            Write-Log "still running after $([int]((Get-Date) - $process.StartTime).TotalSeconds) second(s)"
            $lastMinute = $currentMinute
        }

        Start-Sleep -Seconds 1
    }

    Write-NewLogLines $logFolder $linesSeen
    Write-NewMountLogLines $tailMounts $linesSeen
    $process.WaitForExit()
    Write-Log "process $($process.Id) exited with code $($process.ExitCode)"
    return $process.ExitCode
}

function Wait-LoggedProcess($process, $logFolder, $timeoutSeconds)
{
    $linesSeen  = @{}
    $lastMinute = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm')
    $deadline   = (Get-Date).AddSeconds($timeoutSeconds)
    while (!$process.HasExited)
    {
        Write-NewLogLines $logFolder $linesSeen
        $currentMinute = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm')
        if ($currentMinute -ne $lastMinute)
        {
            Write-Log "still running after $([int]((Get-Date) - $process.StartTime).TotalSeconds) second(s)"
            $lastMinute = $currentMinute
        }

        if ((Get-Date) -gt $deadline)
        {
            Write-Log "the process is still running after $timeoutSeconds second(s), so the run stops it"
            $process.Kill()
            throw "the process did not finish within $timeoutSeconds second(s)"
        }

        Start-Sleep -Seconds 1
    }

    Write-NewLogLines $logFolder $linesSeen
    $process.WaitForExit()
    Write-Log "process $($process.Id) exited with code $($process.ExitCode)"
    return $process.ExitCode
}
