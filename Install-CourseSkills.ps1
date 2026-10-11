#Requires -Version 5.1
[CmdletBinding()]
param([string]$WorkingDirectory, [string]$PackageRoot)

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

function Install-CourseSkills {
    param([string]$Workspace, [string]$Root)
    $Workspace = (Resolve-Path -LiteralPath $Workspace -ErrorAction Stop).Path
    if (-not $Root) { $Root = Find-CoursePackageRoot $Workspace }
    $Root = (Resolve-Path -LiteralPath $Root).Path
    if (-not (Test-Path -LiteralPath (Join-Path $Root 'setup-guide.md'))) { throw '指定目录没有 setup-guide.md。' }
    $skillNames = @('ai-coding-env', 'ai-coding-project')
    # New packages include the cloud setup guide; older two-skill packages still work.
    if (Test-Path -LiteralPath (Join-Path $Root 'ai-coding-cloudbase-skill.zip')) { $skillNames += 'ai-coding-cloudbase' }
    $archives = @{}
    foreach ($name in $skillNames) { $archives[$name] = $name + '-skill.zip' }
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
        foreach ($name in $skillNames) {
            $destination = Join-Path $Workspace ('.trae-cn\skills\' + $name)
            [void](New-Item -ItemType Directory -Path $destination -Force)
            Get-ChildItem -LiteralPath (Join-Path $stage $name) -Force | ForEach-Object {
                Copy-Item -LiteralPath $_.FullName -Destination $destination -Recurse -Force
            }
            [pscustomobject]@{ PackageRoot = $Root; Name = $name; Destination = $destination }
        }
    } finally {
        $stagePath = [IO.Path]::GetFullPath($stage)
        $stagePrefix = [IO.Path]::GetFullPath((Join-Path $Workspace '.skill-install-stage')) + [IO.Path]::DirectorySeparatorChar
        if (-not $stagePath.StartsWith($stagePrefix, [StringComparison]::OrdinalIgnoreCase)) { throw '安装临时目录不在当前工作目录内。' }
        Remove-Item -LiteralPath $stagePath -Recurse -Force
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    if (-not $WorkingDirectory) { $WorkingDirectory = (Get-Location).Path }
    $WorkingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory).Path
    Install-CourseSkills $WorkingDirectory $PackageRoot
}
