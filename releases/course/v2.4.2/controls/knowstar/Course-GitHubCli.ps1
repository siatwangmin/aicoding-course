#Requires -Version 5.1
# Pure function library. Importing does not download, install or authorize anything.
function Resolve-CourseGitHubCli {
    param([switch]$AllowMissing)
    $bindingPath=Join-Path $env:USERPROFILE '.ai-coding\github-cli.json'
    if(Test-Path -LiteralPath $bindingPath){
        Assert-CoursePlainPath $bindingPath
        $binding=Get-Content -LiteralPath $bindingPath -Raw -Encoding UTF8|ConvertFrom-Json
        if($binding.schemaVersion -ne 1 -or -not [IO.Path]::IsPathRooted($binding.path) -or $binding.sha256 -cnotmatch '^[a-f0-9]{64}$'){throw 'INVALID_GITHUB_CLI_BINDING'}
        Assert-CoursePlainPath $binding.path
        if(-not(Test-Path -LiteralPath $binding.path -PathType Leaf)){
            if($AllowMissing){return $null}
            throw 'MANAGED_GITHUB_CLI_MISSING: recover Setup-GitHubCli.ps1; preserve the original binding.'
        }
        if((Get-FileHash -LiteralPath $binding.path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $binding.sha256){throw 'GITHUB_CLI_SHA256_MISMATCH'}
        return $binding.path
    }
    $command=Get-Command gh.exe -CommandType Application -ErrorAction SilentlyContinue
    if($command){return $command.Source}
    $candidates=@()
    if($env:LOCALAPPDATA){$candidates+=Join-Path $env:LOCALAPPDATA 'Programs\gh-cli\bin\gh.exe'}
    if($env:ProgramFiles){$candidates+=Join-Path $env:ProgramFiles 'GitHub CLI\gh.exe'}
    foreach($candidate in $candidates){if(Test-Path -LiteralPath $candidate -PathType Leaf){return $candidate}}
    if($AllowMissing){return $null}
    throw 'GitHub CLI not found. Run the preparation Setup-GitHubCli.ps1; preserve Pages configuration.'
}
function Get-CourseGitHubCliManifest {
    $path=Join-Path $PSScriptRoot '..\assets\github-cli.json'
    if(-not(Test-Path -LiteralPath $path)){$path=Join-Path $PSScriptRoot 'github-cli.json'}
    $entry=Read-CourseJson $path
    if($entry.version -cnotmatch '^\d+\.\d+\.\d+$' -or $entry.file -cne ('gh_'+$entry.version+'_windows_amd64.zip') -or $entry.sha256 -cnotmatch '^[a-f0-9]{64}$' -or $entry.executableSha256 -cnotmatch '^[a-f0-9]{64}$'){throw 'INVALID_GITHUB_CLI_MANIFEST'}
    $origin='https://github.com/cli/cli/releases/download/v'+$entry.version+'/'+$entry.file
    # Third-party accelerators transport only the public archive; never credentials/API traffic.
    $gitCode='https://gitcode.com/oh_my_love/ai_practice/releases/download/1.0.0/'+$entry.file
    $expected=@($gitCode,('https://ghfast.top/'+$origin),('https://gh-proxy.com/'+$origin),$origin)
    if((@($entry.downloadUrls) -join "`n") -cne ($expected -join "`n")){throw 'UNAPPROVED_GITHUB_CLI_DOWNLOAD_SOURCE'}
    return $entry
}
function Save-CourseGitHubCliArchive($Workspace,$Plan,$Entry,[string]$InstallerDirectory) {
    [void](New-Item -ItemType Directory -Path $Plan.installers -Force)
    $archive=Join-Path $Plan.installers $Entry.file;Assert-CoursePlainPath $archive
    $existed=Test-Path -LiteralPath $archive;$attempts=@();$source='verified-cache'
    if($existed -and (Get-FileHash -LiteralPath $archive).Hash.ToLowerInvariant() -cne $Entry.sha256){throw 'GITHUB_CLI_CACHED_ARCHIVE_CHANGED'}
    if(-not $existed -and $InstallerDirectory){
        $local=Join-Path $InstallerDirectory $Entry.file;Assert-CoursePlainPath $local
        if(Test-Path -LiteralPath $local){
            if((Get-FileHash -LiteralPath $local).Hash.ToLowerInvariant() -cne $Entry.sha256){throw 'GITHUB_CLI_LOCAL_ARCHIVE_CHANGED'}
            Copy-Item -LiteralPath $local -Destination $archive;$source='verified-local'
        }
    }
    if(-not(Test-Path -LiteralPath $archive)){
        foreach($url in $Entry.downloadUrls){
            $partial=$archive+'.partial';Assert-CoursePlainPath $partial
            try{
                Receive-SetupInstaller $url $partial
                if((Get-FileHash -LiteralPath $partial).Hash.ToLowerInvariant() -cne $Entry.sha256){throw 'GITHUB_CLI_DOWNLOAD_SHA256_MISMATCH'}
                Move-Item -LiteralPath $partial -Destination $archive;$source=$url
                $attempts+=@{source=$url;status='verified'};break
            }catch{
                $attempts+=@{source=$url;status='failed';error=$_.Exception.Message}
                if(Test-Path -LiteralPath $partial){Remove-Item -LiteralPath $partial -Force}
            }
        }
        if(-not(Test-Path -LiteralPath $archive)){throw ('GITHUB_CLI_DOWNLOAD_FAILED: '+($attempts|ConvertTo-Json -Compress))}
    }
    $installation=Find-CourseInstallation $Workspace
    if($installation){$null=Register-CourseResource -InstallationId $installation.installationId -Kind file -Locator $archive -Ownership $(if($existed){'reused'}else{'created'}) -AllowedRoot $Plan.installers -DataClass rebuildable}
    Write-CourseJson (Join-Path $Workspace '.course-setup\github-cli-download.json') @{version=$Entry.version;sha256=$Entry.sha256;source=$source;attempts=$attempts;checkedAt=(Get-Date).ToString('o')}
    return $archive
}
function Invoke-CourseGitHubCliSetup {
    param([string]$Workspace,[ValidateSet('Prepare','Verify')][string]$Mode='Prepare',[string]$StorageRoot,[string]$InstallerDirectory)
    $Workspace=(Resolve-Path -LiteralPath $Workspace).Path;Assert-CoursePlainPath $Workspace
    $lease=Enter-CourseOperation $Workspace 'GitHubCliSetup'
    $mutex=[Threading.Mutex]::new($false,('Local\ai-coding-gh-'+(Get-CourseLifecycleHash (Get-CourseUserRoot))))
    $entered=$false
    try{
        try{$entered=$mutex.WaitOne(15000)}catch [Threading.AbandonedMutexException]{$entered=$true}
        if(-not $entered){throw 'GITHUB_CLI_SETUP_BUSY: wait for the existing preparation worker, then retry.'}
        $entry=Get-CourseGitHubCliManifest
        $installation=Find-CourseInstallation $Workspace
        if(-not $installation){throw 'GITHUB_CLI_INSTALLATION_REGISTRATION_REQUIRED: install course materials in A first.'}
        $bindingPath=Join-Path (Get-CourseUserRoot) 'github-cli.json'
        $bindingExisted=Test-Path -LiteralPath $bindingPath
        $gh=Resolve-CourseGitHubCli -AllowMissing
        if(-not $gh -and $Mode -eq 'Verify'){throw 'GITHUB_CLI_NOT_INSTALLED'}
        if(-not $gh){
            $runtime=Resolve-CourseRecordedRuntime $Workspace
            $StorageRoot=Resolve-CourseStorageRoot $Workspace $runtime $StorageRoot
            $plan=Get-CourseStoragePlan $StorageRoot 0
            $archive=Save-CourseGitHubCliArchive $Workspace $plan $entry $InstallerDirectory
            $parent=Join-Path $plan.programs 'github-cli';$target=Join-Path $parent $entry.version
            Assert-CoursePlainPath $target
            if($bindingExisted){
                $previous=Read-CourseJson $bindingPath
                if($previous.path -ne (Join-Path $target 'bin\gh.exe') -or $previous.sha256 -cne $entry.executableSha256){throw 'GITHUB_CLI_RECOVERY_BINDING_CONFLICT: preserve the original version and storage location.'}
            }
            $existed=Test-Path -LiteralPath $target
            if(-not $existed){
                [void](New-Item -ItemType Directory -Path $parent -Force)
                $staging=Join-Path $parent ('.staging-'+[guid]::NewGuid().ToString('N'))
                $intent=Start-CourseCreationIntent $installation.installationId tool $target $false
                try{
                    Expand-CourseMaterials $archive $staging
                    $candidate=Join-Path $staging 'bin\gh.exe'
                    if(-not(Test-Path -LiteralPath $candidate) -or (Get-FileHash -LiteralPath $candidate).Hash.ToLowerInvariant() -cne $entry.executableSha256){throw 'GITHUB_CLI_EXECUTABLE_SHA256_MISMATCH'}
                    Move-Item -LiteralPath $staging -Destination $target
                }finally{
                    if(Test-Path -LiteralPath $staging){Assert-CoursePlainPath $staging;if(-not(Test-CoursePathWithin $parent $staging)){throw 'UNSAFE_GITHUB_CLI_STAGING'};Remove-Item -LiteralPath $staging -Recurse -Force}
                }
            }
            $gh=Join-Path $target 'bin\gh.exe';Assert-CoursePlainPath $gh
            if(-not(Test-Path -LiteralPath $gh) -or (Get-FileHash -LiteralPath $gh).Hash.ToLowerInvariant() -cne $entry.executableSha256){throw 'EXISTING_GITHUB_CLI_CONFLICT'}
            $null=Register-CourseResource -InstallationId $installation.installationId -Kind tool -Locator $target -Ownership $(if($existed){'reused'}else{'created'}) -AllowedRoot $parent -Metadata @{installer='portable';productName='GitHub CLI';productVersion=$entry.version;scope='current-user'}
            Write-CourseJson $bindingPath @{schemaVersion=1;path=$gh;sha256=$entry.executableSha256;version=$entry.version;archiveSha256=$entry.sha256}
            $null=Register-CourseResource -InstallationId $installation.installationId -Kind file -Locator $bindingPath -Ownership $(if($bindingExisted){'reused'}else{'created'}) -AllowedRoot (Get-CourseUserRoot)
        }elseif(Test-Path -LiteralPath $bindingPath){
            $binding=Read-CourseJson $bindingPath
            $target=Split-Path (Split-Path $gh -Parent) -Parent
            $null=Register-CourseResource -InstallationId $installation.installationId -Kind tool -Locator $target -Ownership reused -AllowedRoot (Split-Path $target -Parent) -Metadata @{installer='portable'}
            $null=Register-CourseResource -InstallationId $installation.installationId -Kind file -Locator $bindingPath -Ownership reused -AllowedRoot (Get-CourseUserRoot)
        }else{
            Assert-CoursePlainPath $gh
            $null=Register-CourseResource -InstallationId $installation.installationId -Kind tool -Locator $gh -Ownership reused -AllowedRoot (Split-Path $gh -Parent) -Metadata @{installer='portable'}
        }
        $probe=Invoke-SetupNative $gh @('--version') 15 $Workspace
        if($probe.ExitCode -ne 0 -or $probe.Output -notmatch 'gh version (\d+\.\d+\.\d+)'){throw 'GITHUB_CLI_VERSION_PROBE_FAILED'}
        $actualVersion=$Matches[1]
        $record=[pscustomobject]@{schemaVersion=1;status='verified';path=$gh;version=$actualVersion;sha256=(Get-FileHash -LiteralPath $gh).Hash.ToLowerInvariant();managed=[bool](Test-Path -LiteralPath $bindingPath);checkedAt=(Get-Date).ToString('o');authorization='not-checked';githubConnectivity='not-checked'}
        Write-CourseJson (Join-Path $Workspace '.course-setup\github-cli.json') $record
        return $record
    }finally{if($entered){$mutex.ReleaseMutex()};$mutex.Dispose();Exit-CourseOperation $lease}
}
