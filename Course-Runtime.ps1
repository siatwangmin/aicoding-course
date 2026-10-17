#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'Course-Context.ps1')
. (Join-Path $PSScriptRoot 'Course-ProjectRoot.ps1')
. (Join-Path $PSScriptRoot 'Course-Docker.ps1')
$lifecycle=Join-Path $PSScriptRoot 'Course-Lifecycle.ps1'
if(Test-Path -LiteralPath $lifecycle){. $lifecycle}
function Test-CourseSourceMount([string]$Actual,[string]$Expected) {
    if($Actual -match '^/(?:run/desktop/mnt/host|mnt|host_mnt)/([a-zA-Z])/(.*)$'){
        $Actual=$Matches[1]+':\'+($Matches[2] -replace '/','\')
    }
    return [IO.Path]::GetFullPath($Actual).TrimEnd('\') -eq [IO.Path]::GetFullPath($Expected).TrimEnd('\')
}
function Get-CourseProjectRuntime([string]$Root,[switch]$Start,[switch]$ForDependencyMaintenance) {
    $Root=Resolve-CourseProjectRoot $Root
    if(Get-Command Assert-CourseInstallationActive -ErrorAction SilentlyContinue){Assert-CourseInstallationActive $Root}
    $lifecycleLease=$null
    if(Get-Command Enter-CourseOperation -ErrorAction SilentlyContinue){$lifecycleLease=Enter-CourseOperation $Root 'Runtime'}
    try{
    $p=Read-CourseJson (Join-Path $Root '.ai-coding\project.json')
    $composeBinding=$null
    if($p.containerRuntime -notin @('docker','podman') -or -not $p.image -or -not $p.toolchain.imageDigest){throw 'PROJECT_TOOLCHAIN_BINDING_REQUIRED'}
    if($p.containerRuntime -eq 'docker'){
        $paths=Get-SetupDockerPaths;$cli=$paths.Cli;$prefix=@('--host','npipe:////./pipe/dockerDesktopLinuxEngine')
        if(-not $cli){throw 'DOCKER_CLI_UNAVAILABLE'}
        $ready=Invoke-SetupNative $cli ($prefix+@('info','--format','json')) 20
        if($ready.ExitCode -ne 0 -and $Start){
            if(-not $paths.Desktop){throw 'DOCKER_DESKTOP_PATH_UNAVAILABLE'}
            Start-Process -FilePath $paths.Desktop -WindowStyle Hidden|Out-Null
            for($i=0;$i -lt 12;$i++){
                Start-Sleep -Seconds 2
                $ready=Invoke-SetupNative $cli ($prefix+@('info','--format','json')) 10
                if($ready.ExitCode -eq 0){break}
            }
        }
    }else{
        . (Join-Path $PSScriptRoot 'Course-Podman.ps1')
        $paths=Get-PodmanPaths;$cli=$paths.Cli
        $composeBinding=Get-CourseComposeBinding
        if(-not $cli -or $p.connection -notmatch '^podman-machine-[a-zA-Z0-9_-]+$'){throw 'PODMAN_LOCAL_CONNECTION_REQUIRED'}
        $prefix=@('--connection',$p.connection)
        $ready=Invoke-SetupNative $cli ($prefix+@('info','--format','json')) 20
        if($ready.ExitCode -ne 0 -and $Start){
            $machine=$p.connection -replace '-root$',''
            $inspect=Invoke-SetupNative $cli @('machine','inspect',$machine) 15
            if($inspect.ExitCode -ne 0){throw 'EXISTING_PODMAN_MACHINE_REQUIRED'}
            $started=Invoke-SetupNative $cli @('machine','start',$machine) 180
            if($started.ExitCode -ne 0){throw 'PODMAN_MACHINE_START_FAILED'}
            $ready=Invoke-SetupNative $cli ($prefix+@('info','--format','json')) 20
        }
    }
    if($ready.ExitCode -ne 0){throw 'LOCAL_ENGINE_UNAVAILABLE_NO_HOST_FALLBACK'}
    if($p.containerRuntime -eq 'podman'){
        $machine=$p.connection -replace '-root$',''
        $verified=if($Start){Get-SetupPodman $machine $Root}else{Get-SetupPodman $machine}
        if($verified.Connection -ne $p.connection){throw 'PODMAN_PREPARATION_CONNECTION_CHANGED'}
    }
    $info=$(if($ready.Stdout){$ready.Stdout}else{$ready.Output})|ConvertFrom-Json
    if($p.containerRuntime -eq 'docker'){$os=$info.OSType;$arch=$info.Architecture}else{$os=$info.host.os;$arch=$info.host.arch}
    if($os -ne 'linux' -or $arch -notin @('amd64','x86_64')){throw 'LOCAL_LINUX_AMD64_REQUIRED'}
    $image=Invoke-SetupNative $cli ($prefix+@('image','inspect',$p.image)) 20
    if($image.ExitCode -ne 0){throw 'PREPARED_IMAGE_UNAVAILABLE'}
    $actual=@($(if($image.Stdout){$image.Stdout}else{$image.Output})|ConvertFrom-Json)[0]
    $digest=@($actual.RepoDigests|Where-Object {$_ -like ('*@'+$p.toolchain.imageDigest)}).Count -gt 0
    $offline=$p.toolchain.verificationMethod -eq 'archive-sha256+image-config' -and $actual.Id -eq $p.toolchain.imageId -and $p.toolchain.archiveSha256 -match '^[a-f0-9]{64}$'
    if($actual.Os -ne 'linux' -or $actual.Architecture -ne 'amd64' -or (-not $digest -and -not $offline)){throw 'PREPARED_IMAGE_MISMATCH'}
    $prior=(Get-Location).Path
    try{
        Set-Location -LiteralPath $Root
        $configured=Invoke-SetupNative $cli ($prefix+@('compose','config','--format','json')) 30 $Root
        if($configured.ExitCode -ne 0){throw 'COMPOSE_CONFIG_UNAVAILABLE'}
        $app=(ConvertFrom-CourseComposeJson $(if($configured.Stdout){$configured.Stdout}else{$configured.Output})).services.app
        if($app.image -ne $p.image -or $app.build){throw 'COMPOSE_IMAGE_MISMATCH'}
        $source=[IO.Path]::GetFullPath((Join-Path $Root $p.sourceDirectory));Assert-CoursePlainPath $source
        if($source -ne $Root -and -not $source.StartsWith($Root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'SOURCE_ESCAPES_PROJECT'}
        if(-not @($app.volumes|Where-Object {$_.type -eq 'bind' -and $_.target -eq '/workspace' -and [IO.Path]::GetFullPath($_.source) -eq $source}).Count){throw 'COMPOSE_SOURCE_MISMATCH'}
        if(-not @($app.volumes|Where-Object {$_.type -eq 'volume' -and $_.target -eq '/workspace/node_modules'}).Count){throw 'ISOLATED_DEPENDENCY_VOLUME_REQUIRED'}
        if($app.environment -and @($app.environment.Keys|Where-Object {$_ -match 'SILICONFLOW_API_KEY|TENCENTCLOUD_SECRET|CLOUDBASE_SECRET'}).Count){throw 'SERVER_SECRET_IN_APP_CONTAINER'}
        # Recovery must work even when the development process cannot start.
        if($ForDependencyMaintenance){return [pscustomobject]@{Root=$Root;Source=$source;Project=$p;Cli=$cli;Prefix=$prefix;ImageId=$actual.Id;CheckedAt=(Get-Date).ToString('o')}}
        $lifecycleBeforeContainers=@();$lifecycleBeforeVolumes=@();$lifecycleBeforeNetworks=@()
        $lifecycleRuntimeIntent=$null
        $lifecycleInstallation=if($p.installationId){Get-CourseInstallation $p.installationId}else{$null}
        if($lifecycleInstallation -and $Start){
            $all=Invoke-SetupNative $cli ($prefix+@('ps','-a','--no-trunc','--format','{{.ID}}')) 20
            $volumes=Invoke-SetupNative $cli ($prefix+@('volume','ls','-q')) 20
            $networks=Invoke-SetupNative $cli ($prefix+@('network','ls','--format','{{.Name}}')) 20
            if($all.ExitCode -ne 0 -or $volumes.ExitCode -ne 0 -or $networks.ExitCode -ne 0){throw 'RUNTIME_OWNERSHIP_SNAPSHOT_FAILED'}
            $lifecycleBeforeContainers=@($all.Output -split '\r?\n');$lifecycleBeforeVolumes=@($volumes.Output -split '\r?\n');$lifecycleBeforeNetworks=@($networks.Output -split '\r?\n')
            $lifecycleRuntimeIntent=Start-CourseCreationIntent $p.installationId runtimeGroup $Root $true
        }
        if($Start){
            $up=Invoke-SetupNative $cli ($prefix+@('compose','up','-d','--pull','never','--no-build','--wait','--wait-timeout','90','app')) 180 $Root
            if($up.ExitCode -ne 0){throw 'PROJECT_CONTAINER_START_FAILED'}
        }
        if($p.containerRuntime -in @('docker','podman')){
            $ids=Invoke-SetupNative $cli ($prefix+@('compose','ps','-q','app')) 20 $Root
            if($ids.ExitCode -ne 0){throw 'PROJECT_CONTAINER_LOOKUP_FAILED'}
            $containerIds=@($(if($ids.Stdout){$ids.Stdout}else{$ids.Output}) -split '\r?\n'|Where-Object {$_ -match '^[a-f0-9]{12,64}$'})
            if($containerIds.Count -ne 1){throw 'EXPECTED_ONE_PROJECT_APP_CONTAINER'}
            $inspected=Invoke-SetupNative $cli ($prefix+@('inspect',$containerIds[0])) 20 $Root
            if($inspected.ExitCode -ne 0){throw 'PROJECT_CONTAINER_INSPECT_FAILED'}
            $parsedContainer=ConvertFrom-Json -InputObject $(if($inspected.Stdout){$inspected.Stdout}else{$inspected.Output})
            $container=@($parsedContainer)[0]
            if(($container.Image -replace '^sha256:','') -ne ($actual.Id -replace '^sha256:','')){throw 'RUNNING_CONTAINER_IMAGE_MISMATCH'}
            if(-not @($container.Mounts|Where-Object {$_.Destination -eq '/workspace' -and $_.Type -eq 'bind' -and (Test-CourseSourceMount $_.Source $source)}).Count -or
               -not @($container.Mounts|Where-Object {$_.Destination -eq '/workspace/node_modules' -and $_.Type -eq 'volume'}).Count){throw 'ACTUAL_CONTAINER_MOUNT_MISMATCH'}
            if($Start){
                $probeDir=Join-Path $source '.local';Assert-CoursePlainPath $probeDir
                [void](New-Item -ItemType Directory -Path $probeDir -Force)
                $probeName='course-mount-'+[guid]::NewGuid().ToString('N')
                $probeFile=Join-Path $probeDir $probeName;$probeValue=[guid]::NewGuid().ToString('N')
                try{
                    [IO.File]::WriteAllText($probeFile,$probeValue)
                    $code='const fs=require("fs"),p="/workspace/.local/"+process.argv[1],v=process.argv[2];if(fs.readFileSync(p,"utf8")!==v)process.exit(2);fs.writeFileSync(p+".back",v)'
                    $roundtrip=Invoke-SetupNative $cli ($prefix+@('compose','exec','-T','app','node','-e',$code,$probeName,$probeValue)) 20 $Root
                    if($roundtrip.ExitCode -ne 0 -or -not(Test-Path -LiteralPath ($probeFile+'.back')) -or [IO.File]::ReadAllText($probeFile+'.back') -ne $probeValue){throw 'SOURCE_MOUNT_ROUNDTRIP_FAILED'}
                    if($p.port -lt 1024 -or $p.port -gt 65535){throw 'INVALID_PROJECT_PORT'}
                    $response=Invoke-WebRequest -UseBasicParsing -Uri ('http://127.0.0.1:'+$p.port+'/') -TimeoutSec 15
                    if($response.StatusCode -ne 200){throw 'HOST_PROJECT_HTTP_UNAVAILABLE'}
                }finally{
                    foreach($file in @($probeFile,($probeFile+'.back'))){if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file -Force}}
                }
            }
            Write-CourseJson (Join-Path $Root '.ai-coding\runtime-check.json') @{schemaVersion=2;runtime=$p.containerRuntime;connection=$p.connection;compose=$composeBinding;containerId=$containerIds[0];imageId=$actual.Id;actualMountsVerified=$true;mountRoundtripAndHostHttp=$(if($Start){'verified'}else{'not-checked'});checkedAt=(Get-Date).ToString('o')}
            if($lifecycleInstallation -and $Start){
                . (Join-Path $PSScriptRoot 'Course-UninstallAdapters.ps1')
                $projectId=Get-CourseLifecycleHash $Root.ToLowerInvariant()
                $connection=if($p.containerRuntime -eq 'podman'){$p.connection}else{'npipe:////./pipe/dockerDesktopLinuxEngine'}
                $ownership=if($lifecycleBeforeContainers -contains $container.Id){'reused'}else{'created'}
                $registeredContainer=Register-CourseEngineResource $p.installationId container $container.Id $ownership rebuildable $cli $p.containerRuntime $connection $projectId
                foreach($volume in @($container.Mounts|Where-Object Type -eq 'volume')){
                    $ownership=if($lifecycleBeforeVolumes -contains $volume.Name){'reused'}else{'created'}
                    $class=if($volume.Destination -eq '/workspace/node_modules'){'rebuildable'}else{'businessData'}
                    $null=Register-CourseEngineResource $p.installationId volume $volume.Name $ownership $class $cli $p.containerRuntime $connection $projectId
                }
                foreach($network in @($container.NetworkSettings.Networks.PSObject.Properties|Where-Object {$_ -and $_.Name -and $_.MemberType -eq 'NoteProperty'})){
                    if($network.Name -in @('bridge','host','none','podman','pasta','slirp4netns')){continue}
                    $ownership=if($lifecycleBeforeNetworks -contains $network.Name){'reused'}else{'created'}
                    $null=Register-CourseEngineResource $p.installationId network $network.Name $ownership rebuildable $cli $p.containerRuntime $connection $projectId
                }
                Complete-CourseCreationIntent $lifecycleRuntimeIntent
                Complete-CourseRuntimeIntentRecovery $p.installationId $Root $container.Config.Labels.'com.docker.compose.project' $registeredContainer.metadata
            }
        }
        # Check the actual project volume, not only the template in the tool image.
        $probe='const fs=require("fs"),crypto=require("crypto"),{createRequire}=require("module");const r=createRequire("/workspace/package.json"),bytes=fs.readFileSync("/workspace/package-lock.json"),lock=JSON.parse(bytes),versions={};for(const n of ["typescript","vite","rollup","@ionic/react","@capacitor/android"]){const v=JSON.parse(fs.readFileSync("/workspace/node_modules/"+n+"/package.json")).version;if(v!==lock.packages["node_modules/"+n]?.version)throw Error("LOCKFILE_DEPENDENCY_VERSION_MISMATCH");versions[n]=v};for(const n of ["typescript","vite","rollup"]){r(n)};if(process.platform!=="linux"||process.arch!=="x64")process.exit(2);console.log(JSON.stringify({lockfileSha256:crypto.createHash("sha256").update(bytes).digest("hex"),platform:process.platform,arch:process.arch,versions}))'
        $deps=Invoke-SetupNative $cli ($prefix+@('compose','exec','-T','app','node','-e',$probe)) 30 $Root
        if($deps.ExitCode -ne 0){throw 'PROJECT_DEPENDENCIES_REQUIRE_SAME_IMAGE_REPAIR'}
        $dependencyState=$(if($deps.Stdout){$deps.Stdout}else{$deps.Output})|ConvertFrom-Json
        if($dependencyState.lockfileSha256 -notmatch '^[a-f0-9]{64}$' -or $dependencyState.platform -ne 'linux' -or $dependencyState.arch -ne 'x64'){throw 'DEPENDENCY_STATE_NOT_VERIFIED'}
        $dependencyState|Add-Member -MemberType NoteProperty -Name imageDigest -Value $p.toolchain.imageDigest -Force
        $dependencyState|Add-Member -MemberType NoteProperty -Name checkedAt -Value (Get-Date).ToString('o') -Force
        Write-CourseJson (Join-Path $Root '.ai-coding\dependencies.json') $dependencyState
    }finally{Set-Location -LiteralPath $prior}
    return [pscustomobject]@{Root=$Root;Source=$source;Project=$p;Cli=$cli;Prefix=$prefix;ImageId=$actual.Id;CheckedAt=(Get-Date).ToString('o')}
    }finally{if($lifecycleLease){Exit-CourseOperation $lifecycleLease}}
}
