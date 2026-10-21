#Requires -Version 5.1
# Library only: importing never downloads, installs, or reads secrets.
. (Join-Path $PSScriptRoot 'Course-Context.ps1')
. (Join-Path $PSScriptRoot 'Course-Native.ps1')
$lifecycleFile=Join-Path $PSScriptRoot 'Course-Lifecycle.ps1'
if(Test-Path -LiteralPath $lifecycleFile){. $lifecycleFile}

function Get-CourseTreeHashes([string]$Directory) {
    Assert-CoursePlainPath $Directory
    $map=@{}
    if(-not(Test-Path -LiteralPath $Directory -PathType Container)){return $map}
    foreach($file in Get-ChildItem -LiteralPath $Directory -File -Recurse -Force){
        Assert-CoursePlainPath $file.FullName
        $name=$file.FullName.Substring($Directory.TrimEnd('\').Length+1).Replace('\','/')
        $map[$name]=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    return $map
}
function Test-CourseTree($Actual,$Expected) {
    $keys=if($Expected -is [Collections.IDictionary]){@($Expected.Keys)}else{@($Expected.PSObject.Properties.Name)}
    if($Actual.Count -ne $keys.Count){return $false}
    foreach($name in $keys){if($Actual[$name] -cne [string]$Expected.$name){return $false}}
    return $true
}
function Assert-CourseRelativeFile([string]$Name) {
    if(-not $Name -or $Name -match '[:\\]' -or $Name.StartsWith('/') -or $Name -match '(^|/)\.\.?(/|$)' -or $Name -match '[\x00-\x1f]'){throw 'UNSAFE_RELEASE_PATH'}
}
function Get-CourseUpgradeRoot {
    $root=Join-Path $env:USERPROFILE '.trae-cn/course-skill-updates'
    Assert-CoursePlainPath $root
    return $root
}
function Enter-CourseUpgradeLock {
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$id=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes((Get-CourseUserRoot).ToLowerInvariant())))).Replace('-','')}finally{$sha.Dispose()}
    $mutex=[Threading.Mutex]::new($false,('Local\course-upgrade-'+$id))
    try{$ok=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$ok=$true}
    if(-not $ok){$mutex.Dispose();throw 'COURSE_UPGRADE_BUSY'}
    return $mutex
}
function Exit-CourseUpgradeLock($Lock){if($Lock){$Lock.ReleaseMutex();$Lock.Dispose()}}
function Assert-CourseBundle([string]$Root) {
    $file=Join-Path $Root 'bundle-manifest.json'
    if(-not(Test-Path -LiteralPath $file)){throw 'BUNDLE_MANIFEST_REQUIRED'}
    $bundle=Read-CourseJson $file
    if($bundle.schemaVersion -ne 1 -or $bundle.materialsProtocol -ne 1 -or $bundle.runtimeContractId -cne $bundle.compatibility.runtimeContractId){throw 'INCOMPATIBLE_BUNDLE_PROTOCOL'}
    foreach($item in $bundle.files.PSObject.Properties){
        Assert-CourseRelativeFile $item.Name;$target=Join-Path $Root $item.Name;Assert-CoursePlainPath $target
        if(-not(Test-Path -LiteralPath $target -PathType Leaf) -or (Get-FileHash -LiteralPath $target).Hash.ToLowerInvariant() -cne $item.Value){throw ('BUNDLE_FILE_MISMATCH: '+$item.Name)}
    }
    foreach($item in $bundle.skills.PSObject.Properties){
        if($item.Name -cnotmatch '^[a-z][a-z0-9-]{0,63}$'){throw 'INVALID_SKILL_ID'}
        Assert-CourseRelativeFile $item.Value.archive
        foreach($dependency in @($item.Value.requires)){if(-not $bundle.skills.PSObject.Properties[$dependency]){throw 'BUNDLE_DEPENDENCY_MISSING'}}
    }
    return $bundle
}
function Test-CourseInstalledCompatibility($Bundle,[string]$Workspace) {
    $file=Join-Path (Get-CourseUserRoot) 'installed-skills.json'
    if(-not(Test-Path -LiteralPath $file)){return $false}
    $installed=Read-CourseJson $file
    $skills=Join-Path $env:USERPROFILE '.trae-cn/skills'
    $required = if ($Bundle.compatibility.skillScopes) { @($Bundle.skills.PSObject.Properties | Where-Object Name -eq 'ai-coding-project') } else { @($Bundle.skills.PSObject.Properties) }
    foreach($item in $required){
        $actual=$installed.skills.($item.Name)
        if(-not $actual -or $actual.runtimeContractId -cne $Bundle.runtimeContractId -or $actual.materialsProtocol -ne $Bundle.materialsProtocol -or -not(Test-CourseTree (Get-CourseTreeHashes (Join-Path $skills $item.Name)) $actual.files)){return $false}
    }
    if($Bundle.compatibility.skillScopes){
        if(-not $Workspace){return $false}
        foreach($name in @('ai-coding-env','ai-coding-github','ai-coding-cloudbase')){
            if((Test-Path -LiteralPath (Join-Path $skills $name)) -or -not(Test-CourseTree (Get-CourseTreeHashes (Join-Path $Workspace ('.trae/skills/'+$name))) $Bundle.skills.$name.files)){return $false}
        }
    }
    return $true
}
function Test-CourseRuntimeCompatibility([string]$Workspace,$Compatibility,[switch]$AllowUnprepared) {
    $record=Join-Path $Workspace 'toolchain-verification.json'
    if(-not(Test-Path -LiteralPath $record)){
        if($AllowUnprepared){return [pscustomobject]@{status='NotPrepared';runtime=$null;source=$null}}
        throw 'UPGRADE_REQUIRES_RECORDED_ENVIRONMENT: prepare or restore the original evidence first.'
    }
    $report=Read-CourseJson $record
    $runtime=if($report.ContainerRuntime){$report.ContainerRuntime}else{'docker'}
    if(-not $report.VerifiedAt -or $report.ToolchainCheck.ExitCode -ne 0 -or $report.Os -ne 'linux' -or $report.Architecture -ne 'amd64'){throw 'UPGRADE_ENVIRONMENT_EVIDENCE_INCOMPLETE'}
    if(($report.Image -split '@')[-1] -cne $Compatibility.imageDigest -and $report.imageDigest -cne $Compatibility.imageDigest){throw 'UPGRADE_IMAGE_INCOMPATIBLE'}
    $profile=$Compatibility.profiles.$runtime
    if(-not $profile){throw 'UPGRADE_RUNTIME_INCOMPATIBLE'}
    if($runtime -eq 'podman'){
        if($report.ComposeBinding.sha256 -cne $profile.composeSha256){throw 'UPGRADE_COMPOSE_INCOMPATIBLE'}
        $client=([string]$report.ClientVersion -replace '^podman version\s+','').Trim()
        $binding=Get-CoursePodmanBinding
        if($binding.cli){
            Assert-CoursePlainPath $binding.cli
            $version=Invoke-SetupNative $binding.cli @('--version') 15
            if($version.ExitCode -ne 0 -or $version.Output -notmatch 'podman version ([0-9.]+)'){throw 'UPGRADE_CLI_VERSION_UNVERIFIED'}
            $client=$Matches[1]
        }
        if(-not $client){throw 'UPGRADE_CLI_EVIDENCE_MISSING'}
        $wslVersion=[string]$report.WslVersion
        if(-not $wslVersion){$wslVersion=[string](Get-SetupWsl).Version}
        if($wslVersion -notmatch '^\d+\.\d+\.\d+' -or [version]$wslVersion -lt [version]$profile.wslMinimum){throw 'UPGRADE_WSL_VERSION_UNVERIFIED'}
        $normalizedWsl=[regex]::Match($wslVersion,'^\d+\.\d+\.\d+').Value
        if($normalizedWsl -notin @($profile.supportedWslVersions)){throw 'UPGRADE_WSL_COMBINATION_NOT_VERIFIED'}
        $matches=@($profile.clientServerPairs|Where-Object {$_[1] -ceq $report.ServerVersion -and $_[0] -ceq $client})
        if(-not $matches.Count){throw 'UPGRADE_PODMAN_PAIR_INCOMPATIBLE'}
        # Check recorded executables when the report supplies paths; no installer or engine start.
        if($report.ComposeBinding.path){
            Assert-CoursePlainPath $report.ComposeBinding.path
            if(-not(Test-Path -LiteralPath $report.ComposeBinding.path) -or (Get-FileHash -LiteralPath $report.ComposeBinding.path).Hash.ToLowerInvariant() -cne $profile.composeSha256){throw 'UPGRADE_COMPOSE_BINDING_CHANGED'}
        }
    }
    $project=Join-Path $Workspace '.ai-coding/project.json'
    if(Test-Path -LiteralPath $project){
        $binding=Read-CourseJson $project
        if($binding.schemaVersion -notin @($Compatibility.supportedProjectSchemas) -or $binding.containerRuntime -cne $runtime -or ($binding.image -split '@')[-1] -cne $Compatibility.imageDigest){throw 'UPGRADE_PROJECT_BINDING_INCOMPATIBLE'}
    }
    return [pscustomobject]@{status='Compatible';runtime=$runtime;source=$record;verifiedAt=$report.VerifiedAt;runtimeReverified=$false}
}
function Assert-CourseSharedCompatibility([string]$Workspace,$Bundle) {
    if ($Bundle.compatibility.skillScopes) { return }
    # Only explicitly registered preparations/projects; never enumerate HOME for projects/secrets.
    $catalog=Join-Path (Get-CourseUserRoot) 'lifecycle/catalog.json'
    if(-not(Test-Path -LiteralPath $catalog)){return}
    $db=Read-CourseJson $catalog
    foreach($installation in @($db.installations|Where-Object status -eq 'active')){
        $other=[string]$installation.workspace
        if(-not $other){continue}
        if($other -ne $Workspace -and (Test-Path -LiteralPath (Join-Path $other 'toolchain-verification.json'))){
            $null=Test-CourseRuntimeCompatibility $other $Bundle.compatibility
        }
        foreach($project in @($installation.projects)){
            $path=if($project -is [string]){$project}else{$project.path}
            if(-not $path){$path=$project.projectRoot}
            if(-not $path){continue}
            $file=Join-Path $path '.ai-coding/project.json'
            if(Test-Path -LiteralPath $file){
                $binding=Read-CourseJson $file
                if($binding.schemaVersion -notin @($Bundle.compatibility.supportedProjectSchemas) -or ($binding.image -split '@')[-1] -cne $Bundle.compatibility.imageDigest -or -not $Bundle.compatibility.profiles.($binding.containerRuntime)){throw 'SHARED_PROJECT_INCOMPATIBLE'}
            }
        }
    }
}
function Get-CourseLegacySkillFiles([string]$Workspace,[string]$Name) {
    $file=Join-Path $Workspace '.course-setup/materials.json'
    if(-not(Test-Path -LiteralPath $file)){return $null}
    $prior=Read-CourseJson $file
    foreach($root in @($prior.PackageRoot,$prior.CaseSupplementRoot)){
        if(-not $root){continue}
        $contract=Join-Path $root 'course-contract.json'
        if(-not(Test-Path -LiteralPath $contract)){continue}
        $entry=@((Read-CourseJson $contract).skills|Where-Object name -ceq $Name)
        if($entry.Count -ne 1){continue}
        Assert-CourseRelativeFile $entry[0].archive
        $zip=Join-Path $root $entry[0].archive;$checksum=[IO.Path]::ChangeExtension($zip,'.sha256')
        if(-not(Test-Path -LiteralPath $zip) -or -not(Test-Path -LiteralPath $checksum)){continue}
        Assert-CoursePlainPath $zip
        $expected=((Get-Content -LiteralPath $checksum -Raw).Trim() -split '\s+')[0]
        if((Get-FileHash -LiteralPath $zip).Hash -ine $expected){throw 'LEGACY_SKILL_SOURCE_CHANGED'}
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive=[IO.Compression.ZipFile]::OpenRead($zip);$map=@{}
        try{foreach($member in $archive.Entries){
            if($member.FullName.EndsWith('/')){continue};Assert-CourseRelativeFile $member.FullName
            $stream=$member.Open();$sha=[Security.Cryptography.SHA256]::Create()
            try{$map[$member.FullName]=([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose();$stream.Dispose()}
        }}finally{$archive.Dispose()}
        return $map
    }
    return $null
}
function Restore-CourseSkillTransaction($Journal) {
    if ($Journal.schemaVersion -eq 2 -and $Journal.scope) { . (Join-Path $PSScriptRoot 'Course-SkillScopes.ps1'); Restore-CourseScopedTransaction $Journal; return }
    if([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Journal.root)) -ine (Get-CourseUpgradeRoot) -or (Split-Path $Journal.root -Leaf) -cnotmatch '^[a-f0-9]{32}$' -or $Journal.stage -cne (Join-Path $Journal.root 'stage') -or $Journal.backup -cne (Join-Path $Journal.root 'backup')){throw 'INVALID_UPGRADE_JOURNAL'}
    $skills=Join-Path $env:USERPROFILE '.trae-cn/skills'
    foreach($item in @($Journal.items)){
        if($item.name -cnotmatch '^[a-z][a-z0-9-]{0,63}$'){throw 'INVALID_TRANSACTION_ITEM'}
        $destination=Join-Path $skills $item.name
        $backup=Join-Path $Journal.backup $item.name
        $next=Join-Path $Journal.stage $item.name
        foreach($path in @($destination,$backup,$next)){Assert-CoursePlainPath $path}
        if(Test-Path -LiteralPath $backup){
            if(Test-Path -LiteralPath $destination){
                if(-not(Test-CourseTree (Get-CourseTreeHashes $destination) $item.expected)){throw 'ROLLBACK_USER_CHANGE_PRESERVED'}
                $retained=Join-Path $Journal.root ('failed-'+$item.name)
                if(Test-Path -LiteralPath $retained){throw 'ROLLBACK_COLLISION_PRESERVED'}
                Move-Item -LiteralPath $destination -Destination $retained
            }
            Move-Item -LiteralPath $backup -Destination $destination
        }elseif(-not $item.existed -and -not(Test-Path -LiteralPath $next) -and (Test-Path -LiteralPath $destination)){
            if(-not(Test-CourseTree (Get-CourseTreeHashes $destination) $item.expected)){throw 'ROLLBACK_USER_CHANGE_PRESERVED'}
            Move-Item -LiteralPath $destination -Destination (Join-Path $Journal.root ('failed-'+$item.name))
        }
    }
    foreach($item in @($Journal.projectItems)){
        if($item.name -cnotmatch '^[a-z][a-z0-9-]{0,63}$'){throw 'INVALID_PROJECT_TRANSACTION_ITEM'}
        $source=Join-Path $Journal.workspace ('.trae/skills/'+$item.name)
        $saved=Join-Path $Journal.workspace ('.course-setup/skill-backups/'+(Split-Path $Journal.root -Leaf)+'/'+$item.name)
        Assert-CoursePlainPath $source;Assert-CoursePlainPath $saved
        if(Test-Path -LiteralPath $saved){
            if(Test-Path -LiteralPath $source){throw 'PROJECT_ROLLBACK_COLLISION_PRESERVED'}
            Move-Item -LiteralPath $saved -Destination $source
        }
    }
    foreach($file in @($Journal.records)){
        if($file.path -notin @((Join-Path (Get-CourseUserRoot) 'installed-skills.json'),(Join-Path $Journal.workspace '.course-setup/skills-installation.json'),(Join-Path $Journal.workspace '.course-setup/materials.json'))){throw 'INVALID_TRANSACTION_RECORD'}
        Assert-CoursePlainPath $file.path
        if($file.existed){[IO.File]::WriteAllBytes($file.path,[Convert]::FromBase64String($file.bytes))}
        elseif(Test-Path -LiteralPath $file.path){Remove-Item -LiteralPath $file.path -Force}
    }
    Sync-CourseSkillLifecycle $Journal
    $Journal.status='RolledBack';Write-CourseJson (Join-Path $Journal.root 'transaction.json') $Journal
}
function Sync-CourseSkillLifecycle($Journal) {
    if(-not(Get-Command Register-CourseInstallation -ErrorAction SilentlyContinue)){return}
    $materials=Join-Path $Journal.workspace '.course-setup/materials.json'
    $installed=Join-Path $Journal.workspace '.course-setup/skills-installation.json'
    $record=if(Test-Path -LiteralPath $materials){Read-CourseJson $materials}elseif(Test-Path -LiteralPath $installed){Read-CourseJson $installed}else{$null}
    if(-not $record){return}
    $version=if($record.CourseVersion){$record.CourseVersion}else{([string]$record.ReleaseId -split '-')[0]}
    $installation=Register-CourseInstallation $Journal.workspace $version
    $skills=Join-Path $env:USERPROFILE '.trae-cn/skills'
    foreach($item in @($Journal.items)){
        $path=Join-Path $skills $item.name
        if(-not(Test-Path -LiteralPath $path)){continue}
        $backup=Join-Path $Journal.backup $item.name
        $saved=if(Test-Path -LiteralPath $backup){$backup}else{$null}
        $null=Register-CourseResource -InstallationId $installation.installationId -Kind skill -Locator $path -Ownership created -AllowedRoot $skills -BackupPath $saved
    }
}
function Repair-CourseSkillTransactions {
    $root=Get-CourseUpgradeRoot
    if(-not(Test-Path -LiteralPath $root)){return}
    foreach($directory in Get-ChildItem -LiteralPath $root -Directory){
        Assert-CoursePlainPath $directory.FullName
        $file=Join-Path $directory.FullName 'transaction.json'
        if(-not(Test-Path -LiteralPath $file)){continue}
        $journal=Read-CourseJson $file
        if($journal.root -cne $directory.FullName -or $journal.stage -cne (Join-Path $directory.FullName 'stage') -or $journal.backup -cne (Join-Path $directory.FullName 'backup')){throw 'INVALID_UPGRADE_JOURNAL'}
        if($journal.status -in @('Staged','Applying','FilesApplied')){Restore-CourseSkillTransaction $journal}
    }
}
function Invoke-CourseSkillTransaction {
    param([string]$Workspace,[string]$PackageRoot,[string[]]$Names,[string]$ReleaseId,[switch]$AllowUnprepared,[switch]$DeferCommit)
    $Workspace=(Resolve-Path -LiteralPath $Workspace).Path
    $lock=Enter-CourseUpgradeLock
    $lease=$null
    try {
        Repair-CourseSkillTransactions
        if(Get-Command Enter-CourseOperation -ErrorAction SilentlyContinue){$lease=Enter-CourseOperation $Workspace 'InstallSkills'}
        $bundle=Assert-CourseBundle $PackageRoot
        $null=Test-CourseRuntimeCompatibility $Workspace $bundle.compatibility -AllowUnprepared:$AllowUnprepared
        Assert-CourseSharedCompatibility $Workspace $bundle
        $skills=Join-Path $env:USERPROFILE '.trae-cn/skills';Assert-CoursePlainPath $skills
        $root=Join-Path (Get-CourseUpgradeRoot) ([guid]::NewGuid().ToString('N'))
        $stage=Join-Path $root 'stage';$backup=Join-Path $root 'backup'
        [void](New-Item -ItemType Directory -Path $stage,$backup,$skills -Force)
        $baselineFile=Join-Path (Get-CourseUserRoot) 'installed-skills.json'
        $prior=if(Test-Path -LiteralPath $baselineFile){Read-CourseJson $baselineFile}else{[pscustomobject]@{schemaVersion=1;skills=[pscustomobject]@{}}}
        $items=@();$unchanged=@();$projectItems=@()
        foreach($name in $Names){
            $entry=$bundle.skills.$name
            if(-not $entry){throw 'SKILL_NOT_IN_LOCKED_BUNDLE'}
            $projectCopy=Join-Path $Workspace ('.trae/skills/'+$name)
            Assert-CoursePlainPath $projectCopy
            if(Test-Path -LiteralPath $projectCopy){$projectItems+=@{name=$name}}
            $dest=Join-Path $skills $name;$actual=Get-CourseTreeHashes $dest
            if(Test-CourseTree $actual $entry.files){$unchanged+=$name;continue}
            if($prior.skills.PSObject.Properties[$name] -and -not(Test-CourseTree $actual $prior.skills.$name.files)){throw ('LOCAL_SKILL_CHANGE_PRESERVED: '+$name)}
            if($actual.Count -and -not $prior.skills.PSObject.Properties[$name]){
                $legacy=Get-CourseLegacySkillFiles $Workspace $name
                if(-not $legacy -or -not(Test-CourseTree $actual $legacy)){throw ('UNTRACKED_SKILL_CHANGE_PRESERVED: '+$name)}
            }
            $zip=Join-Path $PackageRoot $entry.archive
            Assert-CoursePlainPath $zip
            if(-not(Test-Path -LiteralPath $zip) -or (Get-FileHash -LiteralPath $zip).Hash.ToLowerInvariant() -cne $entry.sha256){throw ('SKILL_ARCHIVE_MISMATCH: '+$name)}
            $target=Join-Path $stage $name
            Expand-CourseMaterials $zip $target
            if(-not(Test-CourseTree (Get-CourseTreeHashes $target) $entry.files)){throw 'SKILL_CONTENT_MISMATCH'}
            $header=Get-Content -LiteralPath (Join-Path $target 'SKILL.md') -Raw -Encoding UTF8
            if($header -cnotmatch ('(?m)^name:\s*'+[regex]::Escape($name)+'\s*$')){throw 'SKILL_NAME_MISMATCH'}
            $items+=@{name=$name;existed=(Test-Path -LiteralPath $dest);expected=$entry.files}
        }
        # Dependency closure must be satisfied by selected or byte-identical installed skills.
        foreach($name in $Names){foreach($dep in @($bundle.skills.$name.requires)){
            if($Names -notcontains $dep -and -not(Test-CourseTree (Get-CourseTreeHashes (Join-Path $skills $dep)) $bundle.skills.$dep.files)){throw ('SKILL_DEPENDENCY_MISMATCH: '+$dep)}
        }}
        $records=@()
        foreach($path in @($baselineFile,(Join-Path $Workspace '.course-setup/skills-installation.json'),(Join-Path $Workspace '.course-setup/materials.json'))){
            Assert-CoursePlainPath $path;$exists=Test-Path -LiteralPath $path
            $records+=@{path=$path;existed=$exists;bytes=$(if($exists){[Convert]::ToBase64String([IO.File]::ReadAllBytes($path))}else{''})}
        }
        $journal=[pscustomobject]@{schemaVersion=1;root=$root;stage=$stage;backup=$backup;workspace=$Workspace;releaseId=$ReleaseId;status='Staged';items=@($items);projectItems=$projectItems;records=$records}
        Write-CourseJson (Join-Path $root 'transaction.json') $journal
        try {
            $journal.status='Applying';Write-CourseJson (Join-Path $root 'transaction.json') $journal
            foreach($item in $items){
                $dest=Join-Path $skills $item.name
                if($item.existed){Move-Item -LiteralPath $dest -Destination (Join-Path $backup $item.name)}
                Move-Item -LiteralPath (Join-Path $stage $item.name) -Destination $dest
            }
            foreach($item in $projectItems){
                $source=Join-Path $Workspace ('.trae/skills/'+$item.name)
                $saved=Join-Path $Workspace ('.course-setup/skill-backups/'+(Split-Path $root -Leaf)+'/'+$item.name)
                Assert-CoursePlainPath $saved
                [void](New-Item -ItemType Directory -Path (Split-Path $saved -Parent) -Force)
                Move-Item -LiteralPath $source -Destination $saved
            }
            foreach($name in $Names){
                $entry=$bundle.skills.$name
                if(-not(Test-CourseTree (Get-CourseTreeHashes (Join-Path $skills $name)) $entry.files)){throw 'POST_INSTALL_HASH_MISMATCH'}
                $prior.skills|Add-Member NoteProperty $name ([pscustomobject]@{archiveSha256=$entry.sha256;files=$entry.files;runtimeContractId=$bundle.runtimeContractId;materialsProtocol=$bundle.materialsProtocol;releaseId=$ReleaseId}) -Force
            }
            Write-CourseJson $baselineFile $prior
            $knownFile=Join-Path $Workspace '.course-setup/materials.json'
            $known=if(Test-Path -LiteralPath $knownFile){@((Read-CourseJson $knownFile).SkillNames)}else{@()}
            $installed=[pscustomobject]@{schemaVersion=1;InstalledAt=(Get-Date).ToString('o');ReleaseId=$ReleaseId;ContractVersion='2.0.0';PackageRoot=$PackageRoot;SkillScope='user';SkillsDirectory=$skills;SkillNames=@($known+$Names|Select-Object -Unique);Changed=@($items|ForEach-Object {$_.name});Unchanged=$unchanged;TraeLoadVerified=$false;TransactionRoot=$root}
            Write-CourseJson (Join-Path $Workspace '.course-setup/skills-installation.json') $installed
            if(-not $DeferCommit){Sync-CourseSkillLifecycle $journal}
            $journal.status=if($DeferCommit){'FilesApplied'}else{'Committed'};Write-CourseJson (Join-Path $root 'transaction.json') $journal
            return $installed
        }catch{Restore-CourseSkillTransaction $journal;throw}
    }finally{if($lease){Exit-CourseOperation $lease};Exit-CourseUpgradeLock $lock}
}
function Complete-CourseSkillTransaction([string]$Root) {
    $lock=Enter-CourseUpgradeLock
    try{
        $journal=Read-CourseJson (Join-Path $Root 'transaction.json')
        if($journal.status -ne 'FilesApplied'){throw 'TRANSACTION_NOT_READY'}
        Sync-CourseSkillLifecycle $journal
        $journal.status='Committed';Write-CourseJson (Join-Path $Root 'transaction.json') $journal
    }finally{Exit-CourseUpgradeLock $lock}
}
