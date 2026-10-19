#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$WorkingDirectory,[string]$StorageRoot='D:\AI-Practice',[ValidateSet('docker','podman')][string]$ContainerRuntime='podman',[switch]$Verify,[long]$RequiredBytes=20GB)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Course-Storage.ps1')
$workspace=(Resolve-Path -LiteralPath $WorkingDirectory).Path
if($Verify){
    $result=Test-CourseStorageLocation $workspace $ContainerRuntime $StorageRoot
    $result|ConvertTo-Json -Depth 8
    if($result.status -ne 'verified'){exit 2}
}else{
    $plan=Get-CourseStoragePlan $StorageRoot $RequiredBytes
    foreach($path in @($plan.installers,$plan.programs,$plan.dockerData,$plan.podmanData)){
        # Creating a directory is not installation or proof that data was moved.
        if(($ContainerRuntime -eq 'docker' -and $path -eq $plan.podmanData) -or ($ContainerRuntime -eq 'podman' -and $path -eq $plan.dockerData)){continue}
        [void](New-Item -ItemType Directory -Path $path -Force)
    }
    Write-CourseJson (Join-Path $workspace '.course-setup\storage-plan.json') $plan
    $plan|ConvertTo-Json
}
