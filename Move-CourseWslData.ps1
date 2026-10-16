#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$WorkingDirectory,[Parameter(Mandatory=$true)][string]$DistributionName,
      [Parameter(Mandatory=$true)][ValidateSet('docker','podman')][string]$ContainerRuntime,[string]$StorageRoot='D:\AI-Coding',[switch]$Apply)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Course-Runtime.ps1')
$root=(Resolve-Path -LiteralPath $WorkingDirectory).Path;Assert-CoursePlainPath $root
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
$recordPath=Join-Path $root '.course-setup\storage-migration.json';Write-CourseJson $recordPath $record
if(-not $Apply){Write-Output 'Migration plan saved. Coordinate affected workloads before -Apply; program/cache migration is separate.';exit 0}
Protect-CourseDirectory $backupDir
if($source -eq $target){$record.status='already-at-target';Write-CourseJson $recordPath $record;exit 0}
if(Test-Path -LiteralPath $target){throw 'Existing migration target preserved; do not merge or overwrite virtual disks.'}
$wsl=Join-Path $env:SystemRoot 'System32\wsl.exe';$help=Invoke-SetupNative $wsl @('--help') 20
if($help.Output -notmatch '--move'){throw 'Installed WSL does not advertise supported --manage --move; preserve data and restore prerequisites.'}
if($ContainerRuntime -eq 'podman'){
 . (Join-Path $PSScriptRoot 'Setup-PodmanDesktop.ps1');$paths=Get-PodmanPaths
 $inspect=Invoke-SetupNative $paths.Cli @('machine','inspect',$DistributionName) 20
 if($inspect.ExitCode -ne 0){throw 'Selected Podman machine cannot be inspected.'}
 $machine=@($(if($inspect.Stdout){$inspect.Stdout}else{$inspect.Output})|ConvertFrom-Json)[0]
 if($machine.State -eq 'running' -or $machine.Running){$stopped=Invoke-SetupNative $paths.Cli @('machine','stop',$DistributionName) 180;if($stopped.ExitCode -ne 0){throw 'Selected machine could not be stopped; no move performed.'}}
}else{
 $docker=Get-SetupDocker;if($docker.Ready){throw 'Quit the selected Docker Desktop using its supported UI before moving its legacy WSL data; no global shutdown performed.'}
}
$export=Invoke-SetupNative $wsl @('--export',$DistributionName,$backup) 1800 $root
if($export.ExitCode -ne 0 -or -not(Test-Path -LiteralPath $backup) -or (Get-Item -LiteralPath $backup).Length -lt 512){throw 'WSL backup failed; original distribution preserved.'}
$record.backupSha256=(Get-FileHash -LiteralPath $backup).Hash.ToLowerInvariant();$record.status='backup-created';Write-CourseJson $recordPath $record
$move=Invoke-SetupNative $wsl @('--manage',$DistributionName,'--move',$target) 1800 $root
if($move.ExitCode -ne 0){$record.status='move-needs-inspection';Write-CourseJson $recordPath $record;throw 'WSL move failed; inspect actual registration and retained backup, do not unregister/recreate.'}
$actual=@(Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'|ForEach-Object {Get-ItemProperty $_.PSPath}|Where-Object {$_.DistributionName -eq $DistributionName})
if($actual.Count -ne 1 -or [IO.Path]::GetFullPath(($actual[0].BasePath -replace '^\\\\\?\\','')) -ne $target -or -not @(Get-ChildItem -LiteralPath $target -Filter '*.vhdx' -File).Count){throw 'Moved WSL registration/VHD location not verified.'}
$record.status='vhd-location-verified';$record.checkedAt=(Get-Date).ToString('o');Write-CourseJson $recordPath $record
Write-Output 'Selected WSL VHD location verified; retained backup available. Restore the same runtime and verify programs/cache/image/workloads/restart separately.'
