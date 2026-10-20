#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Destination,[string]$PreparationDirectory)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Course-Context.ps1')
$prepared=Find-CoursePreparation $PreparationDirectory
Assert-CoursePlainPath $Destination
# An explicit allowlist; never export raw reports, service credentials or extra index fields.
$value=@{}
foreach($key in @('schemaVersion','preparationId','registeredAt','userSid','machine','containerRuntime','image','imageDigest','verifiedAt','verificationMethod','networkMode','connection','compose','imageId','archiveSha256','capabilities','storageRoot','storageStatus','desiredStorageRoot','storagePaths')){
    $value[$key]=$prepared.record.$key
}
if(-not $value.verifiedAt -or -not $value.image){throw 'Unverified preparation cannot be exported.'}
Write-CourseJson ([IO.Path]::GetFullPath($Destination)) $value
Write-Output 'Sanitized preparation exported. Recheck local engine/image before use; export does not verify current readiness.'
