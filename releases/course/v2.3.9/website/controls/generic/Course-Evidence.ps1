#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'Course-Context.ps1')
function Get-CourseEvidencePath([string]$Root,[string]$Stage){
    $map=@{tools='toolchain-verification.json';cloudbase='.cloudbase-setup\cloudbase-verification.json';github='.github-setup\github-verification.json';ai='.ai-setup\account-readiness.json';summary='.course-setup\summary-verification.json'}
    if(-not $map.ContainsKey($Stage)){throw 'PREPARATION_STAGE_REQUIRED'}
    return Join-Path $Root $map[$Stage]
}
function Get-CourseRequiredChecks([string]$Stage){
    switch($Stage){
        cloudbase {@('identityVerified','managementAccessVerified','pgCapabilityVerified','publicConfigSaved')}
        github {@('identityVerified','emailVerified')}
        ai {@('identityVerified','billingReviewed')}
        summary {@('skillsVerified','traeLoadObserved','currentResultsReviewed')}
        default {throw 'OBSERVATION_STAGE_REQUIRED'}
    }
}
function Get-CourseObservationTime([string]$Value){
    try{$time=[datetimeoffset]::Parse($Value,[Globalization.CultureInfo]::InvariantCulture)}catch{throw 'EVIDENCE_OBSERVATION_TIME_INVALID'}
    $age=([datetimeoffset]::UtcNow-$time.ToUniversalTime()).TotalHours
    if($age -lt 0 -or $age -gt 24){throw 'EVIDENCE_OBSERVATION_TIME_OUTDATED_OR_FUTURE'}
    return $time.ToUniversalTime()
}
function Write-CourseObservation([string]$Root,[string]$Stage,[string]$Check,[string]$Outcome,[string]$Kind,[string]$Reference){
    $required=@(Get-CourseRequiredChecks $Stage)
    if($Check -notin $required -or $Outcome -notin @('passed','failed','pending') -or $Kind -notin @('command','tool','browser','learner') -or -not $Reference){throw 'ACTUAL_OBSERVATION_FIELDS_REQUIRED'}
    if($Reference -ne (Protect-CourseOutput $Reference)){throw 'OBSERVATION_REFERENCE_CONTAINS_SECRET'}
    $path=Join-Path $Root ('.course-setup\observations\'+$Stage+'.json')
    $old=if(Test-Path -LiteralPath $path){Read-CourseJson $path}else{$null}
    $items=@($old.observations|Where-Object {$_.check -and $_.check -ne $Check})
    $items+=@{check=$Check;outcome=$Outcome;kind=$Kind;reference=$Reference;observedAt=[datetimeoffset]::UtcNow.ToString('o')}
    Write-CourseJson $path @{schemaVersion=1;stage=$Stage;observations=$items}
    return $path
}
function Save-CoursePreparationEvidence([string]$Root,[string]$Stage,[string]$ObservationFile){
    $Root=(Resolve-Path -LiteralPath $Root).Path;Assert-CoursePlainPath $Root
    $input=(Resolve-Path -LiteralPath $ObservationFile).Path;Assert-CoursePlainPath $input
    if(-not $input.StartsWith($Root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'OBSERVATIONS_MUST_BELONG_TO_A'}
    $observed=Read-CourseJson $input
    if($observed.stage -ne $Stage){throw 'OBSERVATION_STAGE_MISMATCH'}
    $required=@(Get-CourseRequiredChecks $Stage);$checks=@{};$sources=@();$earliest=[datetimeoffset]::UtcNow;$confirmed=$null
    foreach($name in $required){
        $items=@($observed.observations|Where-Object {$_.check -eq $name})
        if($items.Count -ne 1 -or $items[0].outcome -ne 'passed'){throw ('ACTUAL_OBSERVATION_REQUIRED:'+ $name)}
        $item=$items[0]
        if($item.kind -notin @('command','tool','browser','learner') -or -not $item.reference){throw ('OBSERVATION_SOURCE_REQUIRED:'+ $name)}
        if($name -eq 'traeLoadObserved' -and $item.kind -ne 'browser'){throw 'TRAE_LOAD_REQUIRES_ACTUAL_OBSERVATION'}
        if($Stage -eq 'ai' -and $item.kind -notin @('browser','learner')){throw 'AI_ACCOUNT_REQUIRES_LEARNER_OR_BROWSER_OBSERVATION'}
        $time=Get-CourseObservationTime $item.observedAt
        if($time -lt $earliest){$earliest=$time}
        if($Stage -eq 'ai' -and $item.kind -eq 'learner'){$confirmed=$time.ToString('o')}
        $reference=[string]$item.reference
        if($reference -ne (Protect-CourseOutput $reference)){throw 'OBSERVATION_REFERENCE_CONTAINS_SECRET'}
        $sources+=@{check=$name;kind=$item.kind;observedAt=$time.ToString('o');reference=$reference}
        $checks[$name]=$true
    }
    if($Stage -eq 'ai' -and -not $confirmed){throw 'LEARNER_CONFIRMATION_REQUIRED'}
    $path=Get-CourseEvidencePath $Root $Stage
    if($path -eq $input){throw 'OBSERVATION_SOURCE_MUST_BE_SEPARATE'}
    # Keep source times: writing a file cannot refresh a stale check into a new success.
    $value=@{schemaVersion=3;stage=$Stage;status='verified';checkedAt=$earliest.ToString('o');recordedAt=[datetimeoffset]::UtcNow.ToString('o');operationId=[guid]::NewGuid().ToString('N');checks=$checks;evidence=$sources;observationFile=$input;observationSha256=(Get-FileHash -LiteralPath $input).Hash.ToLowerInvariant()}
    if($Stage -eq 'ai'){$value.mode='account-readiness';$value.learnerConfirmedAt=$confirmed}
    if(Test-Path -LiteralPath $path){
        $history=Join-Path $Root ('.course-setup\evidence-history\'+$Stage+'-'+[guid]::NewGuid().ToString('N')+'.json')
        Assert-CoursePlainPath $history;[void](New-Item -ItemType Directory -Path (Split-Path $history -Parent) -Force);Copy-Item -LiteralPath $path -Destination $history
    }
    Write-CourseJson $path $value
    return $path
}
function Assert-CourseEvidenceSources($Evidence){
    if($Evidence.schemaVersion -ne 3){return}
    if(-not $Evidence.observationFile -or -not(Test-Path -LiteralPath $Evidence.observationFile -PathType Leaf)){throw 'EVIDENCE_SOURCE_MISSING'}
    Assert-CoursePlainPath $Evidence.observationFile
    if((Get-FileHash -LiteralPath $Evidence.observationFile).Hash.ToLowerInvariant() -ne $Evidence.observationSha256){throw 'EVIDENCE_SOURCE_CHANGED'}
    foreach($item in $Evidence.evidence){[void](Get-CourseObservationTime $item.observedAt)}
}
function Convert-CourseMigrationRecord($Record){
    if($Record.movedAt -and $Record.moveCompletedAt -and [datetimeoffset]::Parse($Record.movedAt) -ne [datetimeoffset]::Parse($Record.moveCompletedAt)){throw 'MIGRATION_TIME_FIELDS_CONFLICT'}
    if(-not $Record.movedAt -and $Record.moveCompletedAt){
        if(-not $Record.distribution -or -not $Record.runtime -or -not $Record.target -or -not $Record.connection -or -not $Record.inventoryBefore){throw 'LEGACY_MIGRATION_PROVENANCE_REQUIRED'}
        $time=[datetimeoffset]::Parse($Record.moveCompletedAt)
        if($time -gt [datetimeoffset]::UtcNow){throw 'MIGRATION_TIME_IN_FUTURE'}
        $Record|Add-Member -MemberType NoteProperty -Name movedAt -Value $time.ToString('o') -Force
        $Record|Add-Member -MemberType NoteProperty -Name fieldMigration -Value @{sourceField='moveCompletedAt';originalValue=$Record.moveCompletedAt;normalizedAt=[datetimeoffset]::UtcNow.ToString('o')} -Force
    }
    return $Record
}
