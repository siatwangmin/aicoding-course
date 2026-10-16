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
    $acl=[IO.Directory]::GetAccessControl($Path,[Security.AccessControl.AccessControlSections]::Access)
    $acl.SetAccessRuleProtection($true,$false)
    foreach($rule in @($acl.Access)){[void]$acl.RemoveAccessRuleSpecific($rule)}
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
    [IO.Directory]::SetAccessControl($Path,$acl)
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
    $storageFile=Join-Path $Workspace '.course-setup\storage.json'
    $value.storageRoot=if(Test-Path -LiteralPath $storageFile){(Read-CourseJson $storageFile).desiredRoot}else{'D:\AI-Coding'}
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
    return [pscustomobject]@{preparationId=$id;path=$path;status='registered'}
}
function Find-CoursePreparation([string]$Source) {
    if($Source){$path=Join-Path $Source '.course-setup/preparation.json'}else{
        $index=Read-CourseJson (Join-Path (Get-CourseUserRoot) 'preparation-index.json')
        $entries=@($index.preparations | Where-Object {$_.preparationId -eq $index.selectedId})
        if($entries.Count -ne 1){throw 'Preparation missing or ambiguous; ask for preparation location.'}; $path=$entries[0].path
    }
    $record=if(Test-Path -LiteralPath $path){Read-CourseJson $path}elseif(-not $Source -and $entries[0].record){$entries[0].record}else{throw 'Preparation record unavailable.'}
    if($record.schemaVersion -ne 2 -or $record.userSid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -or $record.machine -ne $env:COMPUTERNAME){throw 'Preparation schema, user or machine mismatch.'}
    return [pscustomobject]@{path=$path;workspace=(Split-Path (Split-Path $path -Parent) -Parent);record=$record}
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
    return [pscustomobject]@{preparationId=$entry.preparationId;status='service-records-registered';authorizationStatus='pending'}
}
function Get-CourseStoragePlan([string]$Root='D:\AI-Coding',[long]$RequiredBytes=20GB) {
    $rootPath=[IO.Path]::GetFullPath($Root); Assert-CoursePlainPath $rootPath
    $drive=New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($rootPath))
    if(-not $drive.IsReady -or $drive.DriveType -ne 'Fixed' -or $drive.DriveFormat -ne 'NTFS'){throw 'Select a local NTFS data drive. No C fallback.'}
    if([IO.Path]::GetPathRoot($rootPath) -eq [IO.Path]::GetPathRoot($env:SystemRoot)){throw 'Large data cannot use the system drive.'}
    if($drive.AvailableFreeSpace -lt $RequiredBytes){throw 'Insufficient target space. No C fallback.'}
    return [pscustomobject]@{schemaVersion=2;desiredRoot=$rootPath;checkedAt=(Get-Date).ToString('o');availableBytes=$drive.AvailableFreeSpace;requiredBytes=$RequiredBytes;programs=(Join-Path $rootPath 'programs');installers=(Join-Path $rootPath 'installers');dockerData=(Join-Path $rootPath 'runtime-data\docker');podmanData=(Join-Path $rootPath 'runtime-data\podman');status='planned';actualStatus='pending'}
}
