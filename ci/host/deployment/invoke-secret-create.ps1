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
    $configuration = Get-Content -Path "$hostRoot\configs\invoke-secret-create.json" -Raw | ConvertFrom-Json
    $shareFolder   = "$hostRoot\$($configuration.hostBindMountFolderName)\$($configuration.shareFolderName)"
    $passwordPath  = "$shareFolder\$($configuration.passwordFileName)"

    $configuration | Add-Member -NotePropertyName 'ShareFolder'  -NotePropertyValue $shareFolder  -Force
    $configuration | Add-Member -NotePropertyName 'PasswordPath' -NotePropertyValue $passwordPath -Force
    return $configuration
}

function New-RunPassword
{
    $value    = [guid]::NewGuid().ToString('N').Substring(0, 20)
    $password = 'Sq!' + $value + '9'
    return $password
}

function Invoke-PasswordCreate($configuration)
{
    $shareFolder  = $configuration.ShareFolder
    $passwordPath = $configuration.PasswordPath
    if (Test-Path -LiteralPath $passwordPath)
    {
        Write-Log "the shared password is already at $passwordPath"
        return
    }

    $null = New-Item -ItemType Directory -Path $shareFolder -Force
    Set-Content -Path $passwordPath -Value (New-RunPassword) -NoNewline
    Write-Log "wrote a generated password to $passwordPath"
}

$configuration = Get-Configuration
Invoke-PasswordCreate $configuration
Write-Log '=== shared password ready ==='
