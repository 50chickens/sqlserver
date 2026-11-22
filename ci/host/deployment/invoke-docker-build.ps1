$ErrorActionPreference = 'Stop'
$VerbosePreference     = 'SilentlyContinue'
Set-Location $PSScriptRoot

Get-ChildItem -Path '..\includes' -Filter '*.ps1' |% {
    Write-Verbose "Dot-sourcing $($_.FullName)"
    . $_.FullName
}

function Get-Configuration
{
    $configuration     = Get-Content -Path '..\configs\invoke-docker-build.json' -Raw | ConvertFrom-Json
    $dockerBuildFolder = (Get-Item $configuration.dockerBuildFolder).FullName

    $configuration | Add-Member -NotePropertyName 'DockerBuildFolder' -NotePropertyValue $dockerBuildFolder -Force
    return $configuration
}

function Invoke-PreflightCheck($configuration)
{
    $dockerBuildFolder = $configuration.DockerBuildFolder
    $dockerfileName    = "$dockerBuildFolder\Dockerfile"
    if (!(Test-Path -Path $dockerfileName))
    {
        throw "no Dockerfile at $dockerfileName"
    }

    $stageFolderNames = @(Get-ChildItem -Path $dockerBuildFolder -Directory |% { $_.Name })
    if ($stageFolderNames.Count -eq 0)
    {
        throw "no staged folder in $dockerBuildFolder, so the stage step did not run"
    }

    $dockerVersion = docker version --format '{{.Server.Version}}'
    if ($LASTEXITCODE -ne 0)
    {
        throw 'the docker daemon did not answer on this host'
    }

    Write-Log "docker engine $dockerVersion"
}

function Invoke-ImageBuild($configuration)
{
    $dockerBuildFolder = $configuration.DockerBuildFolder
    $dockerfileName    = "$dockerBuildFolder\Dockerfile"
    $image             = $configuration.imageName

    Write-Log "building $image from $dockerBuildFolder"
    & docker build --tag $image --file $dockerfileName $dockerBuildFolder
    if ($LASTEXITCODE -ne 0)
    {
        throw "docker build exited with code $LASTEXITCODE"
    }
}

function Invoke-ImageVerification($configuration)
{
    $image   = $configuration.imageName
    $imageId = docker image inspect --format '{{.Id}}' $image
    if ($LASTEXITCODE -ne 0)
    {
        throw "no image $image after the build"
    }

    Write-Log "image $image is $imageId"
}

$configuration = Get-Configuration
Invoke-PreflightCheck $configuration
Invoke-ImageBuild $configuration
Invoke-ImageVerification $configuration
Write-Log '=== image built ==='
