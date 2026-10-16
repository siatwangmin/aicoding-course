#Requires -Version 5.1
[CmdletBinding()]
param([ValidateSet('Check','Prepare','Verify')][string]$Mode='Check', [string]$WorkingDirectory,
      [string]$MachineName='podman-machine-default', [string]$InstallerDirectory,[string]$StorageRoot='D:\AI-Coding')

$podmanInvocation=@{Mode=$Mode;WorkingDirectory=$WorkingDirectory;MachineName=$MachineName;InstallerDirectory=$InstallerDirectory;StorageRoot=$StorageRoot}
. (Join-Path $PSScriptRoot 'Setup-DockerDesktop.ps1')
$Mode=$podmanInvocation.Mode; $WorkingDirectory=$podmanInvocation.WorkingDirectory
$MachineName=$podmanInvocation.MachineName; $InstallerDirectory=$podmanInvocation.InstallerDirectory
$StorageRoot=$podmanInvocation.StorageRoot

function Get-PodmanPaths {
    $registered=$null
    $registry=Join-Path $env:USERPROFILE '.ai-coding\tool-paths.json'
    if(Test-Path -LiteralPath $registry){$registered=(Get-Content -LiteralPath $registry -Raw -Encoding UTF8|ConvertFrom-Json).podman}
    if($registered.dataHome){$env:XDG_DATA_HOME=$registered.dataHome}
    $cli = Get-Command podman.exe -ErrorAction SilentlyContinue
    $cliPath = if ($registered.cli -and (Test-Path -LiteralPath $registered.cli)) { $registered.cli } elseif ($cli) { $cli.Source } else { $null }
    $candidates=@($registered.cli,(Join-Path $StorageRoot 'programs\podman\podman.exe'),"$env:LOCALAPPDATA\Programs\Podman\podman.exe", "$env:ProgramFiles\Podman\podman.exe", "$env:ProgramFiles\RedHat\Podman\podman.exe")
    foreach($key in @('HKCU:\SOFTWARE\Podman','HKLM:\SOFTWARE\Podman')){if(Test-Path $key){$dir=(Get-ItemProperty $key).InstallDir;if($dir){$candidates+=Join-Path $dir 'podman.exe'}}}
    foreach ($candidate in $candidates) {
        if(-not $candidate){continue}
        if (-not $cliPath -and (Test-Path -LiteralPath $candidate)) { $cliPath=$candidate }
    }
    $desktop = @($registered.desktop,(Join-Path $StorageRoot 'programs\podman-desktop\Podman Desktop.exe'),"$env:ProgramFiles\Podman Desktop\Podman Desktop.exe", "$env:LOCALAPPDATA\Programs\Podman Desktop\Podman Desktop.exe", "$env:LOCALAPPDATA\Programs\podman-desktop\Podman Desktop.exe") |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    $compose=if($registered.compose -and (Test-Path -LiteralPath $registered.compose)){$registered.compose}elseif(Get-Command docker-compose.exe -ErrorAction SilentlyContinue){(Get-Command docker-compose.exe).Source}else{$null}
    return [pscustomobject]@{ Cli=$cliPath; Desktop=$desktop; Compose=$compose; DataHome=$registered.dataHome }
}

function Resolve-PodmanComponent([string]$Workspace,[ValidateSet('engine','compose')][string]$Kind){
    . (Join-Path $PSScriptRoot 'Course-Context.ps1')
    $manifest=Join-Path $PSScriptRoot '..\assets\podman-installers.json'
    $entry=(Read-CourseJson $manifest).$Kind
    if($entry.sha256 -notmatch '^[a-f0-9]{64}$' -or $entry.downloadUrl -notmatch '^https://github\.com/(podman-container-tools/podman|docker/compose)/releases/download/'){throw 'Unapproved Podman component manifest.'}
    $plan=Get-CourseStoragePlan $StorageRoot
    [void](New-Item -ItemType Directory -Path $plan.installers -Force)
    $file=Join-Path $plan.installers $entry.file
    if(-not(Test-Path -LiteralPath $file)){
        Receive-SetupInstaller $entry.downloadUrl ($file+'.partial')
        if((Get-FileHash -LiteralPath ($file+'.partial')).Hash.ToLowerInvariant() -ne $entry.sha256){throw 'Component download SHA-256 mismatch.'}
        Move-Item -LiteralPath ($file+'.partial') -Destination $file
    }
    if((Get-FileHash -LiteralPath $file).Hash.ToLowerInvariant() -ne $entry.sha256){throw 'Component SHA-256 mismatch.'}
    if($entry.publisher){$sig=Get-AuthenticodeSignature -LiteralPath $file;if($sig.Status -ne 'Valid' -or $sig.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName,$false) -cne $entry.publisher){throw 'Component publisher mismatch.'}}
    Write-CourseJson (Join-Path $Workspace ('.podman-setup\installer-'+$Kind+'.json')) @{file=$file;source=$entry.downloadUrl;sha256=$entry.sha256;checkedAt=(Get-Date).ToString('o')}
    return $file
}

