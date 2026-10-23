#Requires -Version 5.1
# Scoped installation reuses the verified archive/tree and lifecycle helpers.
. (Join-Path $PSScriptRoot 'Course-Upgrade.ps1')
. (Join-Path $PSScriptRoot 'Course-Archive.ps1')

function Get-CourseSkillScopePolicy {
    $file=Join-Path $PSScriptRoot '../assets/course-contract.json'
    if(-not(Test-Path -LiteralPath $file)){$file=Join-Path $PSScriptRoot 'course-contract.json'}
    return Read-CourseJson $file
}
function Get-CourseScopeMigrationRoots([string]$Workspace) {
    $roots=@($Workspace)
    foreach($installation in (Read-CourseLifecycle).installations){
        if($installation.status -ne 'removed'){$roots+=@($installation.workspace)}
        $roots+=@($installation.projects|ForEach-Object {$_.path})
    }
    return @($roots|Where-Object {$_ -and (Test-Path -LiteralPath $_ -PathType Container)}|ForEach-Object {[IO.Path]::GetFullPath($_)}|Select-Object -Unique)
}
function Get-CourseScopeRoutePlan([string[]]$Roots,[string]$Assets,$Retired){
    $snapshots=@(Get-ChildItem -LiteralPath $Assets -Filter 'guidance-legacy*.json'|ForEach-Object {Read-CourseJson $_.FullName})
    $map=@{'AGENTS.project.md'='AGENTS.md';'trae-entry.md'='.trae/rules/course-entry.md';'spec-template.md'='docs/specs/_template.md'}
    foreach($file in Get-ChildItem -LiteralPath (Join-Path $Assets 'engineering') -File -Filter *.md){$map['engineering/'+$file.Name]='docs/engineering/'+$file.Name}
    $routes=@();$pending=@()
    foreach($ownerRoot in $Roots){foreach($key in $map.Keys){
        $path=Join-Path $ownerRoot $map[$key];Assert-CoursePlainPath $path
        if(-not(Test-Path -LiteralPath $path -PathType Leaf)){continue}
        $bytes=[IO.File]::ReadAllBytes($path);$old=[IO.File]::ReadAllText($path).Replace("`r`n","`n")
        $fresh=[IO.File]::ReadAllText((Join-Path $Assets $key)).Replace("`r`n","`n")
        if($old -eq $fresh){continue}
        $updated=$null
        foreach($snapshot in $snapshots){
            if($snapshot.$key -and $old.StartsWith([string]$snapshot.$key,[StringComparison]::Ordinal)){$updated=$fresh+$old.Substring(([string]$snapshot.$key).Length);break}
        }
        if(-not $updated){
            $start='<!-- ai-coding:guidance:'+ $key +':start -->';$end='<!-- ai-coding:guidance:'+ $key +':end -->'
            $pattern='(?s)'+[regex]::Escape($start)+'\n(.*?)\n'+[regex]::Escape($end)
            $match=[regex]::Match($old,$pattern)
            if($match.Success){
                $known=@($snapshots|Where-Object {$_.${key} -and ([string]$_.${key}).TrimEnd() -ceq $match.Groups[1].Value.TrimEnd()}).Count -gt 0
                if($known -or $match.Groups[1].Value.TrimEnd() -ceq $fresh.TrimEnd()){$updated=$old.Substring(0,$match.Index)+$start+"`n"+$fresh.TrimEnd()+"`n"+$end+$old.Substring($match.Index+$match.Length)}
            }
        }
        if($updated){$routes+=@{root=$ownerRoot;relative=$map[$key];path=$path;before=[Convert]::ToBase64String($bytes);after=[Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes($updated))}}
        elseif($old -match '\.trae[/\\]skills|ai-coding-development|ai-coding-siliconflow'){
            if(@($Retired|Where-Object {$_.boundary -eq (Join-Path $ownerRoot '.trae/skills')}).Count){throw ('CUSTOM_PROJECT_ROUTE_REQUIRES_MERGE: '+$path)}
            $pending+=$path
        }
    }}
    return @{routes=$routes;pending=$pending}
}
function Write-CourseScopeRoute([string]$Path,[byte[]]$Bytes){
    Assert-CoursePlainPath $Path;$temp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{[IO.File]::WriteAllBytes($temp,$Bytes);[IO.File]::Replace($temp,$Path,($temp+'.backup'))}
    finally{foreach($file in @($temp,($temp+'.backup'))){if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file}}}
}

