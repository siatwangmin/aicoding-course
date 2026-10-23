#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$WorkingDirectory,[Parameter(Mandatory=$true)][ValidateSet('tools','cloudbase','github','summary')][string]$Stage,[string]$ObservationFile,[string]$Check,[ValidateSet('passed','failed','pending')][string]$Outcome='passed',[ValidateSet('command','tool','browser','learner')][string]$Kind,[string]$Reference,[string]$TraeObservationFile)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Course-Evidence.ps1')
$root=(Resolve-Path -LiteralPath $WorkingDirectory).Path;Assert-CoursePlainPath $root
if($Check){
    if($ObservationFile -or $Stage -eq 'tools'){throw 'OBSERVATION_INPUT_MODE_CONFLICT'}
    $trae=$null
    if($TraeObservationFile){
        $path=(Resolve-Path -LiteralPath $TraeObservationFile).Path;Assert-CoursePlainPath $path
        if(-not $path.StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'TRAE_OBSERVATIONS_MUST_BELONG_TO_A'}
        $trae=Read-CourseJson $path
    }
    $ObservationFile=Write-CourseObservation $root $Stage $Check $Outcome $Kind $Reference $trae
    $items=(Read-CourseJson $ObservationFile).observations
    $missing=@(Get-CourseRequiredChecks $Stage|Where-Object {$name=$_;@($items|Where-Object {$_.check -eq $name -and $_.outcome -eq 'passed'}).Count -ne 1})
    if($missing.Count){[pscustomobject]@{status='pending';stage=$Stage;missing=$missing;observationFile=$ObservationFile;nextAction='Complete the actual missing checks, then record their results through this same entry.'}|ConvertTo-Json;return}
}
elseif($TraeObservationFile){throw 'TRAE_OBSERVATION_CHECK_MISMATCH'}
$path=if($Stage -eq 'tools'){Get-CourseEvidencePath $root $Stage}else{
    if(-not $ObservationFile){throw 'ACTUAL_OBSERVATION_FILE_REQUIRED'}
    Save-CoursePreparationEvidence $root $Stage $ObservationFile
}
& (Join-Path $PSScriptRoot 'Invoke-CoursePreparation.ps1') -WorkingDirectory $root -Action Record -Stage $Stage -EvidencePath $path
