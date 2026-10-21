#Requires -Version 5.1
# Function library: no parameter block, installation or state mutation on import.
function Test-CoursePodmanProxyPair([string]$Client,[string]$Server) {
    return ($Client -in @('6.0.2','6.1.4') -and $Client -eq $Server) -or ($Client -eq '6.1.4' -and $Server -eq '6.0.2')
}
. (Join-Path $PSScriptRoot 'Course-Native.ps1')
$lifecycleHelper=Join-Path $PSScriptRoot 'Course-Lifecycle.ps1'
if(Test-Path -LiteralPath $lifecycleHelper){. $lifecycleHelper}

function Get-PodmanPaths {
    $registered=Get-CoursePodmanBinding
    $cliPath=$null
    $candidates=@($registered.cli,(Join-Path (Resolve-CourseStorageRoot -RequestedRoot $StorageRoot) 'programs\podman\podman.exe'),"$env:LOCALAPPDATA\Programs\Podman\podman.exe","$env:ProgramFiles\Podman\podman.exe","$env:ProgramFiles\RedHat\Podman\podman.exe")
    $command=Get-Command podman.exe -ErrorAction SilentlyContinue
    if($command){$candidates+=$command.Source}
    foreach($candidate in $candidates){if($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)){$cliPath=$candidate;break}}
    return [pscustomobject]@{Cli=$cliPath;Compose=$registered.compose;DataHome=$registered.dataHome}
}

