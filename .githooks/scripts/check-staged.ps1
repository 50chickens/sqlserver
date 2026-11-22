$ErrorActionPreference = 'Stop'
$VerbosePreference = 'SilentlyContinue'
Set-Location $PSScriptRoot
function Write-Log($message)
{
    Write-Host "[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] $message"
}

function Get-Configuration
{
    
    $configRoot = (Get-Item '..\config').FullName
    $repoRoot = (Get-Item '..\..').FullName
    $configuration = Get-Content "$configRoot\configuration.json" | ConvertFrom-Json
    $configuration | Add-Member -MemberType NoteProperty -Name "ConfigRoot" -Value $configRoot
    $configuration | Add-Member -MemberType NoteProperty -Name "RepoRoot" -Value $repoRoot
    return $configuration
}

function Get-RulesFromFile($file)
{
    return Get-Content $file.FullName | ConvertFrom-Json
}
function Add-RulesForLanguage($configuration, $languageName)
{
    $rules = @()
    $rulesFiles = Get-ChildItem "$($configuration.ConfigRoot)\rules\enabled" -File -Recurse
    $rulesFiles |%{
        $rulesFromFile = Get-RulesFromFile $_
        $rules += $rulesFromFile.rules |? { $_.appliesTo -eq $languageName }
    }
    return $rules
}
function Get-FilesInScopeForChange($configuration, $files)
{
    $included = $configuration.Include
    $includedFiles = $files |? {
        $fileName = $_.Name
        $matchingGlob = $included |? { $fileName -like $_ } | Select-Object -First 1
        $null -ne $matchingGlob
    }
    $excluded = $configuration.Exclude
    $files = $includedFiles |? {
        $fileName = $_.Name
        $matchingGlob = $excluded |? { $fileName -like $_ } | Select-Object -First 1
        $null -eq $matchingGlob
    }
    return $files
}
function Get-FilesInScope($configuration)
{
    $repoRoot = $configuration.RepoRoot
    $filesChangedInCommit = git -C $repoRoot diff --cached --name-only --diff-filter=ACMR |% { Get-Item "$repoRoot\$_" }
    $fileInScope = Get-FilesInScopeForChange $configuration $filesChangedInCommit
    return $fileInScope
}
function Add-RuntimeConfiguration($configuration)
{
    $filesInScope = @(Get-FilesInScope $configuration)
    $configuration | Add-Member -MemberType NoteProperty -Name "FilesInScope" -Value $filesInScope -Force
    return $configuration
}

function Invoke-CheckFile($file, $rules)
{
    Write-Log "Checking $file"
    $violations = Get-Violations $file
    return $violations
}
function Get-LanguageNameFromFileName($configuration, $file)
{
    
    $fileName = $file.Name
    $language = $configuration.languages |? {
        $languageGlobs = $_.globs
        $matchingGlob = $languageGlobs |? { $fileName -like $_ } | Select-Object -First 1
        $null -ne $matchingGlob
    }
    $languageName = $language.name
    return $languageName
}
function Get-LanguageName($configuration, $file)
{
    $languageName = Get-LanguageNameFromFileName $configuration $file
    return $languageName
}

function Test-FileIsExcluded($configuration, $file) 
{
    #test if file is excluded in the configuration.
}
function Get-LineNumbers($content, $regex)
{
    $match = [regex]::Match($content, $regex)
    $linesBefore = $content.Substring(0, $match.Index) -split "`n"
    $matchedLines = $match.Value -split "`n"
    $firstLine = $linesBefore.Count
    $lastLine = $firstLine + $matchedLines.Count - 1
    $lineNumbers = "($firstLine-$lastLine)"
    if ($firstLine -eq $lastLine)
    {
        $lineNumbers = $firstLine
    }
    return $lineNumbers
}
function Get-ViolationsForContent($file, $lineNumber, $content, $rules)
{
    $contentViolations = [psCustomobject]@{ 
        HasViolations = $false
        Violations = @()
    }
    $rules |%{
        $rule = $_
        Write-Verbose "Checking rule $($rule.name)"
        $matchedAllowed = ($rule.allowedRegex) -and ($content -match $rule.allowedRegex)
        $matchedBanned =  $content -match $rule.regex 
        $contentHasViolations = $matchedBanned -and !$matchedAllowed
        if ($contentHasViolations)
        { 
            $contentViolations.HasViolations = $true
            $lineNumbers = $lineNumber
            if ($rule.multiline)
            {
                $lineNumbers = Get-LineNumbers $content $rule.regex
            }
            $contentViolation = [pscustomobject]@{
                RuleName = $rule.name
                FileName = $file.Name
                LineNumbers = $lineNumbers
            }
            $contentViolations.Violations += $contentViolation
        }
    }
    return $contentViolations
}
function Invoke-CheckFile($file, $rules)
{
    $violations = @()
    $lineNumber = 0
    Get-Content $file.FullName |% {
        $content = $_
        $lineNumber++
        $singleLineRules = $rules |? { !$_.multiline }
        $contentViolations = Get-ViolationsForContent $file $lineNumber $content $singleLineRules
        if ($contentViolations.HasViolations)
        { 
            $violations += $contentViolations.Violations 
        }
    }
    $content = Get-Content -Raw $file.FullName
    $multiLineRules = $rules |? { $_.multiline }
    $contentViolations = Get-ViolationsForContent $file $null $content $multiLineRules
    if ($contentViolations.HasViolations) { 
        $violations += $contentViolations.Violations 
    }
    return $violations
}

function Invoke-CommitGate($configuration)
{
    $filesInScope = $configuration.FilesInScope #we have already filtered in Add-RuntimeConfiguration.
    $violations = @()
    $filesInScope |%{
        $file = $_
        $languageName = Get-LanguageNameFromFileName $configuration $file
        $rules = Add-RulesForLanguage $configuration $languageName
        $violations += Invoke-CheckFile $file $rules
    }
    $violations |%{
        $violation = $_
        Write-Log "Violation in $($violation.FileName). Line number(s) $($violation.LineNumbers). Rule Name: $($violation.RuleName)"
    }
    if ($violations.Count -gt 0)
    {
        exit 1
    }
}
$configuration = Get-Configuration
$configuration = Add-RuntimeConfiguration $configuration
Invoke-CommitGate $configuration