#Requires -Version 5.1
[CmdletBinding()]
# Public aliases preserve CLI compatibility; private names cannot reset a caller's
# WorkingDirectory/ContainerRuntime when this zero-material entry is dot-sourced.
param([Alias('WorkingDirectory')][string]$MaterialsWorkingDirectory,
      [Alias('CourseVersion')][string]$MaterialsCourseVersion,
      [Alias('PreviewId')][string]$MaterialsPreviewId,
      [Alias('SkipInstallers')][switch]$MaterialsSkipInstallers,
      [Alias('PackageProfile')][ValidateSet('generic','knowstar')][string]$MaterialsPackageProfile='generic',
      [Alias('ContainerRuntime')][ValidateSet('docker','podman')][string]$MaterialsContainerRuntime='podman',
      [Alias('CheckOnly')][switch]$MaterialsCheckOnly)

function Receive-CourseFile {
    param([string]$Url, [string]$Destination)
    $priorTls = [Net.ServicePointManager]::SecurityProtocol
    $priorProgress = $ProgressPreference
    try {
        [Net.ServicePointManager]::SecurityProtocol = $priorTls -bor [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
    } finally {
        [Net.ServicePointManager]::SecurityProtocol = $priorTls
        $ProgressPreference = $priorProgress
    }
}

function Resolve-CourseRelease {
    param([string]$Workspace,[string]$Version,[string]$Preview)
    $base='https://siatwangmin.github.io/aicoding-course'
    $records=Join-Path $Workspace '.course-setup'
    [void](New-Item -ItemType Directory -Path $records -Force)
    $indexFile=Join-Path $records ('release-index-'+[guid]::NewGuid().ToString('N')+'.json')
    Receive-CourseFile "$base/release-index.json" $indexFile
    $index=Get-Content -LiteralPath $indexFile -Raw -Encoding UTF8|ConvertFrom-Json
    if($index.schemaVersion -ne 1){throw 'UNSUPPORTED_RELEASE_INDEX'}
    if(-not $Version){$Version=$index.latest}
    if($Version -notmatch '^\d+\.\d+\.\d+$'){throw 'INVALID_COURSE_VERSION'}
    $entry=if($Preview){$index.builds.($Version+'-'+$Preview)}else{$index.versions.$Version}
    if(-not $entry -or $entry.version -cne $Version){throw 'REQUESTED_VERSION_NOT_PUBLISHED'}
    if($entry.manifestUrl -notmatch '^https://siatwangmin\.github\.io/aicoding-course/(?:previews/v\d+\.\d+\.\d+/[a-f0-9]{12}|releases/course/v\d+\.\d+\.\d+)/[a-z-]+\.json$' -or $entry.manifestSha256 -notmatch '^[a-f0-9]{64}$'){throw 'INVALID_RELEASE_POINTER'}
    $path=Join-Path $records ('release-'+$Version+'-'+$entry.manifestSha256.Substring(0,12)+'.json')
    if(-not(Test-Path -LiteralPath $path) -or (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -cne $entry.manifestSha256){
        Receive-CourseFile $entry.manifestUrl ($path+'.partial')
        if((Get-FileHash -LiteralPath ($path+'.partial')).Hash.ToLowerInvariant() -cne $entry.manifestSha256){throw 'RELEASE_MANIFEST_MISMATCH'}
        Move-Item -LiteralPath ($path+'.partial') -Destination $path -Force
    }
    $manifest=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
    if($manifest.version -cne $Version -or ($entry.distributionId -and $manifest.distributionId -cne $entry.distributionId)){throw 'RELEASE_IDENTITY_MISMATCH'}
    if(-not $entry.legacy -and ($manifest.schemaVersion -ne 1 -or $manifest.materialsProtocol -ne 1 -or $manifest.baseUrl -cne $entry.baseUrl)){throw 'UNSUPPORTED_RELEASE_PROTOCOL'}
    return [pscustomobject]@{entry=$entry;manifest=$manifest;path=$path;manifestSha256=$entry.manifestSha256}
}

function Expand-CourseMaterials {
    param([string]$Archive, [string]$Staging)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $root = [IO.Path]::GetFullPath($Staging).TrimEnd('\') + '\'
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        if ($zip.Entries.Count -gt 2000 -or ($zip.Entries | Measure-Object Length -Sum).Sum -gt 200MB) { throw 'Unexpected course archive size.' }
        # Validate every target before creating or extracting any archive entry.
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName.Replace('/', '\')
            $target = [IO.Path]::GetFullPath((Join-Path $Staging $name))
            if ([IO.Path]::IsPathRooted($name) -or $name.Contains(':') -or -not $target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw 'Unsafe course archive path.' }
        }
        [IO.Compression.ZipFile]::ExtractToDirectory($Archive, $Staging)
    } finally { $zip.Dispose() }
}

function Resolve-CourseBootstrapRuntime([string]$Workspace) {
    # This is the zero-material entry: no adjacent helper is guaranteed to exist yet.
    foreach($relative in @('.ai-coding\project.json','.course-setup\container-runtime.json','.course-setup\materials.json','toolchain-verification.json')){
        $path=Join-Path $Workspace $relative
        if(Test-Path -LiteralPath $path){
            $record=Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json
            if($record.containerRuntime -in @('docker','podman')){return $record.containerRuntime}
            if($record.containerRuntime){throw 'Invalid recorded runtime; preserve workspace and resolve selection.'}
            if($relative -eq 'toolchain-verification.json'){return 'docker'}
        }
    }
    return 'podman'
}

function Add-CourseCase {
    param([string]$Workspace,$Prior,[string]$BaseUrl,[string]$CacheId)
    $records=Join-Path $Workspace '.course-setup'
    $root=Join-Path $records ("case-materials-$CacheId")
    if(-not (Test-Path -LiteralPath $Prior.PackageRoot)){throw 'Restore the recorded generic package before adding a case.'}
    . (Join-Path $Prior.PackageRoot 'Install-CourseSkills.ps1')
    $contract=Get-Content -LiteralPath (Join-Path $Prior.PackageRoot 'course-contract.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $generic=@($contract.skills|Where-Object kind -eq 'generic'|ForEach-Object {$_.name})
    $verified=Test-CourseSkills -Workspace $Workspace -Names $generic
    if(-not $verified.UserInstallationVerified){throw 'Restore the existing generic skills before adding a case.'}
    [void](New-Item -ItemType Directory -Path $root -Force)
    $profilePath=Join-Path $root 'case-profile.json'
    Receive-CourseFile "$BaseUrl/case-profile.json" ($profilePath+'.partial')
    $profile=Get-Content -LiteralPath ($profilePath+'.partial') -Raw -Encoding UTF8|ConvertFrom-Json
    if($profile.caseSkillName -cnotmatch '^[a-z][a-z0-9-]{0,63}$' -or $profile.caseSkillArchive -cnotmatch '^[a-z][a-z0-9-]{0,100}\.zip$' -or $generic -contains $profile.caseSkillName){throw 'Invalid case supplement identity.'}
    if(Test-Path -LiteralPath $profilePath){
        if((Get-FileHash -LiteralPath $profilePath).Hash -ne (Get-FileHash -LiteralPath ($profilePath+'.partial')).Hash){throw 'Existing case metadata differs; preserved.'}
        Remove-Item -LiteralPath ($profilePath+'.partial')
    }else{Move-Item -LiteralPath ($profilePath+'.partial') -Destination $profilePath}
    $archive=Join-Path $root $profile.caseSkillArchive
    $checksum=[IO.Path]::ChangeExtension($archive,'.sha256')
    Receive-CourseFile ("$BaseUrl/"+[IO.Path]::GetFileName($checksum)) $checksum
    $checksumText=(Get-Content -LiteralPath $checksum -Raw).Trim()
    if($checksumText -notmatch ('^([a-fA-F0-9]{64})\s+'+[regex]::Escape($profile.caseSkillArchive)+'$')){throw 'Invalid case supplement checksum.'}
    $expected=$Matches[1].ToLowerInvariant()
    if($Prior.DistributionId){
        $manifestPath=Join-Path $records "case-manifest-$CacheId.json"
        Receive-CourseFile "$BaseUrl/preview-manifest.json" $manifestPath
        $manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8|ConvertFrom-Json
        if($manifest.version -ne $Prior.CourseVersion -or $manifest.distributionId -ne $Prior.DistributionId -or -not ([string]$manifest.packageSha256).StartsWith($Prior.DistributionId) -or $manifest.files.($profile.caseSkillArchive) -ne $expected){throw 'Pinned case supplement identity mismatch.'}
    }
    if(-not(Test-Path -LiteralPath $archive) -or (Get-FileHash -LiteralPath $archive).Hash.ToLowerInvariant() -ne $expected){
        Receive-CourseFile ("$BaseUrl/"+$profile.caseSkillArchive) ($archive+'.partial')
        if((Get-FileHash -LiteralPath ($archive+'.partial')).Hash.ToLowerInvariant() -ne $expected){throw 'Case supplement checksum mismatch.'}
        Move-Item -LiteralPath ($archive+'.partial') -Destination $archive -Force
    }
    foreach($name in @('setup-guide.md','VERSION.json','course-contract.json','Course-Lifecycle.ps1','Course-Context.ps1','Install-CourseSkills.ps1')){
        $source=Join-Path $Prior.PackageRoot $name;$target=Join-Path $root $name
        if(Test-Path -LiteralPath $target){if((Get-FileHash -LiteralPath $source).Hash -ne (Get-FileHash -LiteralPath $target).Hash){throw 'Existing supplement dependency differs; preserved.'}}
        else{Copy-Item -LiteralPath $source -Destination $target}
    }
    $installed=@(& (Join-Path $root 'Install-CourseSkills.ps1') -WorkingDirectory $Workspace -PackageRoot $root -CaseOnly)
    $Prior.SkillNames=@($generic+@($installed.Name)|Select-Object -Unique)
    $Prior|Add-Member NoteProperty CaseSupplementRoot $root -Force
    $Prior|Add-Member NoteProperty CaseSupplementSha256 $expected -Force
    $Prior|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $records 'materials.json') -Encoding UTF8
    $installation=Register-CourseInstallation $Workspace $Prior.CourseVersion
    $null=Register-CourseResource -InstallationId $installation.installationId -Kind directory -Locator $root -Ownership created -DataClass rebuildable -AllowedRoot $records
    return $Prior
}

function Get-CourseMaterials {
    param([string]$Workspace, [string]$Version, [string]$Preview, [switch]$WithoutInstallers,
          [ValidateSet('generic','knowstar')][string]$Profile='generic',
          [ValidateSet('docker','podman')][string]$Runtime='podman')
    $workspacePath = (Resolve-Path -LiteralPath $Workspace -ErrorAction Stop).Path
    $requestedProfile=$Profile
    if(-not $PSBoundParameters.ContainsKey('Runtime')){
        $Runtime=Resolve-CourseBootstrapRuntime $workspacePath
    }
    $baseUrl = 'https://siatwangmin.github.io/aicoding-course'
    $records = Join-Path $workspacePath '.course-setup'
    [void](New-Item -ItemType Directory -Path $records -Force)
    $metadataInfo=$null
    $priorActive=if(Test-Path -LiteralPath (Join-Path $records 'materials.json')){Get-Content -LiteralPath (Join-Path $records 'materials.json') -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
    if($priorActive.SkillNames -contains 'knowstar-course'){$Profile='knowstar'}
    # Resuming an A preserves its exact snapshot; an explicit upgrade uses Update-CourseMaterials.
    if(-not $Version -and -not $Preview -and (Test-Path -LiteralPath (Join-Path $records 'materials.json'))){
        $resume=Get-Content -LiteralPath (Join-Path $records 'materials.json') -Raw -Encoding UTF8|ConvertFrom-Json
        $Version=$resume.CourseVersion;$Preview=$resume.DistributionId
        if($resume.SkillNames -contains 'knowstar-course'){$Profile='knowstar'}
    }
    if (-not $Version -or (-not $Preview -and $Version -match '^[2-9]\d*\.')) {
        $metadata = Join-Path $records 'VERSION.json'
        Receive-CourseFile "$baseUrl/VERSION.json" $metadata
        $metadataInfo = Get-Content -LiteralPath $metadata -Raw | ConvertFrom-Json
        if(-not $Version){$Version=$metadataInfo.version}
        if($metadataInfo.version -eq $Version -and $metadataInfo.status -eq 'candidate'){
            $Preview=$metadataInfo.distributionId
            if(-not $Preview){throw 'Candidate metadata has no pinned distribution. Do not download a formal-release path.'}
        }
    }
    $lockedRelease=$null
    if(($Version -and [version]$Version -ge [version]'2.3.0') -or ($metadataInfo -and [version]$metadataInfo.version -ge [version]'2.3.0')){
        $lockedRelease=Resolve-CourseRelease -Workspace $workspacePath -Version $Version -Preview $Preview
        $Version=$lockedRelease.entry.version;$Preview=$lockedRelease.entry.distributionId
    }
    if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid course version.' }
    if([version]$Version -ge [version]'2.5.3'){
        if($requestedProfile -eq 'knowstar'){throw 'CASE_PACKAGE_RETIRED: new releases provide the generic toolkit; use a pinned historical version for the case package.'}
        $Profile='generic'
    }
    if($Preview -and $Preview -notmatch '^[a-f0-9]{12}$'){throw 'Invalid preview identity.'}
    if($lockedRelease -and -not $lockedRelease.entry.legacy -and $priorActive.CourseVersion -ceq $Version -and $priorActive.DistributionId -ceq $Preview -and $priorActive.PackageProfile -ceq $Profile){
        $upgrade=Join-Path $priorActive.PackageRoot 'Course-Upgrade.ps1'
        if(Test-Path -LiteralPath $upgrade){
            . $upgrade
            $existingBundle=Assert-CourseBundle $priorActive.PackageRoot
            $resumeNeedsCleanup=$false
            if(Test-CourseInstalledCompatibility $existingBundle $workspacePath){
                $recoveryHelper=Join-Path $PSScriptRoot 'Course-InstallRecovery.ps1'
                if(-not(Test-Path -LiteralPath $recoveryHelper)){$recoveryHelper=Join-Path $priorActive.PackageRoot 'Course-InstallRecovery.ps1'}
                if(Test-Path -LiteralPath $recoveryHelper){. $recoveryHelper;$null=Repair-CourseInstallationForInstall $workspacePath}
                elseif(Get-Command Find-CourseInstallation -ErrorAction SilentlyContinue){$oldInstall=Find-CourseInstallation $workspacePath;$resumeNeedsCleanup=($oldInstall -and $oldInstall.status -ne 'active')}
                if(-not $resumeNeedsCleanup){
                    Write-Host ('沿资料 v'+$Version+' 恢复；共享技能按已验证内容与兼容约定复用，不因恢复任务自动降级或重装。')
                    return $priorActive
                }
            }
            if(-not $resumeNeedsCleanup -and (Test-Path -LiteralPath (Join-Path (Get-CourseUserRoot) 'installed-skills.json'))){throw 'SHARED_SKILL_SET_CHANGED: preserve the active preparation and use the update compatibility check; never downgrade shared skills while resuming.'}
        }
    }
    $distribution=if($Preview){"previews/v$Version/$Preview"}else{"releases/course/v$Version"}
    $cacheId=if($Preview){"v$Version-preview-$Preview"}else{"v$Version"}
    $modern=[version]$Version -ge [version]'2.2.3'
    $packageName=if($modern -and $Profile -eq 'generic'){'ai-coding-toolkit.zip'}else{'aicoding-student-kit.zip'}
    $url = "$baseUrl/$distribution/$packageName"
    $checksumFile = Join-Path $records ($packageName.Replace('.zip',"-$cacheId.sha256"))
    Receive-CourseFile ($url -replace '\.zip$', '.sha256') $checksumFile
    $checksum = (Get-Content -LiteralPath $checksumFile -Raw).Trim()
    if ($checksum -notmatch ('^([a-fA-F0-9]{64})\s+'+[regex]::Escape($packageName)+'$')) { throw 'Invalid course checksum file.' }
    $expectedHash = $Matches[1].ToLowerInvariant()
    if($lockedRelease -and -not $lockedRelease.entry.legacy -and $lockedRelease.manifest.profiles.$Profile.sha256 -cne $expectedHash){throw 'RELEASE_PACKAGE_MISMATCH'}
    if($Preview){
        if($packageName -eq 'aicoding-student-kit.zip'){
            if(-not $expectedHash.StartsWith($Preview)){throw 'Preview identity does not match its artifact checksum.'}
        }else{
            $manifestPath=Join-Path $records "preview-manifest-$cacheId.json"
            Receive-CourseFile "$baseUrl/$distribution/preview-manifest.json" $manifestPath
            $pinned=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8|ConvertFrom-Json
            if($pinned.version -ne $Version -or $pinned.distributionId -ne $Preview -or -not ([string]$pinned.packageSha256).StartsWith($Preview) -or $pinned.files.$packageName -ne $expectedHash){throw 'Pinned generic package checksum/identity mismatch.'}
        }
    }
    # Same-version generic preparation can add only the explicitly selected case.
    $priorPath=Join-Path $records 'materials.json'
    if($modern -and $Profile -eq 'knowstar' -and (Test-Path -LiteralPath $priorPath)){
        $prior=Get-Content -LiteralPath $priorPath -Raw -Encoding UTF8|ConvertFrom-Json
        if($prior.CourseVersion -eq $Version -and $prior.DistributionId -eq $Preview -and $prior.PackageProfile -eq 'generic'){
            if([version]$Version -ge [version]'2.3.0'){
                . (Join-Path $prior.PackageRoot 'Update-CourseMaterials.ps1')
                return Invoke-CourseMaterialsUpdate -Workspace $workspacePath -Version $Version -Mode Skills -Profile knowstar -Names @('knowstar-course') -AllowUnprepared
            }
            return Add-CourseCase -Workspace $workspacePath -Prior $prior -BaseUrl "$baseUrl/$distribution" -CacheId $cacheId
        }
    }
    $archive = Join-Path $records ($packageName.Replace('.zip',"-$cacheId.zip"))
    if (-not (Test-Path -LiteralPath $archive) -or (Get-FileHash -LiteralPath $archive).Hash.ToLowerInvariant() -ne $expectedHash) {
        $partial = $archive + '.partial'
        Receive-CourseFile $url $partial
        if ((Get-FileHash -LiteralPath $partial).Hash.ToLowerInvariant() -ne $expectedHash) { throw 'Course archive checksum mismatch.' }
        Move-Item -LiteralPath $partial -Destination $archive -Force
    }
    $staging = Join-Path $records ('stage-' + [guid]::NewGuid())
    $rootSuffix=if($modern){"-$Profile"}else{''}
    $courseRoot = Join-Path $workspacePath ("course-materials-$cacheId$rootSuffix")
    $courseRootExisted=Test-Path -LiteralPath $courseRoot
    try {
        Expand-CourseMaterials $archive $staging
        $requiredFiles=@('VERSION.json', 'setup-guide.md', 'Install-CourseSkills.ps1', 'Setup-DockerDesktop.ps1', 'windows-installers.json', 'ai-coding-env-skill.zip', 'ai-coding-project-skill.zip')
        if([version]$Version -ge [version]'2.1.1'){$requiredFiles+=@('Course-Docker.ps1','Course-Podman.ps1')}
        if([version]$Version -ge [version]'2.1.0'){$requiredFiles+=@('Course-Native.ps1','Setup-Podman.ps1')}
        if([version]$Version -ge [version]'2.2.0'){$requiredFiles+=@('Course-Lifecycle.ps1','Course-Uninstall.ps1','Course-UninstallAdapters.ps1','Uninstall-Course.ps1','Start-CourseUninstall.ps1','lifecycle-contract.json',$(if([version]$Version -ge [version]'2.3.8'){'卸载环境.cmd'}else{'卸载课程环境.cmd'}));if(-not $modern){$requiredFiles+='uninstall.md'}}
        foreach ($required in $requiredFiles) {
            if (-not (Test-Path -LiteralPath (Join-Path $staging $required) -PathType Leaf)) { throw "Missing course file: $required" }
        }
        if ((Get-Content -LiteralPath (Join-Path $staging 'VERSION.json') -Raw | ConvertFrom-Json).version -ne $Version) { throw 'Course archive version mismatch.' }
        if($lockedRelease -and -not $lockedRelease.entry.legacy){
            if((Get-FileHash -LiteralPath (Join-Path $staging 'bundle-manifest.json')).Hash.ToLowerInvariant() -cne $lockedRelease.manifest.profiles.$Profile.bundleManifestSha256){throw 'RELEASE_BUNDLE_MISMATCH'}
        }
        $files = Get-ChildItem -LiteralPath $staging -File -Recurse
        # Preflight all collisions so existing learner modifications remain intact.
        foreach ($file in $files) {
            $relative = $file.FullName.Substring($staging.Length).TrimStart('\')
            $target = Join-Path $courseRoot $relative
            if ((Test-Path -LiteralPath $target) -and ((Get-FileHash -LiteralPath $target).Hash -ne (Get-FileHash -LiteralPath $file.FullName).Hash)) { throw "Existing file differs; preserved: $target" }
        }
        foreach ($file in $files) {
            $target = Join-Path $courseRoot $file.FullName.Substring($staging.Length).TrimStart('\')
            [void](New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force)
            if (-not (Test-Path -LiteralPath $target)) { Copy-Item -LiteralPath $file.FullName -Destination $target }
        }
    } finally {
        $resolvedStage = [IO.Path]::GetFullPath($staging)
        if (-not $resolvedStage.StartsWith([IO.Path]::GetFullPath($records).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe staging cleanup path.' }
        if (Test-Path -LiteralPath $resolvedStage) { Remove-Item -LiteralPath $resolvedStage -Recurse -Force }
    }
    Write-Host ('本次使用资料 v'+$Version+$(if($Preview){'（候选版）'}else{''})+'。正在准备资料与助手技能。')
    $installedSkills = @(& (Join-Path $courseRoot 'Install-CourseSkills.ps1') -WorkingDirectory $workspacePath -PackageRoot $courseRoot)
    $installedSkills | Out-Host
    $installerFiles = @()
    if (-not $WithoutInstallers) {
        $priorLocation = Get-Location
        try {
            Set-Location -LiteralPath $workspacePath
            if(Test-Path -LiteralPath (Join-Path $courseRoot 'Course-Docker.ps1')){. (Join-Path $courseRoot 'Course-Docker.ps1')}else{. (Join-Path $courseRoot 'Setup-DockerDesktop.ps1')}
            $nodeLibrary=Join-Path $courseRoot 'Course-NodeJs.ps1'
            if(Test-Path -LiteralPath $nodeLibrary){
                . (Join-Path $courseRoot 'Course-Lifecycle.ps1')
                . $nodeLibrary
                if(-not(Resolve-CourseNodeJs -AllowMissing)){
                    $nodeRoot=Resolve-CourseStorageRoot $workspacePath $Runtime
                    $installerFiles+=Save-CourseNodeJsArchive $workspacePath (Get-CourseStoragePlan $nodeRoot 0) (Get-CourseNodeJsManifest)
                }
            }
            $manifest = Join-Path $courseRoot 'windows-installers.json'
            if ($Runtime -eq 'podman') {
                $envSkill=@($installedSkills | Where-Object Name -eq 'ai-coding-env')[0].Destination
                $engineEntry=Join-Path $envSkill 'scripts\Setup-Podman.ps1'
                if(Test-Path -LiteralPath $engineEntry){
                    $podmanLibrary=Join-Path $envSkill 'scripts\Course-Podman.ps1'
                    if(Test-Path -LiteralPath $podmanLibrary){. $podmanLibrary}else{. $engineEntry}
                    if([version]$Version -ge [version]'2.2.4'){
                        Save-CoursePodmanInstallers $workspacePath
                        $downloads=Read-CourseJson (Join-Path $workspacePath '.podman-setup\downloads.json')
                        $installerFiles+=@($downloads.items|ForEach-Object {$_.path})
                    }else{
                        if (-not (Get-SetupWsl).Ready) {$installerFiles += Resolve-SetupInstaller 'wsl' '' $manifest}
                        if (-not (Get-PodmanPaths).Cli) {$installerFiles += Resolve-PodmanComponent $workspacePath 'engine'}
                        $installerFiles += Resolve-PodmanComponent $workspacePath 'compose'
                    }
                }else{
                    # Explicit historical releases retain their original setup route.
                    . (Join-Path $envSkill 'scripts\Setup-PodmanDesktop.ps1')
                    if (-not (Get-SetupWsl).Ready) {$installerFiles += Resolve-SetupInstaller 'wsl' '' $manifest}
                    if (-not (Get-PodmanPaths).Desktop) {$installerFiles += Resolve-PodmanInstaller $workspacePath ''}
                }
            } else {
                $installerFiles += Resolve-SetupInstaller 'wsl' '' $manifest
                $installerFiles += Resolve-SetupInstaller 'docker' '' $manifest
            }
        } finally { Set-Location -LiteralPath $priorLocation }
    }
    $result = [ordered]@{ PreparedAt = (Get-Date).ToString('o'); CourseVersion = $Version; DistributionId=$Preview; DistributionStatus=$(if($Preview){'candidate'}else{'release'}); ContainerRuntime=$Runtime; PackageUrl = $url; PackageSha256 = $expectedHash; PackageRoot = $courseRoot; SetupGuide = (Join-Path $courseRoot 'setup-guide.md'); SkillScope = $(if([version]$Version -ge [version]'2.4.0'){'mixed'}else{'user'}); SkillsDirectory = $(if([version]$Version -ge [version]'2.4.0'){Join-Path $workspacePath '.trae/skills'}else{Split-Path $installedSkills[0].Destination -Parent}); SkillNames = @($installedSkills.Name); InstallerFiles = $installerFiles; InstallersSkipped = [bool]$WithoutInstallers; EnvironmentVerified = $false }
    if($modern){$result.PackageProfile=$Profile}
    if($lockedRelease -and -not $lockedRelease.entry.legacy){
        $result.ReleaseId=$lockedRelease.manifest.releaseId
        $result.ReleaseManifest=$lockedRelease.path
        $result.RuntimeContractId=$lockedRelease.manifest.compatibility.runtimeContractId
    }
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $records 'materials.json') -Encoding UTF8
    @{ContainerRuntime=$Runtime;SelectedAt=(Get-Date).ToString('o')} | ConvertTo-Json | Set-Content (Join-Path $records 'container-runtime.json') -Encoding UTF8
    $agents = Join-Path $workspacePath 'AGENTS.md'
    $entry = "<!-- ai-coding:materials-entry:1 -->`n## Course preparation entry`nRead .course-setup/materials.json to locate setup-guide.md and scoped SkillsDirectory. Read ai-coding-env/references/preparation-workflow.md. For this course start Start-CourseToolPreparation.ps1 in the background, then immediately guide foreground accounts in GitHub -> CloudBase order. Poll background Status between account actions; surface attention for authorization or restart, preserve account progress, and never reboot automatically. Foreground alone records preparation evidence. Join verified tools and all accounts before summary; do not stop at tool readiness or wait for tools before registration. A specifically limited tool-only troubleshooting request keeps its scope. Save the current stage and resume after necessary identity/terms/fees/restart actions. Project initialization reuses preparation and activates only currently confirmed project capabilities, including during initialization when requested. Account readiness does not authorize all future resources. Reuse existing installers and valid service results. Downloads, installed skills, saved configuration, real service checks and learner trials are separate. Preserve work; do not create a product or copy secrets into a project during preparation.`n<!-- ai-coding:materials-entry:end -->"
    $entry=$entry.Replace('Read .course-setup/materials.json', "Selected container runtime: $Runtime. Prepare only this runtime; use its local engine, Compose and reports. New preparations use Podman CLI plus managed standalone Docker Compose, without either Desktop. Existing project runtime bindings remain authoritative; selection is never verification. Read .course-setup/materials.json")
    $text = if (Test-Path -LiteralPath $agents) { Get-Content -LiteralPath $agents -Raw } else { '' }
    if ($text -match '(?s)<!-- ai-coding:materials-entry:1 -->.*?<!-- ai-coding:materials-entry:end -->') { $text = [regex]::Replace($text, '(?s)<!-- ai-coding:materials-entry:1 -->.*?<!-- ai-coding:materials-entry:end -->', $entry) } else { $text = $text.TrimEnd() + "`n`n" + $entry }
    Set-Content -LiteralPath $agents -Value $text -Encoding UTF8
    $rule=Join-Path $workspacePath '.trae\rules\course-preparation.md'
    $ruleText="---`nalwaysApply: true`n---`n<!-- ai-coding:preparation-rule:2 -->`nRead the root AGENTS.md course preparation entry before starting or resuming this workspace. Keep original product rules. Use the selected user-level course skills and recorded preparation source; never treat tool readiness as full account/service readiness.`n"
    if(Test-Path -LiteralPath $rule){
        if([IO.File]::ReadAllText($rule) -notmatch 'ai-coding:preparation-rule:2'){throw 'Existing preparation rule is not course-managed; preserved.'}
    }
    [void](New-Item -ItemType Directory -Path (Split-Path $rule -Parent) -Force)
    Set-Content -LiteralPath $rule -Value $ruleText -Encoding UTF8
    $lifecycleHelper=Join-Path $courseRoot 'Course-Lifecycle.ps1'
    if(Test-Path -LiteralPath $lifecycleHelper){
        . $lifecycleHelper
        $installation=Register-CourseInstallation $workspacePath $Version $expectedHash
        $null=Register-CourseResource -InstallationId $installation.installationId -Kind directory -Locator $courseRoot -Ownership $(if($courseRootExisted){'reused'}else{'created'}) -DataClass rebuildable -AllowedRoot $workspacePath
        $null=Register-CourseResource -InstallationId $installation.installationId -Kind managedBlock -Locator $agents -Ownership created -Metadata @{start='<!-- ai-coding:materials-entry:1 -->';end='<!-- ai-coding:materials-entry:end -->'}
        $null=Register-CourseResource -InstallationId $installation.installationId -Kind file -Locator $rule -Ownership created -AllowedRoot $workspacePath
        foreach($download in @($archive,$checksumFile)){
            $null=Register-CourseResource -InstallationId $installation.installationId -Kind file -Locator $download -Ownership created -DataClass rebuildable -AllowedRoot $records
        }
    }
    Write-Host ('资料 v'+$Version+'：资料和用户级技能文件安装完成。Trae 实际加载、工具与账号准备继续分别验收。')
    return [pscustomobject]$result
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    if($MaterialsCheckOnly){
        if(-not $MaterialsWorkingDirectory){throw 'EXPLICIT_PREPARATION_DIRECTORY_REQUIRED'}
        $preflight=(Resolve-Path -LiteralPath $MaterialsWorkingDirectory -ErrorAction Stop).Path
        if(-not(Test-Path -LiteralPath $preflight -PathType Container)){throw 'PREPARATION_DIRECTORY_REQUIRED'}
        $cursor=[IO.Path]::GetFullPath($preflight)
        while($cursor){
            if((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Preparation path traverses a link.'}
            $parent=Split-Path $cursor -Parent;if($parent -eq $cursor){break};$cursor=$parent
        }
        [pscustomobject]@{status='entry-preflight-passed';workingDirectory=$preflight;installationPerformed=$false;networkRequested=$false;writesPerformed=$false}|ConvertTo-Json
        return
    }
    if (-not $MaterialsWorkingDirectory) { $MaterialsWorkingDirectory = (Get-Location).Path }
    $arguments=@{Workspace=$MaterialsWorkingDirectory;Version=$MaterialsCourseVersion;Preview=$MaterialsPreviewId;WithoutInstallers=$MaterialsSkipInstallers}
    if($PSBoundParameters.ContainsKey('MaterialsPackageProfile')){$arguments.Profile=$MaterialsPackageProfile}
    if($PSBoundParameters.ContainsKey('MaterialsContainerRuntime')){$arguments.Runtime=$MaterialsContainerRuntime}
    Get-CourseMaterials @arguments
}
