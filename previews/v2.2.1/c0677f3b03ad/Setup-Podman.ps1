#Requires -Version 5.1
[CmdletBinding()]
param([ValidateSet('Check','Prepare','Verify')][string]$Mode='Check', [string]$WorkingDirectory,
      [string]$MachineName='podman-machine-default', [string]$InstallerDirectory,
      [string]$StorageRoot='D:\AI-Practice', [string]$ExpectedUserSid)
. (Join-Path $PSScriptRoot 'Course-Podman.ps1')

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference='Stop'
    if(-not $WorkingDirectory){$WorkingDirectory=(Get-Location).Path}
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if($ExpectedUserSid -and $ExpectedUserSid -ne $sid){throw 'User changed during elevation; do not prepare another account.'}
    $needsSystem=$false
    if($Mode -eq 'Prepare'){
        $optional=Get-CimInstance Win32_OptionalFeature -Filter "Name='VirtualMachinePlatform'" -ErrorAction Stop
        $needsSystem=-not(Get-SetupWsl).Ready -or $optional.InstallState -ne 1
    }
    if($needsSystem -and -not(Test-SetupAdministrator)){
        Write-Host 'WSL system preparation requires elevation; handle the Windows prompt, then preparation continues.'
        $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-Mode',$Mode,'-WorkingDirectory',$WorkingDirectory,'-MachineName',$MachineName,'-StorageRoot',$StorageRoot,'-ExpectedUserSid',$sid)
        if($InstallerDirectory){$args+=@('-InstallerDirectory',$InstallerDirectory)}
        $child=Start-Process powershell.exe -ArgumentList (($args|ForEach-Object {ConvertTo-SetupArgument $_}) -join ' ') -Verb RunAs -WindowStyle Hidden -PassThru -Wait
        exit $child.ExitCode
    }
    exit (Invoke-PodmanSetup (Resolve-Path -LiteralPath $WorkingDirectory).Path $Mode $MachineName $InstallerDirectory)
}
