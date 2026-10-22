#Requires -Version 5.1
# Library only. Importing does not create records or inspect credentials.
. (Join-Path $PSScriptRoot 'Course-Context.ps1')

function Get-CourseLifecycleHash([string]$Value) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)))).Replace('-','').ToLowerInvariant() } finally {$sha.Dispose()}
}
function Get-CourseLifecycleRoot { return Join-Path (Get-CourseUserRoot) 'lifecycle' }
function Assert-CourseLifecycleId([string]$Id) { if($Id -cnotmatch '^[a-f0-9]{32}$'){throw 'INVALID_LIFECYCLE_ID'} }
function Assert-CourseCreationIntentOutput($Value,[string]$Phase='CreateResource') {
    $values=@($Value)
    if($values.Count -ne 1 -or $values[0] -isnot [string] -or $values[0] -cnotmatch '^[a-f0-9]{32}$'){
        $types=@($values|ForEach-Object {if($null -eq $_){'null'}else{$_.GetType().FullName}}) -join ','
        throw "LIFECYCLE_OUTPUT_CONTRACT: phase=$Phase function=Start-CourseCreationIntent parameter=IntentId count=$($values.Count) types=$types PowerShell=$($PSVersionTable.PSVersion)"
    }
    return $values[0]
}
function ConvertTo-CourseProcessStartTicks($Value) {
    if($Value -is [DateTimeOffset]){return $Value.UtcDateTime.Ticks}
    if($Value -is [DateTime]){return $Value.ToUniversalTime().Ticks}
    $parsed=[DateTimeOffset]::MinValue
    if($Value -is [string] -and [DateTimeOffset]::TryParse($Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed)){return $parsed.UtcDateTime.Ticks}
    throw 'INVALID_PROCESS_START_TIME'
}
function Test-CourseProcessIdentity($Recorded,$Actual) {
    try{return (ConvertTo-CourseProcessStartTicks $Recorded) -eq (ConvertTo-CourseProcessStartTicks $Actual)}catch{return $false}
}
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
function Get-CourseCheckedLifecycleLock {
    $values=@(Get-CourseLifecycleLock)
    if($values.Count -ne 1 -or $values[0] -isnot [Threading.Mutex]){
        foreach($value in $values){if($value -is [Threading.Mutex]){$null=Close-CourseLifecycleLock $value}}
        throw 'LIFECYCLE_LOCK_OUTPUT_CONTRACT: function=Get-CourseLifecycleLock parameter=Lock'
    }
    return $values[0]
}
function Read-CourseLifecycle {
    $file=Join-Path (Get-CourseLifecycleRoot) 'catalog.json'
    if(-not(Test-Path -LiteralPath $file)){return [pscustomobject]@{schemaVersion=1;revision=0;installations=@();resources=@();leases=@();intents=@()}}
    $db=Read-CourseJson $file
    if($db.schemaVersion -ne 1 -or $db.installations.Count -gt 1000 -or $db.resources.Count -gt 20000){throw 'INVALID_LIFECYCLE_CATALOG'}
    if(-not $db.PSObject.Properties['intents']){$db|Add-Member NoteProperty intents @()}
    return $db
}
function Write-CourseLifecycle($Catalog) {
    $root=Get-CourseLifecycleRoot;$null=Protect-CourseDirectory $root
    $Catalog.revision=[long]$Catalog.revision+1
    $null=Write-CourseJson (Join-Path $root 'catalog.json') $Catalog
}
function Get-CourseInstallation([string]$InstallationId) {
    Assert-CourseLifecycleId $InstallationId
    $items=@((Read-CourseLifecycle).installations|Where-Object installationId -eq $InstallationId)
    if($items.Count -ne 1){throw 'INSTALLATION_NOT_FOUND'}
    if($items[0].userSid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -or $items[0].machine -ne $env:COMPUTERNAME){throw 'INSTALLATION_IDENTITY_MISMATCH'}
    return $items[0]
}
function Assert-CourseInstallationStatus([string]$Status) {
    if($Status -eq 'active'){return}
    if($Status -eq 'partial'){throw 'INSTALLATION_INCOMPLETE: previous cleanup is partial; rerun the current installation entry for automatic recovery.'}
    if($Status -eq 'uninstalling'){throw 'INSTALLATION_UNINSTALLING: uninstall is in progress or interrupted; rerun the current installation entry to recover, or Resume uninstall.'}
    if($Status -eq 'removed'){throw 'INSTALLATION_REMOVED: select an active preparation or reinstall.'}
    throw ('INSTALLATION_STATE_UNSUPPORTED: status='+$Status)
}
function Register-CourseInstallation([string]$Workspace,[string]$Version,[string]$PackageSha256,[switch]$Recovered) {
    $workspacePath=(Resolve-Path -LiteralPath $Workspace -ErrorAction Stop).Path;Assert-CoursePlainPath $workspacePath
    $gate=Get-CourseCheckedLifecycleLock
    try {
        $db=Read-CourseLifecycle
        $found=@($db.installations|Where-Object {$_.workspace -eq $workspacePath -and $_.status -ne 'removed'})
        if($found.Count -gt 1){throw 'AMBIGUOUS_INSTALLATION'}
        if($found.Count){
            $entry=$found[0]
            $null=Assert-CourseInstallationStatus $entry.status
            if($Version){$entry.version=$Version};if($PackageSha256){$entry.packageSha256=$PackageSha256}
        }else{
            $entry=[pscustomobject]@{installationId=[guid]::NewGuid().ToString('N');workspace=$workspacePath;userSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;machine=$env:COMPUTERNAME;version=$Version;packageSha256=$PackageSha256;preparationId=$null;status='active';recovered=[bool]$Recovered;createdAt=(Get-Date).ToUniversalTime().ToString('o');projects=@()}
            $db.installations=@($db.installations)+@($entry)
        }
        $null=Write-CourseLifecycle $db
        Write-CourseJson (Join-Path $workspacePath '.course-setup\lifecycle.json') @{schemaVersion=1;installationId=$entry.installationId}
        return $entry
    }finally{$null=Close-CourseLifecycleLock $gate}
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
    $allowedMetadata=@('start','end','runtime','cli','cliHash','connection','connectionUri','engineIdentity','objectDigest','projectId','installer','productCode','productVersion','productName','scope','machineName','machineId','createdAt','helper','pid','processStart','dataHome','dataHomeOwned','dataHomeParent','backupFor','namespaceConnections','provider','pathEntryOwned')
    foreach($key in $Metadata.Keys){if($key -notin $allowedMetadata){throw 'UNSUPPORTED_RESOURCE_METADATA'}}
    $key=Get-CourseLifecycleHash ($Kind+'|'+$Locator.ToLowerInvariant())
    if($Kind -in @('container','volume','image','network','machine')){$key=Get-CourseLifecycleHash ($Kind+'|'+$Locator.ToLowerInvariant()+'|'+$Metadata.runtime+'|'+$Metadata.connection+'|'+$Metadata.engineIdentity)}
    $gate=Get-CourseCheckedLifecycleLock
    try{
        $db=Read-CourseLifecycle;$existing=@($db.resources|Where-Object resourceKey -eq $key)
        $current=@($db.installations|Where-Object installationId -eq $InstallationId)
        if($current.Count -ne 1){throw 'INSTALLATION_NOT_FOUND'}
        $null=Assert-CourseInstallationStatus $current[0].status
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
        foreach($intent in @($db.intents|Where-Object {$_.installationId -eq $InstallationId -and $_.kind -eq $Kind -and $_.locator -eq $Locator -and $_.status -eq 'pending' -and $_.pid -eq $PID -and (Test-CourseProcessIdentity $_.processStart (Get-Process -Id $PID).StartTime)})){
            $intent.status='registered'
        }
        $null=Write-CourseLifecycle $db;return $entry
    }finally{$null=Close-CourseLifecycleLock $gate}
}
function Assert-CourseInstallationActive([string]$Workspace) {
    $entry=Find-CourseInstallation $Workspace
    if($entry){$null=Assert-CourseInstallationStatus $entry.status}
    $p=Join-Path $Workspace '.ai-coding\project.json'
    if(Test-Path -LiteralPath $p){$project=Read-CourseJson $p;if($project.preparationStatus -eq 'detached'){throw 'PROJECT_PREPARATION_DETACHED: restore user skills and original approved preparation, then Connect-Project and verify.'}}
}
function Enter-CourseOperation([string]$Workspace,[string]$Action) {
    $gate=Get-CourseCheckedLifecycleLock
    try{
        Assert-CourseInstallationActive $Workspace;$db=Read-CourseLifecycle
        $entry=Find-CourseInstallation $Workspace
        if(-not $entry){
            $projectFile=Join-Path $Workspace '.ai-coding\project.json'
            if(Test-Path -LiteralPath $projectFile){$p=Read-CourseJson $projectFile;$entry=@($db.installations|Where-Object {$_.installationId -eq $p.installationId})|Select-Object -First 1}
        }
        if(-not $entry){return $null}
        $null=Assert-CourseInstallationStatus $entry.status
        $process=Get-Process -Id $PID
        $lease=[pscustomobject]@{id=[guid]::NewGuid().ToString('N');installationId=$entry.installationId;pid=$PID;processStart=$process.StartTime.ToUniversalTime().ToString('o');action=$Action}
        $db.leases=@($db.leases)+@($lease);$null=Write-CourseLifecycle $db;return $lease.id
    }finally{$null=Close-CourseLifecycleLock $gate}
}
function Exit-CourseOperation([string]$LeaseId) {
    if(-not $LeaseId){return};$gate=Get-CourseCheckedLifecycleLock
    try{$db=Read-CourseLifecycle;$db.leases=@($db.leases|Where-Object id -ne $LeaseId);$null=Write-CourseLifecycle $db}finally{$null=Close-CourseLifecycleLock $gate}
}
function Test-CourseLeaseAlive($Lease) {
    try{$p=Get-Process -Id $Lease.pid -ErrorAction Stop;return (Test-CourseProcessIdentity $Lease.processStart $p.StartTime)}catch{return $false}
}
function Register-CourseProjectLifecycle([string]$ProjectDirectory,[string]$PreparationDirectory) {
    $entry=Find-CourseInstallation $PreparationDirectory;if(-not $entry){$entry=Register-CourseInstallation $PreparationDirectory -Recovered}
    $file=Join-Path $ProjectDirectory '.ai-coding\project.json';$p=Read-CourseJson $file
    $gate=Get-CourseCheckedLifecycleLock
    try{
        $db=Read-CourseLifecycle;$i=@($db.installations|Where-Object installationId -eq $entry.installationId)[0]
        $null=Assert-CourseInstallationStatus $i.status
        $i.preparationId=$p.preparationId
        $id=Get-CourseLifecycleHash ([IO.Path]::GetFullPath($ProjectDirectory).ToLowerInvariant())
        $i.projects=@($i.projects|Where-Object projectId -ne $id)+@([pscustomobject]@{projectId=$id;path=[IO.Path]::GetFullPath($ProjectDirectory)})
        $null=Write-CourseLifecycle $db
        $p|Add-Member NoteProperty installationId $entry.installationId -Force;$p|Add-Member NoteProperty preparationStatus 'bound' -Force
        Write-CourseJson $file $p
    }finally{$null=Close-CourseLifecycleLock $gate}
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
    $gate=Get-CourseCheckedLifecycleLock
    try{
        $db=Read-CourseLifecycle;$null=Get-CourseInstallation $InstallationId
        $id=[guid]::NewGuid().ToString('N')
        $db.intents=@($db.intents)+@([pscustomobject]@{id=$id;installationId=$InstallationId;kind=$Kind;locator=$Locator;existedBefore=$ExistedBefore;pid=$PID;processStart=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o');status='pending';at=(Get-Date).ToUniversalTime().ToString('o')})
        $null=Write-CourseLifecycle $db
        return (Assert-CourseCreationIntentOutput $id 'Start')
    }finally{$null=Close-CourseLifecycleLock $gate}
}
function Complete-CourseCreationIntent([string]$IntentId) {
    if(-not $IntentId){return};Assert-CourseLifecycleId $IntentId;$gate=Get-CourseCheckedLifecycleLock
    try{
        $db=Read-CourseLifecycle;$intent=@($db.intents|Where-Object id -eq $IntentId)
        if($intent.Count -ne 1 -or $intent[0].pid -ne $PID -or -not (Test-CourseProcessIdentity $intent[0].processStart (Get-Process -Id $PID).StartTime)){throw 'INTENT_PROCESS_IDENTITY_CHANGED'}
        $intent[0].status='registered';$null=Write-CourseLifecycle $db
    }finally{$null=Close-CourseLifecycleLock $gate}
}