function Install-CourseExecutionPackage([string]$Workspace,[string]$PackageRoot,$Bundle,[switch]$NoDefaultSwitch) {
    $storage = Join-Path $Workspace '.course-setup/storage-plan.json'
    $base = Join-Path (Get-CourseUserRoot) 'runtimes'
    if (Test-Path -LiteralPath $storage) {
        $plan = Read-CourseJson $storage
        if ($plan.desiredRoot) { $base = Join-Path $plan.desiredRoot 'programs/ai-coding/runtimes' }
    }
    if ($Bundle.contentId -cnotmatch '^[a-f0-9]{64}$') { throw 'INVALID_EXECUTION_CONTENT_ID' }
    $destination = Join-Path $base $Bundle.contentId.Substring(0,16)
    Assert-CoursePlainPath $destination
    $created=$false
    if (-not (Test-Path -LiteralPath (Join-Path $destination 'execution-manifest.json'))) {
        $stage = Join-Path $base ('.stage-'+[guid]::NewGuid().ToString('N').Substring(0,8))
        [void](New-Item -ItemType Directory -Path $stage -Force)
        $envEntry = $Bundle.skills.'ai-coding-env'
        $archive = Join-Path $PackageRoot $envEntry.archive
        if ((Get-FileHash -LiteralPath $archive).Hash.ToLowerInvariant() -cne $envEntry.sha256) { throw 'EXECUTION_ARCHIVE_MISMATCH' }
        $unpacked = Join-Path $stage 'unpacked'
        Expand-CourseMaterials $archive $unpacked
        if (-not (Test-CourseTree (Get-CourseTreeHashes $unpacked) $envEntry.files)) { throw 'EXECUTION_CONTENT_MISMATCH' }
        foreach ($name in @('scripts','assets','references')) { Copy-Item -LiteralPath (Join-Path $unpacked $name) -Destination (Join-Path $stage $name) -Recurse }
        # Cache complete packages outside skill discovery, so a moved A does not break B.
        $cache = Join-Path $stage 'packages'; [void](New-Item -ItemType Directory -Path $cache)
        foreach ($name in @($Bundle.files.PSObject.Properties.Name)+@('bundle-manifest.json')+@($Bundle.skills.PSObject.Properties | ForEach-Object { $_.Value.archive })) {
            $source = Join-Path $PackageRoot $name; $target = Join-Path $cache $name
            Assert-CourseRelativeFile $name
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw ('EXECUTION_PACKAGE_COMPONENT_MISSING: '+$name) }
            $skill = @($Bundle.skills.PSObject.Properties | Where-Object { $_.Value.archive -eq $name })
            if ($skill.Count -and (Get-FileHash -LiteralPath $source).Hash.ToLowerInvariant() -cne $skill[0].Value.sha256) { throw 'EXECUTION_CACHED_ARCHIVE_MISMATCH' }
            [void](New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force)
            Copy-Item -LiteralPath $source -Destination $target
        }
        # All published files, including the cached bundle, are integrity checked on use.
        $files = Get-CourseTreeHashes $stage
        foreach ($key in @($files.Keys | Where-Object { $_ -like 'unpacked/*' })) { $files.Remove($key) }
        Write-CourseJson (Join-Path $stage 'execution-manifest.json') @{schemaVersion=1;contentId=$Bundle.contentId;files=$files}
        [void](New-Item -ItemType Directory -Path $base -Force)
        if (Test-Path -LiteralPath $destination) { throw 'INCOMPLETE_EXECUTION_PACKAGE_PRESERVED' }
        Move-Item -LiteralPath $stage -Destination $destination
        $created=$true
    }
    if ((Read-CourseJson (Join-Path $destination 'execution-manifest.json')).contentId -cne $Bundle.contentId) { throw 'EXECUTION_CONTENT_ID_COLLISION' }
    . (Join-Path $destination 'scripts/Course-Execution.ps1')
    $pointer = @{executionRoot=$destination;executionId=$Bundle.contentId}
    # Validate the new package before switching the user default. Existing projects stay pinned.
    $check = Read-CourseJson (Join-Path $destination 'execution-manifest.json')
    foreach ($item in $check.files.PSObject.Properties) {
        if ((Get-FileHash -LiteralPath (Join-Path $destination $item.Name)).Hash.ToLowerInvariant() -cne $item.Value) { throw 'EXECUTION_PACKAGE_CHANGED' }
    }
    if(-not $NoDefaultSwitch){Write-CourseJson (Join-Path (Get-CourseUserRoot) 'execution.json') $pointer}
    return [pscustomobject]@{executionRoot=$destination;executionId=$Bundle.contentId;created=$created}
}

