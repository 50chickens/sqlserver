#requires -Version 5.1

param(
    [ValidateSet('primary', 'joiner')]
    [string] $Mode = 'primary',

    [switch] $SkipDatabaseCreation
)

$ErrorActionPreference = 'Stop'
$VerbosePreference     = 'SilentlyContinue'
Set-Location $PSScriptRoot

function Write-Log($message)
{
    Write-Host "[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] $message"
}

function Get-Configuration
{
    $scriptFolder           = (Get-Item ".").FullName
    $settingsPath           = "$scriptFolder\settings.json"
    $settings               = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json
    $databaseServerName     = $settings.databaseServerName
    $databaseName           = $settings.databaseName
    $lcid                   = $settings.lcid
    $passwordPath           = $settings.passwordPath
    $runPassword            = (Get-Content -LiteralPath $passwordPath -Raw).Trim()
    $databaseConnectionArguments = @{
        CredentialsType     = $settings.databaseCredentialsType
        DatabaseName        = $databaseName
        Encrypt             = $false
        EncryptMode         = ''
        MultiSubnetFailover = $false
        Password            = $runPassword
        Server              = $databaseServerName
        UserName            = $settings.databaseUserName
    }
    $creationScriptArguments = @{ DatabaseName = $databaseName; IsSharePointMode = $false; Lcid = $lcid }
    $rightsScriptArguments   = @{ DatabaseName = $databaseName; IsRemote = $true; IsWindowsUser = $false; UserName = $settings.databaseUserName }
    $urlCalls = @(
        [pscustomobject]@{ Application = 'ReportServerWebService'; VirtualDirectory = $settings.reportServerVirtualDirectory; UrlString = $settings.reportServerUrl }
        [pscustomobject]@{ Application = 'ReportServerWebApp'; VirtualDirectory = $settings.portalVirtualDirectory; UrlString = $settings.portalUrl }
    )

    $configuration = $settings
    $configuration | Add-Member -NotePropertyName 'Mode'                        -NotePropertyValue $Mode                        -Force
    $configuration | Add-Member -NotePropertyName 'SkipDatabaseCreation'        -NotePropertyValue $SkipDatabaseCreation        -Force
    $configuration | Add-Member -NotePropertyName 'DatabasePassword'            -NotePropertyValue $runPassword                 -Force
    $configuration | Add-Member -NotePropertyName 'EncryptionKeyPassword'       -NotePropertyValue $runPassword                 -Force
    $configuration | Add-Member -NotePropertyName 'Lcid'                        -NotePropertyValue $lcid                        -Force
    $configuration | Add-Member -NotePropertyName 'DatabaseConnectionArguments' -NotePropertyValue $databaseConnectionArguments -Force
    $configuration | Add-Member -NotePropertyName 'CreationScriptArguments'     -NotePropertyValue $creationScriptArguments     -Force
    $configuration | Add-Member -NotePropertyName 'RightsScriptArguments'       -NotePropertyValue $rightsScriptArguments       -Force
    $configuration | Add-Member -NotePropertyName 'UrlCalls'                    -NotePropertyValue $urlCalls                    -Force
    return $configuration
}

function Add-RuntimeConfiguration($configuration)
{
    Wait-ServiceRunning $configuration
    $wmiNamespace = $configuration.wmiNamespace
    $instanceName = $configuration.instanceName
    Write-Log "Reading the configuration setting of instance $instanceName from $wmiNamespace"
    $configurationSetting = Get-CimInstance -Namespace $wmiNamespace -ClassName 'MSReportServer_ConfigurationSetting' | Select-Object -First 1
    $sqlCmdPath = (Get-ChildItem -Path 'C:\Program Files\Microsoft SQL Server\Client SDK' -Recurse -Filter 'sqlcmd.exe' -File | Select-Object -First 1).FullName

    $configuration | Add-Member -NotePropertyName 'ConfigurationSetting' -NotePropertyValue $configurationSetting -Force
    $configuration | Add-Member -NotePropertyName 'SqlCmdPath'           -NotePropertyValue $sqlCmdPath           -Force
    Write-Log "sqlcmd at $sqlCmdPath, installation $($configurationSetting.InstallationID)"
    return $configuration
}

