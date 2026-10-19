#Requires -Version 5.1
# Fixed adapters only: resource records never supply an executable command string.
. (Join-Path $PSScriptRoot 'Course-Native.ps1')

function Assert-CourseDeleteBoundary($Resource) {
    $target=[IO.Path]::GetFullPath($Resource.locator);$root=[IO.Path]::GetFullPath($Resource.allowedRoot)
    if(-not(Test-CoursePathWithin $root $target)){throw 'DELETE_BOUNDARY_REFUSED'}
    foreach($protected in @([IO.Path]::GetPathRoot($target),$env:USERPROFILE,(Get-CourseUserRoot),(Join-Path $env:USERPROFILE '.trae-cn'),(Join-Path $env:USERPROFILE '.trae-cn\skills'),$env:SystemRoot)){
        if($protected -and $target.TrimEnd('\') -eq $protected.TrimEnd('\')){throw 'PROTECTED_ROOT_REFUSED'}
    }
    Assert-CoursePlainPath $target
    if(Test-CoursePathWithin $target (Get-CourseLifecycleRoot) -AllowEqual){throw 'LIFECYCLE_RECORDS_PROTECTED'}
    if(Test-CoursePathWithin (Get-CourseLifecycleRoot) $target -AllowEqual){throw 'LIFECYCLE_RECORDS_PROTECTED'}
    if(Test-Path -LiteralPath $target){$null=Get-CourseFileBaseline $target}
}
function Get-CourseManagedBlock($Resource) {
    Assert-CoursePlainPath $Resource.locator
    if(-not(Test-Path -LiteralPath $Resource.locator)){return $null}
    $text=[IO.File]::ReadAllText($Resource.locator)
    $pattern='(?s)'+[regex]::Escape($Resource.metadata.start)+'.*?'+[regex]::Escape($Resource.metadata.end)
    $found=[regex]::Matches($text,$pattern)
    if($found.Count -gt 1){throw 'BLOCK_BOUNDARY_AMBIGUOUS'}
    if(-not $found.Count){return $null}
    return [pscustomobject]@{text=$text;pattern=$pattern;digest=(Get-CourseLifecycleHash $found[0].Value)}
}
function Invoke-CourseEngine($Metadata,[string[]]$Arguments) {
    if($Metadata.runtime -notin @('podman','docker') -or -not [IO.Path]::IsPathRooted($Metadata.cli)){throw 'LOCAL_ENGINE_BINDING_REQUIRED'}
    Assert-CoursePlainPath $Metadata.cli
    if(-not(Test-Path -LiteralPath $Metadata.cli) -or (Get-FileHash -LiteralPath $Metadata.cli -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Metadata.cliHash){throw 'ENGINE_CLI_CHANGED_OR_MISSING'}
    if([IO.Path]::GetFileNameWithoutExtension($Metadata.cli) -ine $Metadata.runtime){throw 'ENGINE_CLI_NAME_MISMATCH'}
    if($Metadata.runtime -eq 'podman'){
        if($Metadata.connection -notmatch '^podman-machine-[a-zA-Z0-9_-]+$'){throw 'LOCAL_CONNECTION_REQUIRED'}
        $prefix=@('--connection',$Metadata.connection)
    }else{
        if($Metadata.connection -notin @('npipe:////./pipe/dockerDesktopLinuxEngine','npipe:////./pipe/docker_engine')){throw 'LOCAL_ENDPOINT_REQUIRED'}
        $prefix=@('--host',$Metadata.connection)
    }
    $r=Invoke-SetupNative $Metadata.cli ($prefix+$Arguments) 40
    if($r.ExitCode -ne 0){throw 'ENGINE_QUERY_FAILED'}
    return $(if($r.Stdout){$r.Stdout}else{$r.Output})
}
function Assert-CourseEngineIdentity($Metadata) {
    Assert-CoursePlainPath $Metadata.cli
    if(-not(Test-Path -LiteralPath $Metadata.cli) -or (Get-FileHash -LiteralPath $Metadata.cli).Hash.ToLowerInvariant() -ne $Metadata.cliHash){throw 'ENGINE_CLI_CHANGED_OR_MISSING'}
    if($Metadata.runtime -eq 'podman'){
        $r=Invoke-SetupNative $Metadata.cli @('system','connection','list','--format','json') 15
        if($r.ExitCode -ne 0){throw 'CONNECTION_QUERY_FAILED'}
        $list=ConvertFrom-Json -InputObject $(if($r.Stdout){$r.Stdout}else{$r.Output})
        $selected=@($list|Where-Object {$_.Name -eq $Metadata.connection -and $_.IsMachine -eq $true -and $_.URI -match '^ssh://(?:root|user)@127\.0\.0\.1:\d+/run/(?:user/\d+/)?podman/podman\.sock$'})
        if($selected.Count -ne 1 -or $selected[0].URI -ne $Metadata.connectionUri){throw 'CONNECTION_IDENTITY_CHANGED'}
    }
    $info=(Invoke-CourseEngine $Metadata @('info','--format','json'))|ConvertFrom-Json
    if($Metadata.runtime -eq 'podman'){
        if($info.host.os -ne 'linux' -or $info.host.arch -notin @('amd64','x86_64')){throw 'ENGINE_PLATFORM_CHANGED'}
        $identity=[string]$info.host.hostname+'|'+[string]$info.store.graphRoot+'|'+[string]$info.host.security.rootless
    }else{
        if($info.OSType -ne 'linux'){throw 'ENGINE_PLATFORM_CHANGED'};$identity=[string]$info.ID
    }
    if(-not $Metadata.engineIdentity -or $identity -ne $Metadata.engineIdentity){throw 'ENGINE_IDENTITY_CHANGED'}
}
function Get-CourseEngineObject($Resource) {
    Assert-CourseEngineIdentity $Resource.metadata
    $name=$Resource.locator
    if($Resource.kind -in @('container','image')){if($name -notmatch '^(sha256:)?[a-f0-9]{12,64}$'){throw 'IMMUTABLE_RESOURCE_ID_REQUIRED'}}
    elseif($name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,200}$'){throw 'INVALID_ENGINE_RESOURCE_NAME'}
    $query=switch($Resource.kind){container {@('ps','-a','--no-trunc','--format','{{.ID}}')};image {@('image','ls','--no-trunc','-q')};volume {@('volume','ls','-q')};network {@('network','ls','--format','{{.Name}}')};default {throw 'UNSUPPORTED_ENGINE_RESOURCE'}}
    $all=Invoke-CourseEngine $Resource.metadata $query
    $names=@($all -split '\r?\n'|Where-Object {$_})
    if($Resource.kind -eq 'image'){$exists=@($names|Where-Object {($_ -replace '^sha256:','') -eq ($name -replace '^sha256:','')}).Count -gt 0}else{$exists=$names -contains $name}
    if(-not $exists){return $null}
    $args=switch($Resource.kind){container {@('container','inspect',$name)};default {@($Resource.kind,'inspect',$name)}}
    $parsed=ConvertFrom-Json -InputObject (Invoke-CourseEngine $Resource.metadata $args)
    $obj=@($parsed)[0]
    $identity=switch($Resource.kind){
        container { [ordered]@{id=$obj.Id;created=$obj.Created;image=$obj.Image;mounts=@($obj.Mounts|ForEach-Object {[ordered]@{type=$_.Type;name=$_.Name;source=$_.Source;destination=$_.Destination}})} }
        image { [ordered]@{id=$obj.Id;created=$obj.Created;tags=@($obj.RepoTags|Sort-Object);digests=@($obj.RepoDigests|Sort-Object)} }
        volume { [ordered]@{name=$obj.Name;created=$obj.CreatedAt;mountpoint=$obj.Mountpoint;driver=$obj.Driver} }
        network { [ordered]@{id=$(if($obj.Id){$obj.Id}else{$obj.id});name=$(if($obj.Name){$obj.Name}else{$obj.name});created=$(if($obj.Created){$obj.Created}else{$obj.created})} }
    }
    return [pscustomobject]@{object=$obj;digest=(Get-CourseLifecycleHash ($identity|ConvertTo-Json -Depth 8 -Compress))}
}
function Get-CourseResourceCheck($Resource,[string]$Action) {
    try{
        if($Resource.kind -eq 'managedBlock'){
            $block=Get-CourseManagedBlock $Resource
            if(-not $block){return [pscustomobject]@{status='absent';reason='already-absent'}}
            if($block.digest -ne $Resource.baseline.digest){throw 'MANAGED_BLOCK_MODIFIED'}
        }elseif($Resource.kind -in @('file','directory','skill','project','credential','tool')){
            Assert-CourseDeleteBoundary $Resource
            $current=Get-CourseFileBaseline $Resource.locator
            if(-not $current){return [pscustomobject]@{status='absent';reason='already-absent'}}
            # Project deletion requires a fresh explicit plan snapshot, not its old creation baseline.
            if(-not $Resource.baseline -or $current.digest -ne $Resource.baseline.digest){throw 'RESOURCE_MODIFIED'}
            if($Action -eq 'restorePrevious'){
                if(-not $Resource.backupPath -or -not $Resource.backupBaseline){throw 'PREVIOUS_COPY_UNVERIFIED'}
                $backup=Get-CourseFileBaseline $Resource.backupPath
                if(-not $backup -or $backup.digest -ne $Resource.backupBaseline.digest){throw 'PREVIOUS_COPY_CHANGED'}
            }
            if($Resource.kind -eq 'tool'){
                if($Resource.metadata.installer -notin @('portable','msi')){throw 'TOOL_UNINSTALL_REQUIRES_VERIFIED_INSTALLER_IDENTITY'}
                if($Resource.metadata.installer -eq 'msi'){
                    $null=Get-CourseMsiRegistration $Resource
                    $directory=Split-Path $Resource.locator -Parent
                    $busy=@(Get-CimInstance Win32_Process -ErrorAction Stop|Where-Object {$_.ExecutablePath -and (Test-CoursePathWithin $directory $_.ExecutablePath -AllowEqual)})
                    if($busy.Count){throw 'TOOL_PROCESSES_STILL_RUNNING'}
                }
            }
        }elseif($Resource.kind -in @('container','volume','image','network')){
            $item=Get-CourseEngineObject $Resource
            if(-not $item){return [pscustomobject]@{status='absent';reason='already-absent'}}
            if($item.digest -ne $Resource.metadata.objectDigest){throw 'ENGINE_RESOURCE_CHANGED'}
            if($Resource.kind -eq 'network' -and $item.object.Containers -and @($item.object.Containers.PSObject.Properties).Count){throw 'NETWORK_STILL_IN_USE'}
            if($Resource.kind -in @('volume','image')){
                # Include stopped containers; this deliberately blocks until owned containers are removed.
                $args=if($Resource.kind -eq 'volume'){@('ps','-a','-q','--filter',('volume='+$Resource.locator))}else{@('ps','-a','-q','--filter',('ancestor='+$Resource.locator))}
                $users=Invoke-CourseEngine $Resource.metadata $args
                if($users.Trim()){throw 'RESOURCE_STILL_IN_USE'}
            }
        }elseif($Resource.kind -eq 'machine'){
            $machine=Get-CourseMachineCheck $Resource
            if(-not $machine){return [pscustomobject]@{status='absent';reason='already-absent'}}
        }
        else{throw 'UNSUPPORTED_RESOURCE_KIND'}
        return [pscustomobject]@{status='ready';reason='verified'}
    }catch{
        # Fixed error codes only; never emit raw engine/config/credential responses.
        $code=[string]$_.Exception.Message
        if($code -notmatch '^[A-Z_]+$'){$code='RESOURCE_INSPECTION_FAILED'}
        return [pscustomobject]@{status='blocked';reason=$code}
    }
}
function Invoke-CourseResourceRemoval($Resource,[string]$Action) {
    $check=Get-CourseResourceCheck $Resource $Action
    if($check.status -eq 'blocked'){throw $check.reason}
    if($check.status -eq 'absent' -and $Action -ne 'restorePrevious'){
        if($Resource.kind -eq 'machine' -and $Resource.metadata.dataHomeOwned -eq $true){Remove-CourseEmptyCacheDirectories $Resource.metadata.dataHome $Resource.metadata.dataHomeParent}
        return
    }
    if($Resource.kind -eq 'managedBlock'){
        $block=Get-CourseManagedBlock $Resource
        if($block){[IO.File]::WriteAllText($Resource.locator,[regex]::Replace($block.text,$block.pattern,''),[Text.UTF8Encoding]::new($false))};return
    }
    if($Resource.kind -in @('container','volume','image','network')){
        if($Resource.kind -eq 'container'){
            $null=Invoke-CourseEngine $Resource.metadata @('stop','--time','20',$Resource.locator)
            $null=Invoke-CourseEngine $Resource.metadata @('container','rm',$Resource.locator)
        }else{$null=Invoke-CourseEngine $Resource.metadata @($Resource.kind,'rm',$Resource.locator)}
        return
    }
    if($Resource.kind -eq 'tool' -and $Resource.metadata.installer -eq 'msi'){
        $null=Get-CourseMsiRegistration $Resource
        $r=Invoke-SetupNative (Join-Path $env:SystemRoot 'System32\msiexec.exe') @('/x',$Resource.metadata.productCode,'/passive','/norestart') 600
        if($r.ExitCode -eq 3010){throw 'RESTART_REQUIRED'}
        if($r.ExitCode -notin @(0,1605)){throw 'TOOL_UNINSTALL_FAILED'}
        return
    }
    if($Resource.kind -eq 'machine'){
        $machine=Get-CourseMachineCheck $Resource
        if($machine){
            if($machine.State -eq 'running'){$r=Invoke-SetupNative $Resource.metadata.cli @('machine','stop',$Resource.locator) 90;if($r.ExitCode -ne 0){throw 'MACHINE_STOP_FAILED'}}
            # --force suppresses the interactive confirmation only after both stores are proven empty.
            $r=Invoke-SetupNative $Resource.metadata.cli @('machine','rm','--force',$Resource.locator) 90
            if($r.ExitCode -ne 0){throw 'MACHINE_REMOVE_FAILED'}
            if($Resource.metadata.dataHomeOwned -eq $true -and $Resource.metadata.dataHome -and $Resource.metadata.dataHomeParent){
                Remove-CourseEmptyCacheDirectories $Resource.metadata.dataHome $Resource.metadata.dataHomeParent
            }
        };return
    }
    Assert-CourseDeleteBoundary $Resource
    if(Test-Path -LiteralPath $Resource.locator){Remove-Item -LiteralPath $Resource.locator -Recurse -Force -ErrorAction Stop}
    if($Action -eq 'restorePrevious'){
        # Copy then verify, keeping the original backup until final verification succeeds.
        Copy-Item -LiteralPath $Resource.backupPath -Destination $Resource.locator -Recurse -ErrorAction Stop
    }
}
function Test-CourseResourceRemoved($Resource,[string]$Action) {
    if($Action -eq 'restorePrevious'){
        $current=Get-CourseFileBaseline $Resource.locator;return ($current -and $current.digest -eq $Resource.backupBaseline.digest)
    }
    if($Resource.kind -eq 'managedBlock'){return ($null -eq (Get-CourseManagedBlock $Resource))}
    if($Resource.kind -in @('container','volume','image','network')){
        if(-not(Test-Path -LiteralPath $Resource.metadata.cli) -and $Resource.metadata.provider -eq 'wsl'){return Test-CourseWslMachineAbsent $Resource.metadata.machineName}
        return ($null -eq (Get-CourseEngineObject $Resource))
    }
    if($Resource.kind -eq 'machine'){
        if(-not(Test-Path -LiteralPath $Resource.metadata.cli) -and $Resource.metadata.provider -eq 'wsl'){return Test-CourseWslMachineAbsent $Resource.locator}
        return ($null -eq (Get-CourseMachineCheck $Resource -AbsentOnly))
    }
    Assert-CoursePlainPath $Resource.locator;return (-not(Test-Path -LiteralPath $Resource.locator))
}

function Get-CourseMsiRegistration($Resource) {
    $m=$Resource.metadata
    if($m.scope -ne 'current-user' -or $m.productCode -notmatch '^\{[A-Fa-f0-9-]{36}\}$'){throw 'USER_MSI_IDENTITY_REQUIRED'}
    $path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\'+$m.productCode
    if(-not(Test-Path -LiteralPath $path)){throw 'USER_MSI_REGISTRATION_NOT_FOUND'}
    $registered=Get-ItemProperty -LiteralPath $path -ErrorAction Stop
    if($registered.DisplayVersion -ne $m.productVersion -or $registered.DisplayName -ne $m.productName){throw 'MSI_REGISTRATION_CHANGED'}
    return $registered
}

function Get-CourseMachineCheck($Resource,[switch]$AbsentOnly) {
    $m=$Resource.metadata
    if($m.runtime -ne 'podman' -or $Resource.locator -notmatch '^podman-machine-[a-zA-Z0-9_-]+$' -or -not $m.createdAt){throw 'MACHINE_CREATION_IDENTITY_REQUIRED'}
    Assert-CoursePlainPath $m.cli
    if([IO.Path]::GetFileNameWithoutExtension($m.cli) -ine 'podman'){throw 'ENGINE_CLI_NAME_MISMATCH'}
    if(-not(Test-Path -LiteralPath $m.cli) -or (Get-FileHash -LiteralPath $m.cli).Hash.ToLowerInvariant() -ne $m.cliHash){throw 'ENGINE_CLI_CHANGED_OR_MISSING'}
    $list=Invoke-SetupNative $m.cli @('machine','list','--format','json') 20
    if($list.ExitCode -ne 0){throw 'MACHINE_LIST_FAILED'}
    $parsed=ConvertFrom-Json -InputObject $(if($list.Stdout){$list.Stdout}else{$list.Output})
    $found=@($parsed|Where-Object Name -eq $Resource.locator)
    if(-not $found.Count){return $null};if($AbsentOnly){return $found[0]}
    $r=Invoke-SetupNative $m.cli @('machine','inspect',$Resource.locator) 20
    if($r.ExitCode -ne 0){throw 'MACHINE_INSPECTION_FAILED'}
    $actual=@($(if($r.Stdout){$r.Stdout}else{$r.Output})|ConvertFrom-Json)[0]
    if([string]$actual.Created -ne $m.createdAt -or $actual.Name -ne $Resource.locator){throw 'MACHINE_IDENTITY_CHANGED'}
    if($actual.State -ne 'running'){throw 'MACHINE_OFFLINE_CANNOT_VERIFY_STORES'}
    $r=Invoke-SetupNative $m.cli @('system','connection','list','--format','json') 20
    if($r.ExitCode -ne 0){throw 'CONNECTION_QUERY_FAILED'}
    $parsed=ConvertFrom-Json -InputObject $(if($r.Stdout){$r.Stdout}else{$r.Output})
    $connections=@($parsed|Where-Object {$_.IsMachine -eq $true -and $_.Name -in @($Resource.locator,($Resource.locator+'-root'))})
    if($connections.Count -ne 2 -or @($connections|Where-Object URI -match '^ssh://root@127\.0\.0\.1:').Count -ne 1 -or @($connections|Where-Object URI -match '^ssh://user@127\.0\.0\.1:').Count -ne 1){throw 'MACHINE_FULL_NAMESPACE_OWNERSHIP_REQUIRES_REVIEW'}
    foreach($connection in $connections){
        if(-not $actual.SSHConfig.Port -or -not $actual.SSHConfig.IdentityPath -or $connection.Identity -ne $actual.SSHConfig.IdentityPath -or $connection.URI -notmatch ('^ssh://(?:root|user)@127\.0\.0\.1:'+ [regex]::Escape([string]$actual.SSHConfig.Port)+'/run/(?:user/\d+/)?podman/podman\.sock$')){throw 'MACHINE_CONNECTION_IDENTITY_CHANGED'}
        foreach($args in @(@('ps','-a','-q'),@('volume','ls','-q'),@('image','ls','-q'))){
            $r=Invoke-SetupNative $m.cli (@('--connection',$connection.Name)+$args) 25
            if($r.ExitCode -ne 0){throw 'MACHINE_STORE_QUERY_FAILED'}
            if($r.Output.Trim()){throw 'MACHINE_STORES_NOT_EMPTY'}
        }
        $r=Invoke-SetupNative $m.cli @('--connection',$connection.Name,'network','ls','--format','{{.Name}}') 25
        if($r.ExitCode -ne 0 -or @($r.Output -split '\r?\n'|Where-Object {$_ -and $_ -notin @('podman','bridge','host','none')}).Count){throw 'MACHINE_NETWORKS_NOT_EMPTY'}
    }
    return $actual
}

function Register-CourseEngineResource {
    param([string]$InstallationId,[string]$Kind,[string]$Id,[string]$Ownership,[string]$DataClass,[string]$Cli,[string]$Runtime,[string]$Connection,[string]$ProjectId)
    $metadata=@{runtime=$Runtime;cli=$Cli;cliHash=(Get-FileHash -LiteralPath $Cli).Hash.ToLowerInvariant();connection=$Connection;projectId=$ProjectId;connectionUri=$null;engineIdentity=$null;objectDigest=$null}
    if($Runtime -eq 'podman'){
        $connections=Invoke-SetupNative $Cli @('system','connection','list','--format','json') 15
        if($connections.ExitCode -ne 0){throw 'CONNECTION_QUERY_FAILED'}
        $list=ConvertFrom-Json -InputObject $(if($connections.Stdout){$connections.Stdout}else{$connections.Output})
        $selected=@($list|Where-Object Name -eq $Connection)
        if($selected.Count -ne 1){throw 'LOCAL_CONNECTION_REQUIRED'};$metadata.connectionUri=$selected[0].URI
    }
    $info=(Invoke-CourseEngine ([pscustomobject]$metadata) @('info','--format','json'))|ConvertFrom-Json
    $metadata.engineIdentity=if($Runtime -eq 'podman'){[string]$info.host.hostname+'|'+[string]$info.store.graphRoot+'|'+[string]$info.host.security.rootless}else{[string]$info.ID}
    $resource=[pscustomobject]@{kind=$Kind;locator=$Id;metadata=[pscustomobject]$metadata}
    $actual=Get-CourseEngineObject $resource
    if(-not $actual){throw 'CREATED_RESOURCE_NOT_FOUND'}
    $metadata.objectDigest=$actual.digest
    if($Runtime -eq 'podman'){
        $machineName=$Connection -replace '-root$',''
        $owned=@((Read-CourseLifecycle).resources|Where-Object {$_.kind -eq 'machine' -and $_.locator -eq $machineName -and $_.metadata.cli -eq $Cli -and $_.metadata.provider -eq 'wsl' -and $_.ownership -eq 'created'})
        if($owned.Count -eq 1){$metadata.machineName=$machineName;$metadata.provider='wsl'}
    }
    return Register-CourseResource -InstallationId $InstallationId -Kind $Kind -Locator $Id -Ownership $Ownership -DataClass $DataClass -Metadata $metadata
}

function Test-CourseWslMachineAbsent([string]$Machine) {
    if($Machine -notmatch '^podman-machine-[a-zA-Z0-9_-]+$'){throw 'MACHINE_IDENTITY_REQUIRED'}
    $r=Invoke-SetupNative (Join-Path $env:SystemRoot 'System32\wsl.exe') @('--list','--quiet') 30
    if($r.ExitCode -ne 0){throw 'WSL_ABSENCE_NOT_VERIFIED'}
    return ($Machine -notin @(($r.Output -replace "`0",'') -split '\r?\n'|ForEach-Object {$_.Trim()}|Where-Object {$_}))
}
function Remove-CourseEmptyCacheDirectories([string]$Root,[string]$Parent) {
    if(-not(Test-CoursePathWithin $Parent $Root)){throw 'CACHE_BOUNDARY_REFUSED'}
    Assert-CoursePlainPath $Root
    if(-not(Test-Path -LiteralPath $Root)){return}
    $pending=New-Object 'Collections.Generic.Stack[string]';$pending.Push($Root)
    $folders=New-Object Collections.Generic.List[string]
    while($pending.Count){
        $folder=$pending.Pop();$folders.Add($folder)
        foreach($child in Get-ChildItem -LiteralPath $folder -Force){
            if($child.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'LINK_IN_PROVIDER_CACHE'}
            if($child.PSIsContainer){$pending.Push($child.FullName)}
        }
        if($folders.Count -gt 10000){throw 'CACHE_TREE_TOO_LARGE'}
    }
    foreach($folder in @($folders.ToArray()|Sort-Object Length -Descending)){
        # Nonrecursive deletion cannot remove an unrecorded file or a concurrent new file.
        if(-not @(Get-ChildItem -LiteralPath $folder -Force).Count){[IO.Directory]::Delete($folder)}
    }
}
function Complete-CourseRuntimeIntentRecovery([string]$InstallationId,[string]$Root,[string]$ProjectLabel,$Metadata) {
    $db=Read-CourseLifecycle
    $pending=@($db.intents|Where-Object {$_.installationId -eq $InstallationId -and $_.kind -eq 'runtimeGroup' -and $_.locator -eq $Root -and $_.status -eq 'pending'})
    if(-not $pending.Count){return}
    if($ProjectLabel -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,99}$'){return}
    $projectId=Get-CourseLifecycleHash $Root.ToLowerInvariant()
    foreach($kind in @('container','volume','network')){
        $args=switch($kind){container {@('ps','-a','--no-trunc','--format','{{.ID}}','--filter',('label=com.docker.compose.project='+$ProjectLabel))};volume {@('volume','ls','-q','--filter',('label=com.docker.compose.project='+$ProjectLabel))};network {@('network','ls','--format','{{.Name}}','--filter',('label=com.docker.compose.project='+$ProjectLabel))}}
        $actual=@((Invoke-CourseEngine $Metadata $args) -split '\r?\n'|Where-Object {$_})
        $known=@($db.resources|Where-Object {$_.kind -eq $kind -and $_.references -contains $InstallationId -and $_.metadata.projectId -eq $projectId -and $_.metadata.connection -eq $Metadata.connection}|ForEach-Object locator)
        if(@($actual|Where-Object {$_ -notin $known}).Count){return}
    }
    $gate=Get-CourseLifecycleLock
    try{
        $db=Read-CourseLifecycle
        foreach($intent in @($db.intents|Where-Object {$_.id -in @($pending.id)})){
            if($intent.pid -eq $PID -or -not(Test-CourseLeaseAlive $intent)){$intent.status='registered'}
        }
        Write-CourseLifecycle $db
    }finally{Close-CourseLifecycleLock $gate}
}