function Install-CourseScopedSkills {
    param([string]$Workspace,[string]$PackageRoot,[ValidateSet('Preparation','Project','User')][string]$Scope='Preparation',[string[]]$Names)
    $Workspace = (Resolve-Path -LiteralPath $Workspace).Path
    $PackageRoot = (Resolve-Path -LiteralPath $PackageRoot).Path
    $bundle = Assert-CourseBundle $PackageRoot
    $contract = Read-CourseJson (Join-Path $PackageRoot 'course-contract.json')
    if (-not $contract.skillScopes) { throw 'SCOPED_PACKAGE_REQUIRED' }
    if($contract.scopePolicy -ne 'user-platform-skills-v1' -or $contract.minimumScopeInstallerProtocol -gt 3){throw 'GLOBAL_PLATFORM_SCOPE_INSTALLER_PROTOCOL_REQUIRED'}
    $lock = Enter-CourseUpgradeLock
    try {
        Repair-CourseScopedTransactions $Workspace
        if($Scope -eq 'Preparation'){
            . (Join-Path $PSScriptRoot 'Course-InstallRecovery.ps1')
            $recovery=Repair-CourseInstallationForInstall $Workspace
            if($recovery.status -eq 'ready-to-install'){Write-Host ('旧安装残留已清理：'+$recovery.removed+' 项；共享及自定义内容保留。报告：'+$recovery.report)}
        }
        if (-not $Names.Count) { $Names = switch ($Scope) { Preparation { @($contract.skillScopes.user)+@($contract.skillScopes.preparation) } User { @($contract.skillScopes.user) } Project { @() } } }
        $Names = @($Names | Select-Object -Unique)
        if (-not $Names.Count) { throw 'EXPLICIT_PROJECT_SKILLS_REQUIRED' }
        if($contract.scopePolicy -ne 'user-platform-skills-v1'){throw 'GLOBAL_PLATFORM_SCOPE_PACKAGE_REQUIRED'}
        # All replacements are staged and verified before any old discovery copy moves.
        if($Scope -eq 'Preparation'){$Names=@($Names+@($contract.skillScopes.user)|Select-Object -Unique)}
        $root = Join-Path $Workspace ('.local/skill-transactions/'+[guid]::NewGuid().ToString('N'))
        $null=Protect-CourseDirectory $root
        $items = @()
        foreach ($name in $Names) {
            $entry = $bundle.skills.$name
            $definition = @($contract.skills | Where-Object name -eq $name)
            if ($definition.Count -ne 1 -or -not $entry) { throw 'SKILL_NOT_IN_LOCKED_BUNDLE' }
            $targetScope = if ($definition[0].scopes -contains 'User') { 'User' } else { $Scope }
            if($Scope -eq 'Project' -and $targetScope -eq 'User'){throw ('USER_SKILL_INSTALL_FROM_PREPARATION: '+$name)}
            if ($definition[0].scopes -notcontains $targetScope) { throw ('SKILL_SCOPE_NOT_ALLOWED: '+$name) }
            $skills = if ($targetScope -eq 'User') { Join-Path $env:USERPROFILE '.trae-cn/skills' } else { Join-Path $Workspace '.trae/skills' }
            $dest = Join-Path $skills $name; Assert-CoursePlainPath $dest
            $ledger = if ($targetScope -eq 'User') { Join-Path (Get-CourseUserRoot) 'installed-skills.json' } else { Join-Path $Workspace '.ai-coding/installed-skills.json' }
            $prior = if (Test-Path -LiteralPath $ledger) { Read-CourseJson $ledger } else { [pscustomobject]@{schemaVersion=2;skills=[pscustomobject]@{}} }
            $actual = Get-CourseTreeHashes $dest
            $same = Test-CourseTree $actual $entry.files
            if ($actual.Count -and -not $same) {
                $known = $prior.skills.$name
                if (-not $known -or -not (Test-CourseTree $actual $known.files)) { throw ('LOCAL_SKILL_CHANGE_PRESERVED: '+$name) }
            }
            $zip = Join-Path $PackageRoot $entry.archive
            if ((Get-FileHash -LiteralPath $zip).Hash.ToLowerInvariant() -cne $entry.sha256) { throw 'SKILL_ARCHIVE_MISMATCH' }
            $staged = Join-Path $root ('stage/'+$name)
            [void](New-Item -ItemType Directory -Path (Split-Path $staged -Parent) -Force)
            Expand-CourseMaterials $zip $staged
            if (-not (Test-CourseTree (Get-CourseTreeHashes $staged) $entry.files)) { throw 'SKILL_CONTENT_MISMATCH' }
            $header = Get-Content -LiteralPath (Join-Path $staged 'SKILL.md') -Raw -Encoding UTF8
            if ($header -cnotmatch ('(?m)^name:\s*'+[regex]::Escape($name)+'\s*$')) { throw 'SKILL_NAME_MISMATCH' }
            $items += [pscustomobject]@{Name=$name;Destination=$dest;Scope=$targetScope;stage=$staged;ledger=$ledger;prior=$prior;entry=$entry;same=$same;backup=$null;applied=$false}
        }
        # Remove only byte-identical, registered old global copies. Custom copies block isolation.
        $globalLedger = Join-Path (Get-CourseUserRoot) 'installed-skills.json'
        $old = if (Test-Path -LiteralPath $globalLedger) { Read-CourseJson $globalLedger } else { $null }
        $retired = @()
        foreach ($name in @('ai-coding-env','ai-coding-development','ai-coding-siliconflow','knowstar-course')) {
            $path = Join-Path $env:USERPROFILE ('.trae-cn/skills/'+$name); Assert-CoursePlainPath $path
            if (-not (Test-Path -LiteralPath $path)) { continue }
            if($name -eq 'ai-coding-env' -and $Scope -ne 'Preparation'){throw 'PREPARATION_SCOPE_MIGRATION_REQUIRED: migrate the original A before retiring global env'}
            if (-not $old.skills.$name -or -not (Test-CourseTree (Get-CourseTreeHashes $path) $old.skills.$name.files)) { throw ('GLOBAL_SKILL_CHANGE_PRESERVED: '+$name) }
            $retired += @{source=$path;backup=(Join-Path $root ('retired/global-'+$name));files=$old.skills.$name.files;boundary=(Split-Path $path -Parent)}
        }
        $migrationLedgers=@{}
        if($Scope -in @('Preparation','User')){
            foreach($knownRoot in (Get-CourseScopeMigrationRoots $Workspace)){
                Assert-CoursePlainPath $knownRoot
                $ledgerPath=Join-Path $knownRoot '.ai-coding/installed-skills.json'
                $local=if(Test-Path -LiteralPath $ledgerPath){Read-CourseJson $ledgerPath}else{$null}
                foreach($name in @($contract.skillScopes.user)){
                    $path=Join-Path $knownRoot ('.trae/skills/'+$name);Assert-CoursePlainPath $path
                    if(-not(Test-Path -LiteralPath $path)){continue}
                    if($Names -notcontains $name){throw 'COMPLETE_GLOBAL_SKILL_MIGRATION_REQUIRED'}
                    if(-not $local.skills.$name -or -not (Test-CourseTree (Get-CourseTreeHashes $path) $local.skills.$name.files)){throw ('LOCAL_SKILL_CHANGE_PRESERVED: '+$path)}
                    $retired+=@{source=$path;backup=(Join-Path $root ('retired/local-'+$retired.Count+'-'+$name));files=$local.skills.$name.files;boundary=(Split-Path $path -Parent)}
                    if(-not $migrationLedgers.ContainsKey($ledgerPath)){$migrationLedgers[$ledgerPath]=@{existed=$true;bytes=[IO.File]::ReadAllBytes($ledgerPath);value=$local}}
                    $local.skills.PSObject.Properties.Remove($name)
                }
            }
        }
        $routePlan=@{routes=@();pending=@()}
        $projectItem=@($items|Where-Object Name -eq 'ai-coding-project')
        if($projectItem.Count){$routePlan=Get-CourseScopeRoutePlan (Get-CourseScopeMigrationRoots $Workspace) (Join-Path $projectItem[0].stage 'assets') $retired}
        $pointerPath = Join-Path (Get-CourseUserRoot) 'execution.json'
        $pointerBefore = if (Test-Path -LiteralPath $pointerPath) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($pointerPath)) } else { $null }
        $execution = Install-CourseExecutionPackage $Workspace $PackageRoot $bundle -NoDefaultSwitch
        $ledgers = $migrationLedgers
        $catalogLock=Get-CourseLifecycleLock
        $catalogPath=Join-Path (Get-CourseLifecycleRoot) 'catalog.json'
        $catalogBefore=if(Test-Path -LiteralPath $catalogPath){[Convert]::ToBase64String([IO.File]::ReadAllBytes($catalogPath))}else{$null}
        $metadataBefore=@()
        foreach($relative in @('.course-setup/materials.json','.course-setup/skills-installation.json')){
            $path=Join-Path $Workspace $relative
            $metadataBefore+=@{path=$path;bytes=$(if(Test-Path -LiteralPath $path){[Convert]::ToBase64String([IO.File]::ReadAllBytes($path))}else{$null})}
        }
        # Persist an intent before moving files. Recovery accepts only original or
        # expected installed bytes; an unexpected concurrent/custom change blocks it.
        foreach($item in $items){
            if(-not $item.same -and (Test-Path -LiteralPath $item.Destination)){$item.backup=Join-Path $root ('backup/'+$item.Name)}
        }
        $intentItems=@($items|ForEach-Object {@{name=$_.Name;scope=$_.Scope;destination=$_.Destination;applied=(-not $_.same);backup=$_.backup;files=$_.entry.files;before=(Get-CourseTreeHashes $_.Destination)}})
        $intentLedgers=@(@($items.ledger)+@($migrationLedgers.Keys)|Select-Object -Unique|ForEach-Object {@{path=$_;existed=(Test-Path -LiteralPath $_);bytes=$(if(Test-Path -LiteralPath $_){[Convert]::ToBase64String([IO.File]::ReadAllBytes($_))}else{$null})}})
        $journalPath=Join-Path $root 'transaction.json'
        $intent=@{schemaVersion=2;root=$root;status='Applying';workspace=$Workspace;scope=$Scope;items=$intentItems;ledgers=$intentLedgers;retired=@($retired);routes=@($routePlan.routes);executionRoot=$execution.executionRoot;pointerBefore=$pointerBefore;catalogBefore=$catalogBefore;catalogAfter=$(if(Test-Path -LiteralPath $catalogPath){(Get-FileHash -LiteralPath $catalogPath).Hash.ToLowerInvariant()}else{$null});metadataBefore=$metadataBefore}
        Write-CourseJson $journalPath $intent
        try {
            Write-CourseJson $pointerPath @{executionRoot=$execution.executionRoot;executionId=$execution.executionId}
            foreach ($item in $items) {
                if (-not $ledgers.ContainsKey($item.ledger)) { $ledgers[$item.ledger] = @{existed=(Test-Path -LiteralPath $item.ledger);bytes=$(if(Test-Path -LiteralPath $item.ledger){[IO.File]::ReadAllBytes($item.ledger)}else{$null});value=$item.prior} }
                if (-not $item.same) {
                    [void](New-Item -ItemType Directory -Path (Split-Path $item.Destination -Parent) -Force)
                    if (Test-Path -LiteralPath $item.Destination) { $item.backup=Join-Path $root ('backup/'+$item.Name);[void](New-Item -ItemType Directory -Path (Split-Path $item.backup -Parent) -Force);Move-Item -LiteralPath $item.Destination -Destination $item.backup }
                    Move-Item -LiteralPath $item.stage -Destination $item.Destination; $item.applied=$true
                }
                $ledgers[$item.ledger].value.skills | Add-Member NoteProperty $item.Name ([pscustomobject]@{files=$item.entry.files;runtimeContractId=$bundle.runtimeContractId;materialsProtocol=1;scope=$item.Scope;archiveSha256=$item.entry.sha256}) -Force
            }
            foreach ($item in $retired) { [void](New-Item -ItemType Directory -Path (Split-Path $item.backup -Parent) -Force);Move-Item -LiteralPath $item.source -Destination $item.backup }
            foreach($route in $routePlan.routes){
                if([Convert]::ToBase64String([IO.File]::ReadAllBytes($route.path)) -cne $route.before){throw 'PROJECT_ROUTE_CHANGED_DURING_MIGRATION'}
                Write-CourseScopeRoute $route.path ([Convert]::FromBase64String($route.after))
            }
            foreach ($path in @($ledgers.Keys)) {
                if ($path -eq $globalLedger) { foreach ($name in @($ledgers[$path].value.skills.PSObject.Properties.Name)) { if ($contract.skillScopes.user -notcontains $name) { $ledgers[$path].value.skills.PSObject.Properties.Remove($name) } } }
                $expected=[Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes(($ledgers[$path].value|ConvertTo-Json -Depth 20)))
                foreach($saved in $intent.ledgers){if($saved.path -eq $path){$saved.expected=$expected}}
                Write-CourseJson $journalPath $intent
                Write-CourseJson $path $ledgers[$path].value
            }
            $record = @{schemaVersion=2;ContractVersion=$contract.baselineVersion;scopePolicy=$contract.scopePolicy;PackageRoot=$PackageRoot;SkillScope=$Scope;SkillsDirectory=(Join-Path $Workspace '.trae/skills');SkillNames=$Names;executionRoot=$execution.executionRoot;executionId=$execution.executionId;TransactionRoot=$root;pendingCustomGuidance=@($routePlan.pending);TraeLoadVerified=$false}
            if ($Scope -eq 'Preparation') { Write-CourseJson (Join-Path $Workspace '.course-setup/skills-installation.json') $record }
            if (Get-Command Register-CourseInstallation -ErrorAction SilentlyContinue) {
                $version = (Read-CourseJson (Join-Path $PackageRoot 'VERSION.json')).version
                $installation = Register-CourseInstallation $Workspace $version
                foreach ($item in $items) {
                    $null = Register-CourseResource -InstallationId $installation.installationId -Kind skill -Locator $item.Destination -Ownership $(if($item.same){'reused'}else{'created'}) -AllowedRoot (Split-Path $item.Destination -Parent) -BackupPath $item.backup
                }
                $null = Register-CourseResource -InstallationId $installation.installationId -Kind directory -Locator $execution.executionRoot -Ownership $(if($execution.created){'created'}else{'reused'}) -AllowedRoot (Split-Path $execution.executionRoot -Parent) -DataClass rebuildable
                if($retired.Count){
                    $catalog=Read-CourseLifecycle
                    foreach($resource in @($catalog.resources|Where-Object {$_.locator -in @($retired|ForEach-Object {$_.source})})){$resource.status='retired-scoped-migration'}
                    Write-CourseLifecycle $catalog
                }
            }
            $savedLedgers = @($ledgers.Keys | ForEach-Object { @{path=$_;existed=$ledgers[$_].existed;bytes=$(if($ledgers[$_].existed){[Convert]::ToBase64String($ledgers[$_].bytes)}else{$null});expected=[Convert]::ToBase64String([IO.File]::ReadAllBytes($_))} })
            $savedItems = @($items | ForEach-Object { @{name=$_.Name;scope=$_.Scope;destination=$_.Destination;applied=$_.applied;backup=$_.backup;files=$_.entry.files} })
            Write-CourseJson $journalPath @{schemaVersion=2;root=$root;status='Committed';workspace=$Workspace;scope=$Scope;names=$Names;items=$savedItems;ledgers=$savedLedgers;retired=@($retired);routes=@($routePlan.routes);executionRoot=$execution.executionRoot;pointerBefore=$pointerBefore;catalogBefore=$catalogBefore;catalogAfter=(Get-FileHash -LiteralPath $catalogPath).Hash.ToLowerInvariant();metadataBefore=$metadataBefore}
            foreach ($item in $items) { [pscustomobject]@{PackageRoot=$PackageRoot;Name=$item.Name;Destination=$item.Destination;Scope=$item.Scope;Changed=(-not $item.same);BackupPath=$item.backup;ProjectBackupPath=$null;ExecutionRoot=$execution.executionRoot;TransactionRoot=$root} }
        } catch {
            $failure=$_
            $intent.catalogAfter=if(Test-Path -LiteralPath $catalogPath){(Get-FileHash -LiteralPath $catalogPath).Hash.ToLowerInvariant()}else{$null}
            Write-CourseJson $journalPath $intent
            # Validate every current tree/route/ledger before rollback; never overwrite a concurrent custom edit.
            Restore-CourseScopedTransaction ([pscustomobject]$intent)
            throw $failure
        } finally { Close-CourseLifecycleLock $catalogLock }
    } finally { Exit-CourseUpgradeLock $lock }
}