function Resolve-PodmanInstaller {
    param([string]$Workspace, [string]$Directory)
    $manifest=Join-Path $PSScriptRoot '..\assets\podman-installers.json'
    if (-not (Test-Path -LiteralPath $manifest)) {$manifest=Join-Path $PSScriptRoot 'podman-installers.json'}
    $entry=(Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json).desktop
    if ($entry.sha256 -notmatch '^[a-f0-9]{64}$' -or $entry.downloadUrl -notmatch '^https://github\.com/podman-desktop/podman-desktop/releases/download/v[0-9.]+/podman-desktop-[0-9.]+-setup-x64\.exe$') { throw 'Invalid official Podman installer manifest.' }
    $folders=@($Directory, (Join-Path $Workspace 'release'), (Join-Path $Workspace 'releases'), (Join-Path $Workspace 'software')) | Where-Object { $_ }
    $file=$folders | ForEach-Object { Join-Path $_ $entry.file } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    $source='Local'
    if (-not $file) {
        . (Join-Path $PSScriptRoot 'Course-Context.ps1'); $plan=Get-CourseStoragePlan $StorageRoot; $folder=$plan.installers; [void](New-Item -ItemType Directory -Path $folder -Force)
        $file=Join-Path $folder $entry.file
        $partial=$file+'.partial'
        Receive-SetupInstaller $entry.downloadUrl $partial
        # Exact official asset hash is required before installation, including local copies.
        if ((Get-FileHash -LiteralPath $partial).Hash.ToLowerInvariant() -ne $entry.sha256) { throw 'Podman installer SHA-256 mismatch; partial file retained for diagnosis.' }
        Move-Item -LiteralPath $partial -Destination $file -Force
        $source=$entry.downloadUrl
    }
    if ((Get-FileHash -LiteralPath $file).Hash.ToLowerInvariant() -ne $entry.sha256) { throw 'Podman installer SHA-256 mismatch.' }
    $signature=Get-AuthenticodeSignature -LiteralPath $file
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName,$false) -cne $entry.publisher) { throw 'Podman installer publisher signature mismatch.' }
    $record=Join-Path $Workspace '.podman-setup'; [void](New-Item -ItemType Directory -Path $record -Force)
    @{File=$file;Source=$source;Sha256=$entry.sha256;Publisher=$entry.publisher;CheckedAt=(Get-Date).ToString('o')} |
        ConvertTo-Json | Set-Content (Join-Path $record 'installer-desktop.json') -Encoding UTF8
    return $file
}

