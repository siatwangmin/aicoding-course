#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'Course-Lifecycle.ps1')
. (Join-Path $PSScriptRoot 'Course-UninstallAdapters.ps1')

function Import-CourseLegacyInstallation([string]$PreparationDirectory) {
    $evidence=@('.course-setup\materials.json','.course-setup\skills-installation.json','.course-setup\preparation.json','toolchain-verification.json','.podman-setup\report.json','.docker-setup\report.json')
    if(-not @($evidence|Where-Object {Test-Path -LiteralPath (Join-Path $PreparationDirectory $_)}).Count){throw 'PREPARATION_RECORD_REQUIRED'}
    $entry=Register-CourseInstallation $PreparationDirectory -Recovered
    $file=Join-Path $PreparationDirectory '.course-setup\skills-installation.json'
    if(Test-Path -LiteralPath $file){
        $record=Read-CourseJson $file
        foreach($name in @($record.SkillNames)){
            if($name -cnotmatch '^[a-z][a-z0-9-]{0,63}$'){throw 'INVALID_LEGACY_SKILL_NAME'}
            $path=if($record.SkillScope -in @('Preparation','mixed') -and $name -ne 'ai-coding-project'){Join-Path $PreparationDirectory ('.trae/skills/'+$name)}else{Join-Path $env:USERPROFILE ('.trae-cn/skills/'+$name)}
            if(Test-Path -LiteralPath $path){$null=Register-CourseResource $entry.installationId skill $path unknown configuration (Split-Path $path -Parent)}
        }
    }
    # Old tool/machine records prove location, never creation ownership.
    foreach($relative in @('.podman-setup\report.json','.docker-setup\report.json','toolchain-verification.json')){
        $legacyFile=Join-Path $PreparationDirectory $relative
        if(Test-Path -LiteralPath $legacyFile){
            $report=Read-CourseJson $legacyFile
            if($report.Machine -match '^podman-machine-[a-zA-Z0-9_-]+$'){$null=Register-CourseResource -InstallationId $entry.installationId -Kind machine -Locator $report.Machine -Ownership unknown -Metadata @{runtime='podman';machineName=$report.Machine}}
            if($report.ImageId -match '^(sha256:)?[a-f0-9]{64}$'){$null=Register-CourseResource -InstallationId $entry.installationId -Kind image -Locator $report.ImageId -Ownership unknown -Metadata @{runtime=$(if($report.ContainerRuntime){$report.ContainerRuntime}else{'docker'});connection=$report.Connection}}
        }
    }
    $pathsFile=Join-Path (Get-CourseUserRoot) 'tool-paths.json'
    if(Test-Path -LiteralPath $pathsFile){
        $paths=Read-CourseJson $pathsFile
        foreach($path in @($paths.podman.cli,$paths.podman.compose)){
            if($path -and (Test-Path -LiteralPath $path)){$null=Register-CourseResource -InstallationId $entry.installationId -Kind tool -Locator $path -Ownership unknown -AllowedRoot (Split-Path $path -Parent)}
        }
    }
    $storageFile=Join-Path $PreparationDirectory '.course-setup\storage.json'
    if(Test-Path -LiteralPath $storageFile){
        $storage=Read-CourseJson $storageFile
        foreach($actual in @($storage.actualPaths)){
            if($actual.path -and (Test-Path -LiteralPath $actual.path)){$null=Register-CourseResource -InstallationId $entry.installationId -Kind directory -Locator $actual.path -Ownership unknown -DataClass businessData -AllowedRoot (Split-Path $actual.path -Parent)}
        }
    }
    $file=Join-Path $PreparationDirectory '.course-setup\preparation.json'
    if(Test-Path -LiteralPath $file){
        $p=Read-CourseJson $file;$gate=Get-CourseLifecycleLock
        try{$db=Read-CourseLifecycle;$i=@($db.installations|Where-Object installationId -eq $entry.installationId)[0];$i.preparationId=$p.preparationId;Write-CourseLifecycle $db}finally{Close-CourseLifecycleLock $gate}
    }
    return Get-CourseInstallation $entry.installationId
}
function Get-CourseUninstallOperationDirectory([string]$OperationId) {
    Assert-CourseLifecycleId $OperationId
    $path=Join-Path (Get-CourseLifecycleRoot) ('operations\'+$OperationId);Assert-CoursePlainPath $path;return $path
}
function Get-CourseProtectedProjectSnapshot([string]$Root) {
    Assert-CoursePlainPath $Root
    $lines=New-Object Collections.Generic.List[string]
    $pending=New-Object 'Collections.Generic.Stack[string]';$pending.Push([IO.Path]::GetFullPath($Root))
    while($pending.Count){
        foreach($child in Get-ChildItem -LiteralPath $pending.Pop() -Force -ErrorAction Stop){
            if($child.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'LINK_IN_PRESERVED_PROJECT'}
            if($child.PSIsContainer){if($child.Name -notin @('node_modules','.local','.ai-coding','dist','.git','build','.gradle')){$pending.Push($child.FullName)}}
            else{
                # Package hooks, design, specs, application data and signing files remain included.
                $relative=$child.FullName.Substring($Root.TrimEnd('\').Length)
                $lines.Add($relative+':'+(Get-FileHash -LiteralPath $child.FullName -Algorithm SHA256).Hash)
            }
            if($lines.Count -gt 100000){throw 'PRESERVED_PROJECT_TOO_LARGE'}
        }
    }
    return Get-CourseLifecycleHash (($lines|Sort-Object) -join "`n")
}
function New-CourseUninstallPlan {
    param([string]$InstallationId,[ValidateSet('KeepWork','TestClean')][string]$Scope='KeepWork',[string[]]$ProjectIds=@(),[string]$OutputDirectory,[switch]$RemovePreparationDirectory,[string[]]$RemoveMachineNames=@())
    $gate=Get-CourseLifecycleLock
    try{
        $install=Get-CourseInstallation $InstallationId
        if($install.status -notin @('active','partial')){throw 'UNINSTALL_ALREADY_STARTED: use Resume.'}
        $db=Read-CourseLifecycle
        if(@($ProjectIds|Where-Object {$_ -notin @($install.projects.projectId)}).Count){throw 'PROJECT_NOT_REGISTERED_TO_INSTALLATION'}
        if($Scope -eq 'KeepWork' -and $ProjectIds.Count){throw 'KEEPWORK_CANNOT_DELETE_PROJECTS'}
        if($RemovePreparationDirectory -and $Scope -ne 'TestClean'){throw 'PREPARATION_DELETE_REQUIRES_TESTCLEAN'}
        if($RemovePreparationDirectory){
            foreach($project in @($install.projects|Where-Object {$_.projectId -notin $ProjectIds})){if(Test-CoursePathWithin $install.workspace $project.path -AllowEqual){throw 'PREPARATION_CONTAINS_PRESERVED_PROJECT'}}
            foreach($other in @($db.installations|Where-Object {$_.installationId -ne $InstallationId -and $_.status -ne 'removed'})){if(Test-CoursePathWithin $install.workspace $other.workspace -AllowEqual){throw 'PREPARATION_CONTAINS_OTHER_INSTALLATION'}}
            foreach($shared in @($db.resources|Where-Object {@($_.references|Where-Object {$_ -ne $InstallationId}).Count -gt 0})){if($shared.allowedRoot -and (Test-CoursePathWithin $install.workspace $shared.locator -AllowEqual)){throw 'PREPARATION_CONTAINS_SHARED_RESOURCE'}}
        }
        $operationId=[guid]::NewGuid().ToString('N');$op=Get-CourseUninstallOperationDirectory $operationId
        if(-not $OutputDirectory){$OutputDirectory=Join-Path $op 'report'}
        $output=[IO.Path]::GetFullPath($OutputDirectory);Assert-CoursePlainPath $output
        foreach($path in @($install.workspace)+@($install.projects.path)){
            if(Test-CoursePathWithin $path $output -AllowEqual){throw 'REPORT_INSIDE_TARGET_WORKSPACE'}
        }
        $items=New-Object Collections.Generic.List[object]
        $resources=@($db.resources|Where-Object {$_.references -contains $InstallationId -and $_.status -eq 'present'})
        if(@($RemoveMachineNames|Where-Object {$_ -notin @($resources|Where-Object kind -eq 'machine'|ForEach-Object locator)}).Count){throw 'MACHINE_NOT_REGISTERED_TO_INSTALLATION'}
        foreach($resource in $resources){
            $action='remove';$reason='owned-unmodified'
            if(@($resource.references|Where-Object {$_ -ne $InstallationId}).Count){$action='retain';$reason='shared'}
            elseif($resource.ownership -in @('unknown','adopted')){$action='blocked';$reason='ownership-unverified'}
            elseif($resource.ownership -eq 'reused'){$action='retain';$reason='pre-existing'}
            elseif($resource.dataClass -in @('source','businessData','signature')){$action='retain';$reason='protected-work'}
            if($action -eq 'remove' -and $resource.backupPath){$action='restorePrevious'}
            if($action -eq 'remove' -and $resource.kind -eq 'managedBlock'){$action='removeManagedBlock'}
            if($action -eq 'remove' -and $resource.kind -eq 'machine' -and $resource.locator -notin $RemoveMachineNames){$action='retain';$reason='machine-not-selected'}
            if($action -notin @('retain','blocked')){
                $check=Get-CourseResourceCheck $resource $action
                # Dependency occupancy can clear after owned containers have been removed.
                if($check.status -eq 'blocked' -and $check.reason -notin @('RESOURCE_STILL_IN_USE','NETWORK_STILL_IN_USE','MACHINE_STORES_NOT_EMPTY','MACHINE_NETWORKS_NOT_EMPTY')){$action='blocked';$reason=$check.reason}
            }
            if($RemovePreparationDirectory -and ($resource.allowedRoot -or $resource.kind -eq 'managedBlock') -and (Test-CoursePathWithin $install.workspace $resource.locator)){$action='retain';$reason='covered-by-preparation-delete'}
            $items.Add([pscustomobject]@{resourceKey=$resource.resourceKey;revision=$resource.revision;action=$action;reason=$reason;resource=$resource})
        }
        foreach($tool in @($items|Where-Object {$_.resource.kind -eq 'tool' -and $_.action -eq 'remove'})){
            if(@($items|Where-Object {$_.resource.kind -eq 'machine' -and $_.action -eq 'retain' -and $_.resource.metadata.cli -eq $tool.resource.locator}).Count){$tool.action='retain';$tool.reason='provider-for-retained-machine'}
        }
        $projects=New-Object Collections.Generic.List[object]
        foreach($project in @($install.projects)){
            $delete=$Scope -eq 'TestClean' -and $ProjectIds -contains $project.projectId
            Assert-CoursePlainPath $project.path
            $manifest=Read-CourseJson (Join-Path $project.path '.ai-coding\project.json')
            if($manifest.installationId -ne $InstallationId){throw 'PROJECT_BINDING_CHANGED'}
            $snapshot=if($delete){Get-CourseFileBaseline $project.path}else{$null}
            $projects.Add([pscustomobject]@{projectId=$project.projectId;path=$project.path;delete=$delete;baseline=$snapshot;protectedDigest=$(if(-not $delete){Get-CourseProtectedProjectSnapshot $project.path}else{$null});manifestDigest=(Get-FileHash -LiteralPath (Join-Path $project.path '.ai-coding\project.json')).Hash})
        }
        $plan=[pscustomobject]@{schemaVersion=1;operationId=$operationId;installationId=$InstallationId;userSid=$install.userSid;machine=$install.machine;workspace=$install.workspace;scope=$Scope;createdAt=(Get-Date).ToUniversalTime().ToString('o');outputDirectory=$output;items=@($items.ToArray());projects=@($projects.ToArray());pendingIntents=@($db.intents|Where-Object {$_.installationId -eq $InstallationId -and $_.status -eq 'pending'});removePreparation=[bool]$RemovePreparationDirectory;preparationBaseline=$(if($RemovePreparationDirectory){Get-CourseFileBaseline $install.workspace}else{$null});remote='retained';phone='retained';systemComponents='retained'}
        foreach($item in $plan.items){if($item.action -notin @('retain','blocked') -and $item.resource.allowedRoot -and (Test-CoursePathWithin $item.resource.locator $output -AllowEqual)){throw 'REPORT_INSIDE_DELETE_TARGET'}}
        Protect-CourseDirectory $op;Protect-CourseDirectory $output
        $file=Join-Path $op 'plan.json';Write-CourseJson $file $plan
        $digest=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        Write-CourseJson (Join-Path $op 'state.json') @{schemaVersion=1;operationId=$operationId;planSha256=$digest;status='Ready';items=@();projects=@();started=$false;exitCode=0;indexesFinalized=$false;runnerFiles=@();preparationRemoved=$false}
        $summary=@('# 卸载计划','','安装：'+$InstallationId,'范围：'+$Scope,'','| 动作 | 资源 | 原因 |','| --- | --- | --- |')
        foreach($item in $items){$summary+=('| '+$item.action+' | '+($item.resource.locator -replace '[\r\n|]',' ')+' | '+$item.reason+' |')}
        foreach($p in $projects){$summary+=('| '+$(if($p.delete){'删除测试项目'}else{'保留作品并解除环境绑定'})+' | '+($p.path -replace '[\r\n|]',' ')+' | 明确选择 |')}
        if($RemovePreparationDirectory){$summary+=('| 删除整个选定测试准备目录 | '+$install.workspace+' | 包含其全部资料、报告和本地配置 |')}
        foreach($intent in $plan.pendingIntents){$summary+=('| 待核实中断创建 | '+($intent.locator -replace '[\r\n|]',' ')+' | 创建意图尚无完成证据 |')}
        $summary+=@('','云端、手机、系统组件保留。未知归属和冲突项不会自动删除。','本次计划不证明所有共享资源没有外部使用，执行前仍逐项核验。')
        [IO.File]::WriteAllLines((Join-Path $output 'plan.md'),[string[]]$summary,[Text.UTF8Encoding]::new($false))
        return [pscustomobject]@{status='Ready';operationId=$operationId;planPath=$file;planSha256=$digest;report=(Join-Path $output 'plan.md');blocked=(@($items|Where-Object action -eq 'blocked').Count+$plan.pendingIntents.Count);exitCode=0}
    }finally{Close-CourseLifecycleLock $gate}
}
function Read-CourseUninstallOperation([string]$OperationId,[string]$ExpectedDigest) {
    $dir=Get-CourseUninstallOperationDirectory $OperationId
    $state=Read-CourseJson (Join-Path $dir 'state.json');$file=Join-Path $dir 'plan.json'
    $digest=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
    if($digest -ne $state.planSha256 -or ($ExpectedDigest -and $digest -cne $ExpectedDigest.ToLowerInvariant())){throw 'PLAN_DIGEST_CHANGED'}
    $plan=Read-CourseJson $file
    if($plan.schemaVersion -ne 1 -or $plan.operationId -ne $OperationId -or $plan.items.Count -gt 20000 -or $plan.scope -notin @('KeepWork','TestClean')){throw 'INVALID_UNINSTALL_PLAN'}
    $install=Get-CourseInstallation $plan.installationId
    if($plan.userSid -ne $install.userSid -or $plan.machine -ne $install.machine){throw 'PLAN_IDENTITY_MISMATCH'}
    foreach($item in $plan.items){if($item.action -notin @('retain','blocked','remove','restorePrevious','removeManagedBlock')){throw 'UNKNOWN_UNINSTALL_ACTION'}}
    return [pscustomobject]@{directory=$dir;state=$state;plan=$plan;installation=$install}
}
function Write-CourseUninstallEvent($Operation,[string]$ResourceKey,[string]$Status,[string]$Reason) {
    $event=@{at=(Get-Date).ToUniversalTime().ToString('o');resourceKey=$ResourceKey;status=$Status;reason=$Reason}
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($event|ConvertTo-Json -Compress)+"`n")
    $stream=[IO.File]::Open((Join-Path $Operation.directory 'events.jsonl'),[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush()}finally{$stream.Dispose()}
}
function Save-CourseUninstallState($Operation) {Write-CourseJson (Join-Path $Operation.directory 'state.json') $Operation.state}
function Set-CourseUninstallItemState($Operation,[string]$Key,[string]$Status,[string]$Reason) {
    $Operation.state.items=@($Operation.state.items|Where-Object resourceKey -ne $Key)+@([pscustomobject]@{resourceKey=$Key;status=$Status;reason=$Reason})
    Save-CourseUninstallState $Operation;Write-CourseUninstallEvent $Operation $Key $Status $Reason
}
function Install-CourseUninstallRunner($Operation) {
    $files=@('Uninstall-Course.ps1','Course-Uninstall.ps1','Course-UninstallAdapters.ps1','Course-Lifecycle.ps1','Course-Context.ps1','Course-Native.ps1')
    $runner=Join-Path $Operation.directory 'runner';Protect-CourseDirectory $runner;$checks=@()
    foreach($name in $files){
        $source=Join-Path $PSScriptRoot $name;Assert-CoursePlainPath $source
        $hash=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
        $target=Join-Path $runner $name
        if([IO.Path]::GetFullPath($source) -ne [IO.Path]::GetFullPath($target)){Copy-Item -LiteralPath $source -Destination $target -Force}
        if((Get-FileHash -LiteralPath $target).Hash -ne $hash){throw 'RUNNER_COPY_MISMATCH'}
        $checks+=@{name=$name;sha256=$hash}
    }
    $Operation.state.runnerFiles=$checks;Save-CourseUninstallState $Operation
    return Join-Path $runner 'Uninstall-Course.ps1'
}
function Invoke-CourseUninstallApply([string]$OperationId,[string]$ExpectedDigest,[switch]$Resume) {
    $gate=Get-CourseLifecycleLock
    try{
        $op=Read-CourseUninstallOperation $OperationId $ExpectedDigest
        if(-not $Resume -and $op.state.started){throw 'UNINSTALL_ALREADY_STARTED: use Resume.'}
        $db=Read-CourseLifecycle
        $active=@($db.leases|Where-Object {Test-CourseLeaseAlive $_})
        if($active.Count){throw 'LIFECYCLE_BUSY: course operations still running.'}
        foreach($item in $op.plan.items){
            $r=@($db.resources|Where-Object resourceKey -eq $item.resourceKey)
            if($r.Count -ne 1 -or $r[0].revision -ne $item.revision){throw 'PLAN_STALE'}
        }
        if(-not $op.state.started){
            $current=@($db.resources|Where-Object {$_.references -contains $op.plan.installationId -and $_.status -eq 'present'}|ForEach-Object resourceKey|Sort-Object)
            $planned=@($op.plan.items|ForEach-Object resourceKey|Sort-Object)
            if(($current -join '|') -ne ($planned -join '|')){throw 'PLAN_STALE'}
            foreach($project in $op.plan.projects){if((Get-FileHash -LiteralPath (Join-Path $project.path '.ai-coding\project.json')).Hash -ne $project.manifestDigest){throw 'PLAN_STALE'}}
        }
        $install=@($db.installations|Where-Object installationId -eq $op.plan.installationId)[0]
        if($install.status -eq 'removed' -and $Resume){return Test-CourseUninstallResult $OperationId}
        $install.status='uninstalling';$db.leases=$active;Write-CourseLifecycle $db
        $op.state.started=$true;$op.state.status='Applying';Save-CourseUninstallState $op
        foreach($item in @($op.plan.items|Sort-Object @{Expression={if($_.resource.metadata.backupFor){100}else{switch($_.resource.kind){container {10};network {20};volume {30};image {40};managedBlock {50};skill {60};machine {70};tool {80};credential {90};default {55}}}}})){
            $previous=@($op.state.items|Where-Object resourceKey -eq $item.resourceKey)|Select-Object -First 1
            if($item.action -eq 'retain'){Set-CourseUninstallItemState $op $item.resourceKey 'retained' $item.reason;continue}
            if($item.action -eq 'blocked'){Set-CourseUninstallItemState $op $item.resourceKey 'blocked' $item.reason;continue}
            try{
                if($previous.reason -eq 'RESTART_REQUIRED'){
                    $boot=(Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime().ToString('o')
                    if(-not $previous.restartBoot -or $previous.restartBoot -eq $boot){throw 'RESTART_REQUIRED'}
                }
                if($item.resource.metadata.backupFor){
                    $dependent=@($op.plan.items|Where-Object resourceKey -eq $item.resource.metadata.backupFor)|Select-Object -First 1
                    $saved=@($op.state.items|Where-Object resourceKey -eq $item.resource.metadata.backupFor)|Select-Object -First 1
                    if($dependent.action -ne 'retain' -and $saved.status -ne 'done'){throw 'BACKUP_STILL_REQUIRED'}
                    if($dependent.action -eq 'retain' -and $dependent.reason -eq 'shared'){throw 'BACKUP_SHARED_REFERENCE_REQUIRED'}
                }
                if($item.resource.kind -eq 'tool'){
                    foreach($dependent in @($op.plan.items|Where-Object {$_.resource.metadata.cli -eq $item.resource.locator})){
                        if(-not(Test-CourseResourceRemoved $dependent.resource 'remove')){throw 'TOOL_HAS_REMAINING_RESOURCES'}
                    }
                }
                if($previous.status -eq 'done'){
                    if(-not(Test-CourseResourceRemoved $item.resource $item.action)){throw 'COMPLETED_RESOURCE_REAPPEARED'}
                    if($item.resource.kind -eq 'machine' -and $item.resource.metadata.dataHomeOwned -eq $true){Remove-CourseEmptyCacheDirectories $item.resource.metadata.dataHome $item.resource.metadata.dataHomeParent}
                    continue
                }
                # An intent may have succeeded before the process exited; inspect before replay.
                if($previous.status -eq 'intent' -and (Test-CourseResourceRemoved $item.resource $item.action)){Set-CourseUninstallItemState $op $item.resourceKey 'done' 'recovered';continue}
                Set-CourseUninstallItemState $op $item.resourceKey 'intent' 'pending'
                Invoke-CourseResourceRemoval $item.resource $item.action
                if(-not(Test-CourseResourceRemoved $item.resource $item.action)){throw 'REMOVAL_NOT_VERIFIED'}
                Set-CourseUninstallItemState $op $item.resourceKey 'done' 'verified'
            }catch{
                $reason=[string]$_.Exception.Message;if($reason -notmatch '^[A-Z_]+$'){$reason='REMOVAL_FAILED'}
                Set-CourseUninstallItemState $op $item.resourceKey 'blocked' $reason
                if($reason -eq 'RESTART_REQUIRED'){
                    $state=@($op.state.items|Where-Object resourceKey -eq $item.resourceKey)[0]
                    $boot=if($previous.restartBoot){$previous.restartBoot}else{try{(Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime().ToString('o')}catch{$null}}
                    $state|Add-Member NoteProperty restartBoot $boot -Force;Save-CourseUninstallState $op
                }
            }
        }
        foreach($project in $op.plan.projects){
            $previous=@($op.state.projects|Where-Object projectId -eq $project.projectId)|Select-Object -First 1
            try{
                if($project.delete){
                    if($op.plan.removePreparation -and (Test-CoursePathWithin $op.plan.workspace $project.path)){
                        $op.state.projects=@($op.state.projects|Where-Object projectId -ne $project.projectId)+@(@{projectId=$project.projectId;status='covered-by-preparation'})
                        Save-CourseUninstallState $op;continue
                    }
                    $resource=[pscustomobject]@{kind='project';locator=$project.path;allowedRoot=(Split-Path $project.path -Parent);baseline=$project.baseline;metadata=@{};backupPath=$null}
                    $overlap=@($op.plan.items|Where-Object {$_.resource.metadata.projectId -eq $project.projectId -and $_.resourceKey -in @($op.state.items|Where-Object status -eq 'blocked'|ForEach-Object resourceKey)})
                    if($overlap.Count){throw 'PROJECT_RESOURCES_NOT_REMOVED'}
                    if(-not(Test-Path -LiteralPath $project.path) -and $previous.status -in @('intent','done')){}
                    else{
                        # Earlier removal of owned project-local files may change the tree. Never silently
                        # refresh this snapshot: a new plan is required rather than deleting new work.
                        $op.state.projects=@($op.state.projects|Where-Object projectId -ne $project.projectId)+@(@{projectId=$project.projectId;status='intent'})
                        Save-CourseUninstallState $op
                        Invoke-CourseResourceRemoval $resource 'remove'
                    }
                }else{
                    if((Get-CourseProtectedProjectSnapshot $project.path) -ne $project.protectedDigest){throw 'PRESERVED_PROJECT_CHANGED'}
                    $manifest=Join-Path $project.path '.ai-coding\project.json';$p=Read-CourseJson $manifest
                    if($p.installationId -ne $op.plan.installationId){throw 'PROJECT_BINDING_CHANGED'}
                    $p|Add-Member NoteProperty preparationStatus 'detached' -Force
                    Write-CourseJson $manifest $p
                    foreach($name in @('preparation.json','local.json')){
                        $binding=Join-Path $project.path ('.ai-coding\'+$name)
                        if(Test-Path -LiteralPath $binding){$value=Read-CourseJson $binding;$value|Add-Member NoteProperty lifecycleStatus 'detached' -Force;Write-CourseJson $binding $value}
                    }
                }
                $op.state.projects=@($op.state.projects|Where-Object projectId -ne $project.projectId)+@(@{projectId=$project.projectId;status='done'})
            }catch{$op.state.projects=@($op.state.projects|Where-Object projectId -ne $project.projectId)+@(@{projectId=$project.projectId;status='blocked'})}
            Save-CourseUninstallState $op
        }
        if($op.plan.removePreparation){
            try{
                if(@($op.state.items|Where-Object status -eq 'blocked').Count -or $op.plan.pendingIntents.Count){throw 'PREPARATION_RESOURCES_NOT_REMOVED'}
                $resource=[pscustomobject]@{kind='directory';locator=$op.plan.workspace;allowedRoot=(Split-Path $op.plan.workspace -Parent);baseline=$op.plan.preparationBaseline;metadata=@{};backupPath=$null}
                Invoke-CourseResourceRemoval $resource 'remove'
                $op.state.preparationRemoved=$true
            }catch{$op.state.preparationRemoved=$false}
            Save-CourseUninstallState $op
        }
        $op.state.status='Verifying';Save-CourseUninstallState $op
        return Test-CourseUninstallResult $OperationId -Finalize
    }finally{Close-CourseLifecycleLock $gate}
}
function Test-CourseUninstallResult([string]$OperationId,[switch]$Finalize) {
    $op=Read-CourseUninstallOperation $OperationId
    $issues=New-Object Collections.Generic.List[string]
    foreach($item in $op.plan.items){
        if($item.action -eq 'retain'){continue}
        $status=@($op.state.items|Where-Object resourceKey -eq $item.resourceKey)|Select-Object -First 1
        if($status.status -ne 'done'){$issues.Add($item.resourceKey);continue}
        try{if(-not(Test-CourseResourceRemoved $item.resource $item.action)){$issues.Add($item.resourceKey)}}catch{$issues.Add($item.resourceKey)}
    }
    foreach($project in $op.plan.projects){
        try{
            if($project.delete){if(Test-Path -LiteralPath $project.path){throw 'PROJECT_REMAINS'}}
            elseif((Get-CourseProtectedProjectSnapshot $project.path) -ne $project.protectedDigest -or (Read-CourseJson (Join-Path $project.path '.ai-coding\project.json')).preparationStatus -ne 'detached'){throw 'PRESERVED_PROJECT_NOT_VERIFIED'}
        }catch{$issues.Add($project.projectId)}
    }
    if(-not $op.state.started){$issues.Add('not-applied')}
    foreach($intent in @($op.plan.pendingIntents)){$issues.Add('intent-'+$intent.id)}
    if($op.plan.removePreparation -and (Test-Path -LiteralPath $op.plan.workspace)){$issues.Add('preparation-directory')}
    $remainingCaches=@($op.plan.items|ForEach-Object {$_.resource.metadata.dataHome}|Where-Object {$_ -and (Test-Path -LiteralPath $_)}|Select-Object -Unique)
    if($op.plan.scope -eq 'TestClean'){
        foreach($item in @($op.plan.items|Where-Object {$_.resource.kind -eq 'machine' -and $_.action -ne 'retain' -and $_.resource.metadata.dataHomeOwned -eq $true -and $_.resource.metadata.dataHome -in $remainingCaches})){$issues.Add('provider-cache-'+$item.resourceKey)}
    }
    if(-not $Finalize -and -not $op.state.indexesFinalized){$issues.Add('indexes-not-finalized')}
    if($Finalize){
        $db=Read-CourseLifecycle
        foreach($item in $op.plan.items){
            $state=@($op.state.items|Where-Object resourceKey -eq $item.resourceKey)|Select-Object -First 1
            if(($item.action -eq 'retain' -and ($item.reason -ne 'covered-by-preparation-delete' -or $op.state.preparationRemoved)) -or ($state.status -eq 'done' -and $issues -notcontains $item.resourceKey)){
                $r=@($db.resources|Where-Object resourceKey -eq $item.resourceKey)[0]
                $r.references=@($r.references|Where-Object {$_ -ne $op.plan.installationId})
                if(-not $r.references.Count -and ($item.action -ne 'retain' -or $item.reason -eq 'covered-by-preparation-delete')){$r.status='removed'}
            }
        }
        $install=@($db.installations|Where-Object installationId -eq $op.plan.installationId)[0]
        $deleted=@($op.plan.projects|Where-Object {$_.delete -and -not(Test-Path -LiteralPath $_.path)}|ForEach-Object projectId)
        $install.projects=@($install.projects|Where-Object {$_.projectId -notin $deleted})
        $install.status=if($issues.Count){'partial'}else{'uninstalling'}
        Write-CourseLifecycle $db
        if(-not $issues.Count -and -not $op.state.indexesFinalized){
            foreach($name in @('preparation-index.json','services.json')){
                $file=Join-Path (Get-CourseUserRoot) $name
                if(Test-Path -LiteralPath $file){
                    $index=Read-CourseJson $file
                    if($install.preparationId){$index.preparations=@($index.preparations|Where-Object preparationId -ne $install.preparationId);if($index.PSObject.Properties['selectedId'] -and $index.selectedId -eq $install.preparationId){$index.selectedId=$null}}
                    Write-CourseJson $file $index
                }
            }
            $toolsFile=Join-Path (Get-CourseUserRoot) 'tool-paths.json'
            if(Test-Path -LiteralPath $toolsFile){
                $tools=Read-CourseJson $toolsFile
                foreach($key in @('cli','compose')){
                    $removed=@($op.plan.items|Where-Object {$_.resource.kind -eq 'tool' -and $_.resource.locator -eq $tools.podman.$key -and $_.action -ne 'retain'})
                    if($removed.Count -and -not(Test-Path -LiteralPath $tools.podman.$key)){$tools.podman.$key=$null}
                }
                Write-CourseJson $toolsFile $tools
            }
            $executionFile=Join-Path (Get-CourseUserRoot) 'execution.json'
            if(Test-Path -LiteralPath $executionFile){
                $execution=Read-CourseJson $executionFile
                $owned=@($op.plan.items|Where-Object {$_.resource.kind -eq 'directory' -and $_.resource.locator -eq $execution.executionRoot -and $_.action -ne 'retain'})
                if($owned.Count -and -not(Test-Path -LiteralPath $execution.executionRoot)){Assert-CoursePlainPath $executionFile;Remove-Item -LiteralPath $executionFile}
            }
            $link=Join-Path $install.workspace '.course-setup\lifecycle.json'
            if(Test-Path -LiteralPath $link){Write-CourseJson $link @{schemaVersion=1;installationId=$install.installationId;status='removed';operationId=$OperationId}}
            $op.state.indexesFinalized=$true;Save-CourseUninstallState $op
        }
        if(-not $issues.Count){$db=Read-CourseLifecycle;@($db.installations|Where-Object installationId -eq $op.plan.installationId)[0].status='removed';Write-CourseLifecycle $db}
    }
    $code=if(@($op.state.items|Where-Object reason -match 'RESTART_REQUIRED|ELEVATION_REQUIRED').Count){4}elseif($issues.Count){2}else{0};$status=if($issues.Count){'Partial'}else{'Completed'}
    $op.state.status=$status;$op.state.exitCode=$code;Save-CourseUninstallState $op
    $result=[pscustomobject]@{schemaVersion=1;operationId=$OperationId;installationId=$op.plan.installationId;status=$status;exitCode=$code;issues=@($issues.ToArray());items=@($op.state.items);projects=@($op.state.projects);retainedPreparation=$(if(Test-Path -LiteralPath $op.plan.workspace){$op.plan.workspace}else{$null});unverifiedProviderCaches=$remainingCaches;remote='retained';phone='retained';systemComponents='retained';traeLoad='requires-new-session-observation';runner=(Join-Path $op.directory 'runner\Uninstall-Course.ps1');report=(Join-Path $op.plan.outputDirectory 'result.md')}
    $resourceResults=@(foreach($item in $op.plan.items){$state=@($op.state.items|Where-Object resourceKey -eq $item.resourceKey)|Select-Object -First 1;[pscustomobject]@{kind=$item.resource.kind;locator=$item.resource.locator;action=$item.action;status=$state.status;reason=$state.reason}})
    $result|Add-Member NoteProperty resources $resourceResults
    Write-CourseJson (Join-Path $op.plan.outputDirectory 'result.json') $result
    $lines=@('# 卸载结果','','状态：'+$status,'安装：'+$result.installationId,'未解决项：'+$issues.Count,'','| 状态 | 动作 | 资源 | 原因 |','| --- | --- | --- | --- |')
    foreach($item in $resourceResults){$lines+=('| '+$item.status+' | '+$item.action+' | '+($item.locator -replace '[\r\n|]',' ')+' | '+$item.reason+' |')}
    $lines+=@('','云端、手机和系统组件保留。源码等保留项按计划验证；Trae 新会话实际加载/移除需另行观察。','报告与脱敏操作记录保留；未完成资源按原计划 Resume，不清空共享目录。')
    if($result.retainedPreparation){$lines+=('保留准备目录（含原报告）：'+$result.retainedPreparation)}
    foreach($cache in $remainingCaches){$lines+=('提供程序缓存目录保留，内部创建归属未逐项证明：'+$cache)}
    if(@($resourceResults|Where-Object {$_.action -eq 'restorePrevious' -and $_.status -eq 'done'}).Count){$lines+='安装前副本已恢复（restorePrevious）；这不表示之前安装的其他工具也已卸载。'}
    [IO.File]::WriteAllLines($result.report,[string[]]$lines,[Text.UTF8Encoding]::new($false))
    return $result
}