function Assert-CoursePodmanHost {
    $os=Get-CimInstance Win32_OperatingSystem
    if([int]$os.BuildNumber -lt 22000 -or -not [Environment]::Is64BitOperatingSystem){throw 'Windows 11 x64 is required by this course route.'}
    $system=Get-CimInstance Win32_ComputerSystem
    if(-not $system.HypervisorPresent){
        $cpu=Get-CimInstance Win32_Processor|Select-Object -First 1
        if(-not $cpu.VirtualizationFirmwareEnabled){throw 'Firmware virtualization requires the learner/system administrator; preserve state and resume.'}
    }
}
function Initialize-PodmanPrerequisites([string]$Workspace) {
    Assert-CoursePodmanHost
    $optional=Get-CimInstance Win32_OptionalFeature -Filter "Name='VirtualMachinePlatform'" -ErrorAction Stop
    if((Get-SetupWsl).Ready -and $optional.InstallState -eq 1){return}
    $systemCode=Install-CourseSystemPrerequisites $Workspace
    if($systemCode -eq 3010){throw 'RESTART_REQUIRED: system prerequisites installed; save work, restart and rerun Prepare. No automatic reboot.'}
}
function Get-CourseComponentSources($Entry,[string]$Kind) {
    $origin=switch($Kind){
        wsl {'https://github.com/microsoft/WSL/releases/download/3.0.1/wsl.3.0.1.0.x64.msi'}
        engine {'https://github.com/podman-container-tools/podman/releases/download/v'+$Entry.version+'/'+$Entry.file}
        compose {'https://github.com/docker/compose/releases/download/v'+$Entry.version+'/'+$Entry.file}
    }
    $sources=@($Entry.downloadUrl)+@($Entry.fallbackUrls)
    $sources=@($sources|Where-Object {$_})
    $mirror=switch($Kind){wsl {'wsl.mirror'};engine {'podman.mirror'};compose {'docker-compose.mirror'}}
    $releasePath=$origin -creplace '^https://github\.com/[^/]+/[^/]+/releases/download/',''
    $sourceForge='https://downloads.sourceforge.net/project/'+$mirror+'/'+$releasePath
    $approved=Test-SetupInstallerSources $sources $origin $sourceForge
    if(-not $approved -or $origin -notmatch '^https://github\.com/[^/]+/[^/]+/releases/download/[^/?#]+/[^/?#]+$'){
        throw 'Unapproved Podman component download sources.'
    }
    return $sources
}
function Assert-CourseComponentSignature([string]$File,$Entry) {
    if($Entry.publisher){
        $sig=Get-AuthenticodeSignature -LiteralPath $File
        if($sig.Status -ne 'Valid' -or $sig.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName,$false) -cne $Entry.publisher){throw 'Component publisher mismatch.'}
    }
}
function Resolve-PodmanComponent([string]$Workspace,[ValidateSet('engine','compose','wsl')][string]$Kind){
    . (Join-Path $PSScriptRoot 'Course-Context.ps1')
    $entry=if($Kind -eq 'wsl'){
        $manifest=Join-Path $PSScriptRoot '..\assets\windows-installers.json'
        if(-not(Test-Path -LiteralPath $manifest)){$manifest=Join-Path $PSScriptRoot 'windows-installers.json'}
        (Read-CourseJson $manifest).wsl
    }else{(Get-CoursePodmanManifest).$Kind}
    $sources=@(Get-CourseComponentSources $entry $Kind)
    if($entry.sha256 -notmatch '^[a-f0-9]{64}$' -or [IO.Path]::GetFileName($entry.file) -cne $entry.file){throw 'Unapproved Podman component manifest.'}
    $componentRoot=Resolve-CourseStorageRoot $Workspace 'podman' $StorageRoot
    $plan=Get-CourseStoragePlan $componentRoot
    [void](New-Item -ItemType Directory -Path $plan.installers -Force)
    $file=Join-Path $plan.installers $entry.file
    $componentExisted=Test-Path -LiteralPath $file
    $actualSource=$null;$sourceMode='cache';$attempts=@()
    if(-not(Test-Path -LiteralPath $file) -and $InstallerDirectory){
        $localFile=Join-Path $InstallerDirectory $entry.file
        if(Test-Path -LiteralPath $localFile){
            if((Get-FileHash -LiteralPath $localFile).Hash.ToLowerInvariant() -ne $entry.sha256){throw 'Local component SHA-256 mismatch.'}
            Copy-Item -LiteralPath $localFile -Destination $file
            $sourceMode='local'
        }
    }
    if(-not(Test-Path -LiteralPath $file)){
        $partial=$file+'.partial';$sourceMode='download'
        foreach($url in $sources){
            try{
                if(Test-Path -LiteralPath $partial){Remove-Item -LiteralPath $partial -Force}
                Receive-SetupInstaller $url $partial
                if((Get-FileHash -LiteralPath $partial).Hash.ToLowerInvariant() -ne $entry.sha256){throw 'Component download SHA-256 mismatch.'}
                Assert-CourseComponentSignature $partial $entry
                Move-Item -LiteralPath $partial -Destination $file
                $actualSource=$url;$attempts+=@{source=$url;status='Verified'}
                break
            }catch{
                $attempts+=@{source=$url;status='Failed';error=$_.Exception.Message}
                if(Test-Path -LiteralPath $partial){Remove-Item -LiteralPath $partial -Force}
                Write-Warning ('Component source failed: '+$url+'; '+$_.Exception.Message)
            }
        }
        if(-not $actualSource){throw ('COMPONENT_DOWNLOAD_FAILED: '+(($attempts|ForEach-Object {$_.source+': '+$_.error}) -join '; '))}
    }
    if((Get-FileHash -LiteralPath $file).Hash.ToLowerInvariant() -ne $entry.sha256){throw 'Component SHA-256 mismatch.'}
    Assert-CourseComponentSignature $file $entry
    Write-CourseJson (Join-Path $Workspace ('.podman-setup\installer-'+$Kind+'.json')) @{file=$file;source=$actualSource;sourceMode=$sourceMode;preferredSource=$sources[0];fallbackSources=@($sources|Select-Object -Skip 1);attempts=$attempts;sha256=$entry.sha256;checkedAt=(Get-Date).ToString('o')}
    if(Get-Command Find-CourseInstallation -ErrorAction SilentlyContinue){
        $installation=Find-CourseInstallation $Workspace
        if($installation){$null=Register-CourseResource -InstallationId $installation.installationId -Kind file -Locator $file -Ownership $(if($componentExisted){'reused'}else{'created'}) -DataClass rebuildable -AllowedRoot $plan.installers}
    }
    return $file
}

