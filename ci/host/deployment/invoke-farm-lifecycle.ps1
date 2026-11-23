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
    $configuration   = Get-Content -Path "$hostRoot\configs\invoke-farm-lifecycle.json" -Raw | ConvertFrom-Json
    $composeFilePath = (Get-Item "$hostRoot\$($configuration.composeFilePath)").FullName
    $passwordPath    = "$hostRoot\$($configuration.passwordRelativePath)"
    $password        = (Get-Content -LiteralPath $passwordPath -Raw).Trim()
    $logStamp        = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $logFolder       = "$hostRoot\logs\farm-lifecycle-$logStamp"
    $null = New-Item -ItemType Directory -Path $logFolder -Force

    $configuration | Add-Member -NotePropertyName 'HostRoot'         -NotePropertyValue $hostRoot                   -Force
    $configuration | Add-Member -NotePropertyName 'ComposeFilePath'  -NotePropertyValue $composeFilePath            -Force
    $configuration | Add-Member -NotePropertyName 'LogFolder'        -NotePropertyValue $logFolder                  -Force
    $configuration | Add-Member -NotePropertyName 'DatabasePassword' -NotePropertyValue $password                   -Force
    return $configuration
}

function Invoke-PreflightCheck($configuration)
{
    $composePath    = $configuration.composePath
    $composeVersion = & $composePath version --short
    if ($LASTEXITCODE -ne 0)
    {
        throw "$composePath did not answer on this host"
    }

    $containerNames = $configuration.spareNodes
    $containerNames = $containerNames + $configuration.databaseContainer
    $containerNames = $containerNames + $configuration.primaryNode
    Remove-ForeignContainers $configuration $containerNames
    Write-Log "$composePath $composeVersion, its output goes to $($configuration.LogFolder)"
}

function Invoke-FarmQuery($configuration, $query)
{
    $lines = & docker exec $configuration.databaseContainer $configuration.sqlcmdPath -S 'localhost,1433' -U 'sa' -P $configuration.DatabasePassword -C -d 'master' -Q $query -h -1 -W
    $rows  = $lines |? { $_.Trim().Length -gt 0 }
    return $rows
}

function Get-FarmMembers($configuration)
{
    $query   = "SET NOCOUNT ON; SELECT ISNULL(MachineName, '') + '|' + ISNULL(InstanceName, '') FROM $($configuration.reportDatabase).dbo.Keys"
    $rows    = Invoke-FarmQuery $configuration $query
    $members = [System.Collections.Generic.List[string]]::new()
    $keyRows = 0
    $rows |% {
        $parts = $_.Split('|')
        if ($parts[0].Length -eq 0)
        {
            $keyRows = $keyRows + 1
        }
        else
        {
            $members.Add($parts[0])
        }
    }

    if ($keyRows -ne 1)
    {
        throw "$($configuration.reportDatabase).dbo.Keys holds $keyRows encryption key row(s) rather than 1"
    }

    return $members
}

function Test-NodeFarmView($configuration, $containerName, $expectedLine)
{
    & docker exec $containerName powershell -NoProfile -File $configuration.farmViewCommand -Expected $expectedLine
    if ($LASTEXITCODE -ne 0)
    {
        throw "$containerName does not see the farm as $expectedLine"
    }
}

function Test-FarmMembership($configuration, $expectedMembers)
{
    $expected = $expectedMembers |% { $_.ToUpperInvariant() } | Sort-Object
    $actual   = Get-FarmMembers $configuration |% { $_.ToUpperInvariant() } | Sort-Object
    if (($actual -join ',') -ne ($expected -join ','))
    {
        throw "the database holds $($actual -join ', ') and the lifecycle expects $($expected -join ', ')"
    }

    $expectedLine = $expected -join ','
    Write-Log "farm membership is $expectedLine"
    $actual |% { Test-NodeFarmView $configuration $_.ToLowerInvariant() $expectedLine }
}

function Start-FarmNode($configuration, $containerName)
{
    Invoke-Compose $configuration @('up', '--detach', $containerName) "up-$containerName"
    Wait-ContainerHealthy $configuration $containerName
}

function Invoke-ContainerScript($configuration, $containerName, $scriptPath, $scriptArguments, $description)
{
    $command = "powershell -NoProfile -File $scriptPath $scriptArguments"
    $bytes   = [System.Text.Encoding]::Unicode.GetBytes($command)
    $encoded = [Convert]::ToBase64String($bytes)
    $callFolder = "$($configuration.LogFolder)\$containerName"
    $null = New-Item -ItemType Directory -Path $callFolder -Force
    $parameters = @{
        FilePath               = 'docker'
        ArgumentList           = @('exec', $containerName, 'powershell', '-NoProfile', '-EncodedCommand', $encoded)
        RedirectStandardOutput = "$callFolder\$containerName.log"
        RedirectStandardError  = "$callFolder\$containerName.error.log"
        PassThru               = $true
        WindowStyle            = 'Hidden'
    }

    Write-Log "$description in $containerName"
    $process = Start-Process @parameters
    $null = $process.Handle
    $exitCode = Wait-LoggedProcess $process $callFolder $configuration.commandTimeoutSeconds
    if ($exitCode -ne 0)
    {
        throw "$containerName exited with code $exitCode running $command"
    }
}

function Remove-FarmNode($configuration, $containerName)
{
    $machineName = $containerName.ToUpperInvariant()
    $query       = "SET NOCOUNT ON; DELETE FROM $($configuration.reportDatabase).dbo.Keys WHERE UPPER(MachineName) = '$machineName'"
    Write-Log "retiring $machineName, stopping the node before it loses its row"
    $null = docker stop $containerName.ToLowerInvariant()
    $null = Invoke-FarmQuery $configuration $query
}

$configuration = Get-Configuration
Invoke-PreflightCheck $configuration
Invoke-Compose $configuration @('down', '--remove-orphans', '--timeout', '5') 'down'
Start-FarmNode $configuration $configuration.databaseContainer
Invoke-ContainerScript $configuration $configuration.databaseContainer $configuration.databaseConfigureCommand '' 'configuring the sql server engine'
Start-FarmNode $configuration $configuration.primaryNode
Invoke-ContainerScript $configuration $configuration.primaryNode $configuration.nodeConfigureCommand '-Mode primary' 'creating the farm from the primary node'
$members = [System.Collections.Generic.List[string]]::new()
$members.Add($configuration.primaryNode.ToUpperInvariant())
Test-FarmMembership $configuration $members

$spares    = $configuration.spareNodes
$remaining = $spares.Count
while ($remaining -gt 0)
{
    while (($members.Count -lt $configuration.farmSize) -and ($remaining -gt 0))
    {
        $node      = $spares[$spares.Count - $remaining]
        $remaining = $remaining - 1
        Start-FarmNode $configuration $node
        Invoke-ContainerScript $configuration $node $configuration.nodeConfigureCommand '-Mode joiner' "joining $node to the farm"
        $members.Add($node.ToUpperInvariant())
        Test-FarmMembership $configuration $members
    }

    $oldest = $members[0]
    Remove-FarmNode $configuration $oldest
    $members.RemoveAt(0)
    Test-FarmMembership $configuration $members
    Write-Log "the farm reached $($configuration.farmSize) nodes and $oldest was retired"
}

Write-Log "=== the farm holds $($members -join ', ') with its members intact after $($spares.Count) node(s) rose and retired ==="
