function Write-NewLogLines($logFolder, $linesSeen)
{
    $files = @(Get-ChildItem -Path $logFolder -File)
    $files |% {
        $file     = $_
        $fullName = $file.FullName
        $seen     = 0
        if ($linesSeen.ContainsKey($fullName))
        {
            $seen = $linesSeen[$fullName]
        }

        $lines = @(Get-Content -Path $fullName)
        if ($lines.Count -gt $seen)
        {
            $lines | Select-Object -Skip $seen |% { Write-Log "$($file.Name): $_" }
            $linesSeen[$fullName] = $lines.Count
        }
    }
}

function Wait-LoggedProcess($process, $logFolder)
{
    $linesSeen  = @{}
    $lastMinute = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm')
    while (!$process.HasExited)
    {
        Write-NewLogLines $logFolder $linesSeen
        $currentMinute = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm')
        if ($currentMinute -ne $lastMinute)
        {
            Write-Log "still running after $([int]((Get-Date) - $process.StartTime).TotalSeconds) second(s)"
            $lastMinute = $currentMinute
        }

        Start-Sleep -Seconds 1
    }

    Write-NewLogLines $logFolder $linesSeen
    $process.WaitForExit()
    Write-Log "process $($process.Id) exited with code $($process.ExitCode)"
    return $process.ExitCode
}
