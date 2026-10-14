#Requires -Version 5.1
[CmdletBinding()]
param([string]$WorkingDirectory, [string]$CourseVersion, [switch]$SkipInstallers,
      [ValidateSet('docker','podman')][string]$ContainerRuntime='docker')

function Receive-CourseFile {
    param([string]$Url, [string]$Destination)
    $priorTls = [Net.ServicePointManager]::SecurityProtocol
    $priorProgress = $ProgressPreference
    try {
        [Net.ServicePointManager]::SecurityProtocol = $priorTls -bor [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
    } finally {
        [Net.ServicePointManager]::SecurityProtocol = $priorTls
        $ProgressPreference = $priorProgress
    }
}

function Expand-CourseMaterials {
    param([string]$Archive, [string]$Staging)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $root = [IO.Path]::GetFullPath($Staging).TrimEnd('\') + '\'
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        if ($zip.Entries.Count -gt 2000 -or ($zip.Entries | Measure-Object Length -Sum).Sum -gt 200MB) { throw 'Unexpected course archive size.' }
        # Validate every target before creating or extracting any archive entry.
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName.Replace('/', '\')
            $target = [IO.Path]::GetFullPath((Join-Path $Staging $name))
            if ([IO.Path]::IsPathRooted($name) -or $name.Contains(':') -or -not $target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw 'Unsafe course archive path.' }
        }
        [IO.Compression.ZipFile]::ExtractToDirectory($Archive, $Staging)
    } finally { $zip.Dispose() }
}

function Get-CourseMaterials {
    param([string]$Workspace, [string]$Version, [switch]$WithoutInstallers,
          [ValidateSet('docker','podman')][string]$Runtime='docker')
    $workspacePath = (Resolve-Path -LiteralPath $Workspace -ErrorAction Stop).Path
    $baseUrl = 'https://siatwangmin.github.io/aicoding-course'
    $records = Join-Path $workspacePath '.course-setup'
    [void](New-Item -ItemType Directory -Path $records -Force)
    if (-not $Version) {
        $metadata = Join-Path $records 'VERSION.json'
        Receive-CourseFile "$baseUrl/VERSION.json" $metadata
        $Version = (Get-Content -LiteralPath $metadata -Raw | ConvertFrom-Json).version
    }
    if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid course version.' }
    $url = "$baseUrl/releases/course/v$Version/aicoding-student-kit.zip"
    $checksumFile = Join-Path $records "aicoding-student-kit-v$Version.sha256"
    Receive-CourseFile ($url -replace '\.zip$', '.sha256') $checksumFile
    $checksum = (Get-Content -LiteralPath $checksumFile -Raw).Trim()
    if ($checksum -notmatch '^([a-fA-F0-9]{64})\s+aicoding-student-kit\.zip$') { throw 'Invalid course checksum file.' }
    $expectedHash = $Matches[1].ToLowerInvariant()
    $archive = Join-Path $records "aicoding-student-kit-v$Version.zip"
    if (-not (Test-Path -LiteralPath $archive) -or (Get-FileHash -LiteralPath $archive).Hash.ToLowerInvariant() -ne $expectedHash) {
        $partial = $archive + '.partial'
        Receive-CourseFile $url $partial
        if ((Get-FileHash -LiteralPath $partial).Hash.ToLowerInvariant() -ne $expectedHash) { throw 'Course archive checksum mismatch.' }
        Move-Item -LiteralPath $partial -Destination $archive -Force
    }
    $staging = Join-Path $records ('stage-' + [guid]::NewGuid())
    $courseRoot = Join-Path $workspacePath ("course-materials-v$Version")
    try {
        Expand-CourseMaterials $archive $staging
        foreach ($required in @('VERSION.json', 'setup-guide.md', 'Install-CourseSkills.ps1', 'Setup-DockerDesktop.ps1', 'windows-installers.json', 'ai-coding-env-skill.zip', 'ai-coding-project-skill.zip')) {
            if (-not (Test-Path -LiteralPath (Join-Path $staging $required) -PathType Leaf)) { throw "Missing course file: $required" }
        }
        if ((Get-Content -LiteralPath (Join-Path $staging 'VERSION.json') -Raw | ConvertFrom-Json).version -ne $Version) { throw 'Course archive version mismatch.' }
        $files = Get-ChildItem -LiteralPath $staging -File -Recurse
        # Preflight all collisions so existing learner modifications remain intact.
        foreach ($file in $files) {
            $relative = $file.FullName.Substring($staging.Length).TrimStart('\')
            $target = Join-Path $courseRoot $relative
            if ((Test-Path -LiteralPath $target) -and ((Get-FileHash -LiteralPath $target).Hash -ne (Get-FileHash -LiteralPath $file.FullName).Hash)) { throw "Existing file differs; preserved: $target" }
        }
        foreach ($file in $files) {
            $target = Join-Path $courseRoot $file.FullName.Substring($staging.Length).TrimStart('\')
            [void](New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force)
            if (-not (Test-Path -LiteralPath $target)) { Copy-Item -LiteralPath $file.FullName -Destination $target }
        }
    } finally {
        $resolvedStage = [IO.Path]::GetFullPath($staging)
        if (-not $resolvedStage.StartsWith([IO.Path]::GetFullPath($records).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe staging cleanup path.' }
        if (Test-Path -LiteralPath $resolvedStage) { Remove-Item -LiteralPath $resolvedStage -Recurse -Force }
    }
    $installedSkills = @(& (Join-Path $courseRoot 'Install-CourseSkills.ps1') -WorkingDirectory $workspacePath -PackageRoot $courseRoot)
    $installedSkills | Out-Host
    $installerFiles = @()
    if (-not $WithoutInstallers) {
        $priorLocation = Get-Location
        try {
            Set-Location -LiteralPath $workspacePath
            . (Join-Path $courseRoot 'Setup-DockerDesktop.ps1')
            $manifest = Join-Path $courseRoot 'windows-installers.json'
            if ($Runtime -eq 'podman') {
                $envSkill=@($installedSkills | Where-Object Name -eq 'ai-coding-env')[0].Destination
                . (Join-Path $envSkill 'scripts\Setup-PodmanDesktop.ps1')
                if (-not (Get-SetupWsl).Ready) {$installerFiles += Resolve-SetupInstaller 'wsl' '' $manifest}
                if (-not (Get-PodmanPaths).Desktop) {$installerFiles += Resolve-PodmanInstaller $workspacePath ''}
            } else {
                $installerFiles += Resolve-SetupInstaller 'wsl' '' $manifest
                $installerFiles += Resolve-SetupInstaller 'docker' '' $manifest
            }
        } finally { Set-Location -LiteralPath $priorLocation }
    }
    $result = [ordered]@{ PreparedAt = (Get-Date).ToString('o'); CourseVersion = $Version; ContainerRuntime=$Runtime; PackageUrl = $url; PackageSha256 = $expectedHash; PackageRoot = $courseRoot; SetupGuide = (Join-Path $courseRoot 'setup-guide.md'); SkillScope = 'user'; SkillsDirectory = (Split-Path $installedSkills[0].Destination -Parent); SkillNames = @($installedSkills.Name); InstallerFiles = $installerFiles; InstallersSkipped = [bool]$WithoutInstallers; EnvironmentVerified = $false }
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $records 'materials.json') -Encoding UTF8
    @{ContainerRuntime=$Runtime;SelectedAt=(Get-Date).ToString('o')} | ConvertTo-Json | Set-Content (Join-Path $records 'container-runtime.json') -Encoding UTF8
    $agents = Join-Path $workspacePath 'AGENTS.md'
    $entry = "<!-- ai-coding:materials-entry:1 -->`n## Course preparation entry`nRead .course-setup/materials.json to locate the downloaded setup-guide.md and user-level SkillsDirectory. Use its ai-coding-env for E-01 (including the former E-04); continue installation and actual toolchain verification after downloading. Reuse existing installers and preserve existing work. Downloads are not environment verification. Do not install course skills in the project.`n<!-- ai-coding:materials-entry:end -->"
    $entry=$entry.Replace('Read .course-setup/materials.json', "Selected container runtime: $Runtime. Prepare only this runtime; use its local engine, Compose and reports. Browser selection is a preference, never verification. Read .course-setup/materials.json")
    $text = if (Test-Path -LiteralPath $agents) { Get-Content -LiteralPath $agents -Raw } else { '' }
    if ($text -match '(?s)<!-- ai-coding:materials-entry:1 -->.*?<!-- ai-coding:materials-entry:end -->') { $text = [regex]::Replace($text, '(?s)<!-- ai-coding:materials-entry:1 -->.*?<!-- ai-coding:materials-entry:end -->', $entry) } else { $text = $text.TrimEnd() + "`n`n" + $entry }
    Set-Content -LiteralPath $agents -Value $text -Encoding UTF8
    return [pscustomobject]$result
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    if (-not $WorkingDirectory) { $WorkingDirectory = (Get-Location).Path }
    Get-CourseMaterials -Workspace $WorkingDirectory -Version $CourseVersion -WithoutInstallers:$SkipInstallers -Runtime $ContainerRuntime
}