function Get-SetupPodman {
    param([string]$Machine='podman-machine-default', [string]$RepairWorkspace)
    $paths=Get-PodmanPaths
    if($paths.Compose){$env:PODMAN_COMPOSE_PROVIDER=$paths.Compose}
    if (-not $paths.Cli -or -not $paths.Desktop) { throw 'Podman Desktop or Podman CLI is missing; follow references/windows-podman-setup.md.' }
    $inspection=Invoke-SetupNative $paths.Cli @('machine','inspect',$Machine)
    if ($inspection.ExitCode -ne 0) { throw "Local Podman machine unavailable: $($inspection.Output)" }
    $machineList=ConvertFrom-Json -InputObject $inspection.Output
    $machineInfo=@($machineList)[0]
    if ($machineInfo.Name -ne $Machine) { throw 'Unexpected Podman machine.' }
    $connection=if ($machineInfo.Rootful) { "$Machine-root" } else { $Machine }
    $connections=Invoke-SetupNative $paths.Cli @('system','connection','list','--format','json')
    if ($connections.ExitCode -ne 0) { throw $connections.Output }
    $connectionList=ConvertFrom-Json -InputObject $connections.Output
    $local=@($connectionList | Where-Object { $_.Name -eq $connection -and $_.IsMachine -eq $true -and $_.URI -match '^ssh://(?:root|user)@127\.0\.0\.1:\d+/run/(?:user/\d+/)?podman/podman\.sock$' })
    if (@($local).Count -ne 1) { throw 'Podman verification requires the selected local machine connection; remote services cannot substitute.' }
    $info=Invoke-SetupNative $paths.Cli @('--connection',$connection,'info','--format','json')
    if ($info.ExitCode -ne 0) { throw $info.Output }
    $engine=$info.Output | ConvertFrom-Json
    $compose=Invoke-SetupNative $paths.Cli @('--connection',$connection,'compose','version')
    if ($engine.host.os -ne 'linux' -or $engine.host.arch -ne 'amd64' -or $compose.ExitCode -ne 0) { throw 'Linux amd64 Podman Server and Compose must both be available.' }
    # compose version alone works even when the Windows API forwarding pipe is absent.
    $composeApi=Invoke-SetupNative $paths.Cli @('--connection',$connection,'compose','ls','--format','json')
    if ($composeApi.ExitCode -ne 0 -and $RepairWorkspace) {
        $pipe=$machineInfo.ConnectionInfo.PodmanPipe.Path
        $helper=Join-Path (Split-Path $paths.Cli -Parent) 'win-sshproxy.exe'
        if ($pipe -eq "\\.\pipe\$Machine" -and -not (Test-Path -LiteralPath $pipe) -and (Test-Path -LiteralPath $helper)) {
            # Arguments match Podman's bundled Windows forwarding helper (v6.0.2).
            # Restore only the machine's own local pipe; never touch docker_engine or restart workloads.
            $proxyDir=Join-Path $RepairWorkspace '.podman-setup\api-proxy'
            [void](New-Item -ItemType Directory -Path $proxyDir -Force)
            $arguments=@($Machine,$proxyDir,"npipe:////./pipe/$Machine",$local[0].URI,$local[0].Identity)
            Start-Process -FilePath $helper -ArgumentList (($arguments | ForEach-Object {ConvertTo-SetupArgument $_}) -join ' ') -WindowStyle Hidden | Out-Null
            for ($attempt=0;$attempt -lt 8;$attempt++) {
                $composeApi=Invoke-SetupNative $paths.Cli @('--connection',$connection,'compose','ls','--format','json')
                if ($composeApi.ExitCode -eq 0) {break}
                Start-Sleep -Milliseconds 250
            }
        }
    }
    if ($composeApi.ExitCode -ne 0) {throw "Compose cannot reach the selected local Podman API: $($composeApi.Output)"}
    return [pscustomobject]@{ Cli=$paths.Cli; Desktop=$paths.Desktop; Machine=$Machine; Connection=$connection; Endpoint=$local.URI;
        ServerVersion=$engine.version.Version; Rootless=[bool]$engine.host.security.rootless; Compose=$compose.Output;
        NetworkMode=$(if($engine.host.security.rootless){'pasta'}else{'bridge'}) }
}

