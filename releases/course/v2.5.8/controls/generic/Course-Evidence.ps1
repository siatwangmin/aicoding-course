#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'Course-Context.ps1')
function Get-CourseEvidencePath([string]$Root,[string]$Stage){
    $map=@{tools='toolchain-verification.json';cloudbase='.cloudbase-setup\cloudbase-verification.json';github='.github-setup\github-verification.json';summary='.course-setup\summary-verification.json'}
    if(-not $map.ContainsKey($Stage)){throw 'PREPARATION_STAGE_REQUIRED'}
    return Join-Path $Root $map[$Stage]
}
function Get-CourseRequiredChecks([string]$Stage){
    switch($Stage){
        cloudbase {@('identityVerified','managementAccessVerified','pgCapabilityVerified','publicConfigSaved')}
        github {@('identityVerified','emailVerified','cliAvailable','cliAuthVerified','gitCredentialConfigured')}
        summary {@('skillsVerified','traeLoadObserved','currentResultsReviewed')}
        default {throw 'OBSERVATION_STAGE_REQUIRED'}
    }
}
function Get-CourseObservationTime($Value){
    try{
        # PS7 may deserialize JSON timestamps as DateTime; preserve ticks/zone.
        $time=if($Value -is [datetimeoffset]){$Value}elseif($Value -is [datetime]){[datetimeoffset]$Value}else{[datetimeoffset]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture)}
    }catch{throw 'EVIDENCE_OBSERVATION_TIME_INVALID'}
    $age=([datetimeoffset]::UtcNow-$time.ToUniversalTime()).TotalHours
    if($age -lt 0 -or $age -gt 24){throw 'EVIDENCE_OBSERVATION_TIME_OUTDATED_OR_FUTURE'}
    return $time.ToUniversalTime()
}
function Assert-CourseTraeLoadObservation([string]$Root,$Item) {
    if($Item.kind -notin @('tool','learner')){throw 'TRAE_LOAD_REQUIRES_SESSION_OR_LEARNER: website/browser and file-existence checks do not prove IDE discovery.'}
    $seen=$Item.traeObservation
    if(-not $seen -or $seen.schemaVersion -ne 1 -or $seen.newSession -ne $true -or -not $seen.sessionLabel -or ([string]$seen.sessionLabel).Length -gt 160){throw 'TRAE_SESSION_OBSERVATION_REQUIRED'}
    $method=if($Item.kind -eq 'learner'){'learner-confirmation'}else{'trae-session'}
    if($seen.method -cne $method){throw 'TRAE_SESSION_SOURCE_MISMATCH'}
    if(-not $Root -or -not $seen.workspace -or -not [IO.Path]::IsPathRooted($seen.workspace) -or [IO.Path]::GetFullPath($seen.workspace).TrimEnd('\') -ine [IO.Path]::GetFullPath($Root).TrimEnd('\')){throw 'TRAE_WORKSPACE_MISMATCH'}
    $time=Get-CourseObservationTime $seen.observedAt
    if($time -ne (Get-CourseObservationTime $Item.observedAt)){throw 'TRAE_SESSION_TIME_MISMATCH'}
    $skills=Read-CourseJson (Join-Path $Root '.course-setup\skills-verification.json')
    if(-not $skills.ScopedInstallationVerified){throw 'TRAE_SCOPED_SKILLS_NOT_VERIFIED'}
    foreach($name in @('ai-coding-project','ai-coding-github','ai-coding-cloudbase','ai-coding-android','ai-coding-env')){
        $expected=@($skills.Checks|Where-Object Name -eq $name)
        $loaded=@($seen.loadedSkills|Where-Object name -eq $name)
        if($expected.Count -ne 1 -or -not $expected[0].ContentVerified -or $loaded.Count -ne 1){throw ('TRAE_SKILL_NOT_OBSERVED: '+$name)}
        $scope=if($name -eq 'ai-coding-env'){'Preparation'}else{'User'}
        $directory=[string]$loaded[0].directory
        if($loaded[0].scope -cne $scope -or -not [IO.Path]::IsPathRooted($directory) -or [IO.Path]::GetFullPath($directory) -ine [IO.Path]::GetFullPath($expected[0].ExpectedDirectory)){throw ('TRAE_SKILL_SCOPE_MISMATCH: '+$name)}
        $path=Join-Path $directory 'SKILL.md';Assert-CoursePlainPath $path
        if(-not(Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -cne $loaded[0].sha256){throw ('TRAE_SKILL_CONTENT_CHANGED: '+$name)}
    }
    foreach($relative in @('AGENTS.md','.trae/rules/course-preparation.md')){
        $loaded=@($seen.loadedRules|Where-Object path -ceq $relative)
        if($loaded.Count -ne 1){throw ('TRAE_RULE_NOT_OBSERVED: '+$relative)}
        $path=Join-Path $Root $relative;Assert-CoursePlainPath $path
        if(-not(Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -cne $loaded[0].sha256){throw ('TRAE_RULE_CONTENT_CHANGED: '+$relative)}
    }
}
function Assert-CourseLearnerReview($Item){
    if($Item.kind -ne 'learner' -or -not $Item.reference){throw 'SUMMARY_REQUIRES_LEARNER_OBSERVATION'}
}
function Write-CourseObservation([string]$Root,[string]$Stage,[string]$Check,[string]$Outcome,[string]$Kind,[string]$Reference,$TraeObservation){
    $required=@(Get-CourseRequiredChecks $Stage)
    if($Check -notin $required -or $Outcome -notin @('passed','failed','pending') -or $Kind -notin @('command','tool','browser','learner') -or -not $Reference){throw 'ACTUAL_OBSERVATION_FIELDS_REQUIRED'}
    if($Reference -ne (Protect-CourseOutput $Reference)){throw 'OBSERVATION_REFERENCE_CONTAINS_SECRET'}
    if($Check -eq 'currentResultsReviewed' -and $Outcome -eq 'passed'){Assert-CourseLearnerReview ([pscustomobject]@{kind=$Kind;reference=$Reference})}
    $path=Join-Path $Root ('.course-setup\observations\'+$Stage+'.json')
    $old=if(Test-Path -LiteralPath $path){Read-CourseJson $path}else{$null}
    $items=@($old.observations|Where-Object {$_.check -and $_.check -ne $Check})
    $item=@{check=$Check;outcome=$Outcome;kind=$Kind;reference=$Reference;observedAt=[datetimeoffset]::UtcNow.ToString('o')}
    if($TraeObservation -and ($Stage -ne 'summary' -or $Check -ne 'traeLoadObserved')){throw 'TRAE_OBSERVATION_CHECK_MISMATCH'}
    if($Check -eq 'traeLoadObserved' -and $Outcome -eq 'passed'){
        $item.traeObservation=$TraeObservation
        if($TraeObservation){$item.observedAt=$TraeObservation.observedAt}
        Assert-CourseTraeLoadObservation $Root ([pscustomobject]$item)
    }
    $items+=@($item)
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
        if($Stage -eq 'github' -and $name -in @('cliAvailable','cliAuthVerified','gitCredentialConfigured') -and $item.kind -ne 'command'){throw 'GITHUB_CLI_REQUIRES_COMMAND_OBSERVATION'}
        if($name -eq 'traeLoadObserved'){Assert-CourseTraeLoadObservation $Root $item}
        if($name -eq 'currentResultsReviewed'){Assert-CourseLearnerReview $item}
        $time=Get-CourseObservationTime $item.observedAt
        if($time -lt $earliest){$earliest=$time}
        $reference=[string]$item.reference
        if($reference -ne (Protect-CourseOutput $reference)){throw 'OBSERVATION_REFERENCE_CONTAINS_SECRET'}
        $source=@{check=$name;kind=$item.kind;observedAt=$time.ToString('o');reference=$reference}
        if($name -eq 'traeLoadObserved'){$source.traeObservation=$item.traeObservation}
        $sources+=@($source)
        $checks[$name]=$true
    }
    $path=Get-CourseEvidencePath $Root $Stage
    if($path -eq $input){throw 'OBSERVATION_SOURCE_MUST_BE_SEPARATE'}
    # Keep source times: writing a file cannot refresh a stale check into a new success.
    $value=@{schemaVersion=3;stage=$Stage;status='verified';checkedAt=$earliest.ToString('o');recordedAt=[datetimeoffset]::UtcNow.ToString('o');operationId=[guid]::NewGuid().ToString('N');checks=$checks;evidence=$sources;observationFile=$input;observationSha256=(Get-FileHash -LiteralPath $input).Hash.ToLowerInvariant()}
    if(Test-Path -LiteralPath $path){
        $history=Join-Path $Root ('.course-setup\evidence-history\'+$Stage+'-'+[guid]::NewGuid().ToString('N')+'.json')
        Assert-CoursePlainPath $history;[void](New-Item -ItemType Directory -Path (Split-Path $history -Parent) -Force);Copy-Item -LiteralPath $path -Destination $history
    }
    Write-CourseJson $path $value
    return $path
}
function Assert-CourseEvidenceSources($Evidence,[string]$Root){
    if($Evidence.stage -eq 'summary' -or $Evidence.checks.traeLoadObserved){
        $items=@($Evidence.evidence|Where-Object check -eq 'traeLoadObserved')
        if($items.Count -ne 1){throw 'TRAE_SESSION_OBSERVATION_REQUIRED'}
        Assert-CourseTraeLoadObservation $Root $items[0]
        $reviews=@($Evidence.evidence|Where-Object check -eq 'currentResultsReviewed')
        if($reviews.Count -ne 1){throw 'SUMMARY_REQUIRES_LEARNER_OBSERVATION'}
        Assert-CourseLearnerReview $reviews[0]
    }
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
