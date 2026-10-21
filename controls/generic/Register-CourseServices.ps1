#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$WorkingDirectory,[string]$GithubLogin)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Course-Context.ps1')
$root=(Resolve-Path -LiteralPath $WorkingDirectory).Path
Assert-CoursePlainPath $root
$pendingPath=Join-Path $root '.course-setup\pending-services.json'
$pending=if(Test-Path -LiteralPath $pendingPath){Read-CourseJson $pendingPath}else{$null}
if(-not $GithubLogin -and $pending.githubLogin){$GithubLogin=$pending.githubLogin}
if($GithubLogin -and $GithubLogin -notmatch '^[a-zA-Z0-9][a-zA-Z0-9-]{0,38}$'){throw 'Invalid GitHub login.'}
if(-not(Test-Path -LiteralPath (Join-Path $root '.course-setup\preparation.json'))){
    # Account observations remain in A while the independent tool worker runs.
    Write-CourseJson $pendingPath @{schemaVersion=1;githubLogin=$GithubLogin;checkedAt=(Get-Date).ToString('o')}
    [pscustomobject]@{status='pending';reason='ToolsNotRegistered';nextAction='Continue foreground accounts; after tools verification rerun this entry to register the saved non-secret service results.'}|ConvertTo-Json
    return
}
Register-CourseServices $root $GithubLogin | ConvertTo-Json
if(Test-Path -LiteralPath $pendingPath){Remove-Item -LiteralPath $pendingPath -Force}
