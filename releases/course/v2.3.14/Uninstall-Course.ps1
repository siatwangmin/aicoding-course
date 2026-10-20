#Requires -Version 5.1
[CmdletBinding()]
param([ValidateSet('Plan','Apply','Resume','Verify')][string]$Mode='Plan',[string]$InstallationId,[string]$PreparationDirectory,
      [ValidateSet('KeepWork','TestClean')][string]$Scope='KeepWork',[string[]]$ProjectIds=@(),[string]$OutputDirectory,
      [string]$PlanPath,[string]$PlanSha256,[string]$OperationId,[switch]$RemovePreparationDirectory,[string[]]$RemoveMachineNames=@())
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Course-Uninstall.ps1')
try{
    if($Mode -eq 'Plan'){
        if(-not $InstallationId){
            if(-not $PreparationDirectory){throw 'SELECT_INSTALLATION_OR_PREPARATION'}
            $install=Find-CourseInstallation $PreparationDirectory
            if(-not $install){$install=Import-CourseLegacyInstallation $PreparationDirectory}
            $InstallationId=$install.installationId
        }
        $result=New-CourseUninstallPlan $InstallationId $Scope $ProjectIds $OutputDirectory -RemovePreparationDirectory:$RemovePreparationDirectory -RemoveMachineNames $RemoveMachineNames
    }else{
        if($Mode -eq 'Apply'){
            if(-not $PlanPath -or $PlanSha256 -notmatch '^[a-fA-F0-9]{64}$'){throw 'REVIEWED_PLAN_AND_SHA256_REQUIRED'}
            $PlanPath=[IO.Path]::GetFullPath($PlanPath);Assert-CoursePlainPath $PlanPath
            $p=Read-CourseJson $PlanPath;$OperationId=$p.operationId
            $op=Read-CourseUninstallOperation $OperationId $PlanSha256
            if($PlanPath -ne (Join-Path $op.directory 'plan.json')){throw 'REGISTERED_PLAN_REQUIRED'}
            $runner=Install-CourseUninstallRunner $op
            # The runner survives deleting the calling skill. Invoke a fresh process so functions
            # and $PSScriptRoot cannot keep pointing at a directory being removed.
            & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $runner -Mode Resume -OperationId $OperationId
            exit $LASTEXITCODE
        }
        if($Mode -eq 'Resume'){
            $op=Read-CourseUninstallOperation $OperationId
            if(-not $op.state.runnerFiles.Count){throw 'APPLY_REVIEWED_PLAN_FIRST'}
            foreach($file in $op.state.runnerFiles){if((Get-FileHash -LiteralPath (Join-Path $op.directory ('runner\'+$file.name))).Hash -ne $file.sha256){throw 'RUNNER_CHANGED'}}
            $result=Invoke-CourseUninstallApply $OperationId -Resume
        }else{$gate=Get-CourseLifecycleLock;try{$result=Test-CourseUninstallResult $OperationId}finally{Close-CourseLifecycleLock $gate}}
    }
    $result|ConvertTo-Json -Depth 7
    exit $result.exitCode
}catch{
    $message=[string]$_.Exception.Message
    $code=if($message -match 'PLAN_STALE|PLAN_DIGEST_CHANGED'){5}elseif($message -match 'BUSY|RESTART|ELEVATION'){4}elseif($message -match 'INVALID|REQUIRED|MISMATCH|CHANGED|REGISTERED|SELECT_|UNKNOWN|NOT_FOUND|ALREADY_STARTED|IDENTITY|PLAN_|APPLY_'){1}else{3}
    if($message -notmatch '^[A-Z_]+(?:: [a-zA-Z0-9 .,\-/]+)?$'){$message='UNINSTALL_ENTRY_FAILED'}
    @{status='NeedsAction';exitCode=$code;reason=$message}|ConvertTo-Json -Compress
    exit $code
}