function Invoke-ConfigurationSettingMethod($configuration, $methodName, $arguments)
{
    $configurationSetting = $configuration.ConfigurationSetting
    $timeoutSeconds       = $configuration.rpcReadyTimeoutSeconds
    $deadline             = (Get-Date).AddSeconds($timeoutSeconds)
    $lastMinute           = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm')
    $result               = Invoke-CimMethod -InputObject $configurationSetting -MethodName $methodName -Arguments $arguments
    $returnValue          = $result.HRESULT
    while ($returnValue -eq -2147023181)
    {
        if ((Get-Date) -gt $deadline)
        {
            throw "$methodName is still unavailable after $timeoutSeconds second(s)"
        }

        Start-Sleep -Seconds 2
        $currentMinute = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm')
        if ($currentMinute -ne $lastMinute)
        {
            Write-Log "$methodName is not answering yet, retrying"
            $lastMinute = $currentMinute
        }

        $result      = Invoke-CimMethod -InputObject $configurationSetting -MethodName $methodName -Arguments $arguments
        $returnValue = $result.HRESULT
    }

    Write-Log "$methodName returned HRESULT $returnValue"
    if ($returnValue -ne 0)
    {
        throw "$methodName failed with HRESULT $returnValue and $($result.ExtendedErrors)"
    }

    return $result
}

function Get-ServiceSid($configuration)
{
    $serviceAccount = "NT SERVICE\$($configuration.serviceName)"
    $account        = New-Object System.Security.Principal.NTAccount($serviceAccount)
    $sid            = $account.Translate([System.Security.Principal.SecurityIdentifier])
    return $sid.Value
}

function Invoke-UrlAcl($configuration)
{
    $serviceAccount = "NT SERVICE\$($configuration.serviceName)"
    $sid            = Get-ServiceSid $configuration
    $sddl           = "D:(A;;GX;;;$sid)"
    $endpoints      = $configuration.urlAclEndpoints
    $endpoints |% {
        $endpoint = $_
        $existing = & netsh http show urlacl url=$endpoint
        if ("$existing" -match [regex]::Escape($endpoint))
        {
            Write-Log "$endpoint is already reserved in HTTP.sys"
            return
        }

        Write-Log "granting $serviceAccount the reservation $endpoint"
        & netsh http add urlacl url=$endpoint "sddl=$sddl"
        if ($LASTEXITCODE -ne 0)
        {
            throw "netsh could not reserve $endpoint"
        }
    }
}

function Invoke-UrlReservations($configuration)
{
    $configPath     = $configuration.reportServerConfigPath
    $serviceName    = $configuration.serviceName
    $serviceAccount = "NT SERVICE\$serviceName"
    $sid            = Get-ServiceSid $configuration
    $calls          = $configuration.UrlCalls
    Write-Log "stopping $serviceName so it cannot overwrite $configPath while it runs"
    Stop-Service -Name $serviceName -Force
    $document     = [xml](Get-Content -LiteralPath $configPath -Raw)
    $applications = $document.SelectNodes('//URLReservations/Application')
    $calls |% {
        $call        = $_
        $application = $applications |? { $_.SelectSingleNode('Name').InnerText -eq $call.Application }
        if ($null -eq $application)
        {
            throw "no $($call.Application) application in $configPath"
        }

        $application.SelectSingleNode('VirtualDirectory').InnerText = $call.VirtualDirectory
        $urls = $application.SelectSingleNode('URLs')
        $urls.RemoveAll()
        $url = $document.CreateElement('URL')
        $urlString = $document.CreateElement('UrlString')
        $urlString.InnerText = $call.UrlString
        $accountSid = $document.CreateElement('AccountSid')
        $accountSid.InnerText = $sid
        $accountName = $document.CreateElement('AccountName')
        $accountName.InnerText = $serviceAccount
        $null = $url.AppendChild($urlString)
        $null = $url.AppendChild($accountSid)
        $null = $url.AppendChild($accountName)
        $null = $urls.AppendChild($url)
        Write-Log "$($call.Application) serves $($call.VirtualDirectory) at $($call.UrlString) as $serviceAccount"
    }

    $document.Save($configPath)
    Write-Log "wrote the URL reservations to $configPath"
    Write-Log "starting $serviceName with the reservations in place"
    Start-Service -Name $serviceName
    Wait-ServiceListening $configuration
}


function Invoke-DatabaseConnection($configuration)
{
    $configurationSetting = $configuration.ConfigurationSetting
    $arguments            = $configuration.DatabaseConnectionArguments

    Write-Log "pointing the report server at $($arguments.Server) database $($arguments.DatabaseName) as $($arguments.UserName)"
    $result = Invoke-ConfigurationSettingMethod $configuration 'SetDatabaseConnection' $arguments
    return $result
}

