#Requires -Version 5.1
[CmdletBinding()]
param([string]$WorkingDirectory, [string]$PackageRoot, [switch]$VerifyOnly, [string]$SkillNames, [switch]$CaseOnly, [ValidateSet('Preparation','Project','User')][string]$Scope='Preparation')

$lifecycleHelper=Join-Path $PSScriptRoot 'Course-Lifecycle.ps1'
if(Test-Path -LiteralPath $lifecycleHelper){. $lifecycleHelper}

function Get-TraeUserSkillsDirectory {
    if (-not $env:USERPROFILE -or -not [IO.Path]::IsPathRooted($env:USERPROFILE)) { throw '无法确认当前用户目录，不能猜测技能安装位置。' }
    return [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.trae-cn\skills'))
}

function Assert-CourseSkillDirectory {
    param([string]$Path, [string]$Parent)
    $resolved = [IO.Path]::GetFullPath($Path)
    $prefix = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw '技能目录不在预期根目录内。' }
    if ((Test-Path -LiteralPath $resolved) -and ((Get-Item -LiteralPath $resolved -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw '技能目录是链接，已保留，不能自动替换。' }
}

function Test-CourseSkills {
    param([string]$Workspace, [string[]]$Names)
    $Workspace = (Resolve-Path -LiteralPath $Workspace -ErrorAction Stop).Path
    if (-not $Names -or @($Names | Where-Object { $_ -cnotmatch '^[a-z][a-z0-9-]{0,63}$' }).Count) { throw '需要明确提供要核对的技能名称。' }
    $skillsRoot = Get-TraeUserSkillsDirectory
    $rootIssue = $null
    foreach ($directory in @((Split-Path $skillsRoot -Parent), $skillsRoot)) {
        if ((Test-Path -LiteralPath $directory) -and ((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { $rootIssue = '用户技能根目录是链接，尚未确认实际安装位置。' }
    }
    $checks = foreach ($name in @($Names | Select-Object -Unique)) {
        $directory = Join-Path $skillsRoot $name
        $entry = Join-Path $directory 'SKILL.md'
        $projectDirectory = Join-Path $Workspace ('.trae\skills\' + $name)
        $issues = @()
        if ($rootIssue) { $issues += $rootIssue }
        $nameMatches = $false
        if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) { $issues += '当前用户目录缺少根部 SKILL.md。' }
        elseif (((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -or ((Get-Item -LiteralPath $entry -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { $issues += '技能目录或 SKILL.md 是链接，不能当作用户级副本通过。' }
        else {
            try {
                $content = Get-Content -LiteralPath $entry -Raw -Encoding UTF8 -ErrorAction Stop
                $header = [regex]::Match($content, '(?s)\A---\r?\n(.*?)\r?\n---(?:\r?\n|\z)')
                $nameMatches = $header.Success -and $header.Groups[1].Value -cmatch ('(?m)^name:\s*' + [regex]::Escape($name) + '\s*$')
                if (-not $nameMatches) { $issues += 'SKILL.md 的技能名称不匹配。' }
            } catch { $issues += '无法读取用户目录中的 SKILL.md。' }
        }
        $contentVerified=$null
        $baseline=Join-Path $env:USERPROFILE '.ai-coding/installed-skills.json'
        if(Test-Path -LiteralPath $baseline){
            $upgrade=Join-Path $PSScriptRoot 'Course-Upgrade.ps1'
            if(Test-Path -LiteralPath $upgrade){
                . $upgrade
                $installed=Read-CourseJson $baseline
                if($installed.skills.PSObject.Properties[$name]){
                    $contentVerified=Test-CourseTree (Get-CourseTreeHashes $directory) $installed.skills.$name.files
                    if(-not $contentVerified){$issues+='已安装技能内容与记录的版本摘要不同。'}
                }
            }
        }
        $projectCopy = Test-Path -LiteralPath $projectDirectory
        if ($projectCopy) { $issues += '当前项目仍有同名技能副本，需要先备份并移出发现目录。' }
        [pscustomobject]@{ Name = $name; ExpectedDirectory = $directory; NameMatches = $nameMatches; ContentVerified=$contentVerified; ProjectCopyFound = [bool]$projectCopy; ProjectDirectory = $projectDirectory; UserDirectoryVerified = ($issues.Count -eq 0); Issues = @($issues) }
    }
    $verified = @($checks | Where-Object { -not $_.UserDirectoryVerified }).Count -eq 0
    $result = [pscustomobject][ordered]@{ CheckedAt = (Get-Date).ToString('o'); UserInstallationVerified = $verified; SkillsDirectory = $skillsRoot; Checks = @($checks); NotVerified = @('Trae 中的实际识别和加载由助手另行核对；位置检查不代替工具、云服务、GitHub 或 AI 服务验收。') }
    $records = Join-Path $Workspace '.course-setup'
    [void](New-Item -ItemType Directory -Path $records -Force)
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $records 'skills-verification.json') -Encoding UTF8
    return $result
}

function Get-WorkspaceSkillsVerification {
    param([string]$Workspace)
    try {
        # Use the required list, never infer it from whichever folders happen to exist.
        $manifest = Join-Path $Workspace '.course-setup\materials.json'
        if (-not (Test-Path -LiteralPath $manifest)) { $manifest = Join-Path $Workspace '.course-setup\skills-installation.json' }
        $installed = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $names = @($installed.SkillNames)
        if (-not $names.Count -or @($names | Where-Object { $_ -cnotmatch '^[a-z][a-z0-9-]{0,63}$' }).Count -or @($names | Select-Object -Unique).Count -ne $names.Count) {
            throw '准备记录缺少有效的完整技能名单，不能根据现有目录猜测通过。'
        }
        if ($installed.CourseVersion -match '^2\.' -or $installed.ContractVersion -match '^2\.') {
            $contractPath=Join-Path $PSScriptRoot '..\assets\course-contract.json'
            if (-not (Test-Path -LiteralPath $contractPath)) { $contractPath=Join-Path $PSScriptRoot 'course-contract.json' }
            $contract=Get-Content -LiteralPath $contractPath -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json
            foreach ($required in @($contract.skills|Where-Object kind -eq 'generic')) {
                if ($names -notcontains $required.name) { throw 'Preparation skill list does not satisfy the current contract.' }
            }
        }
        return Test-CourseSkills -Workspace $Workspace -Names $names
    } catch {
        $result = [pscustomobject][ordered]@{
            CheckedAt = (Get-Date).ToString('o'); UserInstallationVerified = $false
            SkillsDirectory = $(if ($env:USERPROFILE) { Join-Path $env:USERPROFILE '.trae-cn\skills' } else { $null })
            Checks = @(); Issues = @('无法完成用户级技能检查：' + $_.Exception.Message)
            NotVerified = @('安装位置未确认；Trae 实际识别加载及其他准备结果仍需分别验证。')
        }
        $records = Join-Path $Workspace '.course-setup'
        [void](New-Item -ItemType Directory -Path $records -Force)
        $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $records 'skills-verification.json') -Encoding UTF8
        return $result
    }
}

function Get-SkillsChecklistLines {
    param($Verification)
    function ConvertTo-SkillCell($Value) { return ([string]$Value -replace '\|', '\\|' -replace '[\r\n]+', ' ') }
    '<!-- ai-coding:user-skills:start -->'
    '## 技能：用户级安装检查'
    ''
    '检查时间：' + $Verification.CheckedAt
    '用户技能目录：`' + $Verification.SkillsDirectory + '`'
    '用户级安装结果：' + $(if ($Verification.UserInstallationVerified) { '通过' } else { '未通过' })
    ''
    '| 技能 | 用户目录安装 | 项目同名副本 | 实际位置与问题 |'
    '| --- | --- | --- | --- |'
    foreach ($check in $Verification.Checks) {
        $state = if ($check.UserDirectoryVerified) { '通过' } else { '未通过' }
        $project = if ($check.ProjectCopyFound) { '发现：' + $check.ProjectDirectory } else { '未发现' }
        '| ' + $check.Name + ' | ' + $state + ' | ' + (ConvertTo-SkillCell $project) + ' | ' + (ConvertTo-SkillCell ($check.ExpectedDirectory + '；' + ($check.Issues -join '；'))) + ' |'
    }
    foreach ($issue in $Verification.Issues) { '未通过原因：' + (ConvertTo-SkillCell $issue) }
    ''
    '证据：`.course-setup/skills-verification.json`。用户目录安装可跨项目复用；本项核对实际位置、SKILL.md 名称及当前项目同名副本，不代替 Trae 中的实际识别与加载验证。'
    '<!-- ai-coding:user-skills:end -->'
}

function Get-WorkspaceStorageEvidence {
    param([string]$Workspace)
    $required=$false
    foreach($name in @('materials.json','skills-installation.json')){
        $metadata=Join-Path $Workspace ('.course-setup\'+$name)
        if(Test-Path -LiteralPath $metadata){
            $data=Get-Content -LiteralPath $metadata -Raw -Encoding UTF8|ConvertFrom-Json
            if($data.CourseVersion -match '^2\.' -or $data.ContractVersion -match '^2\.'){$required=$true}
        }
    }
    $path=Join-Path $Workspace '.course-setup\storage.json'
    $verified=$false
    if(Test-Path -LiteralPath $path){
        $record=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
        $verified=$record.schemaVersion -eq 2 -and $record.status -eq 'verified' -and [bool]$record.checkedAt
    }
    return [pscustomobject]@{Required=$required;Verified=$verified;EvidencePath=$path}
}

function Update-ExistingSkillsChecklist {
    param([string]$Workspace, $Verification)
    $path = Join-Path $Workspace 'environment-checklist.md'
    if (-not (Test-Path -LiteralPath $path)) { return }
    $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    $section = (Get-SkillsChecklistLines $Verification) -join "`r`n"
    $pattern = '(?s)<!-- ai-coding:user-skills:start -->.*?<!-- ai-coding:user-skills:end -->'
    if ([regex]::IsMatch($text, $pattern)) { $text = [regex]::Replace($text, $pattern, [Text.RegularExpressions.MatchEvaluator]{ param($match) $section }) }
    else { $text = $text.TrimEnd() + "`r`n`r`n" + $section + "`r`n" }
    if (-not $Verification.UserInstallationVerified) {
        $text = $text -replace '(?m)\*\*结论：已完成[^\r\n]*', '**结论：未完成（技能用户级安装未通过）**'
        $text = $text -replace '(?m)^# 容器工具准备：已完成', '# 容器工具准备：未完成（技能用户级安装未通过）'
    }
    $storage=Get-WorkspaceStorageEvidence $Workspace
    if($storage.Required -and -not $storage.Verified){
        $text=$text -replace '(?m)\*\*结论：已完成[^\r\n]*','**结论：未完成（实际程序与数据存储位置尚未通过）**'
        $text=$text -replace '(?m)^# 容器工具准备：已完成','# 容器工具准备：未完成（存储位置尚未通过）'
    }
    # A location-only recheck never promotes an incomplete toolchain to completed.
    Set-Content -LiteralPath $path -Value $text -Encoding UTF8
}

function Find-CoursePackageRoot {
    param([string]$StartDirectory, [int]$MaxDepth = 6, [int]$MaxDirectories = 2000)
    $start = (Resolve-Path -LiteralPath $StartDirectory -ErrorAction Stop).Path
    if (Test-Path -LiteralPath (Join-Path $start 'setup-guide.md')) { return $start }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [void]$seen.Add($start)
    $frontier = @($start)
    for ($depth = 0; $depth -le $MaxDepth; $depth++) {
        $matches = @($frontier | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'setup-guide.md') })
        if ($matches.Count -eq 1) { return $matches[0] }
        if ($matches.Count -gt 1) {
            $complete = @($matches | Where-Object {
                (Test-Path -LiteralPath (Join-Path $_ 'ai-coding-env-skill.zip')) -and (Test-Path -LiteralPath (Join-Path $_ 'ai-coding-project-skill.zip'))
            })
            if ($complete.Count -eq 1) { return $complete[0] }
            throw ('找到多个等距离的 setup-guide.md，不能猜测资料包根目录：' + ($matches -join ', '))
        }
        if ($depth -eq $MaxDepth) { break }
        $next = @()
        foreach ($folder in $frontier) {
            $neighbors = @()
            $parent = Split-Path $folder -Parent
            if ($parent) { $neighbors += $parent }
            $neighbors += @(Get-ChildItem -LiteralPath $folder -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notin @('.git', 'node_modules', '.docker-setup', '.skill-install-stage') -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
                ForEach-Object { $_.FullName })
            foreach ($neighbor in $neighbors) {
                if ($seen.Add($neighbor)) {
                    if ($seen.Count -gt $MaxDirectories) { throw '目录搜索达到上限，无法确认最近资料包；请提供实际 setup-guide.md 位置。' }
                    $next += $neighbor
                }
            }
        }
        $frontier = $next
        if (-not $frontier.Count) { break }
    }
    throw '在当前目录及最近的上级/子目录未找到 setup-guide.md；请定位或解压真实资料包，不使用固定盘符猜测。'
}

function Install-LegacyCourseSkills {
    param([string]$Workspace, [string]$Root, [switch]$CaseOnly)
    $Workspace = (Resolve-Path -LiteralPath $Workspace -ErrorAction Stop).Path
    if (-not $Root) { $Root = Find-CoursePackageRoot $Workspace }
    $Root = (Resolve-Path -LiteralPath $Root).Path
    if (-not (Test-Path -LiteralPath (Join-Path $Root 'setup-guide.md'))) { throw '指定目录没有 setup-guide.md。' }
    $versionPath=Join-Path $Root 'VERSION.json'
    if(Test-Path -LiteralPath $versionPath){
        $releaseVersion=(Get-Content -LiteralPath $versionPath -Raw -Encoding UTF8|ConvertFrom-Json).version
        if($releaseVersion -and [version]$releaseVersion -ge [version]'2.2.0' -and -not(Get-Command Register-CourseInstallation -ErrorAction SilentlyContinue)){throw 'LIFECYCLE_INSTALLER_DEPENDENCIES_REQUIRED'}
    }
    if($releaseVersion -and [version]$releaseVersion -ge [version]'2.3.0'){
        if(-not(Get-Command Expand-CourseMaterials -ErrorAction SilentlyContinue)){. (Join-Path $PSScriptRoot 'Get-CourseMaterials.ps1')}
        . (Join-Path $PSScriptRoot 'Course-Upgrade.ps1')
        $bundle=Assert-CourseBundle $Root
        $names=@($bundle.skills.PSObject.Properties|Where-Object {-not $CaseOnly -or $_.Value.kind -eq 'case'}|ForEach-Object {$_.Name})
        if(-not $names.Count){throw 'CASE_PROFILE_REQUIRED'}
        $installed=Invoke-CourseSkillTransaction -Workspace $Workspace -PackageRoot $Root -Names $names -ReleaseId $releaseVersion -AllowUnprepared
        $installation=Register-CourseInstallation $Workspace $releaseVersion
        foreach($name in $names){
            $destination=Join-Path $installed.SkillsDirectory $name
            $backup=Join-Path $installed.TransactionRoot ('backup/'+$name)
            $saved=if(Test-Path -LiteralPath $backup){$backup}else{$null}
            $null=Register-CourseResource -InstallationId $installation.installationId -Kind skill -Locator $destination -Ownership $(if($installed.Changed -contains $name){'created'}else{'reused'}) -AllowedRoot $installed.SkillsDirectory -BackupPath $saved
            [pscustomobject]@{PackageRoot=$Root;Name=$name;Destination=$destination;Scope='user';BackupPath=$saved;ProjectBackupPath=$null}
        }
        return
    }
    $skillNames = @('ai-coding-env', 'ai-coding-project')
    # New packages include the cloud setup guide; older two-skill packages still work.
    if (Test-Path -LiteralPath (Join-Path $Root 'ai-coding-cloudbase-skill.zip')) { $skillNames += 'ai-coding-cloudbase' }

    if (Test-Path -LiteralPath (Join-Path $Root 'ai-coding-github-skill.zip')) { $skillNames += 'ai-coding-github' }
    if (Test-Path -LiteralPath (Join-Path $Root 'ai-coding-siliconflow-skill.zip')) { $skillNames += 'ai-coding-siliconflow' }
    $contractPath = Join-Path $Root 'course-contract.json'
    if (-not (Test-Path -LiteralPath $contractPath) -and (Test-Path -LiteralPath (Join-Path $Root 'course-contract\skills.json'))) { $contractPath = Join-Path $Root 'course-contract\skills.json' }
    $archives = @{}
    if (Test-Path -LiteralPath $contractPath) {
        $contract = Get-Content -LiteralPath $contractPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($contract.schemaVersion -ne 2) { throw 'Unsupported course contract.' }
        $generic = @($contract.skills | Where-Object kind -eq 'generic')
        $skillNames = @($generic.name)
        if (-not $skillNames.Count -or @($skillNames | Select-Object -Unique).Count -ne $skillNames.Count) { throw 'Invalid required skill list.' }
        foreach ($entry in $generic) {
            if ($entry.name -cnotmatch '^[a-z][a-z0-9-]{0,63}$' -or $entry.archive -cnotmatch '^[a-z][a-z0-9-]{0,100}\.zip$') { throw 'Unsafe skill contract.' }
            $archives[$entry.name] = $entry.archive
        }
    } else { foreach ($name in $skillNames) { $archives[$name] = $name + '-skill.zip' } }
    $genericNames=@($skillNames)
    if($CaseOnly){
        $check=Test-CourseSkills -Workspace $Workspace -Names $genericNames
        if(-not $check.UserInstallationVerified){throw 'CASE_INCREMENT_REQUIRES_VERIFIED_GENERIC_SKILLS'}
        $skillNames=@()
    }
    $caseProfilePath = Join-Path $Root 'case-profile.json'
    if (Test-Path -LiteralPath $caseProfilePath) {
        $caseProfile = Get-Content -LiteralPath $caseProfilePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $caseName = [string]$caseProfile.caseSkillName
        $caseArchive = [string]$caseProfile.caseSkillArchive
        if ($caseName -cnotmatch '^[a-z][a-z0-9-]{0,63}$' -or $caseName -match '^(con|prn|aux|nul|com[0-9]|lpt[0-9])$' -or
            $caseArchive -cnotmatch '^[a-z][a-z0-9-]{0,100}\.zip$' -or $skillNames -contains $caseName) {
            throw 'case-profile.json 中的案例技能名称或 ZIP 文件名无效。'
        }
        $skillNames += $caseName
        $archives[$caseName] = $caseArchive
    }
    if($CaseOnly -and -not $skillNames.Count){throw 'CASE_PROFILE_REQUIRED'}
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $stage = Join-Path $Workspace ('.skill-install-stage\' + [guid]::NewGuid())
    [void](New-Item -ItemType Directory -Path $stage -Force)
    try {
        # Validate and stage all included skills before updating installed directories.
        foreach ($name in $skillNames) {
            $zip = Join-Path $Root $archives[$name]
            if (-not (Test-Path -LiteralPath $zip)) { throw "资料包缺少 $($archives[$name])。" }
            $hashFile = [IO.Path]::ChangeExtension($zip, '.sha256')
            if (-not (Test-Path -LiteralPath $hashFile)) { throw "资料包缺少 $name-skill.sha256。" }
            $expected = ((Get-Content -LiteralPath $hashFile -Raw).Trim() -split '\s+')[0]
            if ($expected -notmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $expected) { throw "$name 技能包 SHA-256 不一致。" }
            $destination = Join-Path $stage $name
            $archive = [IO.Compression.ZipFile]::OpenRead($zip)
            try {
                $entry = $archive.GetEntry('SKILL.md')
                if (-not $entry) { throw "$name 的 ZIP 根部没有 SKILL.md。" }
                $reader = [IO.StreamReader]::new($entry.Open())
                try { $content = $reader.ReadToEnd() } finally { $reader.Dispose() }
                if ($content -cnotmatch ('(?m)^name:\s*' + [regex]::Escape($name) + '\s*$')) { throw "$name 的技能名称不符。" }
                $prefix = [IO.Path]::GetFullPath($destination) + [IO.Path]::DirectorySeparatorChar
                foreach ($member in $archive.Entries) {
                    $memberPath = [IO.Path]::GetFullPath((Join-Path $destination $member.FullName))
                    if (-not $memberPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw '技能 ZIP 包含越出目标目录的路径。' }
                }
            } finally { $archive.Dispose() }
            Expand-Archive -LiteralPath $zip -DestinationPath $destination -Force
        }
        $skillsRoot = Get-TraeUserSkillsDirectory
        $userTraeRoot = Split-Path $skillsRoot -Parent
        $migrationId = [guid]::NewGuid().ToString()
        $userStage = Join-Path $userTraeRoot ('.course-skill-stage-' + $migrationId)
        $userBackup = Join-Path $userTraeRoot ('course-skill-backups\' + $migrationId)
        $projectSkillsRoot = Join-Path $Workspace '.trae\skills'
        $projectBackup = Join-Path $Workspace ('.course-setup\skill-backups\' + $migrationId)
        Assert-CourseSkillDirectory $skillsRoot $userTraeRoot
        Assert-CourseSkillDirectory $projectSkillsRoot $Workspace
        [void](New-Item -ItemType Directory -Path $skillsRoot, $userStage -Force)
        $lifecycleInstallation=$null;$lifecycleLease=$null
        if(Get-Command Register-CourseInstallation -ErrorAction SilentlyContinue){
            $versionFile=Join-Path $Root 'VERSION.json'
            $packageVersion=if(Test-Path -LiteralPath $versionFile){(Read-CourseJson $versionFile).version}else{$null}
            $lifecycleInstallation=Register-CourseInstallation $Workspace $packageVersion
            $lifecycleLease=Enter-CourseOperation $Workspace 'InstallSkills'
        }
        try {
            # Prepare the new user-level copies on the same volume before replacing old ones.
            foreach ($name in $skillNames) {
                Assert-CourseSkillDirectory (Join-Path $skillsRoot $name) $skillsRoot
                Assert-CourseSkillDirectory (Join-Path $projectSkillsRoot $name) $projectSkillsRoot
                Copy-Item -LiteralPath (Join-Path $stage $name) -Destination (Join-Path $userStage $name) -Recurse
            }
            foreach ($name in $skillNames) {
                $destination = Join-Path $skillsRoot $name
                $prior = Join-Path $userBackup $name
                if($lifecycleInstallation){$null=Start-CourseCreationIntent $lifecycleInstallation.installationId skill $destination ([bool](Test-Path -LiteralPath $destination))}
                if (Test-Path -LiteralPath $destination) {
                    Assert-CourseSkillDirectory $destination $skillsRoot
                    Assert-CourseSkillDirectory $prior $userTraeRoot
                    [void](New-Item -ItemType Directory -Path $userBackup -Force)
                    Move-Item -LiteralPath $destination -Destination $prior
                }
                try {
                    Move-Item -LiteralPath (Join-Path $userStage $name) -Destination $destination
                    if($lifecycleInstallation){
                        $saved=if(Test-Path -LiteralPath $prior){$prior}else{$null}
                        $registered=Register-CourseResource -InstallationId $lifecycleInstallation.installationId -Kind skill -Locator $destination -Ownership created -AllowedRoot $skillsRoot -BackupPath $saved
                        if($saved){$null=Register-CourseResource -InstallationId $lifecycleInstallation.installationId -Kind directory -Locator $saved -Ownership created -AllowedRoot (Split-Path $saved -Parent) -Metadata @{backupFor=$registered.resourceKey}}
                    }
                }
                catch {
                    if ((Test-Path -LiteralPath $prior) -and -not (Test-Path -LiteralPath $destination)) { Move-Item -LiteralPath $prior -Destination $destination }
                    throw
                }
            }
            # Retire only matching project copies; preserve them outside Trae's discovery directory.
            foreach ($name in $skillNames) {
                $projectCopy = Join-Path $projectSkillsRoot $name
                $savedProjectCopy = $null
                if (Test-Path -LiteralPath $projectCopy) {
                    $savedProjectCopy = Join-Path $projectBackup $name
                    Assert-CourseSkillDirectory $projectCopy $projectSkillsRoot
                    Assert-CourseSkillDirectory $savedProjectCopy $Workspace
                    [void](New-Item -ItemType Directory -Path $projectBackup -Force)
                    Move-Item -LiteralPath $projectCopy -Destination $savedProjectCopy
                    if($lifecycleInstallation){$null=Register-CourseResource -InstallationId $lifecycleInstallation.installationId -Kind directory -Locator $savedProjectCopy -Ownership created -DataClass source -AllowedRoot $projectBackup}
                }
                $prior = Join-Path $userBackup $name
                [pscustomobject]@{ PackageRoot = $Root; Name = $name; Destination = (Join-Path $skillsRoot $name); Scope = 'user'; BackupPath = $(if (Test-Path -LiteralPath $prior) { $prior } else { $null }); ProjectBackupPath = $savedProjectCopy }
            }
            $records = Join-Path $Workspace '.course-setup'
            [void](New-Item -ItemType Directory -Path $records -Force)
            @{ InstalledAt = (Get-Date).ToString('o'); ContractVersion = $(if ($contract) { $contract.baselineVersion } else { '1' }); PackageRoot = $Root; SkillScope = 'user'; SkillsDirectory = $skillsRoot; SkillNames = @($(if($CaseOnly){$genericNames})+$skillNames|Select-Object -Unique); InstallationId=$lifecycleInstallation.installationId; UserBackupDirectory=$userBackup; ProjectBackupDirectory=$projectBackup } |
                ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $records 'skills-installation.json') -Encoding UTF8
        } finally {
            if($lifecycleLease){Exit-CourseOperation $lifecycleLease}
            Assert-CourseSkillDirectory $userStage $userTraeRoot
            if (Test-Path -LiteralPath $userStage) { Remove-Item -LiteralPath $userStage -Recurse -Force }
        }
    } finally {
        $stagePath = [IO.Path]::GetFullPath($stage)
        $stagePrefix = [IO.Path]::GetFullPath((Join-Path $Workspace '.skill-install-stage')) + [IO.Path]::DirectorySeparatorChar
        if (-not $stagePath.StartsWith($stagePrefix, [StringComparison]::OrdinalIgnoreCase)) { throw '安装临时目录不在当前工作目录内。' }
        Remove-Item -LiteralPath $stagePath -Recurse -Force
    }
}

. (Join-Path $PSScriptRoot 'Course-SkillScopes.ps1')

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    if (-not $WorkingDirectory) { $WorkingDirectory = (Get-Location).Path }
    $WorkingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory).Path
    if ($VerifyOnly) {
        if (-not $SkillNames) { throw 'VerifyOnly 需要 SkillNames，以逗号分隔要核对的技能名称。' }
        $verification = Test-CourseSkills -Workspace $WorkingDirectory -Names @($SkillNames.Split(',') | ForEach-Object { $_.Trim() })
        Update-ExistingSkillsChecklist -Workspace $WorkingDirectory -Verification $verification
        $verification | ConvertTo-Json -Depth 6
        if (-not $verification.UserInstallationVerified) { exit 2 }
        exit 0
    }
    $selectedNames = if ($SkillNames) { @($SkillNames.Split(',') | ForEach-Object { $_.Trim() } | Where-Object {$_}) } else { @() }
    Install-CourseSkills $WorkingDirectory $PackageRoot -CaseOnly:$CaseOnly -Scope $Scope -Names $selectedNames
}