function Save-CoursePodmanInstallers([string]$Workspace) {
    # One download phase before elevation/restart. Never starts an installer.
    $items=@();$failures=@()
    foreach($kind in @('engine','compose','wsl')){
        try {
            $asset=Resolve-PodmanComponent $Workspace $kind
            $items+=@{kind=$kind;path=$asset;sha256=(Get-FileHash -LiteralPath $asset).Hash.ToLowerInvariant();status='Verified'}
        }catch{$failures+=@{kind=$kind;message=$_.Exception.Message}}
    }
    Write-CourseJson (Join-Path $Workspace '.podman-setup\downloads.json') @{stage='Downloads';status=$(if($failures.Count){'Incomplete'}else{'Verified'});items=$items;failures=$failures;checkedAt=(Get-Date).ToString('o');installationVerified=$false}
    if($failures.Count){throw ('INSTALLER_PREFETCH_INCOMPLETE: '+(($failures|ForEach-Object {$_.kind+': '+$_.message}) -join '; '))}
}

function Install-CourseSystemPrerequisites([string]$Workspace) {
    # This is the only elevated phase. User bindings and machine creation remain
    # in the original user's process; do not elevate the complete preparation.
    if(-not(Test-SetupAdministrator)){throw 'WSL_PREREQUISITES_REQUIRE_ELEVATION'}
    Write-CourseJson (Join-Path $Workspace '.podman-setup\system-install.json') @{stage='SystemInstall';status='Installing';checkedAt=(Get-Date).ToString('o');runtimeVerified=$false}
    try {
    $restart=$false
    $feature=Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction Stop
    if($feature.State -eq 'EnablePending'){$restart=$true}
    elseif($feature.State -ne 'Enabled'){
        $result=Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All -NoRestart -ErrorAction Stop
        $restart=[bool]$result.RestartNeeded
    }
    # WSL MSI may be installed while feature activation awaits a reboot.
    if(-not(Get-SetupWsl).Ready){
        $asset=Resolve-PodmanComponent $Workspace 'wsl'
        $installed=Invoke-SetupNative (Join-Path $env:SystemRoot 'System32\msiexec.exe') @('/i',$asset,'/passive','/norestart','/L*v',(Join-Path $Workspace '.podman-setup\wsl-install.log')) 900
        if($installed.ExitCode -in @(3010,1641)){$restart=$true}
        elseif($installed.ExitCode -ne 0){throw 'WSL installation failed; inspect wsl-install.log; verified downloads retained.'}
    }
    Write-CourseJson (Join-Path $Workspace '.podman-setup\system-install.json') @{stage='SystemInstall';status=$(if($restart){'RestartRequired'}else{'Installed'});restartRequired=$restart;checkedAt=(Get-Date).ToString('o');runtimeVerified=$false}
    if($restart){return 3010}
    if(-not(Get-SetupWsl).Ready){throw 'WSL installation unverified; inspect the installation log.'}
    return 0
    }catch{
        Write-CourseJson (Join-Path $Workspace '.podman-setup\system-install.json') @{stage='SystemInstall';status='Failed';checkedAt=(Get-Date).ToString('o');runtimeVerified=$false;next='Inspect system state and wsl-install.log; preserve verified cache and resume Prepare.'}
        throw
    }
}

