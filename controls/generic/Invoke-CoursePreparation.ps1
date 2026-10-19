#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$WorkingDirectory,[ValidateSet('Status','Record')][string]$Action='Status',
      [ValidateSet('tools','cloudbase','github','ai','summary')][string]$Stage,[string]$EvidencePath,[ValidateSet('tools','cloudbase','github','ai','summary')][string[]]$RequiredStages)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Course-Context.ps1')
. (Join-Path $PSScriptRoot 'Course-Evidence.ps1')
$root=(Resolve-Path -LiteralPath $WorkingDirectory).Path;Assert-CoursePlainPath $root
$file=Join-Path $root '.course-setup\preparation-progress.json'
$canonicalOrder=@('tools','cloudbase','github','ai','summary')
$skills=@{tools='ai-coding-env';cloudbase='ai-coding-cloudbase';github='ai-coding-github';ai='ai-coding-siliconflow';summary='ai-coding-env'}
$state=if(Test-Path -LiteralPath $file){Read-CourseJson $file}else{[pscustomobject]@{schemaVersion=2;runId=[guid]::NewGuid().ToString();stages=[pscustomobject]@{}}}
if($PSBoundParameters.ContainsKey('RequiredStages')){$selected=@('tools')+@($RequiredStages)+@('summary')}elseif($state.requiredStages){$selected=@($state.requiredStages)}else{$selected=@($canonicalOrder)}
$order=@($canonicalOrder|Where-Object {$selected -contains $_})
$state|Add-Member NoteProperty requiredStages $order -Force
function Test-PreparationStage([string]$Name,$Item){
    if(-not $Item -or -not(Test-Path -LiteralPath $Item.path)){return $false}
    Assert-CoursePlainPath $Item.path
    if((Get-FileHash -LiteralPath $Item.path).Hash.ToLowerInvariant() -ne $Item.sha256){return $false}
    $e=Read-CourseJson $Item.path
    try{Assert-CourseEvidenceSources $e}catch{return $false}
    $time=if($Name -eq 'tools'){$e.VerifiedAt}else{$e.checkedAt}
    try{$age=((Get-Date)-[datetime]::Parse($time)).TotalHours}catch{return $false}
    if($age -lt 0 -or $age -gt 24){return $false}
    if($Name -eq 'tools'){
        if(-not $e.VerifiedAt -or $e.ToolchainCheck.ExitCode -ne 0 -or -not $e.SkillInstallationVerified){return $false}
        $storage=Join-Path $root '.course-setup\storage.json'
        if(-not(Test-Path -LiteralPath $storage) -or (Read-CourseJson $storage).status -ne 'verified'){return $false}
        $migration=Join-Path $root '.course-setup\storage-migration.json'
        if(Test-Path -LiteralPath $migration){try{$m=Convert-CourseMigrationRecord (Read-CourseJson $migration)}catch{return $false};if($m.movedAt -and $m.restartStatus -ne 'verified'){return $false}}
        if($e.ContainerRuntime -eq 'podman'){
            try{
                . (Join-Path $PSScriptRoot 'Course-Native.ps1')
                $binding=Get-CoursePodmanBinding
                if(-not $binding.cli -or -not(Test-Path -LiteralPath $binding.cli) -or -not $binding.dataHome -or -not(Test-Path -LiteralPath $binding.dataHome)){return $false}
                $provider=Get-CourseComposeBinding
                if($provider.sha256 -ne $e.ComposeBinding.sha256 -or $provider.path -ne $e.ComposeBinding.path){return $false}
            }catch{return $false}
        }
        return $true
    }
    if($Name -eq 'ai'){
        if($e.mode -eq 'account-readiness'){
            try{$confirmed=[datetime]::Parse($e.learnerConfirmedAt);$validConfirmation=$confirmed -le (Get-Date) -and $confirmed -ge [datetime]::Parse($e.checkedAt).AddHours(-24)}catch{$validConfirmation=$false}
            return $e.status -eq 'verified' -and $e.checks.identityVerified -eq $true -and $e.checks.billingReviewed -eq $true -and $validConfirmation -and @($e.evidence).Count -gt 0
        }
        # Explicitly retained legacy service evidence is not required for new course preparation.
        return $e.credentials -eq 'passed' -and $e.text.status -eq 'passed' -and $e.vision.status -eq 'passed'
    }
    $required=switch($Name){cloudbase{@('identityVerified','managementAccessVerified','pgCapabilityVerified','publicConfigSaved')}github{@('identityVerified','emailVerified')}summary{@('skillsVerified','traeLoadObserved','currentResultsReviewed')}}
    return $e.status -eq 'verified' -and @($required|Where-Object {$e.checks.$_ -ne $true}).Count -eq 0 -and @($e.evidence).Count -gt 0
}
if($Action -eq 'Record'){
    if(-not $Stage){throw 'PREPARATION_STAGE_REQUIRED'}
    if(-not $EvidencePath){$EvidencePath=Get-CourseEvidencePath $root $Stage}
    $path=(Resolve-Path -LiteralPath $EvidencePath).Path;Assert-CoursePlainPath $path
    if(-not $path.StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Preparation evidence must belong to A.'}
    $item=[pscustomobject]@{path=$path;sha256=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()}
    if(-not(Test-PreparationStage $Stage $item)){throw ('PREPARATION_EVIDENCE_INVALID:'+ $Stage+': verify the current source, required checks, age and migration/runtime binding; do not edit timestamps to pass.')}
    $state.stages|Add-Member -MemberType NoteProperty -Name $Stage -Value $item -Force
    Write-CourseEvent $root @{operationId=$state.runId;stage=$Stage;action='PreparationRecord';status='verified';evidence=$path}
}
$pending=@($order|Where-Object {-not(Test-PreparationStage $_ $state.stages.$_)})
$next=if($pending.Count){$pending[0]}else{$null}
$state|Add-Member -MemberType NoteProperty -Name status -Value $(if($next){'pending'}else{'verified'}) -Force
$state|Add-Member -MemberType NoteProperty -Name checkedAt -Value (Get-Date).ToString('o') -Force
Write-CourseJson $file $state
$materialsFile=Join-Path $root '.course-setup/materials.json'
$materials=if(Test-Path -LiteralPath $materialsFile){Read-CourseJson $materialsFile}else{$null}
[pscustomobject]@{status=$state.status;courseVersion=$materials.CourseVersion;distributionStatus=$materials.DistributionStatus;releaseId=$materials.ReleaseId;nextStage=$next;nextSkill=$(if($next){$skills[$next]}else{$null});pending=$pending;record=$file}|ConvertTo-Json
# A continuation plan, not an automatic authorization/login or product acceptance.
