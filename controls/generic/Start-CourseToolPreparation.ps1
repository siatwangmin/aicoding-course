#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$WorkingDirectory,
      [ValidateSet('Start','Status','Watch','Run')][string]$Action='Start',
      [ValidateSet('podman','docker')][string]$ContainerRuntime='podman',
      [string]$StorageRoot,[string]$InstallerDirectory,[string]$ImageArchive,[switch]$SkipPull,
      [string]$TaskId,[ValidateRange(1,30)][int]$WaitSeconds=20)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Course-Context.ps1')
. (Join-Path $PSScriptRoot 'Course-PreparationFeedback.ps1')
$root=(Resolve-Path -LiteralPath $WorkingDirectory).Path
Assert-CoursePlainPath $root
$folder=Join-Path $root '.course-setup'
Assert-CoursePlainPath $folder
$statePath=Join-Path $folder 'tools-background.json'
$powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
function Read-BackgroundJson([string]$Path){
    # Allow atomic replacement while foreground polls the worker's state.
    Assert-CoursePlainPath $Path
    for($attempt=0;$attempt -lt 8;$attempt++){
        $stream=$null;$reader=$null
        try{
            $share=[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
            $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,$share)
            $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true)
            return $reader.ReadToEnd()|ConvertFrom-Json
        }catch [IO.IOException]{if($attempt -eq 7){throw};Start-Sleep -Milliseconds 25}
        finally{if($reader){$reader.Dispose()}elseif($stream){$stream.Dispose()}}
    }
}
function Get-BackgroundToolStatus {
    if(-not(Test-Path -LiteralPath $statePath)){return (Add-CoursePreparationAdvice ([pscustomobject]@{status='NotStarted';attention=$null}) $root)}
    $current=Read-BackgroundJson $statePath
    if($current.status -in @('Running','Starting')){
        $alive=$false
        if($current.processId){
            $alive=Test-CourseBackgroundProcess $current.processId $current.processStartedAt
        }elseif($current.status -eq 'Starting'){
            try{$age=([datetimeoffset]::UtcNow-(ConvertTo-CourseBackgroundTime $current.startedAt)).TotalSeconds;$alive=$age -ge 0 -and $age -lt 15}catch{$alive=$false}
        }
        if(-not $alive){
            if(Test-CourseBackgroundProcess $current.childProcessId $current.childStartedAt){
                $current.status='ChildRunning';$current.attention='后台控制进程已中断，但原安装进程仍在运行；先等待原进程结束，保留账号进度，不重复启动安装。'
            }else{$current.status='Interrupted';$current.attention='后台工具准备已中断，请从原目录重新 Start；保留下载和账号结果。'}
        }
        elseif($current.phase -eq 'Prepare'){
            $systemPath=Join-Path $root '.podman-setup\system-install.json'
            if(Test-Path -LiteralPath $systemPath){
                $system=Read-BackgroundJson $systemPath
                if((ConvertTo-CourseBackgroundTime $system.checkedAt) -ge (ConvertTo-CourseBackgroundTime $current.startedAt)){
                    if($system.status -eq 'AwaitingAuthorization'){$current.attention='请处理 Windows 管理员授权提示，后台准备会继续；账号注册进度已保留。'}
                    elseif($system.status -eq 'RestartRequired'){$current.attention='工具准备需要重启；先保存当前注册进度和工作，由本人决定何时重启，回原目录继续。'}
                }
            }
        }
    }
    return (Add-CoursePreparationAdvice $current $root)
}
function Save-BackgroundToolState([string]$Status,[string]$Phase,[string]$Attention=$null){
    $now=[datetimeoffset]::UtcNow
    $transition=$script:record.status -ne $Status -or $script:record.phase -ne $Phase
    if($script:record.phase -ne $Phase -or -not $script:record.phaseStartedAt){$script:record.phaseStartedAt=$now.ToString('o')}
    $script:record.status=$Status;$script:record.phase=$Phase;$script:record.attention=$Attention
    $script:record.checkedAt=$now.ToString('o');$script:record.heartbeatAt=$now.ToString('o')
    $script:record.phaseElapsedSeconds=[math]::Round(($now-(ConvertTo-CourseBackgroundTime $script:record.phaseStartedAt)).TotalSeconds,1)
    Write-CourseJson $statePath $script:record
    $history=Join-Path $folder ('tool-runs/'+$script:record.taskId)
    Write-CourseJson (Join-Path $history 'state.json') $script:record
    if($transition){
        $events=Join-Path $history 'events.jsonl';Assert-CoursePlainPath $events
        [IO.File]::AppendAllText($events,((@{taskId=$script:record.taskId;status=$Status;phase=$Phase;at=$now.ToString('o')}|ConvertTo-Json -Compress)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
    }
}
function Invoke-BackgroundToolStep([string]$Name,[string]$Script,[string[]]$Arguments){
    Save-BackgroundToolState 'Running' $Name
    $stdout=Join-Path $folder ($record.taskId+'-'+$Name+'.log')
    $stderr=Join-Path $folder ($record.taskId+'-'+$Name+'.error.log')
    $values=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot $Script),'-WorkingDirectory',$root)+$Arguments
    # Quote Windows arguments without invoking a shell or relying on PATH.
    $quoted=@($values|ForEach-Object {'"'+([string]$_ -replace '(\\*)"','$1$1\"' -replace '(\\+)$','$1$1')+'"'})
    $stepStarted=[datetimeoffset]::UtcNow;$code=$null;$finished=$false
    try{
    $child=Start-Process -FilePath $powershell -ArgumentList ($quoted -join ' ') -WorkingDirectory $root -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    # Cache the handle before exit: PS5.1 otherwise loses ExitCode without -Wait.
    $null=$child.Handle
    $record.childProcessId=$child.Id;$record.childStartedAt=$child.StartTime.ToUniversalTime().ToString('o')
    Save-BackgroundToolState 'Running' $Name
    while(-not $child.WaitForExit(10000)){Save-BackgroundToolState 'Running' $Name}
    $child.Refresh();$code=$child.ExitCode;$finished=$true
    }finally{
        $stepFinished=[datetimeoffset]::UtcNow
        $timing=@{taskId=$record.taskId;phase=$Name;startedAt=$stepStarted.ToString('o');finishedAt=$stepFinished.ToString('o');durationSeconds=[math]::Round(($stepFinished-$stepStarted).TotalSeconds,3);exitCode=$code;outcome=$(if(-not $finished){'outcome-unknown'}elseif($code -eq 0){'completed'}elseif($code -eq 3010){'restart-required'}else{'failed'});metric='phase-wall-time-not-download-speed'}
        Write-CourseJson (Join-Path $folder ('tool-runs/'+$record.taskId+'/'+$Name+'-timing.json')) $timing
        if($finished){$record.childProcessId=$null;$record.childStartedAt=$null}
    }
    if($code -eq 3010){
        Save-BackgroundToolState 'RestartRequired' $Name '请保存账号注册进度和工作；由本人重启后回原任务继续，已验证下载会复用。'
        return $false
    }
    if($code -ne 0){throw ('TOOL_STEP_FAILED: '+$Name+'; exit='+$code+'; logs='+$stdout+'; '+$stderr)}
    return $true
}
if($Action -eq 'Status'){Get-BackgroundToolStatus|ConvertTo-Json -Depth 8;return}
if($Action -eq 'Watch'){
    $initial=Get-BackgroundToolStatus
    $signature=([string]$initial.status)+'|'+([string]$initial.phase)+'|'+([string]$initial.attention)
    $watch=[Diagnostics.Stopwatch]::StartNew()
    do{
        $current=Get-BackgroundToolStatus
        $now=([string]$current.status)+'|'+([string]$current.phase)+'|'+([string]$current.attention)
        if($current.actionRequired -or $now -ne $signature){break}
        $remaining=$WaitSeconds*1000-$watch.Elapsed.TotalMilliseconds
        if($remaining -gt 0){Start-Sleep -Milliseconds ([int][math]::Min(250,$remaining))}
    }while($watch.Elapsed.TotalSeconds -lt $WaitSeconds)
    $current|ConvertTo-Json -Depth 8;return
}
[void](New-Item -ItemType Directory -Path $folder -Force)
if($Action -eq 'Start'){
    # Serialize launch requests; the worker holds its own lock for the full pipeline.
    $launchLock=[IO.File]::Open((Join-Path $folder 'tools-launch.lock'),'OpenOrCreate','ReadWrite','None')
    try{
        $current=Get-BackgroundToolStatus
        if($current.status -in @('Running','Starting','ChildRunning')){$current|ConvertTo-Json -Depth 8;return}
        if($current.taskId -match '^[a-f0-9]{32}$'){
            $oldHistory=Join-Path $folder ('tool-runs/'+$current.taskId+'/state.json')
            if(-not(Test-Path -LiteralPath $oldHistory)){Write-CourseJson $oldHistory $current}
        }
        if(-not $PSBoundParameters.ContainsKey('ContainerRuntime')){$ContainerRuntime=Resolve-CourseRecordedRuntime $root}
        $id=[guid]::NewGuid().ToString('N')
        $record=[ordered]@{schemaVersion=1;taskId=$id;workingDirectory=$root;runtime=$ContainerRuntime;status='Starting';phase='Start';startedAt=(Get-Date).ToString('o');checkedAt=(Get-Date).ToString('o');processId=$null;processStartedAt=$null;childProcessId=$null;childStartedAt=$null;attention=$null;error=$null}
        Save-BackgroundToolState 'Starting' 'Start'
        $values=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-Action','Run','-WorkingDirectory',$root,'-ContainerRuntime',$ContainerRuntime,'-TaskId',$id)
        foreach($pair in @(@('StorageRoot',$StorageRoot),@('InstallerDirectory',$InstallerDirectory),@('ImageArchive',$ImageArchive))){if($pair[1]){$values+=@(('-'+$pair[0]),$pair[1])}}
        if($SkipPull){$values+='-SkipPull'}
        $quoted=@($values|ForEach-Object {'"'+([string]$_ -replace '(\\*)"','$1$1\"' -replace '(\\+)$','$1$1')+'"'})
        try{
            $null=Start-Process -FilePath $powershell -ArgumentList ($quoted -join ' ') -WorkingDirectory $root -WindowStyle Hidden -RedirectStandardOutput (Join-Path $folder ($id+'-worker.log')) -RedirectStandardError (Join-Path $folder ($id+'-worker.error.log')) -PassThru
        }catch{$record.error=Protect-CourseOutput $_.Exception.Message;Save-BackgroundToolState 'Failed' 'Start' '后台任务未能启动；检查实际错误后从原目录重试。';throw}
        Get-BackgroundToolStatus|ConvertTo-Json -Depth 8
    }finally{$launchLock.Dispose()}
    return
}
if(-not $TaskId){throw 'BACKGROUND_TASK_ID_REQUIRED'}
$workerLock=[IO.File]::Open((Join-Path $folder 'tools-worker.lock'),'OpenOrCreate','ReadWrite','None')
try{
    $record=Read-BackgroundJson $statePath
    if($record.taskId -ne $TaskId -or $record.workingDirectory -ne $root -or $record.runtime -ne $ContainerRuntime){throw 'BACKGROUND_TASK_BINDING_CHANGED'}
    $record.processId=$PID;$record.processStartedAt=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
    Save-BackgroundToolState 'Running' 'StoragePlan'
    $storageArgs=@('-ContainerRuntime',$ContainerRuntime)
    if($StorageRoot){$storageArgs+=@('-StorageRoot',$StorageRoot)}
    if(-not(Invoke-BackgroundToolStep 'StoragePlan' 'Prepare-CourseStorage.ps1' $storageArgs)){return}
    $nodeArgs=@()
    if($StorageRoot){$nodeArgs+=@('-StorageRoot',$StorageRoot)}
    if($InstallerDirectory){$nodeArgs+=@('-InstallerDirectory',$InstallerDirectory)}
    if(-not(Invoke-BackgroundToolStep 'NodeJs' 'Setup-NodeJs.ps1' $nodeArgs)){return}
    if(-not(Invoke-BackgroundToolStep 'Git' 'Setup-Git.ps1' (@('-Mode','Prepare')+$nodeArgs))){return}
    $githubArgs=@()
    if($StorageRoot){$githubArgs+=@('-StorageRoot',$StorageRoot)}
    if($InstallerDirectory){$githubArgs+=@('-InstallerDirectory',$InstallerDirectory)}
    if(-not(Invoke-BackgroundToolStep 'GitHubCli' 'Setup-GitHubCli.ps1' $githubArgs)){return}
    $setup=if($ContainerRuntime -eq 'podman'){'Setup-Podman.ps1'}else{'Setup-DockerDesktop.ps1'}
    $setupArgs=@('-Mode','Prepare')
    if($StorageRoot){$setupArgs+=@('-StorageRoot',$StorageRoot)}
    if($InstallerDirectory){$setupArgs+=@('-InstallerDirectory',$InstallerDirectory)}
    if(-not(Invoke-BackgroundToolStep 'Prepare' $setup $setupArgs)){return}
    if(-not(Invoke-BackgroundToolStep 'Verify' $setup @('-Mode','Verify'))){return}
    if(-not(Invoke-BackgroundToolStep 'StorageVerify' 'Prepare-CourseStorage.ps1' ($storageArgs+@('-Verify')))){return}
    if(-not(Invoke-BackgroundToolStep 'NodeJsVerify' 'Setup-NodeJs.ps1' @('-Mode','Verify'))){return}
    if(-not(Invoke-BackgroundToolStep 'GitVerify' 'Setup-Git.ps1' @('-Mode','Verify'))){return}
    $verifyArgs=@('-ContainerRuntime',$ContainerRuntime)
    if($ImageArchive){$verifyArgs+=@('-ImageArchive',$ImageArchive)}
    if($SkipPull){$verifyArgs+='-SkipPull'}
    if(-not(Invoke-BackgroundToolStep 'Toolchain' 'Verify-Toolchain.ps1' $verifyArgs)){return}
    Save-BackgroundToolState 'Verified' 'Complete'
    # Foreground owns preparation-progress.json; it records actual tools evidence.
}catch{
    if($record -and $record.taskId -eq $TaskId){$record.error=Protect-CourseOutput $_.Exception.Message;Save-BackgroundToolState 'Failed' $record.phase '工具准备失败，请读取本次日志修复并从原目录接续；账号结果保留。'}
    throw
}finally{$workerLock.Dispose()}
