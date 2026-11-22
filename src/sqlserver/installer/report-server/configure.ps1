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
    $databaseConnectionArguments = @{
        CredentialsType     = $settings.databaseCredentialsType
        DatabaseName        = $databaseName
        Encrypt             = $false
        EncryptMode         = ''
        MultiSubnetFailover = $false
        Password            = $settings.databasePassword
        Server              = $databaseServerName
        UserName            = $settings.databaseUserName
    }
    $creationScriptArguments = @{ DatabaseName = $databaseName; IsSharePointMode = $false; Lcid = $lcid }
    $rightsScriptArguments   = @{ DatabaseName = $databaseName; IsRemote = $true; IsWindowsUser = $false; UserName = $settings.databaseUserName }
    $virtualDirectoryCalls   = @(
        [pscustomobject]@{ Application = 'ReportServerWebService'; VirtualDirectory = $settings.reportServerVirtualDirectory }
        [pscustomobject]@{ Application = 'ReportServerWebApp'; VirtualDirectory = $settings.portalVirtualDirectory }
    )
    $urlCalls = @(
        [pscustomobject]@{ Application = 'ReportServerWebService'; UrlString = $settings.reportServerUrl }
        [pscustomobject]@{ Application = 'ReportServerWebApp'; UrlString = $settings.portalUrl }
    )

    $configuration = $settings
    $configuration | Add-Member -NotePropertyName 'Mode'                 -NotePropertyValue $Mode                 -Force
    $configuration | Add-Member -NotePropertyName 'SkipDatabaseCreation' -NotePropertyValue $SkipDatabaseCreation -Force
    $configuration | Add-Member -NotePropertyName 'Lcid'                      -NotePropertyValue $lcid                      -Force
    $configuration | Add-Member -NotePropertyName 'DatabaseConnectionArguments' -NotePropertyValue $databaseConnectionArguments -Force
    $configuration | Add-Member -NotePropertyName 'CreationScriptArguments'   -NotePropertyValue $creationScriptArguments   -Force
    $configuration | Add-Member -NotePropertyName 'RightsScriptArguments'     -NotePropertyValue $rightsScriptArguments     -Force
    $configuration | Add-Member -NotePropertyName 'VirtualDirectoryCalls'     -NotePropertyValue $virtualDirectoryCalls     -Force
    $configuration | Add-Member -NotePropertyName 'UrlCalls'                  -NotePropertyValue $urlCalls                  -Force
    return $configuration
}

function Add-RuntimeConfiguration($configuration)
{
    $wmiNamespace = $configuration.wmiNamespace
    $instanceName = $configuration.instanceName
    Write-Log "Reading the configuration setting of instance $instanceName from $wmiNamespace"
    $configurationSetting = Get-CimInstance -Namespace $wmiNamespace -ClassName 'MSReportServer_ConfigurationSetting' | Select-Object -First 1
    $sqlCmdPath = (Get-ChildItem -Path 'C:\Program Files\Microsoft SQL Server\Client SDK' -Recurse -Filter 'sqlcmd.exe' | Select-Object -First 1).FullName

    $configuration | Add-Member -NotePropertyName 'ConfigurationSetting' -NotePropertyValue $configurationSetting -Force
    $configuration | Add-Member -NotePropertyName 'SqlCmdPath'           -NotePropertyValue $sqlCmdPath           -Force
    Write-Log "sqlcmd at $sqlCmdPath, installation $($configurationSetting.InstallationID)"
    return $configuration
}

function Invoke-ConfigurationSettingMethod($configurationSetting, $methodName, $arguments)
{
    $result      = Invoke-CimMethod -InputObject $configurationSetting -MethodName $methodName -Arguments $arguments
    $returnValue = $result.HRESULT
    Write-Log "$methodName returned HRESULT $returnValue"
    if ($returnValue -ne 0)
    {
        throw "$methodName failed with HRESULT $returnValue"
    }

    return $result
}

