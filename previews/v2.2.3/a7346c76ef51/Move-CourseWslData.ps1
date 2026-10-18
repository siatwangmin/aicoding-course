#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$WorkingDirectory,[Parameter(Mandatory=$true)][string]$DistributionName,
      [Parameter(Mandatory=$true)][ValidateSet('docker','podman')][string]$ContainerRuntime,[string]$StorageRoot='D:\AI-Practice',[switch]$Apply,[switch]$VerifyAfterRestart)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Course-Runtime.ps1')
. (Join-Path $PSScriptRoot 'Course-Storage.ps1')
. (Join-Path $PSScriptRoot 'Course-Evidence.ps1')
$root=(Resolve-Path -LiteralPath $WorkingDirectory).Path;Assert-CoursePlainPath $root
$recordPath=Join-Path $root '.course-setup\storage-migration.json'
function Get-CoursePodmanInventory([string]$Cli,[string]$Connection){
    $snapshot=@{}
    foreach($kind in @('images','containers','volumes')){
        $args=switch($kind){images{@('images','--format','json')}containers{@('ps','-a','--format','json')}volumes{@('volume','ls','--format','json')}}
        $r=Invoke-SetupNative $Cli (@('--connection',$Connection)+$args) 60 $root
        if($r.ExitCode -ne 0){throw 'PODMAN_RESOURCE_INVENTORY_FAILED'}
        $items=@($(if($r.Stdout){$r.Stdout}else{$r.Output})|ConvertFrom-Json)
        $snapshot[$kind]=@($items|ForEach-Object {if($kind -eq 'volumes'){$_.Name}elseif($_.Id){$_.Id}else{$_.ID}}|Where-Object {$_}|Sort-Object -Unique)
    }
    return $snapshot
}
function Test-CourseInventoryPreserved($Before,$After){
    foreach($kind in @('images','containers','volumes')){foreach($id in $Before.$kind){if(@($After.$kind) -notcontains $id){return $false}}}
    return $true
}
if($VerifyAfterRestart){
    if($ContainerRuntime -ne 'podman'){throw 'Restart inventory verification currently applies to the Podman migration route.'}
    $saved=Convert-CourseMigrationRecord (Read-CourseJson $recordPath)
    if($saved.runtime -ne 'podman' -or $saved.distribution -ne $DistributionName -or -not $saved.movedAt){throw 'Matching completed move record required.'}
    $boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    if($boot -le [datetime]::Parse($saved.movedAt)){throw 'Windows restart not yet observed; keep restart verification pending.'}
    . (Join-Path $PSScriptRoot 'Course-Podman.ps1');$paths=Get-PodmanPaths
    $started=Invoke-SetupNative $paths.Cli @('machine','start',$DistributionName) 180
    $engine=Get-SetupPodman $DistributionName $root
    if($engine.Connection -ne $saved.connection){throw 'Original connection not restored.'}
    $current=Get-CoursePodmanInventory $paths.Cli $engine.Connection
    if(-not(Test-CourseInventoryPreserved $saved.inventoryBefore $current)){throw 'Original resources not fully observed after restart.'}
    $locations=Test-CourseStorageLocation $root 'podman' $StorageRoot
    if($locations.status -ne 'verified'){throw 'Actual program/cache/VHD positions still pending.'}
    $saved|Add-Member -MemberType NoteProperty -Name restartStatus -Value 'verified' -Force
    $saved|Add-Member -MemberType NoteProperty -Name inventoryAfter -Value $current -Force
    $saved|Add-Member -MemberType NoteProperty -Name restartVerifiedAt -Value (Get-Date).ToString('o') -Force
    $saved|Add-Member -MemberType NoteProperty -Name status -Value 'restart-and-resources-verified-workload-trial-pending' -Force
    Write-CourseJson $recordPath $saved
    Write-Output 'Restart, resource inventory and storage checked. Project build and learner trial remain separate.';exit 0
}
if(($ContainerRuntime -eq 'podman' -and $DistributionName -notmatch '^podman-machine-[a-zA-Z0-9_-]+$') -or ($ContainerRuntime -eq 'docker' -and $DistributionName -ne 'docker-desktop-data')){throw 'Only the explicitly selected course runtime distribution can be moved.'}
$matches=@(Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'|ForEach-Object {Get-ItemProperty $_.PSPath}|Where-Object {$_.DistributionName -eq $DistributionName})
if($matches.Count -ne 1){throw 'Exact registered WSL distribution not found; do not guess a Docker VHD or recreate a machine.'}
$source=[IO.Path]::GetFullPath(($matches[0].BasePath -replace '^\\\\\?\\',''));Assert-CoursePlainPath $source
$disks=@(Get-ChildItem -LiteralPath $source -Filter '*.vhdx' -File)
if($disks.Count -ne 1){throw 'Selected WSL VHD not uniquely identified.'}
$plan=Get-CourseStoragePlan $StorageRoot ($disks[0].Length*2+4GB)
$target=[IO.Path]::GetFullPath((Join-Path $StorageRoot ('runtime-data\'+$ContainerRuntime+'\machines\'+$DistributionName)));Assert-CoursePlainPath $target
if(-not $target.StartsWith($plan.desiredRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Migration target escapes confirmed storage root.'}
$backupDir=Join-Path $StorageRoot 'backups'
$backup=Join-Path $backupDir ($DistributionName+'-'+[guid]::NewGuid().ToString('N')+'.tar')
$record=@{schemaVersion=2;runtime=$ContainerRuntime;distribution=$DistributionName;source=$source;target=$target;backup=$backup;status='planned';scope='selected-wsl-vhd-only';programAndCache='not-verified';checkedAt=(Get-Date).ToString('o')}
if($source.StartsWith($plan.desiredRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){
    # New machines already under the confirmed root need no relocation or new backup.
    # Preserve any earlier move/restart evidence instead of replacing it on a repeated call.
    if(-not(Test-Path -LiteralPath $recordPath)){$record.status='already-within-target-root';Write-CourseJson $recordPath $record}
    Write-Output 'Selected WSL disk already resides under the confirmed data root; no move performed. Program/cache and restart checks remain separate.';exit 0
}
Write-CourseJson $recordPath $record
if(-not $Apply){Write-Output 'Migration plan saved. Coordinate affected workloads before -Apply; program/cache migration is separate.';exit 0}
Protect-CourseDirectory $backupDir
if($source -eq $target){$record.status='already-at-target';Write-CourseJson $recordPath $record;exit 0}
if(Test-Path -LiteralPath $target){
    Assert-CoursePlainPath $target
    if(-not(Test-Path -LiteralPath $target -PathType Container) -or @(Get-ChildItem -LiteralPath $target -Force).Count){throw 'Existing migration target preserved; do not merge or overwrite virtual disks.'}
    Remove-Item -LiteralPath $target -Force # Verified empty directory inside confirmed root; no recursive removal.
}
$wsl=Join-Path $env:SystemRoot 'System32\wsl.exe';$help=Invoke-SetupNative $wsl @('--help') 20
if($help.Output -notmatch '--move'){throw 'Installed WSL does not advertise supported --manage --move; preserve data and restore prerequisites.'}
if($ContainerRuntime -eq 'podman'){
 . (Join-Path $PSScriptRoot 'Course-Podman.ps1');$paths=Get-PodmanPaths
 $inspect=Invoke-SetupNative $paths.Cli @('machine','inspect',$DistributionName) 20
 if($inspect.ExitCode -ne 0){throw 'Selected Podman machine cannot be inspected.'}
 $machine=@($(if($inspect.Stdout){$inspect.Stdout}else{$inspect.Output})|ConvertFrom-Json)[0]
 if($machine.State -ne 'running' -and -not $machine.Running){
     $started=Invoke-SetupNative $paths.Cli @('machine','start',$DistributionName) 180
     if($started.ExitCode -ne 0){throw 'Cannot inspect original resources; migration not performed.'}
 }
 $engine=Get-SetupPodman $DistributionName $root
 $record.connection=$engine.Connection
 $record.inventoryBefore=Get-CoursePodmanInventory $paths.Cli $engine.Connection
 Write-CourseJson $recordPath $record
 $stopped=Invoke-SetupNative $paths.Cli @('machine','stop',$DistributionName) 180;if($stopped.ExitCode -ne 0){throw 'Selected machine could not be stopped; no move performed.'}
}else{
 $docker=Get-SetupDocker;if($docker.Ready){throw 'Quit the selected Docker Desktop using its supported UI before moving its legacy WSL data; no global shutdown performed.'}
}
$export=Invoke-SetupNative $wsl @('--export',$DistributionName,$backup) 1800 $root
if($export.ExitCode -ne 0 -or -not(Test-Path -LiteralPath $backup) -or (Get-Item -LiteralPath $backup).Length -lt 512){throw 'WSL backup failed; original distribution preserved.'}
$record.backupSha256=(Get-FileHash -LiteralPath $backup).Hash.ToLowerInvariant();$record.status='backup-created';Write-CourseJson $recordPath $record
$move=Invoke-SetupNative $wsl @('--manage',$DistributionName,'--move',$target) 1800 $root
if($move.ExitCode -ne 0){$record.status='move-needs-inspection';$record.moveExitCode=$move.ExitCode;$record.moveDetail=Protect-CourseOutput $move.Output;Write-CourseJson $recordPath $record;throw 'WSL move failed; inspect actual registration and retained backup, do not unregister/recreate.'}
$actual=@(Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'|ForEach-Object {Get-ItemProperty $_.PSPath}|Where-Object {$_.DistributionName -eq $DistributionName})
if($actual.Count -ne 1 -or [IO.Path]::GetFullPath(($actual[0].BasePath -replace '^\\\\\?\\','')) -ne $target -or -not @(Get-ChildItem -LiteralPath $target -Filter '*.vhdx' -File).Count){throw 'Moved WSL registration/VHD location not verified.'}
$record.status='vhd-location-verified';$record.checkedAt=(Get-Date).ToString('o');Write-CourseJson $recordPath $record
if($ContainerRuntime -eq 'podman'){
    $record.movedAt=(Get-Date).ToString('o');$record.restartStatus='pending';Write-CourseJson $recordPath $record
    Write-CourseJson (Join-Path $root '.course-setup\restart-continuation.json') @{schemaVersion=1;workingDirectory=$root;distribution=$DistributionName;runtime=$ContainerRuntime;storageRoot=$StorageRoot;target=$target;createdAt=[datetimeoffset]::UtcNow.ToString('o')}
    $resumeFile=Join-Path $root '.course-setup\resume-preparation.ps1'
    $shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $entry=Join-Path $PSScriptRoot 'Resume-CoursePreparation.ps1'
    # Generated script contains literal paths only, not credentials or arbitrary arguments.
    $resumeText="& '$($shell.Replace("'","''"))' -NoProfile -File '$($entry.Replace("'","''"))' -WorkingDirectory '$($root.Replace("'","''"))'`nexit `$LASTEXITCODE`n"
    [IO.File]::WriteAllText($resumeFile,$resumeText,[Text.UTF8Encoding]::new($true))
    $started=Invoke-SetupNative $paths.Cli @('machine','start',$DistributionName) 180
    if($started.ExitCode -ne 0){throw 'Moved machine could not restart; backup retained, inspect original connection.'}
    $engine=Get-SetupPodman $DistributionName $root
    if($engine.Connection -ne $record.connection){throw 'Moved machine connection changed.'}
    $record.inventoryAfter=Get-CoursePodmanInventory $paths.Cli $engine.Connection
    if(-not(Test-CourseInventoryPreserved $record.inventoryBefore $record.inventoryAfter)){throw 'Resources missing after move; inspect retained backup, do not reset machine.'}
    $record.status='runtime-and-resources-restored-restart-pending';Write-CourseJson $recordPath $record
}
Write-Output 'Selected WSL VHD location verified; retained backup available. Restore the same runtime and verify programs/cache/image/workloads/restart separately.'
