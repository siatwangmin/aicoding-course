#Requires -Version 5.1
# Library only. No listener, process or project is touched on import.
. (Join-Path $PSScriptRoot 'Course-Context.ps1')
function Get-CoursePortCandidates([int]$Preferred=5187){
    if($Preferred -lt 1024 -or $Preferred -gt 65535){throw 'INVALID_PROJECT_PORT'}
    return @(@($Preferred)+@(5187..5197)|Select-Object -Unique)
}
function Test-CoursePortBindable([int]$Port){
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$Port)
    try{$listener.Server.ExclusiveAddressUse=$true;$listener.Start();return $true}catch [Net.Sockets.SocketException]{return $false}finally{$listener.Stop()}
}
function Test-CoursePortFailure([string]$Message){
    return $Message -match '(?is)address already in use|port is already allocated|only one usage of each socket address|bind.{0,100}(?:forbidden by its access permissions|permission denied)|cannot listen on.{0,100}(?:port|address)'
}
function Get-CourseEnvironmentPort([string]$Root){
    $file=Join-Path $Root '.env';Assert-CoursePlainPath $file
    $matches=[regex]::Matches([IO.File]::ReadAllText($file),'(?m)^AI_CODING_PORT=(\d+)\s*$')
    if($matches.Count -ne 1){throw 'PROJECT_ENV_PORT_REQUIRED'}
    return [int]$matches[0].Groups[1].Value
}
function Set-CoursePortValues([string]$Root,[int]$Port){
    $file=Join-Path $Root '.env';Assert-CoursePlainPath $file
    $text=[IO.File]::ReadAllText($file)
    if([regex]::Matches($text,'(?m)^AI_CODING_PORT=\d+\s*$').Count -ne 1){throw 'PROJECT_ENV_PORT_REQUIRED'}
    $text=[regex]::Replace($text,'(?m)^AI_CODING_PORT=\d+[^\S\r\n]*',('AI_CODING_PORT='+$Port))
    $temp=$file+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{[IO.File]::WriteAllText($temp,$text,[Text.UTF8Encoding]::new($false));[IO.File]::Replace($temp,$file,($temp+'.backup'))}finally{foreach($cleanup in @($temp,($temp+'.backup'))){if(Test-Path -LiteralPath $cleanup){Remove-Item -LiteralPath $cleanup}}}
    $path=Join-Path $Root '.ai-coding/project.json';$p=Read-CourseJson $path;$p.port=$Port;Write-CourseJson $path $p
}
function Repair-CoursePortTransition([string]$Root){
    $file=Join-Path $Root '.ai-coding/port-transition.json'
    if(-not(Test-Path -LiteralPath $file)){return}
    $state=Read-CourseJson $file;$p=Read-CourseJson (Join-Path $Root '.ai-coding/project.json');$envPort=Get-CourseEnvironmentPort $Root
    if($state.schemaVersion -ne 1 -or $state.root -ne [IO.Path]::GetFullPath($Root) -or $state.slug -ne $p.slug -or $p.port -notin @($state.before,$state.after) -or $envPort -notin @($state.before,$state.after)){throw 'PORT_TRANSITION_CONFLICT_PRESERVED'}
    if($state.before -lt 1024 -or $state.before -gt 65535 -or $state.after -lt 1024 -or $state.after -gt 65535){throw 'INVALID_PORT_TRANSITION'}
    Set-CoursePortValues $Root $state.before
    Remove-Item -LiteralPath $file
}
function Set-CourseProjectPort([string]$Root,[int]$Port){
    if($Port -lt 1024 -or $Port -gt 65535){throw 'INVALID_PROJECT_PORT'}
    $p=Read-CourseJson (Join-Path $Root '.ai-coding/project.json')
    if($p.port -ne (Get-CourseEnvironmentPort $Root)){throw 'PROJECT_PORT_BINDING_MISMATCH'}
    if($p.port -eq $Port){return}
    $file=Join-Path $Root '.ai-coding/port-transition.json'
    # Each candidate is a small recoverable update; no environment secrets enter the journal.
    Write-CourseJson $file @{schemaVersion=1;root=[IO.Path]::GetFullPath($Root);slug=$p.slug;before=$p.port;after=$Port}
    Set-CoursePortValues $Root $Port
}
function Get-CourseActualHostPort($Container){
    $ports=@($Container.NetworkSettings.Ports.'5187/tcp')
    $values=@($ports|Where-Object {$_ -and $_.HostIp -in @('127.0.0.1','0.0.0.0','::')}|ForEach-Object {[int]$_.HostPort}|Select-Object -Unique)
    if($values.Count -ne 1){throw 'ACTUAL_CONTAINER_PORT_MAPPING_REQUIRED'}
    return $values[0]
}
function Start-CourseProjectApp([string]$Root,[string]$Cli,[string[]]$Prefix,[string]$ImageId,[string]$Source,[string]$ComposeName){
    $mutex=[Threading.Mutex]::new($false,('Local\course-project-ports-'+(Get-CourseLifecycleHash (Get-CourseUserRoot).ToLowerInvariant())))
    try{$entered=$mutex.WaitOne(15000)}catch [Threading.AbandonedMutexException]{$entered=$true}
    if(-not $entered){$mutex.Dispose();throw 'PROJECT_PORT_SELECTION_BUSY'}
    try{
        Repair-CoursePortTransition $Root
        $p=Read-CourseJson (Join-Path $Root '.ai-coding/project.json');$originalPort=[int]$p.port
        if($p.port -ne (Get-CourseEnvironmentPort $Root)){throw 'PROJECT_PORT_BINDING_MISMATCH'}
        $ids=Invoke-SetupNative $Cli ($Prefix+@('compose','ps','-q','app')) 20 $Root
        if($ids.ExitCode -ne 0){throw 'PROJECT_CONTAINER_LOOKUP_FAILED'}
        $existing=@($ids.Output -split '\r?\n'|Where-Object {$_ -match '^[a-f0-9]{12,64}$'})
        if($existing.Count -eq 1){
            $inspection=Invoke-SetupNative $Cli ($Prefix+@('inspect',$existing[0])) 20 $Root
            if($inspection.ExitCode -ne 0){throw 'PROJECT_CONTAINER_INSPECT_FAILED'}
            $container=@($inspection.Output|ConvertFrom-Json)[0]
            $imageMatches=($container.Image -replace '^sha256:','') -eq ($ImageId -replace '^sha256:','')
            $mountMatches=@($container.Mounts|Where-Object {$_.Destination -eq '/workspace' -and $_.Type -eq 'bind' -and (Test-CourseSourceMount $_.Source $Source)}).Count -eq 1
            if(-not $imageMatches -or -not $mountMatches -or $container.Config.Labels.'com.docker.compose.project' -ne $ComposeName){throw 'EXISTING_CONTAINER_PROJECT_IDENTITY_MISMATCH'}
            if($container.State.Running -and $container.State.Health.Status -eq 'healthy' -and (Get-CourseActualHostPort $container) -eq $p.port){return [pscustomobject]@{port=$p.port;reused=$true;attempts=0}}
        }
        $attempts=0
        try{
            foreach($port in (Get-CoursePortCandidates $p.port)){
                if(-not(Test-CoursePortBindable $port)){continue}
                Set-CourseProjectPort $Root $port
                $attempts++
                $up=Invoke-SetupNative $Cli ($Prefix+@('compose','up','-d','--pull','never','--no-build','--wait','--wait-timeout','90','app')) 180 $Root
                if($up.ExitCode -eq 0){
                    # The runtime caller verifies actual container identity, mapping and HTTP
                    # before committing this transition and publishing a URL.
                    return [pscustomobject]@{port=$port;reused=$false;attempts=$attempts}
                }
                if(-not(Test-CoursePortFailure $up.Output)){throw 'PROJECT_CONTAINER_START_FAILED_NON_PORT: inspect engine/application diagnostics'}
                Repair-CoursePortTransition $Root
            }
            throw 'PROJECT_PORT_CANDIDATES_EXHAUSTED: 5187-5197; project retained'
        }catch{
            Repair-CoursePortTransition $Root
            if((Read-CourseJson (Join-Path $Root '.ai-coding/project.json')).port -ne $originalPort){Set-CoursePortValues $Root $originalPort}
            throw
        }
    }finally{$mutex.ReleaseMutex();$mutex.Dispose()}
}
