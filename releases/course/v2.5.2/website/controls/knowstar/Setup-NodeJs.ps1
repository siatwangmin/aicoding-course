#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$WorkingDirectory,[ValidateSet('Prepare','Verify')][string]$Mode='Prepare',[string]$StorageRoot,[string]$InstallerDirectory)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Course-Native.ps1')
. (Join-Path $PSScriptRoot 'Course-Lifecycle.ps1')
. (Join-Path $PSScriptRoot 'Course-Archive.ps1')
. (Join-Path $PSScriptRoot 'Course-NodeJs.ps1')
Invoke-CourseNodeJsSetup -Workspace $WorkingDirectory -Mode $Mode -StorageRoot $StorageRoot -InstallerDirectory $InstallerDirectory | ConvertTo-Json -Depth 6
