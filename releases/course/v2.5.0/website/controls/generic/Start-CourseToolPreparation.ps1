#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$WorkingDirectory,
      [ValidateSet('Start','Status','Run')][string]$Action='Start',
      [ValidateSet('podman','docker')][string]$ContainerRuntime='podman',
      [string]$StorageRoot,[string]$InstallerDirectory,[string]$ImageArchive,[switch]$SkipPull,
      [string]$TaskId)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Course-Context.ps1')
$root=(Resolve-Path -LiteralPath $WorkingDirectory).Path
Assert-CoursePlainPath $root
$folder=Join-Path $root '.course-setup'
[void](New-Item -ItemType Directory -Path $folder -Force)
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
    if(-not(Test-Path -LiteralPath $statePath)){return [pscustomobject]@{status='NotStarted';attention=$null}}
    $current=Read-BackgroundJson $statePath
    if($current.status -in @('Running','Starting')){
        $alive=$false
        if($current.processId){
            $process=Get-Process -Id $current.processId -ErrorAction SilentlyContinue
            $alive=$process -and $process.StartTime.ToUniversalTime().ToString('o') -eq $current.processStartedAt
        }elseif($current.status -eq 'Starting'){$alive=((Get-Date)-[datetime]::Parse($current.startedAt)).TotalSeconds -lt 15}
        if(-not $alive){
            $child=if($current.childProcessId){Get-Process -Id $current.childProcessId -ErrorAction SilentlyContinue}else{$null}
            if($child -and $child.StartTime.ToUniversalTime().ToString('o') -eq $current.childStartedAt){
                $current.status='ChildRunning';$current.attention='后台控制进程已中断，但原安装进程仍在运行；先等待原进程结束，保留账号进度，不重复启动安装。'
            }else{$current.status='Interrupted';$current.attention='后台工具准备已中断，请从原目录重新 Start；保留下载和账号结果。'}
        }
        elseif($current.phase -eq 'Prepare'){
            $systemPath=Join-Path $root '.podman-setup\system-install.json'
            if(Test-Path -LiteralPath $systemPath){
                $system=Read-BackgroundJson $systemPath
                if([datetime]::Parse($system.checkedAt) -ge [datetime]::Parse($current.startedAt)){
                    if($system.status -eq 'AwaitingAuthorization'){$current.attention='请处理 Windows 管理员授权提示，后台准备会继续；账号注册进度已保留。'}
                    elseif($system.status -eq 'RestartRequired'){$current.attention='工具准备需要重启；先保存当前注册进度和工作，由本人决定何时重启，回原目录继续。'}
                }
            }
        }
    }
    return $current
}
function Save-BackgroundToolState([string]$Status,[string]$Phase,[string]$Attention=$null){
    $script:record.status=$Status;$script:record.phase=$Phase;$script:record.attention=$Attention
    $script:record.checkedAt=(Get-Date).ToString('o')
    Write-CourseJson $statePath $script:record
}
function Invoke-BackgroundToolStep([string]$Name,[string]$Script,[string[]]$Arguments){
    Save-BackgroundToolState 'Running' $Name
    $stdout=Join-Path $folder ($record.taskId+'-'+$Name+'.log')
    $stderr=Join-Path $folder ($record.taskId+'-'+$Name+'.error.log')
    $values=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot $Script),'-WorkingDirectory',$root)+$Arguments
    # Quote Windows arguments without invoking a shell or relying on PATH.
    $quoted=@($values|ForEach-Object {'"'+([string]$_ -replace '(\\*)"','$1$1\"' -replace '(\\+)$','$1$1')+'"'})
    $child=Start-Process -FilePath $powershell -ArgumentList ($quoted -join ' ') -WorkingDirectory $root -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    # Cache the handle before exit: PS5.1 otherwise loses ExitCode without -Wait.
    $null=$child.Handle
    $record.childProcessId=$child.Id;$record.childStartedAt=$child.StartTime.ToUniversalTime().ToString('o')
    Save-BackgroundToolState 'Running' $Name
    $child.WaitForExit();$child.Refresh();$code=$child.ExitCode
    $record.childProcessId=$null;$record.childStartedAt=$null
    if($code -eq 3010){
        Save-BackgroundToolState 'RestartRequired' $Name '请保存账号注册进度和工作；由本人重启后回原任务继续，已验证下载会复用。'
        return $false
    }
    if($code -ne 0){throw ('TOOL_STEP_FAILED: '+$Name+'; exit='+$code+'; logs='+$stdout+'; '+$stderr)}
    return $true
}
if($Action -eq 'Status'){Get-BackgroundToolStatus|ConvertTo-Json -Depth 8;return}
if($Action -eq 'Start'){
    # Serialize launch requests; the worker holds its own lock for the full pipeline.
    $launchLock=[IO.File]::Open((Join-Path $folder 'tools-launch.lock'),'OpenOrCreate','ReadWrite','None')
    try{
        $current=Get-BackgroundToolStatus
        if($current.status -in @('Running','Starting','ChildRunning')){$current|ConvertTo-Json -Depth 8;return}
        if(-not $PSBoundParameters.ContainsKey('ContainerRuntime')){$ContainerRuntime=Resolve-CourseRecordedRuntime $root}
        $id=[guid]::NewGuid().ToString('N')
        $record=[ordered]@{schemaVersion=1;taskId=$id;workingDirectory=$root;runtime=$ContainerRuntime;status='Starting';phase='Start';startedAt=(Get-Date).ToString('o');checkedAt=(Get-Date).ToString('o');processId=$null;processStartedAt=$null;childProcessId=$null;childStartedAt=$null;attention=$null;error=$null}
        Write-CourseJson $statePath $record
        $values=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-Action','Run','-WorkingDirectory',$root,'-ContainerRuntime',$ContainerRuntime,'-TaskId',$id)
        foreach($pair in @(@('StorageRoot',$StorageRoot),@('InstallerDirectory',$InstallerDirectory),@('ImageArchive',$ImageArchive))){if($pair[1]){$values+=@(('-'+$pair[0]),$pair[1])}}
        if($SkipPull){$values+='-SkipPull'}
        $quoted=@($values|ForEach-Object {'"'+([string]$_ -replace '(\\*)"','$1$1\"' -replace '(\\+)$','$1$1')+'"'})
        try{
            $null=Start-Process -FilePath $powershell -ArgumentList ($quoted -join ' ') -WorkingDirectory $root -WindowStyle Hidden -RedirectStandardOutput (Join-Path $folder ($id+'-worker.log')) -RedirectStandardError (Join-Path $folder ($id+'-worker.error.log')) -PassThru
        }catch{$record.error=$_.Exception.Message;Save-BackgroundToolState 'Failed' 'Start' '后台任务未能启动；检查实际错误后从原目录重试。';throw}
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
    $verifyArgs=@('-ContainerRuntime',$ContainerRuntime)
    if($ImageArchive){$verifyArgs+=@('-ImageArchive',$ImageArchive)}
    if($SkipPull){$verifyArgs+='-SkipPull'}
    if(-not(Invoke-BackgroundToolStep 'Toolchain' 'Verify-Toolchain.ps1' $verifyArgs)){return}
    Save-BackgroundToolState 'Verified' 'Complete'
    # Foreground owns preparation-progress.json; it records actual tools evidence.
}catch{
    if($record -and $record.taskId -eq $TaskId){$record.error=$_.Exception.Message;Save-BackgroundToolState 'Failed' $record.phase '工具准备失败，请读取本次日志修复并从原目录接续；账号结果保留。'}
    throw
}finally{$workerLock.Dispose()}
