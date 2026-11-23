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
    $gitRoot = "\git"
    $customRulesFolderPrefix = ".*githooks_rules.*"
    $customRulesFolderSuffix = "config\rules\enabled"
    $configuration = Get-Content "$configRoot\configuration.json" | ConvertFrom-Json
    $configuration | Add-Member -MemberType NoteProperty -Name "ConfigRoot" -Value $configRoot
    $configuration | Add-Member -MemberType NoteProperty -Name "GitRoot" -Value $gitRoot
    
    $configuration | Add-Member -MemberType NoteProperty -Name "CustomRulesFolderPrefix" -Value $customRulesFolderPrefix
    $configuration | Add-Member -MemberType NoteProperty -Name "CustomRulesFolderSuffix" -Value $customRulesFolderSuffix
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
    $rulesFiles = Get-ChildItem "$($configuration.ConfigRoot)\rules\enabled" -File -Filter "*.json"
    
    if (Test-Path $configuration.GitRoot)
    {
        $customRulesFolders = Get-ChildItem $configuration.GitRoot -Directory | ? { 
                $_.Name -imatch $configuration.CustomRulesFolderPrefix
        } 
        $rulesFiles += $customRulesFolders |% { Get-ChildItem "$($_.FullName)\$($configuration.CustomRulesFolderSuffix)" -File -Filter "*.json" }
    }
    $rulesFiles |%{
        $ruleFile = $_
        $ruleFileTag = $ruleFile.Name
        $rulesFromFile = Get-RulesFromFile $ruleFile
        $rulesFromFile.rules |%{
            $ruleAppliesToAll = $null -eq $_.appliesTo
            $ruleAppliesToLanguage = $_.appliesTo -eq $languageName
            if ($ruleAppliesToAll -or $ruleAppliesToLanguage)
            {
                $rule = $_
                $rule | Add-Member -MemberType NoteProperty -Name "ruleFileTag" -Value $ruleFileTag -Force
                $rules += $rule
            }
        }
    }
    return $rules
}
function Get-FilesInScopeForChange($configuration, $files)
{
    $included = $configuration.Include
    $includedFiles = $files |? { $_ -imatch $included }
    $excluded = $configuration.Exclude
    $files = $includedFiles |? { !($_ -imatch $excluded) }
    return $files
}
function Get-FilesInScope($configuration)
{
    $repoRoot = $configuration.RepoRoot
    $filesChangedInCommit = git -C $repoRoot diff --cached --name-only --diff-filter=ACMR
    $fileInScope = Get-FilesInScopeForChange $configuration $filesChangedInCommit
    return $fileInScope
}
function Add-RuntimeConfiguration($configuration)
{
    $filesInScope = Get-FilesInScope $configuration
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
    $language = $configuration.languages |? { $file -imatch $_.globs }
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
    $match = [regex]::Match($content, $regex, "IgnoreCase")
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
    $rules |? { $null -ne $_ } |%{
        $rule = $_
        Write-Verbose "Checking rule $($rule.name)"
        $matchedAllowed = ($rule.allowedRegex) -and ($content -imatch $rule.allowedRegex)
        $matchedBanned =  $content -imatch $rule.regex 
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
                RuleFileTag = $rule.ruleFileTag
                FileName = $file
                LineNumbers = $lineNumbers
            }
            $contentViolations.Violations += $contentViolation
        }
    }
    return $contentViolations
}
function Invoke-CheckFile($configuration, $file, $rules)
{
    $filePath = "$($configuration.RepoRoot)\$file"
    $violations = @()
    $lineNumber = 0
    Get-Content $filePath |% {
        $content = $_
        $lineNumber++
        $singleLineRules = $rules |? { !$_.multiline }
        $contentViolations = Get-ViolationsForContent $file $lineNumber $content $singleLineRules
        if ($contentViolations.HasViolations)
        { 
            $violations += $contentViolations.Violations 
        }
    }
    $content = Get-Content -Raw $filePath
    $multiLineRules = $rules |? { $_.multiline }
    $contentViolations = Get-ViolationsForContent $file $null $content $multiLineRules
    if ($contentViolations.HasViolations) { 
        $violations += $contentViolations.Violations 
    }
    return $violations
}

function Invoke-CheckBannedWrites($configuration)
{
    $bannedWrites = $configuration.bannedWrites
    $repoRoot = $configuration.RepoRoot
    $filesChanged = git -C $repoRoot diff --cached --name-only --diff-filter=ACMR
    $bannedFiles = $filesChanged |? { $_ -imatch $bannedWrites }
    if (!$bannedFiles)
    {
        return
    }
    $bannedFiles |% {
        Write-Log "Banned write: $_"
    }
    throw "Commit blocked: $($bannedFiles.Count) banned write(s) in the staged changes."
}
function Invoke-CommitGate($configuration)
{
    $filesInScope = $configuration.FilesInScope #we have already filtered in Add-RuntimeConfiguration.
    if (!$filesInScope)
    {
        return
    }
    $violations = @()
    $filesInScope |%{
        $file = $_
        $languageName = Get-LanguageNameFromFileName $configuration $file
        $rules = Add-RulesForLanguage $configuration $languageName
        $fileViolations = @(Invoke-CheckFile $configuration $file $rules)
        $violations += $fileViolations
    }
    $violations |%{
        $violation = $_
        $fileName = $violation.FileName
        $fullRelativeFilePathName = $fileName #relative path from the root of the repo.
        $ruleName = $violation.RuleName
        $ruleFileName = $violation.RuleFileTag
        Write-Log "Violation in $($fullRelativeFilePathName). Line number(s) $($violation.LineNumbers). Rule Name: $($ruleName) in rule file $($ruleFileName)"
    }
    if ($violations.Count -gt 0)
    {
        throw "Commit blocked: $($violations.Count) violation(s) in the staged changes."
    }
}
$configuration = Get-Configuration
$configuration = Add-RuntimeConfiguration $configuration
Invoke-CheckBannedWrites $configuration
Invoke-CommitGate $configuration