#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$WorkingDirectory)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Course-Evidence.ps1')
$root=(Resolve-Path -LiteralPath $WorkingDirectory).Path;Assert-CoursePlainPath $root
$file=Join-Path $root '.course-setup\restart-continuation.json'
if(Test-Path -LiteralPath $file){
    $resume=Read-CourseJson $file
    $record=Read-CourseJson (Join-Path $root '.course-setup\storage-migration.json')
    if($resume.workingDirectory -ne $root -or $resume.distribution -ne $record.distribution -or $resume.runtime -ne $record.runtime -or $resume.target -ne $record.target){throw 'RESTART_CONTINUATION_BINDING_CHANGED'}
    if($record.restartStatus -ne 'verified'){
        & (Join-Path $PSScriptRoot 'Move-CourseWslData.ps1') -WorkingDirectory $root -DistributionName $resume.distribution -ContainerRuntime $resume.runtime -StorageRoot $resume.storageRoot -VerifyAfterRestart|Out-Host
    }
}
& (Join-Path $PSScriptRoot 'Invoke-CoursePreparation.ps1') -WorkingDirectory $root