function Invoke-DatabaseScript($configuration, $methodName, $arguments)
{
    $configurationSetting = $configuration.ConfigurationSetting
    $sqlCmdPath           = $configuration.SqlCmdPath
    $scriptFolder         = (Get-Item $env:TEMP).FullName
    $scriptPath           = "$scriptFolder\$methodName.sql"
    $databaseUser         = $configuration.databaseUserName
    $databasePassword     = $configuration.databasePassword
    $databaseServer       = $configuration.databaseServerName

    Write-Log "generating the $methodName script"
    $result = Invoke-ConfigurationSettingMethod $configuration $methodName $arguments
    Set-Content -Path $scriptPath -Value $result.Script
    Write-Log "running $scriptPath against $databaseServer"
    & $sqlCmdPath -S $databaseServer -U $databaseUser -P $databasePassword -C -b -i $scriptPath
    if ($LASTEXITCODE -ne 0)
    {
        throw "$methodName script failed with exit code $LASTEXITCODE"
    }
}

function Test-DatabaseExists($configuration)
{
    $sqlCmdPath       = $configuration.SqlCmdPath
    $databaseServer   = $configuration.databaseServerName
    $databaseName     = $configuration.databaseName
    $databaseUser     = $configuration.databaseUserName
    $databasePassword = $configuration.databasePassword
    $statement        = "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.databases WHERE name = '$databaseName'"
    $result           = & $sqlCmdPath -S $databaseServer -U $databaseUser -P $databasePassword -C -b -h -1 -Q $statement
    if ($LASTEXITCODE -ne 0)
    {
        throw "the database check against $databaseServer failed with exit code $LASTEXITCODE"
    }
    $count = ($result -join '').Trim()
    $databaseExists = $count -eq '1'
    return $databaseExists
}

function Invoke-DatabaseCreation($configuration)
{
    if ($configuration.Mode -ne 'primary')
    {
        return
    }

    if ($configuration.SkipDatabaseCreation)
    {
        Write-Log 'skipping the database creation scripts'
        return
    }

    if (Test-DatabaseExists $configuration)
    {
        Write-Log "database $($configuration.databaseName) is present, so the creation scripts are skipped"
        return
    }

    Invoke-DatabaseScript $configuration 'GenerateDatabaseCreationScript' $configuration.CreationScriptArguments
    Invoke-DatabaseScript $configuration 'GenerateDatabaseRightsScript' $configuration.RightsScriptArguments
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

    Wait-ServiceReady $configuration
}

function Wait-ServiceRunning($configuration)
{
    $serviceName    = $configuration.serviceName
    $timeoutSeconds = $configuration.readyTimeoutSeconds
    $deadline       = (Get-Date).AddSeconds($timeoutSeconds)
    $lastMinute     = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm')
    $status         = (Get-Service -Name $serviceName).Status
    while ($status -ne 'Running')
    {
        if ((Get-Date) -gt $deadline)
        {
            throw "$serviceName is $status after $timeoutSeconds second(s)"
        }

        Start-Sleep -Seconds 1
        $currentMinute = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm')
        if ($currentMinute -ne $lastMinute)
        {
            Write-Log "still waiting for $serviceName, $status at $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
            $lastMinute = $currentMinute
        }

        $status = (Get-Service -Name $serviceName).Status
    }

    Write-Log "$serviceName is Running"
}

function Test-ServiceReady($configuration)
{
    $configurationSetting = $configuration.ConfigurationSetting
    $ready = $false
    try
    {
        $null = Invoke-CimMethod -InputObject $configurationSetting -MethodName 'ListReportServersInDatabase' -Arguments @{}
        $ready = $true
    }
    catch
    {
        $ready = $false
    }
    return $ready
}

function Wait-ServiceReady($configuration)
{
    $serviceName    = $configuration.serviceName
    $timeoutSeconds = $configuration.readyTimeoutSeconds
    $deadline       = (Get-Date).AddSeconds($timeoutSeconds)
    $lastMinute     = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm')
    $ready          = Test-ServiceReady $configuration
    while (!$ready)
    {
        if ((Get-Date) -gt $deadline)
        {
            throw "$serviceName did not answer on its WMI provider within $timeoutSeconds second(s)"
        }

        Start-Sleep -Seconds 1
        $currentMinute = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm')
        if ($currentMinute -ne $lastMinute)
        {
            Write-Log "still waiting for $serviceName to answer at $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
            $lastMinute = $currentMinute
        }

        $ready = Test-ServiceReady $configuration
    }

    Write-Log "$serviceName answers on its WMI provider"
}