function Restore-CourseScopedTransaction($Journal) {
    $restoreLock=Get-CourseLifecycleLock
    try {
    $workspace = [IO.Path]::GetFullPath($Journal.workspace)
    $root = [IO.Path]::GetFullPath($Journal.root)
    if ($Journal.schemaVersion -ne 2 -or $Journal.status -notin @('Committed','Applying') -or -not $root.StartsWith((Join-Path $workspace '.local/skill-transactions/'),[StringComparison]::OrdinalIgnoreCase)) { throw 'INVALID_SCOPED_TRANSACTION' }
    $interrupted=$Journal.status -eq 'Applying'
    $catalogPath=Join-Path (Get-CourseLifecycleRoot) 'catalog.json'
    if($Journal.catalogAfter -and (Get-FileHash -LiteralPath $catalogPath).Hash.ToLowerInvariant() -cne $Journal.catalogAfter){throw 'SCOPED_ROLLBACK_LIFECYCLE_CHANGED'}
    foreach ($item in $Journal.items) {
        $expected = if ($item.scope -eq 'User' -or $item.name -eq 'ai-coding-project') { Join-Path $env:USERPROFILE ('.trae-cn/skills/'+$item.name) } else { Join-Path $workspace ('.trae/skills/'+$item.name) }
        if ($item.destination -cne $expected) { throw 'INVALID_SCOPED_DESTINATION' }
        Assert-CoursePlainPath $expected
        if ($item.backup -and -not ([IO.Path]::GetFullPath($item.backup)).StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'INVALID_SCOPED_BACKUP' }
        $actual=Get-CourseTreeHashes $expected
        if (-not (Test-CourseTree $actual $item.files) -and -not ($interrupted -and (-not $actual.Count -or (Test-CourseTree $actual $item.before)))) { throw 'SCOPED_ROLLBACK_CUSTOM_CHANGE_PRESERVED' }
    }
    foreach ($item in $Journal.retired) {
        $allowedRoots=@((Join-Path $env:USERPROFILE '.trae-cn/skills'))+@((Get-CourseScopeMigrationRoots $workspace)|ForEach-Object {Join-Path $_ '.trae/skills'})
        if ((Split-Path $item.source -Parent) -notin $allowedRoots -or -not ([IO.Path]::GetFullPath($item.backup)).StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase) -or ((Test-Path -LiteralPath $item.source) -and (-not $interrupted -or (Test-Path -LiteralPath $item.backup)))) { throw 'SCOPED_RETIRED_COPY_CONFLICT' }
        if((Test-Path -LiteralPath $item.backup) -and $item.files -and -not(Test-CourseTree (Get-CourseTreeHashes $item.backup) $item.files)){throw 'SCOPED_RETIRED_BACKUP_CHANGED'}
    }
    foreach($route in $Journal.routes){
        if($route.root -notin (Get-CourseScopeMigrationRoots $workspace) -or $route.relative -notmatch '^(AGENTS\.md|\.trae/rules/course-entry\.md|docs/specs/_template\.md|docs/engineering/[a-zA-Z0-9_-]+\.md)$' -or $route.path -ne (Join-Path $route.root $route.relative)){throw 'INVALID_SCOPED_ROUTE'}
        Assert-CoursePlainPath $route.path
        $current=[Convert]::ToBase64String([IO.File]::ReadAllBytes($route.path))
        if($current -cne $route.after -and -not($interrupted -and $current -ceq $route.before)){throw 'SCOPED_ROUTE_CUSTOM_CHANGE_PRESERVED'}
    }
    foreach ($ledger in $Journal.ledgers) {
        $allowedLedgers=@((Join-Path (Get-CourseUserRoot) 'installed-skills.json'))+@((Get-CourseScopeMigrationRoots $workspace)|ForEach-Object {Join-Path $_ '.ai-coding/installed-skills.json'})
        if ($ledger.path -notin $allowedLedgers) { throw 'INVALID_SCOPED_LEDGER' }
        if($ledger.expected){
            $current=if(Test-Path -LiteralPath $ledger.path){[Convert]::ToBase64String([IO.File]::ReadAllBytes($ledger.path))}else{$null}
            if($current -cne $ledger.expected -and -not($interrupted -and $current -ceq $ledger.bytes)){throw 'SCOPED_LEDGER_CUSTOM_CHANGE_PRESERVED'}
        }
    }
    foreach($item in $Journal.metadataBefore){if($item.path -notin @((Join-Path $workspace '.course-setup/materials.json'),(Join-Path $workspace '.course-setup/skills-installation.json'))){throw 'INVALID_SCOPED_METADATA'}}
    foreach ($item in $Journal.items) {
        if (-not $item.applied) { continue }
        if($interrupted -and (Test-CourseTree (Get-CourseTreeHashes $item.destination) $item.before)){continue}
        if(Test-Path -LiteralPath $item.destination){Move-Item -LiteralPath $item.destination -Destination (Join-Path $root ('rolledback-'+$item.name))}
        if ($item.backup -and (Test-Path -LiteralPath $item.backup)) { Move-Item -LiteralPath $item.backup -Destination $item.destination }
    }
    foreach ($item in $Journal.retired) { if(Test-Path -LiteralPath $item.backup){Move-Item -LiteralPath $item.backup -Destination $item.source} }
    foreach($route in $Journal.routes){Write-CourseScopeRoute $route.path ([Convert]::FromBase64String($route.before))}
    foreach ($ledger in $Journal.ledgers) {
        if ($ledger.existed) { [IO.File]::WriteAllBytes($ledger.path,[Convert]::FromBase64String($ledger.bytes)) }
        elseif (Test-Path -LiteralPath $ledger.path) { Remove-Item -LiteralPath $ledger.path }
    }
    $pointer = Join-Path (Get-CourseUserRoot) 'execution.json'
    if (-not(Test-Path -LiteralPath $pointer) -or (Read-CourseJson $pointer).executionRoot -eq $Journal.executionRoot) {
        if ($Journal.pointerBefore) { [IO.File]::WriteAllBytes($pointer,[Convert]::FromBase64String($Journal.pointerBefore)) }
        else { Remove-Item -LiteralPath $pointer }
    }
    if($Journal.catalogBefore){[IO.File]::WriteAllBytes($catalogPath,[Convert]::FromBase64String($Journal.catalogBefore))}elseif(Test-Path -LiteralPath $catalogPath){Remove-Item -LiteralPath $catalogPath}
    foreach($item in $Journal.metadataBefore){
        if($item.path -notin @((Join-Path $workspace '.course-setup/materials.json'),(Join-Path $workspace '.course-setup/skills-installation.json'))){throw 'INVALID_SCOPED_METADATA'}
        if($item.bytes){[IO.File]::WriteAllBytes($item.path,[Convert]::FromBase64String($item.bytes))}elseif(Test-Path -LiteralPath $item.path){Remove-Item -LiteralPath $item.path}
    }
    $Journal.status='RolledBack';Write-CourseJson (Join-Path $root 'transaction.json') $Journal
    } finally { Close-CourseLifecycleLock $restoreLock }
}

