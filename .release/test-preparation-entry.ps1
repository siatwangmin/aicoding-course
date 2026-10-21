#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$SitePath,[Parameter(Mandatory=$true)][string]$ExpectedVersion,[Parameter(Mandatory=$true)][string]$OutputPath)
$ErrorActionPreference='Stop'
$site=[IO.Path]::GetFullPath($SitePath)
$testTemp=if($env:RUNNER_TEMP){$env:RUNNER_TEMP}else{[IO.Path]::GetTempPath()}
$evidence=Join-Path $testTemp ('er-'+[guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $evidence -Force|Out-Null
$guide=Get-Content -LiteralPath (Join-Path $site 'setup-guide.md') -Raw -Encoding UTF8
$blocks=[regex]::Matches($guide,'(?s)```powershell\r?\n(.*?)```')
if($blocks.Count -ne 2){throw 'Expected exactly two maintained preparation examples.'}
for($i=0;$i -lt $blocks.Count;$i++){
    [IO.File]::WriteAllText((Join-Path $evidence ('entry-'+($i+1)+'.ps1')),$blocks[$i].Groups[1].Value,[Text.UTF8Encoding]::new($true))
}
New-Item -ItemType Directory -Path (Split-Path ([IO.Path]::GetFullPath($OutputPath)) -Parent) -Force|Out-Null
$fixture=$evidence
$savedProfile=$env:USERPROFILE
$savedLocation=(Get-Location).Path
function Assert-True($Value,[string]$Message){if(-not $Value){throw $Message}}
# Serve only the actual publication files; no external network/engine operations.
function Invoke-WebRequest {
    param([string]$Uri,[string]$OutFile,[switch]$UseBasicParsing,[int]$TimeoutSec)
    $prefix='https://siatwangmin.github.io/aicoding-course/'
    if(-not $Uri.StartsWith($prefix)){throw 'UNEXPECTED_NETWORK_URL'}
    $relative=$Uri.Substring($prefix.Length)
    if($relative -match '\.\.|[?]'){throw 'UNEXPECTED_FIXTURE_PATH'}
    Copy-Item -LiteralPath (Join-Path $site $relative) -Destination $OutFile
}
try {
    $env:USERPROFILE=Join-Path $fixture 'profile'
    $fresh=Join-Path $fixture 'Fresh'
    New-Item -ItemType Directory -Path $env:USERPROFILE,$fresh -Force|Out-Null
    Set-Location -LiteralPath $fresh
    & (Join-Path $evidence 'entry-1.ps1') | Out-Host
    $current=Get-Content -LiteralPath (Join-Path $fresh '.course-setup/materials.json') -Raw -Encoding UTF8|ConvertFrom-Json
    Assert-True ($current.CourseVersion -eq $ExpectedVersion) 'Fresh preparation did not select the target version'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $fresh '.trae/skills') -Directory).Count -eq 1) 'Fresh preparation scopes incorrect'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $env:USERPROFILE '.trae-cn/skills') -Directory).Count -eq 4) 'Fresh user-level platform scopes incorrect'
    # Install the real historical skill set into a separate isolated user profile.
    $env:USERPROFILE=Join-Path $fixture 'old-profile'
    $oldA=Join-Path $fixture 'OldA'
    New-Item -ItemType Directory -Path $env:USERPROFILE,(Join-Path $oldA '.course-setup') -Force|Out-Null
    . (Join-Path $site 'Get-CourseMaterials.ps1')
    $oldPackage=Join-Path $fixture 'old-package'
    Expand-CourseMaterials -Archive (Join-Path $site 'releases/course/v2.3.14/ai-coding-toolkit.zip') -Staging $oldPackage
    & (Join-Path $oldPackage 'Install-CourseSkills.ps1') -WorkingDirectory $oldA -PackageRoot $oldPackage | Out-Host
    # Recorded compatibility fixture, not a claim of a real engine check.
    $compat=Get-Content -LiteralPath (Join-Path $site 'course-contract/compatibility.json') -Raw -Encoding UTF8|ConvertFrom-Json
    @{VerifiedAt='2026-10-21T00:00:00Z';ToolchainCheck=@{ExitCode=0};Os='linux';Architecture='amd64';ContainerRuntime='docker';Image=('fixture@'+$compat.imageDigest)} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $oldA 'toolchain-verification.json') -Encoding UTF8
    @{CourseVersion='2.3.14';PackageRoot=$oldPackage;PackageProfile='generic';SkillNames=@('ai-coding-env','ai-coding-project','ai-coding-github','ai-coding-cloudbase','ai-coding-development','ai-coding-siliconflow','ai-coding-android');ContainerRuntime='docker';EnvironmentVerified=$true;PreparedAt='2026-10-20T00:00:00Z'} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $oldA '.course-setup/materials.json') -Encoding UTF8
    Set-Location -LiteralPath $oldA
    & (Join-Path $evidence 'entry-2.ps1') | Out-Host
    $updated=Get-Content -LiteralPath (Join-Path $oldA '.course-setup/materials.json') -Raw -Encoding UTF8|ConvertFrom-Json
    Assert-True ($updated.CourseVersion -eq $ExpectedVersion) 'Upgrade did not advance the historical version to the target'
    Assert-True ($updated.ContainerRuntime -eq 'docker') 'Upgrade changed original runtime'
    Assert-True ($updated.SkillScope -eq 'mixed') 'Upgrade retained old global scope'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $oldA '.trae/skills') -Directory).Count -eq 1) 'Upgrade preparation scopes incorrect'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $env:USERPROFILE '.trae-cn/skills') -Directory).Count -eq 4) 'Upgrade did not install all user-level platform skills'
    @{status='passed';fixture=$fixture;freshVersion=$current.CourseVersion;from='2.3.14';to=$updated.CourseVersion;scope=$updated.SkillScope;engineOperations=$false;externalNetwork=$false}|ConvertTo-Json|Set-Content -LiteralPath $OutputPath -Encoding UTF8
    Write-Output ('PASS: actual documented commands; fresh latest selection and historical package/scope upgrade. Fixture: '+$fixture)
}catch{
    @{status='failed';version=$ExpectedVersion;error=$_.Exception.Message}|ConvertTo-Json|Set-Content -LiteralPath $OutputPath -Encoding UTF8
    throw
}finally{$env:USERPROFILE=$savedProfile;Set-Location -LiteralPath $savedLocation}
