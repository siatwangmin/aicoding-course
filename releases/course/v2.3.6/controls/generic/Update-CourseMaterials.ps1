#Requires -Version 5.1
[CmdletBinding()]
param([string]$WorkingDirectory,[string]$CourseVersion,
      [ValidateSet('Check','Download','Apply','Skills','Recover','Rollback')][string]$Action='Apply',
      [ValidateSet('generic','knowstar')][string]$PackageProfile,[string]$SkillNames)
if(-not(Get-Command Resolve-CourseRelease -ErrorAction SilentlyContinue)){. (Join-Path $PSScriptRoot 'Get-CourseMaterials.ps1')}
. (Join-Path $PSScriptRoot 'Course-Upgrade.ps1')

function Receive-CourseVerifiedFile([string]$Url,[string]$Path,[string]$Sha256) {
    Assert-CoursePlainPath $Path
    if($Sha256 -cnotmatch '^[a-f0-9]{64}$'){throw 'INVALID_ARTIFACT_DIGEST'}
    if(Test-Path -LiteralPath $Path){
        if((Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant() -ceq $Sha256){return}
        throw 'MODIFIED_CACHE_PRESERVED'
    }
    [void](New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force)
    Receive-CourseFile $Url ($Path+'.partial')
    if((Get-FileHash -LiteralPath ($Path+'.partial')).Hash.ToLowerInvariant() -cne $Sha256){throw 'ARTIFACT_CHECKSUM_MISMATCH'}
    Move-Item -LiteralPath ($Path+'.partial') -Destination $Path
}
function Get-CourseArchiveTree([string]$Zip) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z=[IO.Compression.ZipFile]::OpenRead($Zip);$map=@{}
    try{foreach($entry in $z.Entries){
        if($entry.FullName.EndsWith('/')){continue};Assert-CourseRelativeFile $entry.FullName
        $stream=$entry.Open();$sha=[Security.Cryptography.SHA256]::Create()
        try{$map[$entry.FullName]=([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant()}finally{$stream.Dispose();$sha.Dispose()}
    }}finally{$z.Dispose()}
    return $map
}
function Convert-CourseLegacyBundle([string]$Root,$Selection,[string]$Profile) {
    # Explicitly supported historical execution-only packages, never rewrite their snapshots.
    if($Selection.entry.version -notin @('2.2.3','2.2.4')){throw 'LEGACY_VERSION_REQUIRES_ORIGINAL_PREPARATION: independent updates support 2.2.3 and later.'}
    $compatPath=Join-Path $PSScriptRoot '..\assets\compatibility.json'
    if(-not(Test-Path -LiteralPath $compatPath)){$compatPath=Join-Path $PSScriptRoot 'course-contract/compatibility.json'}
    $compat=Read-CourseJson $compatPath
    $contract=Read-CourseJson (Join-Path $Root 'course-contract.json');$skills=[ordered]@{}
    foreach($entry in @($contract.skills|Where-Object {$_.kind -eq 'generic' -or $Profile -eq 'knowstar'})){
        $zip=Join-Path $Root $entry.archive
        $expected=$Selection.manifest.files.($entry.archive)
        if(-not $expected -or (Get-FileHash -LiteralPath $zip).Hash.ToLowerInvariant() -cne $expected){throw 'LEGACY_COMPONENT_MISMATCH'}
        $skills[$entry.name]=@{archive=$entry.archive;sha256=$expected;files=(Get-CourseArchiveTree $zip);kind=$entry.kind;requires=@($compat.skillDependencies.($entry.name))}
    }
    $envZip=[IO.Compression.ZipFile]::OpenRead((Join-Path $Root 'ai-coding-env-skill.zip'))
    try{$reader=[IO.StreamReader]::new($envZip.GetEntry('assets/toolchain.json').Open());try{$toolchain=$reader.ReadToEnd()|ConvertFrom-Json}finally{$reader.Dispose()}}finally{$envZip.Dispose()}
    if($toolchain.imageDigest -cne $compat.imageDigest){throw 'LEGACY_IMAGE_CONTRACT_UNKNOWN'}
    $files=@{}
    foreach($file in Get-ChildItem -LiteralPath $Root -File -Recurse){
        $relative=$file.FullName.Substring($Root.Length+1).Replace('\','/')
        if($file.Extension -eq '.zip' -or $relative -eq 'bundle-manifest.json'){continue}
        $files[$relative]=(Get-FileHash -LiteralPath $file.FullName).Hash.ToLowerInvariant()
    }
    $bundle=@{schemaVersion=1;materialsProtocol=1;runtimeContractId=$compat.runtimeContractId;compatibility=$compat;profile=$Profile;contentId=('legacy-'+$Selection.entry.version);skills=$skills;files=$files}
    Write-CourseJson (Join-Path $Root 'bundle-manifest.json') $bundle
    return Read-CourseJson (Join-Path $Root 'bundle-manifest.json')
}
function Invoke-CourseMaterialsUpdate {
    param([string]$Workspace,[string]$Version,[string]$Mode='Apply',[string]$Profile,[string[]]$Names,[switch]$AllowUnprepared)
    $Workspace=(Resolve-Path -LiteralPath $Workspace).Path;Assert-CoursePlainPath $Workspace
    $lock=Enter-CourseUpgradeLock
    try {
        Repair-CourseSkillTransactions
        if($Mode -eq 'Recover'){return [pscustomobject]@{status='Recovered';environmentChanged=$false}}
        if($Mode -eq 'Rollback'){
            $last=Read-CourseJson (Join-Path $Workspace '.course-setup/last-update.json')
            $journal=Read-CourseJson (Join-Path $last.TransactionRoot 'transaction.json')
            if($journal.workspace -cne $Workspace -or $journal.status -ne 'Committed'){throw 'NO_COMMITTED_UPDATE_TO_ROLL_BACK'}
            Restore-CourseSkillTransaction $journal
            Write-CourseJson (Join-Path $Workspace '.course-setup/pending-update.json') @{status='RolledBack'}
            return [pscustomobject]@{status='RolledBack';environmentChanged=$false}
        }
        $priorFile=Join-Path $Workspace '.course-setup/materials.json'
        if(-not(Test-Path -LiteralPath $priorFile)){throw 'PREPARATION_NOT_FOUND: use the stable preparation entry for the first installation.'}
        $prior=Read-CourseJson $priorFile
        if(-not $Profile){$Profile=if($prior.SkillNames -contains 'knowstar-course'){'knowstar'}else{'generic'}}
        $pendingFile=Join-Path $Workspace '.course-setup/pending-update.json'
        $pending=if(Test-Path -LiteralPath $pendingFile){Read-CourseJson $pendingFile}else{$null}
        $preview=$null
        if(-not $Version -and $pending.status -in @('Downloading','Downloaded','Applying')){$Version=$pending.version;$preview=$pending.distributionId}
        $selection=Resolve-CourseRelease -Workspace $Workspace -Version $Version -Preview $preview
        $release=$selection.manifest;$entry=$selection.entry
        if($pending.status -in @('Downloading','Downloaded','Applying') -and $pending.version -ceq $entry.version -and $pending.distributionId -ceq $entry.distributionId -and $pending.manifestSha256 -cne $selection.manifestSha256){throw 'PENDING_RELEASE_LOCK_CHANGED'}
        Write-Host ('当前课程 v'+$prior.CourseVersion+'；目标课程 v'+$entry.version+$(if($entry.status -eq 'candidate'){'（候选版）'}else{''})+'。')
        $id=$entry.version+'-'+$(if($entry.distributionId){$entry.distributionId}else{'release'})
        $root=Join-Path $Workspace ('.course-setup/update-cache/'+$id+'-'+$Profile)
        Assert-CoursePlainPath $root
        $bundle=if(-not $entry.legacy){$release.profiles.$Profile.bundle}else{$null}
        if(-not $entry.legacy -and -not $bundle){throw 'PACKAGE_PROFILE_NOT_PUBLISHED'}
        if($Mode -eq 'Check'){
            if($entry.legacy){return [pscustomobject]@{status='LegacyVersion';version=$entry.version;downloadRequired=$true;environmentChanged=$false}}
            $compatibility=Test-CourseRuntimeCompatibility $Workspace $bundle.compatibility
            Assert-CourseSharedCompatibility $Workspace $bundle
            return [pscustomobject]@{status='Compatible';from=$prior.CourseVersion;version=$entry.version;runtime=$compatibility;environmentChanged=$false}
        }
        $pending=[pscustomobject]@{version=$entry.version;distributionId=$entry.distributionId;manifestSha256=$selection.manifestSha256;profile=$Profile;status='Downloading';packageRoot=$root;mode=$Mode}
        Write-CourseJson $pendingFile $pending
        if($Mode -in @('Apply','Download') -or $entry.legacy){
            $archiveName=if($Profile -eq 'generic'){'ai-coding-toolkit.zip'}else{'aicoding-student-kit.zip'}
            $expected=if($entry.legacy){$release.files.$archiveName}else{$release.profiles.$Profile.sha256}
            $archive=Join-Path (Split-Path $root -Parent) ($id+'-'+$Profile+'.zip')
            Receive-CourseVerifiedFile ($entry.baseUrl+'/'+$archiveName) $archive $expected
            if(-not(Test-Path -LiteralPath $root)){
                $stage=$root+'.stage-'+[guid]::NewGuid().ToString('N')
                Expand-CourseMaterials $archive $stage
                if(-not $entry.legacy -and (Get-FileHash -LiteralPath (Join-Path $stage 'bundle-manifest.json')).Hash.ToLowerInvariant() -cne $release.profiles.$Profile.bundleManifestSha256){throw 'LOCKED_BUNDLE_MISMATCH'}
                Move-Item -LiteralPath $stage -Destination $root
            }
            if($entry.legacy){$bundle=Convert-CourseLegacyBundle $root $selection $Profile}
        }else{
            # Independent Skill update: metadata + helpers, no full ZIP or installers.
            foreach($file in $bundle.files.PSObject.Properties){
                Assert-CourseRelativeFile $file.Name
                Receive-CourseVerifiedFile ($entry.baseUrl+'/controls/'+$Profile+'/'+$file.Name) (Join-Path $root $file.Name) $file.Value
            }
            Receive-CourseVerifiedFile ($entry.baseUrl+'/controls/'+$Profile+'/bundle-manifest.json') (Join-Path $root 'bundle-manifest.json') $release.profiles.$Profile.bundleManifestSha256
        }
        $bundle=Assert-CourseBundle $root
        if((Read-CourseJson (Join-Path $root 'VERSION.json')).version -cne $entry.version){throw 'BUNDLE_VERSION_MISMATCH'}
        if($Mode -eq 'Download'){
            $pending.status='Downloaded';Write-CourseJson $pendingFile $pending
            Write-Host ('课程 v'+$entry.version+' 的资料已下载校验，尚未应用；当前课程和技能保持原状态。')
            return [pscustomobject]@{status='Downloaded';version=$entry.version;PackageRoot=$root;applied=$false;environmentChanged=$false}
        }
        $compatibility=Test-CourseRuntimeCompatibility $Workspace $bundle.compatibility -AllowUnprepared:$AllowUnprepared
        Assert-CourseSharedCompatibility $Workspace $bundle
        if(-not $Names){$Names=@($bundle.skills.PSObject.Properties.Name)}
        $selected=New-Object Collections.Generic.HashSet[string]
        function Add-RequiredSkill([string]$Name){
            if(-not $bundle.skills.PSObject.Properties[$Name]){throw 'REQUESTED_SKILL_NOT_PUBLISHED'}
            if($selected.Add($Name)){foreach($dep in @($bundle.skills.$Name.requires)){Add-RequiredSkill $dep}}
        }
        foreach($name in $Names){Add-RequiredSkill $name}
        $namesToApply=@($selected|Sort-Object)
        $skills=Join-Path $env:USERPROFILE '.trae-cn/skills'
        foreach($name in $namesToApply){
            $item=$bundle.skills.$name
            if(Test-CourseTree (Get-CourseTreeHashes (Join-Path $skills $name)) $item.files){continue}
            Receive-CourseVerifiedFile ($entry.baseUrl+'/'+$item.archive) (Join-Path $root $item.archive) $item.sha256
        }
        $pending.status='Applying';Write-CourseJson $pendingFile $pending
        $installed=Invoke-CourseSkillTransaction -Workspace $Workspace -PackageRoot $root -Names $namesToApply -ReleaseId $id -DeferCommit -AllowUnprepared:$AllowUnprepared
        try {
            $allMatched=$true
            foreach($property in $bundle.skills.PSObject.Properties){if(-not(Test-CourseTree (Get-CourseTreeHashes (Join-Path $skills $property.Name)) $property.Value.files)){$allMatched=$false}}
            if($allMatched){
                $artifact=if($Profile -eq 'generic'){'ai-coding-toolkit.zip'}else{'aicoding-student-kit.zip'}
                $archiveHash=if($entry.legacy){$release.files.$artifact}else{$release.profiles.$Profile.sha256}
                $new=[ordered]@{PreparedAt=$prior.PreparedAt;UpdatedAt=(Get-Date).ToString('o');CourseVersion=$entry.version;DistributionId=$entry.distributionId;DistributionStatus=$entry.status;ReleaseId=$id;ReleaseManifest=$selection.path;RuntimeContractId=$bundle.runtimeContractId;PackageRoot=$root;PackageProfile=$Profile;PackageUrl=($entry.baseUrl+'/'+$artifact);PackageSha256=$archiveHash;PackageSource=$(if($Mode -eq 'Skills'){'components'}else{'archive'});SkillNames=@($bundle.skills.PSObject.Properties.Name);SkillsDirectory=$skills;SkillScope='user';ContainerRuntime=$prior.ContainerRuntime;EnvironmentVerified=$prior.EnvironmentVerified;SetupGuide=(Join-Path $root 'setup-guide.md');CaseSupplementRoot=$root;TraeLoadVerified=$false}
                Write-CourseJson $priorFile $new
            }
            Complete-CourseSkillTransaction $installed.TransactionRoot
        }catch{
            $journal=Read-CourseJson (Join-Path $installed.TransactionRoot 'transaction.json');Restore-CourseSkillTransaction $journal;throw
        }
        $pending.status='Applied';Write-CourseJson $pendingFile $pending
        $result=[pscustomobject]@{status='FilesApplied';version=$entry.version;CourseVersion=$(if($allMatched){$entry.version}else{$prior.CourseVersion});Changed=$installed.Changed;Unchanged=$installed.Unchanged;SkillNames=@($bundle.skills.PSObject.Properties.Name);PackageRoot=$root;CaseSupplementRoot=$root;SkillsDirectory=$skills;PackageProfile=$Profile;environmentChanged=$false;EnvironmentCompatibility=$compatibility;TraeLoadVerified=$false;TransactionRoot=$installed.TransactionRoot}
        if($installed.Changed.Count -or $prior.CourseVersion -cne $entry.version -or $prior.ReleaseId -cne $id){Write-CourseJson (Join-Path $Workspace '.course-setup/last-update.json') $result}
        if(-not $allMatched){Write-Host ('本次仅更新所选技能；课程资料仍为 v'+$prior.CourseVersion+'，尚未切换整套课程版本。')}
        Write-Host ('课程资料/技能文件已校验；实际更新 '+$installed.Changed.Count+' 项技能，编程环境未更换。Trae 实际加载待核对，未据此宣布完整课前准备通过。')
        return $result
    }finally{Exit-CourseUpgradeLock $lock}
}
if($MyInvocation.InvocationName -ne '.'){
    $ErrorActionPreference='Stop'
    if(-not $WorkingDirectory){$WorkingDirectory=(Get-Location).Path}
    $names=if($SkillNames){@($SkillNames.Split(',')|ForEach-Object {$_.Trim()})}else{@()}
    Invoke-CourseMaterialsUpdate -Workspace $WorkingDirectory -Version $CourseVersion -Mode $Action -Profile $PackageProfile -Names $names
}
