function Invoke-ImageCleanup($configuration)
{
    $imageName = $configuration.ImageName
    $dangling  = @(docker image list --filter 'dangling=true' --format '{{.ID}}')
    Write-Log "the host holds $($dangling.Count) dangling image(s) before the cleanup"

    Write-Log 'removing every dangling image, which is untagged and referenced by no container'
    docker image prune --force

    $null = docker image inspect --format '{{.Id}}' $imageName
    if ($LASTEXITCODE -ne 0)
    {
        throw "no image $imageName after the cleanup, so the last valid image is gone"
    }

    Write-Log "$imageName is still present"
}
