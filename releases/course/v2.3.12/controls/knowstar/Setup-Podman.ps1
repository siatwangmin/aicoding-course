#Requires -Version 5.1
[CmdletBinding()]
param([ValidateSet('Check','Download','Prepare','Verify','InstallSystem')][string]$Mode='Check', [string]$WorkingDirectory,
      [string]$MachineName='podman-machine-default', [string]$InstallerDirectory,
      [string]$StorageRoot, [string]$ExpectedUserSid)
. (Join-Path $PSScriptRoot 'Course-Podman.ps1')

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference='Stop'
    if(-not $WorkingDirectory){$WorkingDirectory=(Get-Location).Path}
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if($ExpectedUserSid -and $ExpectedUserSid -ne $sid){throw 'User changed during elevation; do not prepare another account.'}
    $WorkingDirectory=(Resolve-Path -LiteralPath $WorkingDirectory).Path
    $StorageRoot=Resolve-CourseStorageRoot $WorkingDirectory 'podman' $StorageRoot
    if($Mode -in @('Prepare','InstallSystem')){Assert-CoursePodmanHost}
    if($Mode -in @('Download','Prepare')){
        Save-CoursePodmanInstallers $WorkingDirectory
        if($Mode -eq 'Download'){Write-Host 'Installer downloads verified; installation and runtime are not yet verified.';exit 0}
    }
    if($Mode -eq 'InstallSystem'){exit (Install-CourseSystemPrerequisites $WorkingDirectory)}
    $needsSystem=$false
    if($Mode -eq 'Prepare'){
        $optional=Get-CimInstance Win32_OptionalFeature -Filter "Name='VirtualMachinePlatform'" -ErrorAction Stop
        $needsSystem=-not(Get-SetupWsl).Ready -or $optional.InstallState -ne 1
    }
    if($needsSystem -and -not(Test-SetupAdministrator)){
        Write-Host 'WSL system preparation requires elevation; handle the Windows prompt, then preparation continues.'
        $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-Mode','InstallSystem','-WorkingDirectory',$WorkingDirectory,'-MachineName',$MachineName,'-StorageRoot',$StorageRoot,'-ExpectedUserSid',$sid)
        if($InstallerDirectory){$args+=@('-InstallerDirectory',$InstallerDirectory)}
        Write-CourseJson (Join-Path $WorkingDirectory '.podman-setup\system-install.json') @{stage='SystemInstall';status='AwaitingAuthorization';runtimeVerified=$false;checkedAt=(Get-Date).ToString('o')}
        try{
            $child=Start-Process powershell.exe -ArgumentList (($args|ForEach-Object {ConvertTo-SetupArgument $_}) -join ' ') -Verb RunAs -WindowStyle Hidden -PassThru -Wait
        }catch{
            Write-CourseJson (Join-Path $WorkingDirectory '.podman-setup\system-install.json') @{stage='SystemInstall';status='AuthorizationNotCompleted';runtimeVerified=$false;checkedAt=(Get-Date).ToString('o');next='Keep verified downloads; resume Prepare when the learner can authorize this system step.'}
            throw
        }
        if($child.ExitCode -ne 0){
            if($child.ExitCode -eq 3010){Write-Host 'RESTART_REQUIRED: save work, restart and run the same Prepare command. Verified downloads will be reused.'}
            exit $child.ExitCode
        }
    }elseif($needsSystem){
        $systemCode=Install-CourseSystemPrerequisites $WorkingDirectory
        if($systemCode -ne 0){exit $systemCode}
    }
    exit (Invoke-PodmanSetup (Resolve-Path -LiteralPath $WorkingDirectory).Path $Mode $MachineName $InstallerDirectory)
}