function Repair-CourseScopedTransactions([string]$Workspace){
    $folder=Join-Path $Workspace '.local/skill-transactions'
    if(-not(Test-Path -LiteralPath $folder)){return}
    Assert-CoursePlainPath $folder
    foreach($file in Get-ChildItem -LiteralPath $folder -Filter transaction.json -File -Recurse){
        Assert-CoursePlainPath $file.FullName
        $journal=Read-CourseJson $file.FullName
        if($journal.status -eq 'Applying'){Restore-CourseScopedTransaction $journal}
    }
}

function Test-CourseSkills {
    param([string]$Workspace,[string[]]$Names)
    if(-not $Names.Count -or @($Names|Where-Object {$_ -cnotmatch '^[a-z][a-z0-9-]{0,63}$'}).Count){throw 'EXPLICIT_SCOPED_SKILL_NAMES_REQUIRED'}
    $policy=Get-CourseSkillScopePolicy
    $checks = foreach ($name in $Names) {
        $userScope=$policy.skillScopes.user -contains $name
        $directory = if ($userScope) { Join-Path $env:USERPROFILE ('.trae-cn/skills/'+$name) } else { Join-Path $Workspace ('.trae/skills/'+$name) }
        Assert-CoursePlainPath $directory
        $ledger = if ($userScope) { Join-Path (Get-CourseUserRoot) 'installed-skills.json' } else { Join-Path $Workspace '.ai-coding/installed-skills.json' }
        $expected = if (Test-Path -LiteralPath $ledger) { (Read-CourseJson $ledger).skills.$name } else { $null }
        $shadow=$userScope -and (Test-Path -LiteralPath (Join-Path $Workspace ('.trae/skills/'+$name)))
        $verified = $expected -and -not $shadow -and (Test-CourseTree (Get-CourseTreeHashes $directory) $expected.files)
        [pscustomobject]@{Name=$name;ExpectedDirectory=$directory;NameMatches=[bool]$verified;ContentVerified=[bool]$verified;ProjectCopyFound=[bool]$shadow;UserDirectoryVerified=[bool]$verified;Issues=@($(if(-not $verified){'Skill content, installation record or discovery scope mismatch.'}))}
    }
    $verified = @($checks | Where-Object { -not $_.ContentVerified }).Count -eq 0
    $result=[pscustomobject]@{CheckedAt=(Get-Date).ToString('o');UserInstallationVerified=$verified;ScopedInstallationVerified=$verified;SkillsDirectory=(Join-Path $Workspace '.trae/skills');Checks=@($checks);NotVerified=@('Actual Trae discovery and external services require separate observation.')}
    Write-CourseJson (Join-Path $Workspace '.course-setup/skills-verification.json') $result
    return $result
}

