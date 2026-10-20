#Requires -Version 5.1
[CmdletBinding()]
param([string]$ProjectDirectory,[string]$PreparationDirectory)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Course-Runtime.ps1')
$timer=[Diagnostics.Stopwatch]::StartNew();$id=[guid]::NewGuid().ToString('N');$started=(Get-Date).ToUniversalTime().ToString('o')
$root=$null;$result=@{schemaVersion=2;status='pending';checkedAt=$started;operationId=$id;checks=@{};nextSkill='ai-coding-env'}
try{
    if($ProjectDirectory){
        $root=Resolve-CourseProjectRoot $ProjectDirectory
        $prepared=Find-CourseProjectPreparation $root $PreparationDirectory
        $ctx=Get-CourseProjectRuntime $root
        $result.checks=@{preparationId=$prepared.record.preparationId;runtime=$ctx.Project.containerRuntime;connection=$ctx.Project.connection;imageId=$ctx.ImageId;sourceDirectory=$ctx.Project.sourceDirectory;port=$ctx.Project.port;provider=$ctx.Project.compose.provider}
        $result.nextSkill='ai-coding-development'
    }else{
        $prepared=Find-CoursePreparation $PreparationDirectory;$root=$prepared.workspace
        $p=$prepared.record
        if($p.containerRuntime -eq 'podman'){. (Join-Path $PSScriptRoot 'Course-Podman.ps1');$engine=Get-SetupPodman ($p.connection -replace '-root$','')}else{$engine=Get-SetupDocker;if(-not $engine.Ready){throw 'LOCAL_ENGINE_UNAVAILABLE'}}
        $result.checks=@{preparationId=$p.preparationId;runtime=$p.containerRuntime;connection=$p.connection;preparationDirectory=$root;storageStatus=$p.storageStatus;scope='engine-and-binding-only'}
        # Full image/dependency checks are project-specific; no project is created in A.
    }
    $result.status='verified';$result.nextAction='Continue the recorded stage; readiness is not product acceptance.'
}catch{
    $result.errorCode=if($_.Exception.Message -match '^([A-Z][A-Z0-9_]+)'){$Matches[1]}else{'READINESS_CHECK_FAILED'}
    $result.nextAction='Restore the recorded preparation/runtime with ai-coding-env; dependency errors use Invoke-CourseProject -Action Repair. Preserve the project.'
}finally{
    if($root){Write-CourseEvent $root @{operationId=$id;stage='readiness';action='Verify';status=$result.status;startedAt=$started;finishedAt=(Get-Date).ToUniversalTime().ToString('o');durationMs=$timer.ElapsedMilliseconds;errorCode=$result.errorCode;nextAction=$result.nextAction}}
}
$result|ConvertTo-Json -Depth 6
if($result.status -ne 'verified'){exit 2}
