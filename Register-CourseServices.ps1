#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$WorkingDirectory,[string]$GithubLogin)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Course-Context.ps1')
Register-CourseServices $WorkingDirectory $GithubLogin | ConvertTo-Json