function Invoke-PodmanSetup {
    param([string]$Workspace, [string]$Action='Verify', [string]$Machine='podman-machine-default', [string]$Directory)
    if ($Machine -notmatch '^podman-machine-[a-zA-Z0-9_-]+$') { throw 'Use a local named Podman machine.' }
    $folder=Join-Path $Workspace '.podman-setup'; [void](New-Item -ItemType Directory -Path $folder -Force)
    $record=[ordered]@{CheckedAt=(Get-Date).ToString('o');ContainerRuntime='podman';Mode=$Action;Decision='Incomplete';Machine=$Machine;Snapshot=$null;NotVerified=@()}
    try {
        if ($Action -eq 'Prepare') {
            $paths=Get-PodmanPaths
            . (Join-Path $PSScriptRoot 'Course-Context.ps1');$plan=Get-CourseStoragePlan $StorageRoot
            if (-not $paths.Desktop) {
                $installer=Resolve-PodmanInstaller $Workspace $Directory
                Write-Host 'Installing official Podman Desktop. Any terms or elevation prompt must be handled by the learner.'
                $installed=Invoke-SetupNative $installer @('/S','/currentuser',('/D='+(Join-Path $plan.programs 'podman-desktop'))) 900
                if ($installed.ExitCode -ne 0) { throw $installed.Output }
                $paths=Get-PodmanPaths
            }
            if (-not $paths.Cli) {
                $msi=Resolve-PodmanComponent $Workspace 'engine'
                $install=Invoke-SetupNative (Join-Path $env:SystemRoot 'System32\msiexec.exe') @('/i',$msi,'/passive','/norestart','ALLUSERS=2','MSIINSTALLPERUSER=1',('INSTALLDIR='+(Join-Path $plan.programs 'podman')),'MACHINE_PROVIDER=wsl') 900
                if($install.ExitCode -eq 3010){throw 'Podman engine installed; Windows restart required.'}
                if($install.ExitCode -ne 0){throw 'Podman engine installation failed.'}
                $paths=Get-PodmanPaths
            }
            if(-not $paths.Cli){throw 'Installed engine path not confirmed; do not report readiness.'}
            if(-not $paths.Compose){
                $composeAsset=Resolve-PodmanComponent $Workspace 'compose';$composeDir=Join-Path $plan.programs 'compose'
                [void](New-Item -ItemType Directory -Path $composeDir -Force);Copy-Item -LiteralPath $composeAsset -Destination (Join-Path $composeDir 'docker-compose.exe')
                $paths|Add-Member -MemberType NoteProperty -Name Compose -Value (Join-Path $composeDir 'docker-compose.exe') -Force
            }
            $userRoot=Get-CourseUserRoot;Protect-CourseDirectory $userRoot
            $toolPaths=Join-Path $userRoot 'tool-paths.json';$recorded=if(Test-Path -LiteralPath $toolPaths){Read-CourseJson $toolPaths}else{[pscustomobject]@{schemaVersion=2}}
            $recorded|Add-Member -MemberType NoteProperty -Name podman -Value @{cli=$paths.Cli;desktop=$paths.Desktop;compose=$paths.Compose;storageRoot=$StorageRoot} -Force
            Write-CourseJson $toolPaths $recorded;$env:PODMAN_COMPOSE_PROVIDER=$paths.Compose
            $machines=Invoke-SetupNative $paths.Cli @('machine','list','--format','json')
            if ($machines.ExitCode -ne 0) { throw $machines.Output }
            $machineList=ConvertFrom-Json -InputObject $machines.Output
            $existing=@($machineList | Where-Object Name -eq $Machine)
            $operation=$null
            if (-not $existing) {
                if(@($machineList|Where-Object {$_}).Count -gt 0){throw 'Other machines exist; preserve their data/config and select the intended machine before creating another.'}
                # Podman v6.1.4 env.GetDataDir uses homedir.GetDataHome; set only this process/children.
                # Both the image cache and WSL --import destination then originate on the data drive.
                $dataHome=Join-Path $plan.podmanData 'data-home';Assert-CoursePlainPath $dataHome
                [void](New-Item -ItemType Directory -Path $dataHome -Force);$env:XDG_DATA_HOME=$dataHome
                $recorded.podman['dataHome']=$dataHome;Write-CourseJson $toolPaths $recorded
                $operation=Invoke-SetupNative $paths.Cli @('machine','init','--rootful=false','--now',$Machine) 900
            }
            elseif (-not $existing.Running) { $operation=Invoke-SetupNative $paths.Cli @('machine','start',$Machine) 300 }
            if ($operation -and $operation.ExitCode -ne 0) { throw $operation.Output }
            if ($paths.Desktop -and -not (Get-Process -Name 'Podman Desktop' -ErrorAction SilentlyContinue)) { Start-Process -FilePath $paths.Desktop -WindowStyle Hidden | Out-Null }
        }
        $record.Snapshot=if($Action -eq 'Prepare'){Get-SetupPodman $Machine $Workspace}else{Get-SetupPodman $Machine}
        $record.Decision='Ready'
        return 0
    } catch { $record.NotVerified+= $_.Exception.Message; Write-Host $_.Exception.Message; return 2 }
    finally {
        $record | ConvertTo-Json -Depth 7 | Set-Content (Join-Path $folder 'report.json') -Encoding UTF8
        $choice=Join-Path $Workspace '.course-setup'; [void](New-Item -ItemType Directory -Path $choice -Force)
        @{ContainerRuntime='podman';Machine=$Machine;SelectedAt=(Get-Date).ToString('o')} | ConvertTo-Json | Set-Content (Join-Path $choice 'container-runtime.json') -Encoding UTF8
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference='Stop'
    if (-not $WorkingDirectory) {$WorkingDirectory=(Get-Location).Path}
    exit (Invoke-PodmanSetup (Resolve-Path -LiteralPath $WorkingDirectory).Path $Mode $MachineName $InstallerDirectory)
}
