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
    $candidates=@($registered.cli,(Join-Path $(if($StorageRoot){$StorageRoot}elseif($registered.storageRoot){$registered.storageRoot}else{'D:\AI-Practice'}) 'programs\podman\podman.exe'),"$env:LOCALAPPDATA\Programs\Podman\podman.exe","$env:ProgramFiles\Podman\podman.exe","$env:ProgramFiles\RedHat\Podman\podman.exe")
    $command=Get-Command podman.exe -ErrorAction SilentlyContinue
    if($command){$candidates+=$command.Source}
    foreach($candidate in $candidates){if($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)){$cliPath=$candidate;break}}
    return [pscustomobject]@{Cli=$cliPath;Compose=$registered.compose;DataHome=$registered.dataHome}
}

function Initialize-PodmanPrerequisites([string]$Workspace) {
    $os=Get-CimInstance Win32_OperatingSystem
    if([int]$os.BuildNumber -lt 22000 -or -not [Environment]::Is64BitOperatingSystem){throw 'Windows 11 x64 is required by this course route.'}
    $system=Get-CimInstance Win32_ComputerSystem
    if(-not $system.HypervisorPresent){
        $cpu=Get-CimInstance Win32_Processor|Select-Object -First 1
        if(-not $cpu.VirtualizationFirmwareEnabled){throw 'Firmware virtualization requires the learner/system administrator; preserve state and resume.'}
    }
    $optional=Get-CimInstance Win32_OptionalFeature -Filter "Name='VirtualMachinePlatform'" -ErrorAction Stop
    if((Get-SetupWsl).Ready -and $optional.InstallState -eq 1){return}
    if(-not(Test-SetupAdministrator)){throw 'WSL_PREREQUISITES_REQUIRE_ELEVATION'}
    $feature=Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction Stop
    if($feature.State -ne 'Enabled'){
        if($feature.State -ne 'EnablePending'){Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All -NoRestart -ErrorAction Stop|Out-Null}
        throw 'RESTART_REQUIRED: VirtualMachinePlatform; save work, restart and rerun Prepare. No automatic reboot.'
    }
    if((Get-SetupWsl).Ready){return}
    $manifest=Join-Path $PSScriptRoot '..\assets\windows-installers.json'
    if(-not(Test-Path -LiteralPath $manifest)){$manifest=Join-Path $PSScriptRoot 'windows-installers.json'}
    $entry=(Read-CourseJson $manifest).wsl
    if($entry.downloadUrl -cne 'https://github.com/microsoft/WSL/releases/download/3.0.1/wsl.3.0.1.0.x64.msi'){throw 'Unapproved WSL asset.'}
    $plan=Get-CourseStoragePlan $StorageRoot
    [void](New-Item -ItemType Directory -Path $plan.installers -Force)
    $asset=Join-Path $plan.installers $entry.file
    if(-not(Test-Path -LiteralPath $asset)){
        Receive-SetupInstaller $entry.downloadUrl ($asset+'.partial')
        if((Get-FileHash -LiteralPath ($asset+'.partial')).Hash.ToLowerInvariant() -cne $entry.sha256){throw 'WSL SHA-256 mismatch.'}
        Move-Item -LiteralPath ($asset+'.partial') -Destination $asset
    }
    if((Get-FileHash -LiteralPath $asset).Hash.ToLowerInvariant() -cne $entry.sha256){throw 'WSL SHA-256 mismatch.'}
    Write-CourseJson (Join-Path $Workspace '.podman-setup\installer-wsl.json') @{path=$asset;sha256=$entry.sha256;source=$entry.downloadUrl;checkedAt=(Get-Date).ToString('o')}
    $installed=Invoke-SetupNative (Join-Path $env:SystemRoot 'System32\msiexec.exe') @('/i',$asset,'/passive','/norestart','/L*v',(Join-Path $Workspace '.podman-setup\wsl-install.log')) 900
    if($installed.ExitCode -in @(3010,1641)){throw 'RESTART_REQUIRED: WSL installed; rerun Prepare after restart.'}
    if($installed.ExitCode -ne 0 -or -not(Get-SetupWsl).Ready){throw 'WSL installation unverified; inspect the installation log.'}
}
function Resolve-PodmanComponent([string]$Workspace,[ValidateSet('engine','compose')][string]$Kind){
    . (Join-Path $PSScriptRoot 'Course-Context.ps1')
    $entry=(Get-CoursePodmanManifest).$Kind
    if($entry.sha256 -notmatch '^[a-f0-9]{64}$' -or $entry.downloadUrl -notmatch '^https://github\.com/(podman-container-tools/podman|docker/compose)/releases/download/'){throw 'Unapproved Podman component manifest.'}
    $plan=Get-CourseStoragePlan $StorageRoot
    [void](New-Item -ItemType Directory -Path $plan.installers -Force)
    $file=Join-Path $plan.installers $entry.file
    $componentExisted=Test-Path -LiteralPath $file
    if(-not(Test-Path -LiteralPath $file) -and $InstallerDirectory){
        $localFile=Join-Path $InstallerDirectory $entry.file
        if(Test-Path -LiteralPath $localFile){
            if((Get-FileHash -LiteralPath $localFile).Hash.ToLowerInvariant() -ne $entry.sha256){throw 'Local component SHA-256 mismatch.'}
            Copy-Item -LiteralPath $localFile -Destination $file
        }
    }
    if(-not(Test-Path -LiteralPath $file)){
        Receive-SetupInstaller $entry.downloadUrl ($file+'.partial')
        if((Get-FileHash -LiteralPath ($file+'.partial')).Hash.ToLowerInvariant() -ne $entry.sha256){throw 'Component download SHA-256 mismatch.'}
        Move-Item -LiteralPath ($file+'.partial') -Destination $file
    }
    if((Get-FileHash -LiteralPath $file).Hash.ToLowerInvariant() -ne $entry.sha256){throw 'Component SHA-256 mismatch.'}
    if($entry.publisher){$sig=Get-AuthenticodeSignature -LiteralPath $file;if($sig.Status -ne 'Valid' -or $sig.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName,$false) -cne $entry.publisher){throw 'Component publisher mismatch.'}}
    Write-CourseJson (Join-Path $Workspace ('.podman-setup\installer-'+$Kind+'.json')) @{file=$file;source=$entry.downloadUrl;sha256=$entry.sha256;checkedAt=(Get-Date).ToString('o')}
    if(Get-Command Find-CourseInstallation -ErrorAction SilentlyContinue){
        $installation=Find-CourseInstallation $Workspace
        if($installation){$null=Register-CourseResource -InstallationId $installation.installationId -Kind file -Locator $file -Ownership $(if($componentExisted){'reused'}else{'created'}) -DataClass rebuildable -AllowedRoot $plan.installers}
    }
    return $file
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
                $operation=Invoke-SetupNative $paths.Cli @('machine','init','--rootful=false','--now',$Machine) 900
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


