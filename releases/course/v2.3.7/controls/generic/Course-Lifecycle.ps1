#Requires -Version 5.1
# Library only. Importing does not create records or inspect credentials.
. (Join-Path $PSScriptRoot 'Course-Context.ps1')

function Get-CourseLifecycleHash([string]$Value) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)))).Replace('-','').ToLowerInvariant() } finally {$sha.Dispose()}
}
function Get-CourseLifecycleRoot { return Join-Path (Get-CourseUserRoot) 'lifecycle' }
function Assert-CourseLifecycleId([string]$Id) { if($Id -cnotmatch '^[a-f0-9]{32}$'){throw 'INVALID_LIFECYCLE_ID'} }
function Test-CoursePathWithin([string]$Root,[string]$Path,[switch]$AllowEqual) {
    if(-not $Root -or -not $Path){return $false}
    $a=[IO.Path]::GetFullPath($Root).TrimEnd('\');$b=[IO.Path]::GetFullPath($Path).TrimEnd('\')
    return (($AllowEqual -and $a -eq $b) -or $b.StartsWith($a+'\',[StringComparison]::OrdinalIgnoreCase))
}
function Get-CourseLifecycleLock {
    $name='Local\ai-coding-lifecycle-'+(Get-CourseLifecycleHash ((Get-CourseLifecycleRoot).ToLowerInvariant()))
    $mutex=[Threading.Mutex]::new($false,$name)
    try {$entered=$mutex.WaitOne(15000)} catch [Threading.AbandonedMutexException] {$entered=$true}
    if(-not $entered){$mutex.Dispose();throw 'LIFECYCLE_BUSY'}
    return $mutex
}
function Close-CourseLifecycleLock($Lock) { if($Lock){$Lock.ReleaseMutex();$Lock.Dispose()} }
function Read-CourseLifecycle {
    $file=Join-Path (Get-CourseLifecycleRoot) 'catalog.json'
    if(-not(Test-Path -LiteralPath $file)){return [pscustomobject]@{schemaVersion=1;revision=0;installations=@();resources=@();leases=@();intents=@()}}
    $db=Read-CourseJson $file
    if($db.schemaVersion -ne 1 -or $db.installations.Count -gt 1000 -or $db.resources.Count -gt 20000){throw 'INVALID_LIFECYCLE_CATALOG'}
    if(-not $db.PSObject.Properties['intents']){$db|Add-Member NoteProperty intents @()}
    return $db
}
function Write-CourseLifecycle($Catalog) {
    $root=Get-CourseLifecycleRoot;Protect-CourseDirectory $root
    $Catalog.revision=[long]$Catalog.revision+1
    Write-CourseJson (Join-Path $root 'catalog.json') $Catalog
}
function Get-CourseInstallation([string]$InstallationId) {
    Assert-CourseLifecycleId $InstallationId
    $items=@((Read-CourseLifecycle).installations|Where-Object installationId -eq $InstallationId)
    if($items.Count -ne 1){throw 'INSTALLATION_NOT_FOUND'}
    if($items[0].userSid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -or $items[0].machine -ne $env:COMPUTERNAME){throw 'INSTALLATION_IDENTITY_MISMATCH'}
    return $items[0]
}
function Register-CourseInstallation([string]$Workspace,[string]$Version,[string]$PackageSha256,[switch]$Recovered) {
    $workspacePath=(Resolve-Path -LiteralPath $Workspace -ErrorAction Stop).Path;Assert-CoursePlainPath $workspacePath
    $gate=Get-CourseLifecycleLock
    try {
        $db=Read-CourseLifecycle
        $found=@($db.installations|Where-Object {$_.workspace -eq $workspacePath -and $_.status -ne 'removed'})
        if($found.Count -gt 1){throw 'AMBIGUOUS_INSTALLATION'}
        if($found.Count){
            $entry=$found[0]
            if($entry.status -ne 'active'){throw 'INSTALLATION_UNINSTALLING: resume uninstall before installing.'}
            if($Version){$entry.version=$Version};if($PackageSha256){$entry.packageSha256=$PackageSha256}
        }else{
            $entry=[pscustomobject]@{installationId=[guid]::NewGuid().ToString('N');workspace=$workspacePath;userSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;machine=$env:COMPUTERNAME;version=$Version;packageSha256=$PackageSha256;preparationId=$null;status='active';recovered=[bool]$Recovered;createdAt=(Get-Date).ToUniversalTime().ToString('o');projects=@()}
            $db.installations=@($db.installations)+@($entry)
        }
        Write-CourseLifecycle $db
        Write-CourseJson (Join-Path $workspacePath '.course-setup\lifecycle.json') @{schemaVersion=1;installationId=$entry.installationId}
        return $entry
    }finally{Close-CourseLifecycleLock $gate}
}
function Find-CourseInstallation([string]$Workspace) {
    $path=[IO.Path]::GetFullPath($Workspace)
    $entries=@((Read-CourseLifecycle).installations|Where-Object {$_.workspace -eq $path -and $_.status -ne 'removed'})
    if($entries.Count -ne 1){return $null};return Get-CourseInstallation $entries[0].installationId
}
function Get-CourseFileBaseline([string]$Path) {
    Assert-CoursePlainPath $Path
    if(-not(Test-Path -LiteralPath $Path)){return $null}
    $root=Get-Item -LiteralPath $Path -Force
    $lines=New-Object Collections.Generic.List[string];$bytes=0L
    if($root.PSIsContainer){
        # Inspect links before recursing, including hidden files and empty directories.
        $pending=New-Object 'Collections.Generic.Stack[string]';$pending.Push($root.FullName)
        while($pending.Count){
            $directory=$pending.Pop()
            foreach($child in Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop){
                if($child.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'LINK_IN_RESOURCE_TREE'}
                $rel=$child.FullName.Substring($root.FullName.TrimEnd('\').Length).Replace('\','/')
                if($child.PSIsContainer){$lines.Add('d:'+ $rel);$pending.Push($child.FullName)}else{$bytes+=$child.Length;$lines.Add('f:'+$rel+':'+(Get-FileHash -LiteralPath $child.FullName -Algorithm SHA256).Hash)}
                if($lines.Count -gt 100000){throw 'RESOURCE_TREE_TOO_LARGE'}
            }
        }
    }else{$bytes=$root.Length;$lines.Add((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash)}
    return [pscustomobject]@{digest=(Get-CourseLifecycleHash (($lines|Sort-Object) -join "`n"));bytes=$bytes;entries=$lines.Count;directory=[bool]$root.PSIsContainer}
}
function Register-CourseResource {
    param([string]$InstallationId,[ValidateSet('file','directory','skill','managedBlock','project','credential','container','volume','image','network','machine','tool')][string]$Kind,
          [string]$Locator,[ValidateSet('created','reused','adopted','unknown')][string]$Ownership='unknown',
          [ValidateSet('configuration','rebuildable','businessData','source','signature','credential')][string]$DataClass='configuration',
          [string]$AllowedRoot,[string]$BackupPath,[hashtable]$Metadata=@{})
    $null=Get-CourseInstallation $InstallationId
    $allowedMetadata=@('start','end','runtime','cli','cliHash','connection','connectionUri','engineIdentity','objectDigest','projectId','installer','productCode','productVersion','productName','scope','machineName','machineId','createdAt','helper','pid','processStart','dataHome','dataHomeOwned','dataHomeParent','backupFor','namespaceConnections','provider')
    foreach($key in $Metadata.Keys){if($key -notin $allowedMetadata){throw 'UNSUPPORTED_RESOURCE_METADATA'}}
    $key=Get-CourseLifecycleHash ($Kind+'|'+$Locator.ToLowerInvariant())
    if($Kind -in @('container','volume','image','network','machine')){$key=Get-CourseLifecycleHash ($Kind+'|'+$Locator.ToLowerInvariant()+'|'+$Metadata.runtime+'|'+$Metadata.connection+'|'+$Metadata.engineIdentity)}
    $gate=Get-CourseLifecycleLock
    try{
        $db=Read-CourseLifecycle;$existing=@($db.resources|Where-Object resourceKey -eq $key)
        if(@($db.installations|Where-Object {$_.installationId -eq $InstallationId -and $_.status -eq 'active'}).Count -ne 1){throw 'INSTALLATION_UNINSTALLING'}
        $baseline=$null
        if($Kind -in @('file','directory','skill','project','tool','credential')){
            if(-not $AllowedRoot -or -not(Test-CoursePathWithin $AllowedRoot $Locator)){throw 'RESOURCE_BOUNDARY_REQUIRED'}
            if($Ownership -ne 'unknown'){$baseline=Get-CourseFileBaseline $Locator}
        }
        if($Kind -eq 'managedBlock'){
            Assert-CoursePlainPath $Locator
            if(-not $Metadata.start -or -not $Metadata.end){throw 'BLOCK_MARKERS_REQUIRED'}
            $text=[IO.File]::ReadAllText($Locator);$pattern='(?s)'+[regex]::Escape($Metadata.start)+'.*?'+[regex]::Escape($Metadata.end)
            $matches=[regex]::Matches($text,$pattern);if($matches.Count -ne 1){throw 'BLOCK_BOUNDARY_AMBIGUOUS'}
            $baseline=[pscustomobject]@{digest=(Get-CourseLifecycleHash $matches[0].Value);bytes=0}
            $key=Get-CourseLifecycleHash ($Kind+'|'+$Locator.ToLowerInvariant()+'|'+$Metadata.start)
            $existing=@($db.resources|Where-Object resourceKey -eq $key)
        }
        if($existing.Count){
            $entry=$existing[0]
            # Preserve original ownership and earliest pre-course backup across upgrades.
            $entry.references=@(@($entry.references)+@($InstallationId)|Select-Object -Unique)
            if($Ownership -ne 'reused'){$entry.baseline=$baseline;$entry.metadata=[pscustomobject]$Metadata}
            $entry.revision=[guid]::NewGuid().ToString('N')
            if($entry.status -eq 'removed'){$entry.ownership=$Ownership;$entry.owner=$InstallationId;$entry.backupPath=$BackupPath;$entry.backupBaseline=$(if($BackupPath){Get-CourseFileBaseline $BackupPath}else{$null})}
            $entry.status='present'
        }else{
            $entry=[pscustomobject]@{resourceKey=$key;kind=$Kind;locator=$Locator;ownership=$Ownership;owner=$InstallationId;references=@($InstallationId);dataClass=$DataClass;allowedRoot=$AllowedRoot;baseline=$baseline;backupPath=$BackupPath;backupBaseline=$(if($BackupPath){Get-CourseFileBaseline $BackupPath}else{$null});metadata=[pscustomobject]$Metadata;revision=[guid]::NewGuid().ToString('N');status='present'}
            $db.resources=@($db.resources)+@($entry)
        }
        if($Kind -eq 'skill' -and $entry.backupPath){
            foreach($saved in @($db.resources|Where-Object locator -eq $entry.backupPath)){$saved.references=@(@($saved.references)+@($InstallationId)|Select-Object -Unique)}
        }
        foreach($intent in @($db.intents|Where-Object {$_.installationId -eq $InstallationId -and $_.kind -eq $Kind -and $_.locator -eq $Locator -and $_.status -eq 'pending' -and $_.pid -eq $PID -and $_.processStart -eq (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')})){
            $intent.status='registered'
        }
        Write-CourseLifecycle $db;return $entry
    }finally{Close-CourseLifecycleLock $gate}
}
function Assert-CourseInstallationActive([string]$Workspace) {
    $entry=Find-CourseInstallation $Workspace
    if($entry -and $entry.status -ne 'active'){throw 'INSTALLATION_UNINSTALLING'}
    $p=Join-Path $Workspace '.ai-coding\project.json'
    if(Test-Path -LiteralPath $p){$project=Read-CourseJson $p;if($project.preparationStatus -eq 'detached'){throw 'PROJECT_PREPARATION_DETACHED: restore user skills and original approved preparation, then Connect-Project and verify.'}}
}
function Enter-CourseOperation([string]$Workspace,[string]$Action) {
    $gate=Get-CourseLifecycleLock
    try{
        Assert-CourseInstallationActive $Workspace;$db=Read-CourseLifecycle
        $entry=Find-CourseInstallation $Workspace
        if(-not $entry){
            $projectFile=Join-Path $Workspace '.ai-coding\project.json'
            if(Test-Path -LiteralPath $projectFile){$p=Read-CourseJson $projectFile;$entry=@($db.installations|Where-Object {$_.installationId -eq $p.installationId})|Select-Object -First 1}
        }
        if(-not $entry){return $null}
        if($entry.status -ne 'active'){throw 'INSTALLATION_UNINSTALLING'}
        $process=Get-Process -Id $PID
        $lease=[pscustomobject]@{id=[guid]::NewGuid().ToString('N');installationId=$entry.installationId;pid=$PID;processStart=$process.StartTime.ToUniversalTime().ToString('o');action=$Action}
        $db.leases=@($db.leases)+@($lease);Write-CourseLifecycle $db;return $lease.id
    }finally{Close-CourseLifecycleLock $gate}
}
function Exit-CourseOperation([string]$LeaseId) {
    if(-not $LeaseId){return};$gate=Get-CourseLifecycleLock
    try{$db=Read-CourseLifecycle;$db.leases=@($db.leases|Where-Object id -ne $LeaseId);Write-CourseLifecycle $db}finally{Close-CourseLifecycleLock $gate}
}
function Test-CourseLeaseAlive($Lease) {
    try{$p=Get-Process -Id $Lease.pid -ErrorAction Stop;return ($p.StartTime.ToUniversalTime().ToString('o') -eq $Lease.processStart)}catch{return $false}
}
function Register-CourseProjectLifecycle([string]$ProjectDirectory,[string]$PreparationDirectory) {
    $entry=Find-CourseInstallation $PreparationDirectory;if(-not $entry){$entry=Register-CourseInstallation $PreparationDirectory -Recovered}
    $file=Join-Path $ProjectDirectory '.ai-coding\project.json';$p=Read-CourseJson $file
    $gate=Get-CourseLifecycleLock
    try{
        $db=Read-CourseLifecycle;$i=@($db.installations|Where-Object installationId -eq $entry.installationId)[0]
        if($i.status -ne 'active'){throw 'INSTALLATION_UNINSTALLING'}
        $i.preparationId=$p.preparationId
        $id=Get-CourseLifecycleHash ([IO.Path]::GetFullPath($ProjectDirectory).ToLowerInvariant())
        $i.projects=@($i.projects|Where-Object projectId -ne $id)+@([pscustomobject]@{projectId=$id;path=[IO.Path]::GetFullPath($ProjectDirectory)})
        Write-CourseLifecycle $db
        $p|Add-Member NoteProperty installationId $entry.installationId -Force;$p|Add-Member NoteProperty preparationStatus 'bound' -Force
        Write-CourseJson $file $p
    }finally{Close-CourseLifecycleLock $gate}
    return $entry
}

function Get-CourseMsiIdentity([string]$Path) {
    Assert-CoursePlainPath $Path
    $installer=New-Object -ComObject WindowsInstaller.Installer
    $database=$installer.OpenDatabase($Path,0);$result=@{}
    foreach($property in @('ProductCode','ProductVersion','ProductName')){
        $view=$database.OpenView("SELECT ``Value`` FROM ``Property`` WHERE ``Property`` = '$property'")
        $view.Execute();$record=$view.Fetch();if($record){$result[$property]=$record.StringData(1)};$view.Close()
    }
    if($result.ProductCode -notmatch '^\{[A-Fa-f0-9-]{36}\}$'){throw 'MSI_IDENTITY_UNVERIFIED'}
    return $result
}
function Start-CourseCreationIntent([string]$InstallationId,[string]$Kind,[string]$Locator,[bool]$ExistedBefore) {
    $gate=Get-CourseLifecycleLock
    try{
        $db=Read-CourseLifecycle;$null=Get-CourseInstallation $InstallationId
        $id=[guid]::NewGuid().ToString('N')
        $db.intents=@($db.intents)+@([pscustomobject]@{id=$id;installationId=$InstallationId;kind=$Kind;locator=$Locator;existedBefore=$ExistedBefore;pid=$PID;processStart=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o');status='pending';at=(Get-Date).ToUniversalTime().ToString('o')})
        Write-CourseLifecycle $db;return $id
    }finally{Close-CourseLifecycleLock $gate}
}
function Complete-CourseCreationIntent([string]$IntentId) {
    if(-not $IntentId){return};Assert-CourseLifecycleId $IntentId;$gate=Get-CourseLifecycleLock
    try{
        $db=Read-CourseLifecycle;$intent=@($db.intents|Where-Object id -eq $IntentId)
        if($intent.Count -ne 1 -or $intent[0].pid -ne $PID -or $intent[0].processStart -ne (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')){throw 'INTENT_PROCESS_IDENTITY_CHANGED'}
        $intent[0].status='registered';Write-CourseLifecycle $db
    }finally{Close-CourseLifecycleLock $gate}
}