function Wait-ServiceListening($configuration)
{
    $httpPort       = $configuration.httpPort
    $timeoutSeconds = $configuration.readyTimeoutSeconds
    $deadline       = (Get-Date).AddSeconds($timeoutSeconds)
    $lastMinute     = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm')
    $listening      = Test-PortListening $httpPort
    while (!$listening)
    {
        if ((Get-Date) -gt $deadline)
        {
            throw "nothing answers on port $httpPort within $timeoutSeconds second(s) of the restart"
        }

        Start-Sleep -Seconds 1
        $currentMinute = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm')
        if ($currentMinute -ne $lastMinute)
        {
            Write-Log "still waiting for port $httpPort at $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
            $lastMinute = $currentMinute
        }

        $listening = Test-PortListening $httpPort
    }

    Write-Log "port $httpPort answers, so the report server has finished starting"
}

function Test-PortListening($port)
{
    $client    = [Net.Sockets.TcpClient]::new()
    $attempt   = $client.ConnectAsync('127.0.0.1', $port)
    $connected = $false
    try
    {
        $connected = $attempt.Wait(3000)
    }
    catch
    {
        $connected = $false
    }
    $client.Close()
    return $connected
}

function Invoke-DatabaseInitialization($configuration)
{
    if ($configuration.Mode -ne 'primary')
    {
        return
    }

    $configurationSetting = $configuration.ConfigurationSetting
    if ($configurationSetting.IsInitialized)
    {
        Write-Log "installation $($configurationSetting.InstallationID) is already initialised"
        return
    }

    $installationId       = $configurationSetting.InstallationID
    $arguments            = @{ InstallationID = $installationId }

    Write-Log "initialising the report server installation $installationId"
    $result = Invoke-ConfigurationSettingMethod $configuration 'InitializeReportServer' $arguments
    return $result
}

function Invoke-KeyBackup($configuration)
{
    if ($configuration.Mode -ne 'primary')
    {
        return
    }

    $configurationSetting = $configuration.ConfigurationSetting
    $keyPassword          = $configuration.encryptionKeyPassword
    $keySharePath         = $configuration.encryptionKeySharePath
    $arguments            = @{ Password = $keyPassword }

    Write-Log "backing up the encryption key"
    $result = Invoke-ConfigurationSettingMethod $configuration 'BackupEncryptionKey' $arguments
    Set-Content -Path $keySharePath -Value $result.KeyFile -Encoding Byte
    Write-Log "the key is at $keySharePath"
}

function Invoke-KeyRestore($configuration)
{
    if ($configuration.Mode -ne 'joiner')
    {
        return
    }

    $configurationSetting = $configuration.ConfigurationSetting
    $keyPassword          = $configuration.encryptionKeyPassword
    $keySharePath         = $configuration.encryptionKeySharePath
    $keyBytes             = [byte[]](Get-Content -Path $keySharePath -Encoding Byte)
    $keyLength            = $keyBytes.Length
    $arguments            = @{ KeyFile = $keyBytes; Length = $keyLength; Password = $keyPassword }

    Write-Log "restoring the encryption key from $keySharePath"
    $result = Invoke-ConfigurationSettingMethod $configuration 'RestoreEncryptionKey' $arguments
    return $result
}

function Invoke-ScaleOutReport($configuration)
{
    $configurationSetting = $configuration.ConfigurationSetting
    $result               = Invoke-ConfigurationSettingMethod $configuration 'ListReportServersInDatabase' @{}
    $names                = $result.InstanceNames
    $machines             = $result.MachineNames
    $initialized          = $result.IsInitialized
    $localMachine         = [System.Net.Dns]::GetHostName()
    Write-Log "the database holds $($names.Count) report server(s), this node is $localMachine"
    $index = 0
    $names |% {
        $name = $_
        Write-Log "server $name machine $($machines[$index]) initialised $($initialized[$index])"
        $index = $index + 1
    }

    $registered = $machines |? { $_ -eq $localMachine }
    if ($registered.Count -eq 0)
    {
        Write-Log "$localMachine has no row of its own in the database, because both nodes were installed from one image and share installation $($configurationSetting.InstallationID)"
    }
}

$configuration = Get-Configuration
$configuration = Add-RuntimeConfiguration $configuration
Invoke-UrlAcl $configuration
$null = Invoke-DatabaseConnection $configuration
Invoke-DatabaseCreation $configuration
Invoke-UrlReservations $configuration
Invoke-DatabaseInitialization $configuration
Invoke-KeyBackup $configuration
Invoke-KeyRestore $configuration
Invoke-ScaleOutReport $configuration
Invoke-ServiceRestart $configuration
Wait-ServiceListening $configuration
Write-Log "=== report server configured as $($configuration.Mode) ==="
