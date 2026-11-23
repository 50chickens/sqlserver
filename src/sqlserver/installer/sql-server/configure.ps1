$ErrorActionPreference = 'Stop'
$VerbosePreference     = 'SilentlyContinue'
Set-Location $PSScriptRoot

function Write-Log($message)
{
    Write-Host "[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] $message"
}

function Get-Configuration
{
    $scriptFolder = (Get-Item '.').FullName
    $settings     = Get-Content -Path "$scriptFolder\settings.json" -Raw | ConvertFrom-Json
    $instanceKey  = "MSSQL17.$($settings.instanceName)"
    $instanceRoot = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceKey"
    $passwordPath = $settings.passwordPath
    $saPassword   = (Get-Content -LiteralPath $passwordPath -Raw).Trim()

    $configuration = $settings
    $configuration | Add-Member -NotePropertyName 'InstanceKey'  -NotePropertyValue $instanceKey  -Force
    $configuration | Add-Member -NotePropertyName 'LoginModePath' -NotePropertyValue "$instanceRoot\MSSQLServer" -Force
    $configuration | Add-Member -NotePropertyName 'TcpPath'      -NotePropertyValue "$instanceRoot\MSSQLServer\SuperSocketNetLib\Tcp" -Force
    $configuration | Add-Member -NotePropertyName 'SaPassword'   -NotePropertyValue $saPassword   -Force
    return $configuration
}

function Add-RuntimeConfiguration($configuration)
{
    $sqlCmd = (Get-ChildItem -Path 'C:\Program Files\Microsoft SQL Server\Client SDK' -Recurse -Filter 'sqlcmd.exe' -File | Select-Object -First 1).FullName

    $configuration | Add-Member -NotePropertyName 'SqlCmdPath' -NotePropertyValue $sqlCmd -Force
    return $configuration
}

function Invoke-MixedModeAuthentication($configuration)
{
    $loginModePath = $configuration.LoginModePath
    Write-Log "setting LoginMode 2, mixed authentication, at $loginModePath"
    Set-ItemProperty -Path $loginModePath -Name 'LoginMode' -Value 2
}

function Invoke-TcpProtocol($configuration)
{
    $tcpPath = $configuration.TcpPath
    $tcpPort = $configuration.tcpPort
    Write-Log "enabling TCP and fixing port $tcpPort at $tcpPath"
    Set-ItemProperty -Path $tcpPath -Name 'Enabled' -Value 1
    Set-ItemProperty -Path $tcpPath -Name 'TcpPort' -Value "$tcpPort"
    Set-ItemProperty -Path "$tcpPath\IpAll" -Name 'TcpPort' -Value "$tcpPort"
    Set-ItemProperty -Path "$tcpPath\IpAll" -Name 'TcpDynamicPorts' -Value ''
}

function Invoke-ServiceRestart($configuration)
{
    $serviceName = $configuration.serviceName
    Write-Log "restarting the $serviceName service"
    Restart-Service -Name $serviceName -Force
    $service = Get-Service -Name $serviceName
    Write-Log "$serviceName is $($service.Status)"
    if ($service.Status -ne 'Running')
    {
        throw "$serviceName is $($service.Status) after the restart"
    }
}

function Invoke-SaLogin($configuration)
{
    $sqlCmdPath = $configuration.SqlCmdPath
    $tcpPort    = $configuration.tcpPort
    $saPassword = $configuration.saPassword
    $server     = "localhost,$tcpPort"
    $statement  = "ALTER LOGIN sa ENABLE; ALTER LOGIN sa WITH PASSWORD = '$saPassword';"
    Write-Log "enabling the sa login over $server"
    & $sqlCmdPath -S $server -E -C -b -Q $statement
    if ($LASTEXITCODE -ne 0)
    {
        throw "enabling the sa login failed with exit code $LASTEXITCODE"
    }
}

function Invoke-SqlLoginProbe($configuration)
{
    $sqlCmdPath = $configuration.SqlCmdPath
    $tcpPort    = $configuration.tcpPort
    $saPassword = $configuration.saPassword
    Write-Log "proving a SQL login over TCP port $tcpPort"
    $result = & $sqlCmdPath -S "localhost,$tcpPort" -U sa -P $saPassword -C -b -h -1 -Q 'SELECT 1'
    if ($LASTEXITCODE -ne 0)
    {
        throw "the sa login over TCP port $tcpPort failed with exit code $LASTEXITCODE"
    }
    Write-Log "the sa login over TCP port $tcpPort returns $($result -join ' ')"
}

$configuration = Get-Configuration
$configuration = Add-RuntimeConfiguration $configuration
Invoke-MixedModeAuthentication $configuration
Invoke-TcpProtocol $configuration
Invoke-ServiceRestart $configuration
Invoke-SaLogin $configuration
Invoke-SqlLoginProbe $configuration
Write-Log '=== sql server configured ==='
