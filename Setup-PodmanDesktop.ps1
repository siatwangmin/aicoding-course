#Requires -Version 5.1
# Legacy entry point: retained for existing packages; no Desktop is installed or started.
[CmdletBinding()]
param([ValidateSet('Check','Prepare','Verify')][string]$Mode='Check',[string]$WorkingDirectory,
      [string]$MachineName='podman-machine-default',[string]$InstallerDirectory,[string]$StorageRoot='D:\AI-Practice')
if($MyInvocation.InvocationName -eq '.'){
    . (Join-Path $PSScriptRoot 'Course-Podman.ps1') @PSBoundParameters
}else{
    & (Join-Path $PSScriptRoot 'Setup-Podman.ps1') @PSBoundParameters
    exit $LASTEXITCODE
}
