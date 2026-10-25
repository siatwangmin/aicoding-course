#Requires -Version 5.1
# Pure library; importing does not install tools or change PATH/npm settings.
function Get-CourseNodeJsManifest {
    $path=Join-Path $PSScriptRoot '..\assets\nodejs.json'
    if(-not(Test-Path -LiteralPath $path)){$path=Join-Path $PSScriptRoot 'nodejs.json'}
    $entry=Read-CourseJson $path
    if($entry.schemaVersion -ne 1 -or $entry.version -cnotmatch '^24\.\d+\.\d+$' -or $entry.file -cne ('node-v'+$entry.version+'-win-x64.zip') -or $entry.sha256 -cnotmatch '^[a-f0-9]{64}$' -or $entry.executableSha256 -cnotmatch '^[a-f0-9]{64}$' -or $entry.registry -cne 'https://registry.npmmirror.com/'){throw 'INVALID_NODEJS_MANIFEST'}
    $suffix='/v'+$entry.version+'/'+$entry.file
    $expected=@(('https://npmmirror.com/mirrors/node'+$suffix),('https://mirrors.nju.edu.cn/nodejs-release'+$suffix),('https://nodejs.org/dist'+$suffix))
    if((@($entry.downloadUrls) -join "`n") -cne ($expected -join "`n")){throw 'UNAPPROVED_NODEJS_DOWNLOAD_SOURCE'}
    return $entry
}
function Get-CourseNodeJsProbe([string]$Node,[string]$Workspace) {
    Assert-CoursePlainPath $Node
    $directory=Split-Path $Node -Parent
    foreach($relative in @('node.exe','npm.cmd','npx.cmd','node_modules\npm\bin\npm-cli.js','node_modules\npm\bin\npx-cli.js')){
        $file=Join-Path $directory $relative;Assert-CoursePlainPath $file
        if(-not(Test-Path -LiteralPath $file -PathType Leaf)){throw 'NODEJS_NPM_NPX_REQUIRED'}
    }
    $version=Invoke-SetupNative $Node @('--version') 20 $Workspace
    if($version.ExitCode -ne 0 -or $version.Output.Trim() -notmatch '^v(22|24)\.\d+\.\d+$'){throw 'SUPPORTED_NODEJS_LTS_REQUIRED'}
    $npm=Invoke-SetupNative $Node @((Join-Path $directory 'node_modules\npm\bin\npm-cli.js'),'--version') 30 $Workspace
    $npx=Invoke-SetupNative $Node @((Join-Path $directory 'node_modules\npm\bin\npx-cli.js'),'--version') 30 $Workspace
    if($npm.ExitCode -ne 0 -or $npx.ExitCode -ne 0 -or $npm.Output.Trim() -notmatch '^\d+\.\d+\.\d+$' -or $npx.Output.Trim() -notmatch '^\d+\.\d+\.\d+$'){throw 'NODEJS_NPM_NPX_PROBE_FAILED'}
    return [pscustomobject]@{node=$version.Output.Trim();npm=$npm.Output.Trim();npx=$npx.Output.Trim()}
}
function Resolve-CourseNodeJs {
    param([switch]$AllowMissing)
    $bindingPath=Join-Path $env:USERPROFILE '.ai-coding\nodejs.json'
    if(Test-Path -LiteralPath $bindingPath){
        Assert-CoursePlainPath $bindingPath
        $binding=Read-CourseJson $bindingPath
        if($binding.schemaVersion -ne 1 -or -not [IO.Path]::IsPathRooted($binding.path) -or $binding.sha256 -cnotmatch '^[a-f0-9]{64}$' -or $binding.treeSha256 -cnotmatch '^[a-f0-9]{64}$'){throw 'INVALID_NODEJS_BINDING'}
        Assert-CoursePlainPath $binding.path
        if(-not(Test-Path -LiteralPath $binding.path -PathType Leaf)){
            if($AllowMissing){return $null};throw 'MANAGED_NODEJS_MISSING: recover Setup-NodeJs.ps1 with the original storage root.'
        }
        if((Get-FileHash -LiteralPath $binding.path).Hash.ToLowerInvariant() -cne $binding.sha256 -or (Get-CourseFileBaseline (Split-Path $binding.path -Parent)).digest -cne $binding.treeSha256){throw 'NODEJS_SHA256_MISMATCH'}
        return $binding.path
    }
    $command=Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue
    $candidates=@($(if($command){$command.Source}))
    if($env:ProgramFiles){$candidates+=Join-Path $env:ProgramFiles 'nodejs\node.exe'}
    foreach($candidate in $candidates){
        if($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)){
            try{$null=Get-CourseNodeJsProbe $candidate $env:USERPROFILE;return $candidate}catch{continue}
        }
    }
    if($AllowMissing){return $null};throw 'NODEJS_NOT_INSTALLED: run Setup-NodeJs.ps1 in the preparation workspace.'
}
function Resolve-CourseManagementNode([string]$Path){
    if(-not $Path){return Resolve-CourseNodeJs}
    if(-not [IO.Path]::IsPathRooted($Path) -or -not(Test-Path -LiteralPath $Path -PathType Leaf)){throw 'ABSOLUTE_MANAGEMENT_NODE_REQUIRED'}
    Assert-CoursePlainPath $Path
    $version=Invoke-SetupNative $Path @('--version') 15
    if($version.ExitCode -ne 0 -or $version.Output.Trim() -notmatch '^v(?:22|24)\.\d+\.\d+$'){throw 'SUPPORTED_MANAGEMENT_NODE_REQUIRED'}
    return [IO.Path]::GetFullPath($Path)
}
function Save-CourseNodeJsArchive($Workspace,$Plan,$Entry,[string]$InstallerDirectory) {
    [void](New-Item -ItemType Directory -Path $Plan.installers -Force)
    $archive=Join-Path $Plan.installers $Entry.file;Assert-CoursePlainPath $archive
    $existed=Test-Path -LiteralPath $archive;$attempts=@();$source='verified-cache'
    if($existed -and (Get-FileHash -LiteralPath $archive).Hash.ToLowerInvariant() -cne $Entry.sha256){throw 'NODEJS_CACHED_ARCHIVE_CHANGED'}
    if(-not $existed -and $InstallerDirectory){
        $local=Join-Path $InstallerDirectory $Entry.file;Assert-CoursePlainPath $local
        if(Test-Path -LiteralPath $local){
            if((Get-FileHash -LiteralPath $local).Hash.ToLowerInvariant() -cne $Entry.sha256){throw 'NODEJS_LOCAL_ARCHIVE_CHANGED'}
            Copy-Item -LiteralPath $local -Destination $archive;$source='verified-local'
        }
    }
    if(-not(Test-Path -LiteralPath $archive)){
        foreach($url in $Entry.downloadUrls){
            $partial=$archive+'.partial';Assert-CoursePlainPath $partial
            try{
                Receive-SetupInstaller $url $partial
                if((Get-FileHash -LiteralPath $partial).Hash.ToLowerInvariant() -cne $Entry.sha256){throw 'NODEJS_DOWNLOAD_SHA256_MISMATCH'}
                Move-Item -LiteralPath $partial -Destination $archive;$source=$url
                $attempts+=@{source=$url;status='verified'};break
            }catch{
                $attempts+=@{source=$url;status='failed';error=$_.Exception.Message}
                if(Test-Path -LiteralPath $partial){Remove-Item -LiteralPath $partial -Force}
            }
        }
        if(-not(Test-Path -LiteralPath $archive)){throw ('NODEJS_DOWNLOAD_FAILED: '+($attempts|ConvertTo-Json -Compress))}
    }
    $installation=Find-CourseInstallation $Workspace
    if($installation){$null=Register-CourseResource -InstallationId $installation.installationId -Kind file -Locator $archive -Ownership $(if($existed){'reused'}else{'created'}) -AllowedRoot $Plan.installers -DataClass rebuildable}
    Write-CourseJson (Join-Path $Workspace '.course-setup\nodejs-download.json') @{version=$Entry.version;sha256=$Entry.sha256;source=$source;attempts=$attempts;checkedAt=(Get-Date).ToString('o')}
    return $archive
}
function Invoke-CourseNodeJsSetup {
    param([string]$Workspace,[ValidateSet('Prepare','Verify')][string]$Mode='Prepare',[string]$StorageRoot,[string]$InstallerDirectory)
    $Workspace=(Resolve-Path -LiteralPath $Workspace).Path;Assert-CoursePlainPath $Workspace
    $lease=Enter-CourseOperation $Workspace 'NodeJsSetup'
    $mutex=[Threading.Mutex]::new($false,('Local\ai-coding-node-'+(Get-CourseLifecycleHash (Get-CourseUserRoot))))
    $entered=$false;$evidence=Join-Path $Workspace '.course-setup\nodejs.json'
    try{
        try{$entered=$mutex.WaitOne(15000)}catch [Threading.AbandonedMutexException]{$entered=$true}
        if(-not $entered){throw 'NODEJS_SETUP_BUSY'}
        Write-CourseJson $evidence @{schemaVersion=1;status='pending';checkedAt=(Get-Date).ToString('o')}
        $entry=Get-CourseNodeJsManifest
        $installation=Find-CourseInstallation $Workspace
        if(-not $installation){throw 'NODEJS_INSTALLATION_REGISTRATION_REQUIRED'}
        $bindingPath=Join-Path (Get-CourseUserRoot) 'nodejs.json'
        $bindingExisted=Test-Path -LiteralPath $bindingPath
        $node=Resolve-CourseNodeJs -AllowMissing
        if(-not $node -and $Mode -eq 'Verify'){throw 'NODEJS_NOT_INSTALLED'}
        if(-not $node){
            $runtime=Resolve-CourseRecordedRuntime $Workspace
            $StorageRoot=Resolve-CourseStorageRoot $Workspace $runtime $StorageRoot
            $plan=Get-CourseStoragePlan $StorageRoot 0
            $archive=Save-CourseNodeJsArchive $Workspace $plan $entry $InstallerDirectory
            $parent=Join-Path $plan.programs 'nodejs';$target=Join-Path $parent $entry.version
            Assert-CoursePlainPath $target
            if($bindingExisted){
                $previous=Read-CourseJson $bindingPath
                if($previous.path -ne (Join-Path $target 'node.exe') -or $previous.sha256 -cne $entry.executableSha256){throw 'NODEJS_RECOVERY_BINDING_CONFLICT'}
            }
            $existed=Test-Path -LiteralPath $target
            if(-not $existed){
                [void](New-Item -ItemType Directory -Path $parent -Force)
                $staging=Join-Path $parent ('.staging-'+[guid]::NewGuid().ToString('N'))
                $intent=Assert-CourseCreationIntentOutput @(Start-CourseCreationIntent $installation.installationId tool $target $false) 'Course-NodeJs'
                try{
                    Expand-CourseMaterials $archive $staging -MaxEntries 5000
                    $candidate=Join-Path $staging ('node-v'+$entry.version+'-win-x64')
                    if((Get-FileHash -LiteralPath (Join-Path $candidate 'node.exe')).Hash.ToLowerInvariant() -cne $entry.executableSha256){throw 'NODEJS_EXECUTABLE_SHA256_MISMATCH'}
                    Move-Item -LiteralPath $candidate -Destination $target
                }finally{
                    if(Test-Path -LiteralPath $staging){Assert-CoursePlainPath $staging;if(-not(Test-CoursePathWithin $parent $staging)){throw 'UNSAFE_NODEJS_STAGING'};Remove-Item -LiteralPath $staging -Recurse -Force}
                }
            }elseif(-not $bindingExisted){throw 'EXISTING_NODEJS_TARGET_CONFLICT'}
            $node=Join-Path $target 'node.exe';Assert-CoursePlainPath $node
            if((Get-FileHash -LiteralPath $node).Hash.ToLowerInvariant() -cne $entry.executableSha256){throw 'EXISTING_NODEJS_CONFLICT'}
            $binding=@{schemaVersion=1;path=$node;sha256=$entry.executableSha256;version=$entry.version;archiveSha256=$entry.sha256;treeSha256=(Get-CourseFileBaseline $target).digest;pathEntryOwned=$false}
            if($bindingExisted){
                if($binding.treeSha256 -cne $previous.treeSha256){throw 'NODEJS_RECOVERY_TREE_MISMATCH'}
                # Keep the exact original bytes and lifecycle baseline on recovery.
                $binding=$previous
            }else{Write-CourseJson $bindingPath $binding}
        }
        $probe=Get-CourseNodeJsProbe $node $Workspace
        $directory=Split-Path $node -Parent
        $managed=Test-Path -LiteralPath $bindingPath
        if($managed){
            $binding=Read-CourseJson $bindingPath
            # Persist only the added entry; never replace or expand unrelated PATH entries.
            $userPath=[Environment]::GetEnvironmentVariable('Path','User')
            if(@($userPath -split ';'|Where-Object {$_.TrimEnd('\') -ieq $directory.TrimEnd('\')}).Count -eq 0){
                if($Mode -eq 'Verify'){throw 'NODEJS_USER_PATH_MISSING'}
                $binding.pathEntryOwned=$true;Write-CourseJson $bindingPath $binding
                [Environment]::SetEnvironmentVariable('Path',($directory+';'+$userPath),'User')
            }
            $null=Register-CourseResource -InstallationId $installation.installationId -Kind tool -Locator $directory -Ownership $(if($existed -eq $false -and -not $bindingExisted){'created'}else{'reused'}) -AllowedRoot (Split-Path $directory -Parent) -Metadata @{installer='portable';productName='Node.js';productVersion=$probe.node;pathEntryOwned=$binding.pathEntryOwned}
            $null=Register-CourseResource -InstallationId $installation.installationId -Kind file -Locator $bindingPath -Ownership $(if($bindingExisted){'reused'}else{'created'}) -AllowedRoot (Get-CourseUserRoot)
        }else{
            $null=Register-CourseResource -InstallationId $installation.installationId -Kind tool -Locator $node -Ownership reused -AllowedRoot $directory -Metadata @{installer='portable';productName='Node.js'}
        }
        $env:PATH=$directory+';'+$env:PATH
        $npmCli=Join-Path $directory 'node_modules\npm\bin\npm-cli.js'
        if($Mode -eq 'Prepare'){
            $set=Invoke-SetupNative $node @($npmCli,'config','set','registry',$entry.registry,'--location=user') 30 $Workspace
            if($set.ExitCode -ne 0){throw 'NPM_REGISTRY_CONFIGURATION_FAILED'}
        }
        $registry=Invoke-SetupNative $node @($npmCli,'config','get','registry') 30 $Workspace
        if($registry.ExitCode -ne 0 -or $registry.Output.Trim().TrimEnd('/') -cne $entry.registry.TrimEnd('/')){throw 'NPM_DOMESTIC_REGISTRY_NOT_EFFECTIVE: inspect project/environment overrides; preserve credentials.'}
        $record=[pscustomobject]@{schemaVersion=1;status='verified';path=$node;node=$probe.node;npm=$probe.npm;npx=$probe.npx;registry=$entry.registry;sha256=(Get-FileHash -LiteralPath $node).Hash.ToLowerInvariant();managed=[bool]$managed;checkedAt=(Get-Date).ToString('o');newTerminalRequired=[bool]$managed;cloudbaseAuthorization='not-checked'}
        Write-CourseJson $evidence $record
        return $record
    }catch{
        Write-CourseJson $evidence @{schemaVersion=1;status='failed';checkedAt=(Get-Date).ToString('o')}
        throw
    }finally{if($entered){$mutex.ReleaseMutex()};$mutex.Dispose();Exit-CourseOperation $lease}
}
