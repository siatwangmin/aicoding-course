#Requires -Version 5.1
# Library: importing does not install tools, register state or read credentials.
function Assert-CoursePlainPath([string]$Path) {
    $cursor=[IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Course path traverses a link.' }
        $next=Split-Path $cursor -Parent; if($next -eq $cursor){break}; $cursor=$next
    }
}
function Get-CourseUserRoot {
    if (-not $env:USERPROFILE -or -not [IO.Path]::IsPathRooted($env:USERPROFILE)) { throw 'User profile unavailable.' }
    $root=Join-Path $env:USERPROFILE '.ai-coding'; Assert-CoursePlainPath $root; return $root
}
function Protect-CourseDirectory([string]$Path) {
    Assert-CoursePlainPath $Path; [void](New-Item -ItemType Directory -Path $Path -Force)
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
    $legacyAclApi=[IO.Directory].GetMethods().Name -contains 'GetAccessControl'
    $acl=if($legacyAclApi){[IO.Directory]::GetAccessControl($Path,[Security.AccessControl.AccessControlSections]::Access)}else{[IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]::new($Path),[Security.AccessControl.AccessControlSections]::Access)}
    $acl.SetAccessRuleProtection($true,$false)
    foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){[void]$acl.RemoveAccessRuleSpecific($rule)}
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
    if($legacyAclApi){[IO.Directory]::SetAccessControl($Path,$acl)}else{[IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($Path),$acl)}
}
function Write-CourseJson([string]$Path,$Value) {
    Assert-CoursePlainPath $Path; [void](New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force)
    $temp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllText($temp,($Value | ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        if(Test-Path -LiteralPath $Path){[IO.File]::Replace($temp,$Path,($temp+'.backup'))}else{[IO.File]::Move($temp,$Path)}
    } finally {foreach($file in @($temp,($temp+'.backup'))){if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file -Force}}}
}
function Read-CourseJson([string]$Path) {
    Assert-CoursePlainPath $Path
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
}
function Protect-CourseOutput([string]$Text) {
    $value=[regex]::Replace($Text,'(?i)\bsk-[a-z0-9_-]{12,}|\beyJ[a-zA-Z0-9_.-]{30,}','[REDACTED]')
    $value=[regex]::Replace($value,'(?im)(["'']?(?:[a-z0-9_]*(?:api_?key|access_?key|secret|password|authorization|token)[a-z0-9_]*)["'']?\s*[:=]\s*)[^\r\n,}]+','$1[REDACTED]')
    return $value
}
function Get-CourseErrorDiagnostic($Record,[string]$Phase,[string]$ExecutionRoot){
    $identityFile=Join-Path $ExecutionRoot 'execution-manifest.json'
    $identity=if(Test-Path -LiteralPath $identityFile){Read-CourseJson $identityFile}else{$null}
    $versionFile=Join-Path $ExecutionRoot 'packages/VERSION.json'
    $version=if(Test-Path -LiteralPath $versionFile){(Read-CourseJson $versionFile).version}else{$null}
    return @{schemaVersion=1;phase=$Phase;message=(Protect-CourseOutput $Record.Exception.Message);function=$Record.InvocationInfo.MyCommand.Name;parameterNames=@($Record.InvocationInfo.BoundParameters.Keys);script=$Record.InvocationInfo.ScriptName;line=$Record.InvocationInfo.ScriptLineNumber;stack=(Protect-CourseOutput $Record.ScriptStackTrace);executionId=$identity.contentId;version=$version;powerShell=$PSVersionTable.PSVersion.ToString();at=(Get-Date).ToUniversalTime().ToString('o')}
}
function Write-CourseEvent([string]$Root,[hashtable]$Value) {
    # Fixed allowlist: never record command arguments, credentials, env, or arbitrary errors.
    $event=[ordered]@{recordedAt=(Get-Date).ToUniversalTime().ToString('o')}
    foreach($key in @('operationId','stage','action','status','startedAt','finishedAt','durationMs','runtime','imageId','inputFingerprint','evidence','waitKind','nextAction','errorCode')){
        if($Value.ContainsKey($key)){$event[$key]=$Value[$key]}
    }
    $folder=Join-Path $Root '.local';Assert-CoursePlainPath $folder
    [void](New-Item -ItemType Directory -Path $folder -Force)
    $path=Join-Path $folder 'course-execution.jsonl';Assert-CoursePlainPath $path
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes((Protect-CourseOutput ($event|ConvertTo-Json -Depth 5 -Compress))+"`n")
    $stream=[IO.File]::Open($path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{[void]$stream.Seek(0,[IO.SeekOrigin]::End);$stream.Write($bytes,0,$bytes.Length);$stream.Flush()}finally{$stream.Dispose()}
}
function Get-CoursePriorToolchain([string]$Workspace) {
    $current=Join-Path $Workspace 'toolchain-verification.json'
    if(Test-Path -LiteralPath $current){$report=Read-CourseJson $current;if($report.VerifiedAt){return [pscustomobject]@{path=$current;report=$report}}}
    # Only the explicit selected preparation, never a workspace/HOME search.
    try{
        $known=Find-CoursePreparation
        $path=Join-Path $known.workspace 'toolchain-verification.json'
        if(Test-Path -LiteralPath $path){$report=Read-CourseJson $path;if($report.VerifiedAt){return [pscustomobject]@{path=$path;report=$report}}}
    }catch{ return $null }
    return $null
}
function Resolve-CourseRecordedRuntime([string]$Workspace) {
    foreach($relative in @('.ai-coding\project.json','.course-setup\container-runtime.json','.course-setup\materials.json','toolchain-verification.json')){
        $path=Join-Path $Workspace $relative
        if(Test-Path -LiteralPath $path){
            $record=Read-CourseJson $path
            $runtime=$record.containerRuntime
            if($runtime -in @('docker','podman')){return $runtime}
            if($relative -eq 'toolchain-verification.json'){return 'docker'}
        }
    }
    return 'podman'
}
function Register-CoursePreparation([string]$Workspace) {
    $Workspace=(Resolve-Path -LiteralPath $Workspace).Path; Assert-CoursePlainPath $Workspace
    $report=Read-CourseJson (Join-Path $Workspace 'toolchain-verification.json')
    if(-not $report.VerifiedAt -or $report.ToolchainCheck.ExitCode -ne 0 -or -not $report.Image -or $report.Architecture -ne 'amd64' -or $report.Os -ne 'linux'){throw 'Toolchain not verified; registration refused.'}
    $runtime=if($report.ContainerRuntime){$report.ContainerRuntime}else{'docker'}
    if($runtime -notin @('docker','podman')){throw 'Invalid runtime.'}
    $path=Join-Path $Workspace '.course-setup\preparation.json'
    $prior=if(Test-Path -LiteralPath $path){Read-CourseJson $path}else{$null}
    $id=if($prior.preparationId){$prior.preparationId}else{[guid]::NewGuid().ToString()}
    $value=@{schemaVersion=2;preparationId=$id;registeredAt=(Get-Date).ToString('o');userSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;machine=$env:COMPUTERNAME;containerRuntime=$runtime;image=$report.Image;imageDigest=$report.imageDigest;verifiedAt=$report.VerifiedAt;verificationMethod=$report.VerificationMethod;networkMode=$report.NetworkMode;connection=$report.Connection;toolchainEvidence='toolchain-verification.json';storageEvidence='.course-setup/storage.json'}
    $value.imageId=$report.ImageId;$value.archiveSha256=$report.ArchiveSha256
    if($runtime -eq 'podman'){$value.compose=$report.ComposeBinding}
    $storageFile=Join-Path $Workspace '.course-setup\storage.json'
    $storage=if(Test-Path -LiteralPath $storageFile){Read-CourseJson $storageFile}else{$null}
    $value.desiredStorageRoot=$storage.desiredRoot
    $value.storageStatus=if($storage.status){$storage.status}else{'pending'}
    $value.storageRoot=if($storage.status -eq 'verified'){$storage.desiredRoot}else{$null}
    $value.storagePaths=@($storage.actualPaths)
    $capabilityLine=([string]$report.ToolchainCheck.Output -split '\r?\n'|Where-Object {$_ -like 'CAPABILITIES_JSON:*'}|Select-Object -Last 1)
    if($capabilityLine){
        $capabilities=$capabilityLine.Substring('CAPABILITIES_JSON:'.Length)|ConvertFrom-Json
        $value.capabilities=$capabilities
        Write-CourseJson (Join-Path $Workspace '.course-setup\capabilities.json') @{schemaVersion=2;image=$report.Image;imageDigest=$report.imageDigest;checkedAt=$report.VerifiedAt;capabilities=$capabilities}
    }
    Write-CourseJson $path $value
    $root=Get-CourseUserRoot; Protect-CourseDirectory $root
    $indexPath=Join-Path $root 'preparation-index.json'; $entries=@()
    if(Test-Path -LiteralPath $indexPath){$entries=@((Read-CourseJson $indexPath).preparations | Where-Object {$_.preparationId -ne $id})}
    $entries+=@{preparationId=$id;path=$path;record=$value}
    Write-CourseJson $indexPath @{schemaVersion=2;selectedId=$id;preparations=@($entries)}
    $lifecycle=Join-Path $PSScriptRoot 'Course-Lifecycle.ps1'
    if(Test-Path -LiteralPath $lifecycle){
        . $lifecycle
        $installation=Find-CourseInstallation $Workspace
        if($installation){
            $gate=Get-CourseLifecycleLock
            try{$db=Read-CourseLifecycle;$entry=@($db.installations|Where-Object installationId -eq $installation.installationId)[0];$entry.preparationId=$id;Write-CourseLifecycle $db}finally{Close-CourseLifecycleLock $gate}
        }
    }
    return [pscustomobject]@{preparationId=$id;path=$path;status='registered'}
}
function Find-CoursePreparation([string]$Source,[string]$PreparationId) {
    if($Source){$path=Join-Path $Source '.course-setup/preparation.json'}else{
        $index=Read-CourseJson (Join-Path (Get-CourseUserRoot) 'preparation-index.json')
        $wanted=if($PreparationId){$PreparationId}else{$index.selectedId}
        $entries=@($index.preparations | Where-Object {$_.preparationId -eq $wanted})
        if($entries.Count -ne 1){throw 'Preparation missing or ambiguous; ask for preparation location.'}; $path=$entries[0].path
    }
    $record=if(Test-Path -LiteralPath $path){Read-CourseJson $path}elseif(-not $Source -and $entries[0].record){$entries[0].record}else{throw 'Preparation record unavailable.'}
    $catalog=Join-Path (Get-CourseUserRoot) 'lifecycle\catalog.json'
    if(Test-Path -LiteralPath $catalog){
        $db=Read-CourseJson $catalog
        $active=@($db.installations|Where-Object {$_.preparationId -eq $record.preparationId -and $_.status -eq 'active'})
        $retired=@($db.installations|Where-Object {$_.preparationId -eq $record.preparationId -and $_.status -ne 'active'})
        if($retired.Count -and -not $active.Count){throw 'PREPARATION_REMOVED_OR_UNINSTALLING: restore and verify the original approved environment before reconnecting.'}
    }
    if($record.schemaVersion -ne 2 -or $record.userSid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -or $record.machine -ne $env:COMPUTERNAME){throw 'Preparation schema, user or machine mismatch.'}
    return [pscustomobject]@{path=$path;workspace=(Split-Path (Split-Path $path -Parent) -Parent);record=$record}
}
function Find-CourseProjectPreparation([string]$ProjectDirectory,[string]$Source) {
    $manifest=Join-Path $ProjectDirectory '.ai-coding\project.json'
    if(-not(Test-Path -LiteralPath $manifest)){return Find-CoursePreparation $Source}
    $project=Read-CourseJson $manifest
    $bindingPath=Join-Path $ProjectDirectory '.ai-coding\preparation.json'
    $binding=if(Test-Path -LiteralPath $bindingPath){Read-CourseJson $bindingPath}else{$null}
    $id=if($project.preparationId){$project.preparationId}else{$binding.preparationId}
    if($Source){$found=Find-CoursePreparation $Source}
    elseif($id){$found=Find-CoursePreparation -PreparationId $id}
    else{
        # Legacy projects may lack an ID: match existing toolchain, never adopt an unrelated selected environment.
        $index=Read-CourseJson (Join-Path (Get-CourseUserRoot) 'preparation-index.json')
        $matches=@($index.preparations|Where-Object {$_.record.image -eq $project.image -and $_.record.containerRuntime -eq $project.containerRuntime -and (-not $project.connection -or $_.record.connection -eq $project.connection)})
        if($matches.Count -ne 1){throw 'PROJECT_PREPARATION_MISSING_OR_AMBIGUOUS: preserve project and identify its original preparation.'}
        $found=Find-CoursePreparation -PreparationId $matches[0].preparationId
    }
    if(($id -and $found.record.preparationId -ne $id) -or $found.record.image -ne $project.image -or $found.record.containerRuntime -ne $project.containerRuntime -or ($project.connection -and $project.connection -ne $found.record.connection)){
        throw 'PROJECT_PREPARATION_CONFLICT: existing binding preserved.'
    }
    return $found
}
function Register-CourseServices([string]$Workspace,[string]$GithubLogin) {
    $source=Find-CoursePreparation $Workspace
    $root=Get-CourseUserRoot;Protect-CourseDirectory $root
    $registryPath=Join-Path $root 'services.json'
    $registry=if(Test-Path -LiteralPath $registryPath){Read-CourseJson $registryPath}else{[pscustomobject]@{schemaVersion=2;preparations=@()}}
    $prior=@($registry.preparations|Where-Object {$_.preparationId -eq $source.record.preparationId})
    $entry=if($prior.Count -eq 1){$prior[0]}else{[pscustomobject]@{preparationId=$source.record.preparationId;cloudbase=$null;ai=$null;github=$null}}
    if($GithubLogin){
        if($GithubLogin -notmatch '^[a-zA-Z0-9][a-zA-Z0-9-]{0,38}$'){throw 'Invalid GitHub login.'}
        $entry|Add-Member -MemberType NoteProperty -Name github -Value ([pscustomobject]@{login=$GithubLogin;authorizationStatus='pending';checkedAt=(Get-Date).ToString('o')}) -Force
    }
    $publicFile=Join-Path $Workspace '.cloudbase-setup\connection.env'
    if(Test-Path -LiteralPath $publicFile){
        Assert-CoursePlainPath $publicFile;$values=@{}
        foreach($line in [IO.File]::ReadAllLines($publicFile)){
            if($line -match '^\s*(VITE_CLOUDBASE_ENV_ID|VITE_CLOUDBASE_PUBLISHABLE_KEY)\s*=\s*([a-zA-Z0-9._:-]+)\s*$'){$values[$Matches[1]]=$Matches[2]}
        }
        if($values.Count -eq 2){$entry.cloudbase=[pscustomobject]@{envId=$values.VITE_CLOUDBASE_ENV_ID;publishableKey=$values.VITE_CLOUDBASE_PUBLISHABLE_KEY;authorizationStatus='pending'}}
    }
    $aiFile=Join-Path $Workspace '.ai-setup\verification.json'
    $accountFile=Join-Path $Workspace '.ai-setup\account-readiness.json'
    if(Test-Path -LiteralPath $accountFile){
        $account=Read-CourseJson $accountFile
        if($account.mode -eq 'account-readiness'){
            if(-not $entry.ai){$entry.ai=[pscustomobject]@{}}
            $entry.ai|Add-Member -MemberType NoteProperty -Name accountReadiness -Value ([pscustomobject]@{status=$account.status;checkedAt=$account.checkedAt;learnerConfirmedAt=$account.learnerConfirmedAt;scope='account-and-billing-only';checks=[pscustomobject]@{identityVerified=($account.checks.identityVerified -eq $true);billingReviewed=($account.checks.billingReviewed -eq $true)}}) -Force
        }
    }
    if(Test-Path -LiteralPath $aiFile){
        $report=Read-CourseJson $aiFile
        # Only known non-secret fields; never copy arbitrary provider responses.
        $entry.ai=[pscustomobject]@{credentialRef='siliconflow/course-default';checkedAt=$report.checkedAt;credentials=$report.credentials;textStatus=$report.text.status;textModel=$report.text.model;visionStatus=$report.vision.status;visionModel=$report.vision.model;credentialFingerprint=$report.credentialFingerprint}
    }
    $feePath=Join-Path $Workspace '.ai-setup\fee-scope.json'
    if(Test-Path -LiteralPath $feePath){
        $fees=Read-CourseJson $feePath
        if($fees.schemaVersion -ne 2 -or -not $fees.confirmedAt -or -not @($fees.allowedModels).Count -or $fees.maxTestCalls -lt 0 -or $fees.maxTestCalls -gt 10){throw 'Invalid recorded trial-cost scope.'}
        if(-not $entry.ai){$entry.ai=[pscustomobject]@{credentialRef='siliconflow/course-default'}}
        $entry.ai|Add-Member -MemberType NoteProperty -Name feeScope -Value ([pscustomobject]@{confirmedAt=$fees.confirmedAt;allowedModels=@($fees.allowedModels);maxTestCalls=$fees.maxTestCalls;purpose='minimum-service-check'}) -Force
    }
    $remaining=@($registry.preparations|Where-Object {$_.preparationId -ne $entry.preparationId})
    Write-CourseJson $registryPath @{schemaVersion=2;preparations=@($remaining)+@($entry)}
    $lifecycle=Join-Path $PSScriptRoot 'Course-Lifecycle.ps1'
    if(Test-Path -LiteralPath $lifecycle){
        . $lifecycle;$installation=Find-CourseInstallation $Workspace
        $credential=Join-Path (Get-CourseUserRoot) 'credentials\siliconflow-course-default.json'
        if($installation -and $entry.ai.credentialRef -eq 'siliconflow/course-default' -and (Test-Path -LiteralPath $credential)){
            $null=Register-CourseResource -InstallationId $installation.installationId -Kind credential -Locator $credential -Ownership reused -DataClass credential -AllowedRoot (Split-Path $credential -Parent)
        }
    }
    return [pscustomobject]@{preparationId=$entry.preparationId;status='service-records-registered';authorizationStatus='pending'}
}
function Get-CourseStorageDrives {return [IO.DriveInfo]::GetDrives()}
function Get-CourseStorageDriveInfo([string]$Root) {return New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($Root))}
function Get-CourseDefaultStorageRoot {
    $contract=$null
    foreach($file in @((Join-Path $PSScriptRoot '..\assets\course-contract.json'),(Join-Path $PSScriptRoot 'course-contract.json'))){
        if(Test-Path -LiteralPath $file){$contract=Read-CourseJson $file;break}
    }
    if(-not $contract.defaultStorageRoot -or -not $contract.storagePolicy){throw 'COURSE_STORAGE_DEFAULT_MISSING: restore the matching course contract.'}
    $policy=$contract.storagePolicy
    if(-not $policy.preferNonSystemDrive -or -not $policy.allowSystemDriveWhenOnlyDrive -or $policy.directoryName -notmatch '^[a-zA-Z0-9_-]+$'){throw 'Unsupported course storage policy.'}
    $systemDrive=[IO.Path]::GetPathRoot($env:SystemRoot)
    $drives=@(Get-CourseStorageDrives | Where-Object {$_.DriveType -eq 'Fixed'})
    $other=@($drives | Where-Object {$_.Name -ne $systemDrive} | Sort-Object Name)
    if($other.Count){
        $eligible=@($other | Where-Object {$_.IsReady -and $_.DriveFormat -eq 'NTFS'})
        if(-not $eligible.Count){throw 'NON_SYSTEM_STORAGE_UNAVAILABLE: select or prepare a local NTFS data drive; do not silently use the system drive.'}
        $preferred=[IO.Path]::GetPathRoot($contract.defaultStorageRoot)
        $selected=@($eligible | Where-Object {$_.Name -eq $preferred} | Select-Object -First 1)
        if(-not $selected.Count){$selected=@($eligible[0])}
        return [IO.Path]::Combine($selected[0].Name,$policy.directoryName)
    }
    $system=@($drives | Where-Object {$_.Name -eq $systemDrive -and $_.IsReady -and $_.DriveFormat -eq 'NTFS'})
    if($system.Count -ne 1){throw 'COURSE_STORAGE_DRIVE_UNAVAILABLE: select a local NTFS installation location.'}
    return [IO.Path]::Combine($systemDrive,$policy.directoryName)
}
function Resolve-CourseStorageRoot([string]$Workspace,[string]$Runtime='podman',[string]$RequestedRoot) {
    if($RequestedRoot){return $RequestedRoot}
    # Resolve the selected workspace before the user-wide tool binding. Updating
    # course materials does not authorize relocating an existing installation.
    if($Workspace){
        foreach($relative in @('.ai-coding\project.json','.course-setup\storage-plan.json','.course-setup\storage.json')){
            $file=Join-Path $Workspace $relative
            if(Test-Path -LiteralPath $file){
                $record=Read-CourseJson $file
                if(($record.containerRuntime -and $record.containerRuntime -ne $Runtime) -or ($record.runtime -and $record.runtime -ne $Runtime)){continue}
                if($record.storageRoot){return [string]$record.storageRoot}
                if($record.desiredRoot){return [string]$record.desiredRoot}
            }
        }
    }
    if($Runtime -eq 'podman' -and (Get-Command Get-CoursePodmanBinding -ErrorAction SilentlyContinue)){
        $binding=Get-CoursePodmanBinding
    }else{
        $tools=Join-Path (Get-CourseUserRoot) 'tool-paths.json'
        $binding=if(Test-Path -LiteralPath $tools){(Read-CourseJson $tools).$Runtime}else{$null}
    }
    if($binding.storageRoot){return [string]$binding.storageRoot}
    return Get-CourseDefaultStorageRoot
}
function Get-CourseStoragePlan([string]$Root,[long]$RequiredBytes=20GB) {
    if(-not $Root){$Root=Resolve-CourseStorageRoot}
    $rootPath=[IO.Path]::GetFullPath($Root); Assert-CoursePlainPath $rootPath
    $drive=Get-CourseStorageDriveInfo $rootPath
    if(-not $drive.IsReady -or $drive.DriveType -ne 'Fixed' -or $drive.DriveFormat -ne 'NTFS'){throw 'Select a local NTFS installation drive. Preserve the selected location on failure.'}
    if($drive.AvailableFreeSpace -lt $RequiredBytes){throw 'Insufficient target space. Select another location explicitly; do not silently switch drives.'}
    return [pscustomobject]@{schemaVersion=2;desiredRoot=$rootPath;checkedAt=(Get-Date).ToString('o');availableBytes=$drive.AvailableFreeSpace;requiredBytes=$RequiredBytes;programs=(Join-Path $rootPath 'programs');installers=(Join-Path $rootPath 'downloads\installers');dockerData=(Join-Path $rootPath 'runtime-data\docker');podmanData=(Join-Path $rootPath 'runtime-data\podman');status='planned';actualStatus='pending'}
}