function Get-SkillsChecklistLines($Verification){
    '<!-- ai-coding:user-skills:start -->'
    '## 技能作用域检查'
    ''
    '安装与内容核验：'+$(if($Verification.ScopedInstallationVerified){'通过'}else{'未通过'})
    ''
    '| 技能 | 实际目录 | 内容与作用域 |'
    '| --- | --- | --- |'
    foreach($check in $Verification.Checks){'| '+$check.Name+' | '+($check.ExpectedDirectory -replace '[\r\n|]',' ')+' | '+$(if($check.ContentVerified){'通过'}else{'待修复'})+' |'}
    ''
    '证据：.course-setup/skills-verification.json。project/github/cloudbase/android 为用户级，env 仅在准备目录；实际 Trae 加载与平台结果另验。'
    '<!-- ai-coding:user-skills:end -->'
}

function Get-WorkspaceSkillsVerification([string]$Workspace) {
    $policy=Get-CourseSkillScopePolicy
    Test-CourseSkills -Workspace $Workspace -Names @(@($policy.skillScopes.user)+@($policy.skillScopes.preparation))
}

function Install-CourseSkills {
    param([string]$Workspace,[string]$Root,[switch]$CaseOnly,[ValidateSet('Preparation','Project','User')][string]$Scope='Preparation',[string[]]$Names)
    if (-not $Root) { $Root=Find-CoursePackageRoot $Workspace }
    $contractFile=Join-Path $Root 'course-contract.json'
    if ((Test-Path -LiteralPath $contractFile) -and (Read-CourseJson $contractFile).skillScopes) {
        if ($CaseOnly) {
            $bundle=Assert-CourseBundle $Root
            $execution=Install-CourseExecutionPackage $Workspace $Root $bundle
            return [pscustomobject]@{Name='knowstar-course';Scope='Cache';Destination=(Join-Path $execution.executionRoot 'packages');PackageRoot=$Root}
        }
        Install-CourseScopedSkills -Workspace $Workspace -PackageRoot $Root -Scope $Scope -Names $Names
    } else { Install-LegacyCourseSkills $Workspace $Root -CaseOnly:$CaseOnly }
}