function Invoke-DatabaseConnection($configuration)
{
    $configurationSetting = $configuration.ConfigurationSetting
    $arguments            = $configuration.DatabaseConnectionArguments

    Write-Log "pointing the report server at $($arguments.Server) database $($arguments.DatabaseName) as $($arguments.UserName)"
    $result = Invoke-ConfigurationSettingMethod $configurationSetting 'SetDatabaseConnection' $arguments
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
    $result = Invoke-ConfigurationSettingMethod $configurationSetting $methodName $arguments
    Set-Content -Path $scriptPath -Value $result.Script
    Write-Log "running $scriptPath against $databaseServer"
    & $sqlCmdPath -S $databaseServer -U $databaseUser -P $databasePassword -C -b -i $scriptPath
    if ($LASTEXITCODE -ne 0)
    {
        throw "$methodName script failed with exit code $LASTEXITCODE"
    }
}

function Invoke-DatabaseInitialization($configuration)
{
    if ($configuration.Mode -ne 'primary')
    {
        return
    }

    $configurationSetting = $configuration.ConfigurationSetting
    $installationId       = $configurationSetting.InstallationID
    $arguments            = @{ InstallationID = $installationId }

    Write-Log "initialising the report server installation $installationId"
    $result = Invoke-ConfigurationSettingMethod $configurationSetting 'InitializeReportServer' $arguments
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
    $result = Invoke-ConfigurationSettingMethod $configurationSetting 'BackupEncryptionKey' $arguments
    Copy-Item -Path $result.KeyFile -Destination $keySharePath -Force
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
    $keyLength            = (Get-Item -Path $keySharePath).Length
    $arguments            = @{ KeyFile = $keySharePath; Length = $keyLength; Password = $keyPassword }

    Write-Log "restoring the encryption key from $keySharePath"
    $result = Invoke-ConfigurationSettingMethod $configurationSetting 'RestoreEncryptionKey' $arguments
    return $result
}

function Invoke-VirtualDirectories($configuration)
{
    $configurationSetting = $configuration.ConfigurationSetting
    $lcid                 = $configuration.Lcid
    $calls                = $configuration.VirtualDirectoryCalls
    $calls |% {
        $call      = $_
        $arguments = @{ Application = $call.Application; Lcid = $lcid; VirtualDirectory = $call.VirtualDirectory }
        Write-Log "setting the virtual directory of $($call.Application) to $($call.VirtualDirectory)"
        $null = Invoke-ConfigurationSettingMethod $configurationSetting 'SetVirtualDirectory' $arguments
    }
}

function Invoke-UrlReservations($configuration)
{
    $configurationSetting = $configuration.ConfigurationSetting
    $lcid                 = $configuration.Lcid
    $calls                = $configuration.UrlCalls
    $calls |% {
        $call      = $_
        $arguments = @{ Application = $call.Application; Lcid = $lcid; UrlString = $call.UrlString }
        Write-Log "reserving $($call.UrlString) for $($call.Application)"
        $null = Invoke-ConfigurationSettingMethod $configurationSetting 'ReserveURL' $arguments
    }
}

function Invoke-ScaleOutReport($configuration)
{
    $configurationSetting = $configuration.ConfigurationSetting
    $result               = Invoke-ConfigurationSettingMethod $configurationSetting 'ListReportServersInDatabase' @{}
    $names                = $result.InstanceNames
    $machines             = $result.MachineNames
    $initialized          = $result.IsInitialized
    Write-Log "the database holds $($names.Count) report server(s)"
    $index = 0
    $names |% {
        $name = $_
        Write-Log "server $name machine $($machines[$index]) initialised $($initialized[$index])"
        $index = $index + 1
    }
}

$configuration = Get-Configuration
$configuration = Add-RuntimeConfiguration $configuration
$null = Invoke-DatabaseConnection $configuration
if ($configuration.Mode -eq 'primary' -and !$configuration.SkipDatabaseCreation)
{
    Invoke-DatabaseScript $configuration 'GenerateDatabaseCreationScript' $configuration.CreationScriptArguments
    Invoke-DatabaseScript $configuration 'GenerateDatabaseRightsScript' $configuration.RightsScriptArguments
}

$null = Invoke-DatabaseInitialization $configuration
Invoke-KeyBackup $configuration
Invoke-KeyRestore $configuration
Invoke-VirtualDirectories $configuration
Invoke-UrlReservations $configuration
Invoke-ScaleOutReport $configuration
Write-Log "=== report server configured as $($configuration.Mode) ==="
