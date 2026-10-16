#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'Course-Context.ps1')
. (Join-Path $PSScriptRoot 'Setup-DockerDesktop.ps1')
function Get-CourseProjectRuntime([string]$Root,[switch]$Start) {
    $Root=(Resolve-Path -LiteralPath $Root).Path;Assert-CoursePlainPath $Root
    $p=Read-CourseJson (Join-Path $Root '.ai-coding\project.json')
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
        . (Join-Path $PSScriptRoot 'Setup-PodmanDesktop.ps1')
        $paths=Get-PodmanPaths;$cli=$paths.Cli
        if($paths.Compose){$env:PODMAN_COMPOSE_PROVIDER=$paths.Compose}
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
        $app=($(if($configured.Stdout){$configured.Stdout}else{$configured.Output})|ConvertFrom-Json).services.app
        if($app.image -ne $p.image -or $app.build){throw 'COMPOSE_IMAGE_MISMATCH'}
        $source=[IO.Path]::GetFullPath((Join-Path $Root $p.sourceDirectory));Assert-CoursePlainPath $source
        if($source -ne $Root -and -not $source.StartsWith($Root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'SOURCE_ESCAPES_PROJECT'}
        if(-not @($app.volumes|Where-Object {$_.type -eq 'bind' -and $_.target -eq '/workspace' -and [IO.Path]::GetFullPath($_.source) -eq $source}).Count){throw 'COMPOSE_SOURCE_MISMATCH'}
        if(-not @($app.volumes|Where-Object {$_.type -eq 'volume' -and $_.target -eq '/workspace/node_modules'}).Count){throw 'ISOLATED_DEPENDENCY_VOLUME_REQUIRED'}
        if($app.environment -and @($app.environment.PSObject.Properties|Where-Object {$_.Name -match 'SILICONFLOW_API_KEY|TENCENTCLOUD_SECRET|CLOUDBASE_SECRET'}).Count){throw 'SERVER_SECRET_IN_APP_CONTAINER'}
        if($Start){
            $up=Invoke-SetupNative $cli ($prefix+@('compose','up','-d','--wait','app')) 180 $Root
            if($up.ExitCode -ne 0){throw 'PROJECT_CONTAINER_START_FAILED'}
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
}