function Get-SetupPodman {
    param([string]$Machine='podman-machine-default', [string]$RepairWorkspace)
    $paths=Get-PodmanPaths
    if (-not $paths.Cli) { throw 'Podman CLI is missing; run Setup-Podman.ps1 -Mode Prepare.' }
    $provider=Get-CourseComposeBinding
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
    $engine=$(if($info.Stdout){$info.Stdout}else{$info.Output}) | ConvertFrom-Json
    $compose=Invoke-SetupNative $paths.Cli @('--connection',$connection,'compose','version')
    if ($engine.host.os -ne 'linux' -or $engine.host.arch -ne 'amd64' -or $compose.ExitCode -ne 0) { throw 'Linux amd64 Podman Server and Compose must both be available.' }
    # compose version alone works even when the Windows API forwarding pipe is absent.
    $composeApi=Invoke-SetupNative $paths.Cli @('--connection',$connection,'compose','ls','--format','json')
    if ($composeApi.ExitCode -ne 0 -and $RepairWorkspace) {
        $client=Invoke-SetupNative $paths.Cli @('--version') 15
        $clientVersion=if($client.ExitCode -eq 0 -and $client.Output -match '^podman version ([0-9.]+)'){$Matches[1]}else{$null}
        $pipe=$machineInfo.ConnectionInfo.PodmanPipe.Path
        $helper=Join-Path (Split-Path $paths.Cli -Parent) 'win-sshproxy.exe'
        if ((Test-CoursePodmanProxyPair $clientVersion $engine.version.Version) -and $pipe -eq "\\.\pipe\$Machine" -and -not (Test-Path -LiteralPath $pipe) -and (Test-Path -LiteralPath $helper)) {
            # Helper argument contract checked against official v6.0.2/v6.1.4 source.
            # Restore only the machine's own local pipe; never touch docker_engine or restart workloads.
            $proxyDir=Join-Path $RepairWorkspace ('.podman-setup\api-proxy\'+[guid]::NewGuid().ToString('N'))
            [void](New-Item -ItemType Directory -Path $proxyDir -Force)
            $arguments=@($Machine,$proxyDir,"npipe:////./pipe/$Machine",$local[0].URI,$local[0].Identity)
            $proxy=Start-Process -FilePath $helper -ArgumentList (($arguments | ForEach-Object {ConvertTo-SetupArgument $_}) -join ' ') -WindowStyle Hidden -PassThru
            Write-CourseJson (Join-Path $proxyDir 'launch.json') @{pid=$proxy.Id;machine=$Machine;cliVersion=$clientVersion;serverVersion=$engine.version.Version;pipe=$pipe;helper=$helper;helperSha256=(Get-FileHash -LiteralPath $helper).Hash.ToLowerInvariant();startedAt=(Get-Date).ToString('o');stopCondition='machine stop or owned helper exits; do not kill other processes'}
            for ($attempt=0;$attempt -lt 8;$attempt++) {
                $composeApi=Invoke-SetupNative $paths.Cli @('--connection',$connection,'compose','ls','--format','json')
                if ($composeApi.ExitCode -eq 0) {break}
                Start-Sleep -Milliseconds 250
            }
        }
    }
    if ($composeApi.ExitCode -ne 0) {
        . (Join-Path $PSScriptRoot 'Course-PodmanDiagnostics.ps1')
        $diagnostic=Get-CoursePodmanApiDiagnostic $machineInfo $paths.Cli $connection $composeApi
        if($RepairWorkspace){Write-CourseJson (Join-Path $RepairWorkspace '.podman-setup\api-diagnostic.json') $diagnostic}
        throw 'PODMAN_API_UNAVAILABLE: selected machine API failed; inspect the scoped API diagnostic and restore the original helper/connection. Legacy sockets and workloads were preserved.'
    }
    return [pscustomobject]@{ Cli=$paths.Cli; ComposeBinding=$provider; Machine=$Machine; Connection=$connection; Endpoint=$local[0].URI; ApiEndpoint=("npipe:////./pipe/$Machine");
        ServerVersion=$engine.version.Version; Rootless=[bool]$engine.host.security.rootless; Compose=$compose.Output;
        NetworkMode=$(if($engine.host.security.rootless){'pasta'}else{'bridge'}) }
}

function Invoke-PodmanSetup {
    param([string]$Workspace, [string]$Action='Verify', [string]$Machine='podman-machine-default', [string]$Directory)
    if ($Machine -notmatch '^podman-machine-[a-zA-Z0-9_-]+$') { throw 'Use a local named Podman machine.' }
    $folder=Join-Path $Workspace '.podman-setup'; [void](New-Item -ItemType Directory -Path $folder -Force)
    $record=[ordered]@{CheckedAt=(Get-Date).ToString('o');ContainerRuntime='podman';Mode=$Action;Decision='Incomplete';Machine=$Machine;Snapshot=$null;NotVerified=@()}
    $lifecycleInstallation=if(Get-Command Find-CourseInstallation -ErrorAction SilentlyContinue){Find-CourseInstallation $Workspace}else{$null}
    $lifecycleLease=$null
    if($lifecycleInstallation){$lifecycleLease=Enter-CourseOperation $Workspace 'PreparePodman'}
    try {
        if ($Action -eq 'Prepare') {
            Save-CoursePodmanInstallers $Workspace
            Initialize-PodmanPrerequisites $Workspace
            $paths=Get-PodmanPaths
            . (Join-Path $PSScriptRoot 'Course-Context.ps1');$plan=Get-CourseStoragePlan $StorageRoot
            if (-not $paths.Cli) {
                $msi=Resolve-PodmanComponent $Workspace 'engine'
                if($lifecycleInstallation){$null=Start-CourseCreationIntent $lifecycleInstallation.installationId tool (Join-Path $plan.programs 'podman\podman.exe') $false}
                $install=Invoke-SetupNative (Join-Path $env:SystemRoot 'System32\msiexec.exe') @('/i',$msi,'/passive','/norestart','ALLUSERS=2','MSIINSTALLPERUSER=1',('INSTALLDIR='+(Join-Path $plan.programs 'podman')),'MACHINE_PROVIDER=wsl') 900
                if($install.ExitCode -eq 3010){throw 'Podman engine installed; Windows restart required.'}
                if($install.ExitCode -ne 0){throw 'Podman engine installation failed.'}
                $paths=Get-PodmanPaths
                if($lifecycleInstallation -and $paths.Cli){
                    $identity=Get-CourseMsiIdentity $msi
                    $null=Register-CourseResource -InstallationId $lifecycleInstallation.installationId -Kind tool -Locator $paths.Cli -Ownership created -AllowedRoot (Split-Path $paths.Cli -Parent) -Metadata @{installer='msi';productCode=$identity.ProductCode;productVersion=$identity.ProductVersion;productName=$identity.ProductName;scope='current-user'}
                }
            }
            if(-not $paths.Cli){throw 'Installed engine path not confirmed; do not report readiness.'}
            if(-not $paths.Compose -or -not(Test-Path -LiteralPath $paths.Compose) -or (Get-FileHash -LiteralPath $paths.Compose).Hash.ToLowerInvariant() -cne (Get-CoursePodmanManifest).compose.sha256 -or $paths.Compose -match '(?i)[\\/]Docker[\\/]Docker[\\/]|podman-desktop'){
                $composeAsset=Resolve-PodmanComponent $Workspace 'compose';$composeDir=Join-Path $plan.programs 'compose'
                [void](New-Item -ItemType Directory -Path $composeDir -Force)
                $priorCompose=Join-Path $composeDir 'docker-compose.exe';$priorComposeExisted=Test-Path -LiteralPath $priorCompose
                if($lifecycleInstallation){$null=Start-CourseCreationIntent $lifecycleInstallation.installationId tool $priorCompose ([bool]$priorComposeExisted)}
                if(Test-Path -LiteralPath $priorCompose){Copy-Item -LiteralPath $priorCompose -Destination ($priorCompose+'.backup-'+(Get-Date -Format 'yyyyMMddHHmmssfff'))}
                Copy-Item -LiteralPath $composeAsset -Destination (Join-Path $composeDir 'docker-compose.exe')
                $paths|Add-Member -MemberType NoteProperty -Name Compose -Value (Join-Path $composeDir 'docker-compose.exe') -Force
                if($lifecycleInstallation){$null=Register-CourseResource -InstallationId $lifecycleInstallation.installationId -Kind tool -Locator $paths.Compose -Ownership $(if($priorComposeExisted){'reused'}else{'created'}) -AllowedRoot $composeDir -Metadata @{installer='portable'}}
            }
            $userRoot=Get-CourseUserRoot;Protect-CourseDirectory $userRoot
            $toolPaths=Join-Path $userRoot 'tool-paths.json';$recorded=if(Test-Path -LiteralPath $toolPaths){Read-CourseJson $toolPaths}else{[pscustomobject]@{schemaVersion=2}}
            if(Test-Path -LiteralPath $toolPaths){Copy-Item -LiteralPath $toolPaths -Destination (Join-Path $folder ('tool-paths.backup-'+(Get-Date -Format 'yyyyMMddHHmmssfff')+'.json'))}
            $recorded|Add-Member -MemberType NoteProperty -Name podman -Value @{cli=$paths.Cli;compose=$paths.Compose;storageRoot=$StorageRoot;dataHome=$paths.DataHome} -Force
            Write-CourseJson $toolPaths $recorded
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
                $dataHomeExisted=Test-Path -LiteralPath $dataHome
                [void](New-Item -ItemType Directory -Path $dataHome -Force)
                $recorded.podman['dataHome']=$dataHome;Write-CourseJson $toolPaths $recorded
                if($lifecycleInstallation){$null=Start-CourseCreationIntent $lifecycleInstallation.installationId machine $Machine $false}
                $operation=Invoke-SetupNative $paths.Cli @('machine','init','--image','docker://quay.nju.edu.cn/podman/machine-os:6.1','--rootful=false','--now',$Machine) 900
                if($operation.ExitCode -eq 0 -and $lifecycleInstallation){
                    $inspection=Invoke-SetupNative $paths.Cli @('machine','inspect',$Machine) 20
                    if($inspection.ExitCode -ne 0){throw 'CREATED_MACHINE_UNVERIFIED'}
                    $actual=@($(if($inspection.Stdout){$inspection.Stdout}else{$inspection.Output})|ConvertFrom-Json)[0]
                    $null=Register-CourseResource -InstallationId $lifecycleInstallation.installationId -Kind machine -Locator $Machine -Ownership created -Metadata @{runtime='podman';cli=$paths.Cli;cliHash=(Get-FileHash -LiteralPath $paths.Cli).Hash.ToLowerInvariant();machineName=$Machine;createdAt=[string]$actual.Created;dataHome=$dataHome;dataHomeOwned=(-not $dataHomeExisted);dataHomeParent=$plan.podmanData;provider='wsl'}
                }
            }
            elseif (-not $existing.Running) { $operation=Invoke-SetupNative $paths.Cli @('machine','start',$Machine) 300 }
            if ($operation -and $operation.ExitCode -ne 0) { throw $operation.Output }
        }
        $record.Snapshot=if($Action -eq 'Prepare'){Get-SetupPodman $Machine $Workspace}else{Get-SetupPodman $Machine}
        if($lifecycleInstallation){
            $bindingPaths=Get-PodmanPaths
            foreach($tool in @($bindingPaths.Cli,$bindingPaths.Compose)){
                if($tool -and (Test-Path -LiteralPath $tool)){$null=Register-CourseResource -InstallationId $lifecycleInstallation.installationId -Kind tool -Locator $tool -Ownership reused -AllowedRoot (Split-Path $tool -Parent) -Metadata @{installer='portable'}}
            }
            $null=Register-CourseResource -InstallationId $lifecycleInstallation.installationId -Kind machine -Locator $Machine -Ownership reused -Metadata @{runtime='podman';cli=$bindingPaths.Cli;cliHash=(Get-FileHash -LiteralPath $bindingPaths.Cli).Hash.ToLowerInvariant();machineName=$Machine}
        }
        $record.Decision='Ready'
        return 0
    } catch { $record.NotVerified+= $_.Exception.Message; Write-Host $_.Exception.Message; return 2 }
    finally {
        if($lifecycleLease){Exit-CourseOperation $lifecycleLease}
        $record | ConvertTo-Json -Depth 7 | Set-Content (Join-Path $folder 'report.json') -Encoding UTF8
        $choice=Join-Path $Workspace '.course-setup'; [void](New-Item -ItemType Directory -Path $choice -Force)
        @{ContainerRuntime='podman';Machine=$Machine;SelectedAt=(Get-Date).ToString('o')} | ConvertTo-Json | Set-Content (Join-Path $choice 'container-runtime.json') -Encoding UTF8
    }
}


