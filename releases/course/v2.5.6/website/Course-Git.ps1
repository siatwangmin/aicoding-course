#Requires -Version 5.1
# Pure helpers; importing never installs Git or changes configuration.
. (Join-Path $PSScriptRoot 'Course-Lifecycle.ps1')
function Get-CourseGitManifest {
    $path=Join-Path $PSScriptRoot '..\assets\git-for-windows.json'
    if(-not(Test-Path -LiteralPath $path)){$path=Join-Path $PSScriptRoot 'git-for-windows.json'}
    $entry=Read-CourseJson $path
    if($entry.schemaVersion -ne 1 -or $entry.version -cnotmatch '^2\.\d+\.\d+(?:\.\d+)?$' -or $entry.tag -cnotmatch '^v2\.\d+\.\d+\.windows\.\d+$' -or $entry.file -cne ('PortableGit-'+$entry.version+'-64-bit.7z.exe') -or $entry.sha256 -cnotmatch '^[a-f0-9]{64}$' -or $entry.executableSha256 -cnotmatch '^[a-f0-9]{64}$'){throw 'INVALID_GIT_MANIFEST'}
    if($entry.tag -cne ('v'+$entry.gitVersion) -or ($entry.gitVersion -replace '\.windows\.','.') -cne $entry.version){throw 'GIT_MANIFEST_VERSION_MISMATCH'}
    $suffix='/'+$entry.tag+'/'+$entry.file
    $expected=@(('https://npmmirror.com/mirrors/git-for-windows'+$suffix),('https://mirrors.huaweicloud.com/git-for-windows'+$suffix),('https://github.com/git-for-windows/git/releases/download'+$suffix))
    if((@($entry.downloadUrls) -join "`n") -cne ($expected -join "`n")){throw 'UNAPPROVED_GIT_DOWNLOAD_SOURCE'}
    return $entry
}
function Get-CourseGitProbe([string]$Git,[string]$Workspace) {
    Assert-CoursePlainPath $Git
    $version=Invoke-SetupNative $Git @('--version') 20 $Workspace
    if($version.ExitCode -ne 0 -or $version.Output.Trim() -notmatch '^git version (2\.\d+\.\d+\.windows\.\d+)$'){throw 'GIT_FOR_WINDOWS_PROBE_FAILED'}
    $actual=$Matches[1]
    $exec=Invoke-SetupNative $Git @('--exec-path') 20 $Workspace
    if($exec.ExitCode -ne 0 -or -not $exec.Output.Trim()){throw 'GIT_EXEC_PATH_PROBE_FAILED'}
    return [pscustomobject]@{version=$actual;execPath=$exec.Output.Trim()}
}
function Resolve-CourseGit {
    param([switch]$AllowMissing)
    $bindingPath=Join-Path $env:USERPROFILE '.ai-coding\git-for-windows.json'
    if(Test-Path -LiteralPath $bindingPath){
        Assert-CoursePlainPath $bindingPath;$binding=Read-CourseJson $bindingPath
        if($binding.schemaVersion -ne 1 -or -not [IO.Path]::IsPathRooted($binding.path) -or -not [IO.Path]::IsPathRooted($binding.root) -or $binding.path -ine (Join-Path $binding.root 'cmd\git.exe') -or $binding.sha256 -cnotmatch '^[a-f0-9]{64}$' -or $binding.treeSha256 -cnotmatch '^[a-f0-9]{64}$'){throw 'INVALID_GIT_BINDING'}
        Assert-CoursePlainPath $binding.path;Assert-CoursePlainPath $binding.root
        if(-not(Test-Path -LiteralPath $binding.path -PathType Leaf)){
            if($AllowMissing){return $null};throw 'MANAGED_GIT_MISSING: recover Setup-Git.ps1 with the original storage root.'
        }
        if((Get-FileHash -LiteralPath $binding.path).Hash.ToLowerInvariant() -cne $binding.sha256 -or (Get-CourseFileBaseline $binding.root).digest -cne $binding.treeSha256){throw 'GIT_SHA256_MISMATCH'}
        return $binding.path
    }
    $command=Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue
    $candidates=@($(if($command){$command.Source}))
    foreach($parent in @($env:ProgramFiles,${env:ProgramFiles(x86)},$(if($env:LOCALAPPDATA){Join-Path $env:LOCALAPPDATA 'Programs'}))){
        if($parent){$candidates+=Join-Path $parent 'Git\cmd\git.exe'}
    }
    foreach($candidate in $candidates){
        if($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)){
            $null=Get-CourseGitProbe $candidate $env:USERPROFILE
            return $candidate
        }
    }
    if($AllowMissing){return $null};throw 'GIT_NOT_INSTALLED: run Setup-Git.ps1 in the preparation workspace.'
}
function Save-CourseGitArchive($Workspace,$Plan,$Entry,[string]$InstallerDirectory) {
    [void](New-Item -ItemType Directory -Path $Plan.installers -Force)
    $archive=Join-Path $Plan.installers $Entry.file;Assert-CoursePlainPath $archive
    $existed=Test-Path -LiteralPath $archive;$attempts=@();$source='verified-cache'
    if($existed -and (Get-FileHash -LiteralPath $archive).Hash.ToLowerInvariant() -cne $Entry.sha256){throw 'GIT_CACHED_ARCHIVE_CHANGED'}
    if(-not $existed -and $InstallerDirectory){
        $local=Join-Path $InstallerDirectory $Entry.file;Assert-CoursePlainPath $local
        if(Test-Path -LiteralPath $local){
            if((Get-FileHash -LiteralPath $local).Hash.ToLowerInvariant() -cne $Entry.sha256){throw 'GIT_LOCAL_ARCHIVE_CHANGED'}
            Copy-Item -LiteralPath $local -Destination $archive;$source='verified-local'
        }
    }
    if(-not(Test-Path -LiteralPath $archive)){
        foreach($url in $Entry.downloadUrls){
            $partial=$archive+'.partial';Assert-CoursePlainPath $partial
            try{
                Receive-SetupInstaller $url $partial
                if((Get-FileHash -LiteralPath $partial).Hash.ToLowerInvariant() -cne $Entry.sha256){throw 'GIT_DOWNLOAD_SHA256_MISMATCH'}
                Move-Item -LiteralPath $partial -Destination $archive;$source=$url
                $attempts+=@{source=$url;status='verified'};break
            }catch{
                $attempts+=@{source=$url;status='failed';error=$_.Exception.Message}
                if(Test-Path -LiteralPath $partial){Remove-Item -LiteralPath $partial -Force}
            }
        }
        if(-not(Test-Path -LiteralPath $archive)){throw ('GIT_DOWNLOAD_FAILED: '+($attempts|ConvertTo-Json -Compress))}
    }
    $installation=Find-CourseInstallation $Workspace
    if($installation){$null=Register-CourseResource -InstallationId $installation.installationId -Kind file -Locator $archive -Ownership $(if($existed){'reused'}else{'created'}) -AllowedRoot $Plan.installers -DataClass rebuildable}
    Write-CourseJson (Join-Path $Workspace '.course-setup\git-download.json') @{version=$Entry.version;sha256=$Entry.sha256;source=$source;attempts=$attempts;checkedAt=(Get-Date).ToString('o')}
    return $archive
}
function Invoke-CourseGitSetup {
    param([string]$Workspace,[ValidateSet('Prepare','Verify')][string]$Mode='Prepare',[string]$StorageRoot,[string]$InstallerDirectory)
    $Workspace=(Resolve-Path -LiteralPath $Workspace).Path;Assert-CoursePlainPath $Workspace
    $lease=Enter-CourseOperation $Workspace 'GitSetup'
    $mutex=[Threading.Mutex]::new($false,('Local\ai-coding-git-'+(Get-CourseLifecycleHash (Get-CourseUserRoot))))
    $entered=$false;$evidence=Join-Path $Workspace '.course-setup\git.json';$intent=$null
    try{
        try{$entered=$mutex.WaitOne(15000)}catch [Threading.AbandonedMutexException]{$entered=$true}
        if(-not $entered){throw 'GIT_SETUP_BUSY'}
        Write-CourseJson $evidence @{schemaVersion=1;status='pending';checkedAt=(Get-Date).ToString('o')}
        $entry=Get-CourseGitManifest;$installation=Find-CourseInstallation $Workspace
        if(-not $installation){throw 'GIT_INSTALLATION_REGISTRATION_REQUIRED'}
        $bindingPath=Join-Path (Get-CourseUserRoot) 'git-for-windows.json'
        $bindingExisted=Test-Path -LiteralPath $bindingPath
        $git=Resolve-CourseGit -AllowMissing;$created=$false
        if(-not $git -and $Mode -eq 'Verify'){throw 'GIT_NOT_INSTALLED'}
        if(-not $git){
            if([Environment]::OSVersion.Version.Major -lt 10 -or -not [Environment]::Is64BitOperatingSystem){throw 'GIT_WINDOWS_10_X64_REQUIRED'}
            $runtime=Resolve-CourseRecordedRuntime $Workspace
            $StorageRoot=Resolve-CourseStorageRoot $Workspace $runtime $StorageRoot
            $plan=Get-CourseStoragePlan $StorageRoot 0
            $archive=Save-CourseGitArchive $Workspace $plan $entry $InstallerDirectory
            $parent=Join-Path $plan.programs 'git-for-windows';$target=Join-Path $parent $entry.version
            Assert-CoursePlainPath $target
            if($bindingExisted){
                $previous=Read-CourseJson $bindingPath
                if($previous.path -ine (Join-Path $target 'cmd\git.exe') -or $previous.sha256 -cne $entry.executableSha256){throw 'GIT_RECOVERY_BINDING_CONFLICT'}
            }
            if(Test-Path -LiteralPath $target){throw 'EXISTING_GIT_TARGET_CONFLICT'}
            [void](New-Item -ItemType Directory -Path $parent -Force)
            $staging=Join-Path $parent ('.staging-'+[guid]::NewGuid().ToString('N'))
            $intent=Assert-CourseCreationIntentOutput @(Start-CourseCreationIntent $installation.installationId tool $target $false) 'Course-Git'
            try{
                # Official PortableGit SFX supports -y and -o; it runs its own post-install.
                $extract=Invoke-SetupNative $archive @('-y',('-o'+$staging)) 300 $Workspace
                if($extract.ExitCode -ne 0){throw 'GIT_EXTRACTION_FAILED'}
                foreach($file in @('cmd\git.exe','git-bash.exe','usr\bin\ssh.exe')){
                    $required=Join-Path $staging $file;Assert-CoursePlainPath $required
                    if(-not(Test-Path -LiteralPath $required -PathType Leaf)){throw ('GIT_PORTABLE_COMPONENT_MISSING: '+$file)}
                }
                if(Test-Path -LiteralPath (Join-Path $staging 'post-install.bat')){throw 'GIT_POST_INSTALL_INCOMPLETE'}
                if((Get-FileHash -LiteralPath (Join-Path $staging 'cmd\git.exe')).Hash.ToLowerInvariant() -cne $entry.executableSha256){throw 'GIT_EXECUTABLE_SHA256_MISMATCH'}
                $probe=Get-CourseGitProbe (Join-Path $staging 'cmd\git.exe') $Workspace
                if($probe.version -cne $entry.gitVersion){throw 'GIT_PORTABLE_VERSION_MISMATCH'}
                $https=Join-Path $probe.execPath 'git-remote-https.exe'
                if(-not(Test-CoursePathWithin $staging $https) -or -not(Test-Path -LiteralPath $https -PathType Leaf)){throw 'GIT_HTTPS_COMPONENT_MISSING'}
                [IO.Directory]::Move($staging,$target);$created=$true
            }finally{
                if(Test-Path -LiteralPath $staging){Assert-CoursePlainPath $staging;if(-not(Test-CoursePathWithin $parent $staging)){throw 'UNSAFE_GIT_STAGING'};Remove-Item -LiteralPath $staging -Recurse -Force}
            }
            $git=Join-Path $target 'cmd\git.exe'
            $binding=@{schemaVersion=1;path=$git;root=$target;sha256=$entry.executableSha256;version=$entry.version;archiveSha256=$entry.sha256;treeSha256=(Get-CourseFileBaseline $target).digest;pathEntryOwned=$false}
            if($bindingExisted){
                if($binding.treeSha256 -cne $previous.treeSha256){throw 'GIT_RECOVERY_TREE_MISMATCH'}
                $binding=$previous
            }else{Write-CourseJson $bindingPath $binding}
        }
        $probe=Get-CourseGitProbe $git $Workspace;$directory=Split-Path $git -Parent
        $managed=Test-Path -LiteralPath $bindingPath
        if($managed){
            $binding=Read-CourseJson $bindingPath
            $userPath=[Environment]::GetEnvironmentVariable('Path','User')
            if(@($userPath -split ';'|Where-Object {$_.TrimEnd('\') -ieq $directory.TrimEnd('\')}).Count -eq 0){
                if($Mode -eq 'Verify'){throw 'GIT_USER_PATH_MISSING'}
                $binding.pathEntryOwned=$true;Write-CourseJson $bindingPath $binding
                [Environment]::SetEnvironmentVariable('Path',($directory+';'+$userPath),'User')
            }
            $null=Register-CourseResource -InstallationId $installation.installationId -Kind tool -Locator $binding.root -Ownership $(if($created -and -not $bindingExisted){'created'}else{'reused'}) -AllowedRoot (Split-Path $binding.root -Parent) -Metadata @{installer='portable';productName='Git for Windows';productVersion=$probe.version;pathEntryOwned=$binding.pathEntryOwned}
            $null=Register-CourseResource -InstallationId $installation.installationId -Kind file -Locator $bindingPath -Ownership $(if($bindingExisted){'reused'}else{'created'}) -AllowedRoot (Get-CourseUserRoot)
        }else{
            $null=Register-CourseResource -InstallationId $installation.installationId -Kind tool -Locator $git -Ownership reused -AllowedRoot $directory -Metadata @{installer='portable';productName='Git for Windows';productVersion=$probe.version}
        }
        if($intent){$null=Complete-CourseCreationIntent $intent}
        if(@($env:PATH -split ';'|Where-Object {$_.TrimEnd('\') -ieq $directory.TrimEnd('\')}).Count -eq 0){$env:PATH=$directory+';'+$env:PATH}
        $record=[pscustomobject]@{schemaVersion=1;status='verified';path=$git;version=$probe.version;execPath=$probe.execPath;sha256=(Get-FileHash -LiteralPath $git).Hash.ToLowerInvariant();managed=[bool]$managed;checkedAt=(Get-Date).ToString('o');newTerminalRequired=[bool]$managed;githubAuthorization='not-checked'}
        Write-CourseJson $evidence $record
        return $record
    }catch{
        Write-CourseJson $evidence @{schemaVersion=1;status='failed';checkedAt=(Get-Date).ToString('o')}
        throw
    }finally{if($entered){$mutex.ReleaseMutex()};$mutex.Dispose();Exit-CourseOperation $lease}
}
