#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'Course-Context.ps1')
function Get-CoursePodmanApiDiagnostic($MachineInfo,[string]$Cli,[string]$Connection,$ApiResult){
    $machine=[string]$MachineInfo.Name
    if($machine -notmatch '^podman-machine-[a-zA-Z0-9_-]+$' -or $Connection -notin @($machine,($machine+'-root'))){throw 'PODMAN_DIAGNOSTIC_BINDING_REQUIRED'}
    $pipe=[string]$MachineInfo.ConnectionInfo.PodmanPipe.Path
    $pipeMatches=$pipe -eq ('\\.\pipe\'+$machine)
    $processes=@();$processInspection='unavailable'
    try{
        $helper=Join-Path (Split-Path $Cli -Parent) 'win-sshproxy.exe'
        foreach($p in @(Get-CimInstance Win32_Process -Filter "Name='win-sshproxy.exe'" -ErrorAction Stop)){
            if($p.ExecutablePath -eq $helper -and $p.CommandLine -match ('(?:^|[\s"''])'+[regex]::Escape($machine)+'(?:[\s"'']|$)')){$processes+=@{pid=$p.ProcessId;helper=$helper}}
        }
        $processInspection='observed'
    }catch{}
    $addressConflict=([string]$ApiResult.Output -match '(?i)address already in use|Only one usage|bind.*sock|win-sshproxy')
    return [pscustomobject]@{schemaVersion=1;machine=$machine;connection=$Connection;apiAvailable=($ApiResult.ExitCode -eq 0);pipeMatches=$pipeMatches;pipePresent=($pipeMatches -and (Test-Path -LiteralPath $pipe));processInspection=$processInspection;matchingProxies=$processes;possibleAddressConflict=$addressConflict;legacySockets='preserved: ownership and occupancy not established';checkedAt=[datetimeoffset]::UtcNow.ToString('o');nextAction='For supported versions restore only this machine API through the official helper in a fresh owned directory; do not delete legacy sockets or stop unrelated workloads.'}
}
