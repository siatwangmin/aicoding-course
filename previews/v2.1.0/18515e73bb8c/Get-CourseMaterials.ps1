#Requires -Version 5.1
[CmdletBinding()]
param([string]$WorkingDirectory, [string]$CourseVersion, [string]$PreviewId, [switch]$SkipInstallers,
      [ValidateSet('docker','podman')][string]$ContainerRuntime='podman')

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

function Resolve-CourseBootstrapRuntime([string]$Workspace) {
    # This is the zero-material entry: no adjacent helper is guaranteed to exist yet.
    foreach($relative in @('.ai-coding\project.json','.course-setup\container-runtime.json','.course-setup\materials.json','toolchain-verification.json')){
        $path=Join-Path $Workspace $relative
        if(Test-Path -LiteralPath $path){
            $record=Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json
            if($record.containerRuntime -in @('docker','podman')){return $record.containerRuntime}
            if($record.containerRuntime){throw 'Invalid recorded runtime; preserve workspace and resolve selection.'}
            if($relative -eq 'toolchain-verification.json'){return 'docker'}
        }
    }
    return 'podman'
}

function Get-CourseMaterials {
    param([string]$Workspace, [string]$Version, [string]$Preview, [switch]$WithoutInstallers,
          [ValidateSet('docker','podman')][string]$Runtime='podman')
    $workspacePath = (Resolve-Path -LiteralPath $Workspace -ErrorAction Stop).Path
    if(-not $PSBoundParameters.ContainsKey('Runtime')){
        $Runtime=Resolve-CourseBootstrapRuntime $workspacePath
    }
    $baseUrl = 'https://siatwangmin.github.io/aicoding-course'
    $records = Join-Path $workspacePath '.course-setup'
    [void](New-Item -ItemType Directory -Path $records -Force)
    $metadataInfo=$null
    if (-not $Version -or (-not $Preview -and $Version -match '^[2-9]\d*\.')) {
        $metadata = Join-Path $records 'VERSION.json'
        Receive-CourseFile "$baseUrl/VERSION.json" $metadata
        $metadataInfo = Get-Content -LiteralPath $metadata -Raw | ConvertFrom-Json
        if(-not $Version){$Version=$metadataInfo.version}
        if($metadataInfo.version -eq $Version -and $metadataInfo.status -eq 'candidate'){
            $Preview=$metadataInfo.distributionId
            if(-not $Preview){throw 'Candidate metadata has no pinned distribution. Do not download a formal-release path.'}
        }
    }
    if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid course version.' }
    if($Preview -and $Preview -notmatch '^[a-f0-9]{12}$'){throw 'Invalid preview identity.'}
    $distribution=if($Preview){"previews/v$Version/$Preview"}else{"releases/course/v$Version"}
    $cacheId=if($Preview){"v$Version-preview-$Preview"}else{"v$Version"}
    $url = "$baseUrl/$distribution/aicoding-student-kit.zip"
    $checksumFile = Join-Path $records "aicoding-student-kit-$cacheId.sha256"
    Receive-CourseFile ($url -replace '\.zip$', '.sha256') $checksumFile
    $checksum = (Get-Content -LiteralPath $checksumFile -Raw).Trim()
    if ($checksum -notmatch '^([a-fA-F0-9]{64})\s+aicoding-student-kit\.zip$') { throw 'Invalid course checksum file.' }
    $expectedHash = $Matches[1].ToLowerInvariant()
    if($Preview -and -not $expectedHash.StartsWith($Preview)){throw 'Preview identity does not match its artifact checksum.'}
    $archive = Join-Path $records "aicoding-student-kit-$cacheId.zip"
    if (-not (Test-Path -LiteralPath $archive) -or (Get-FileHash -LiteralPath $archive).Hash.ToLowerInvariant() -ne $expectedHash) {
        $partial = $archive + '.partial'
        Receive-CourseFile $url $partial
        if ((Get-FileHash -LiteralPath $partial).Hash.ToLowerInvariant() -ne $expectedHash) { throw 'Course archive checksum mismatch.' }
        Move-Item -LiteralPath $partial -Destination $archive -Force
    }
    $staging = Join-Path $records ('stage-' + [guid]::NewGuid())
    $courseRoot = Join-Path $workspacePath ("course-materials-$cacheId")
    try {
        Expand-CourseMaterials $archive $staging
        $requiredFiles=@('VERSION.json', 'setup-guide.md', 'Install-CourseSkills.ps1', 'Setup-DockerDesktop.ps1', 'windows-installers.json', 'ai-coding-env-skill.zip', 'ai-coding-project-skill.zip')
        if([version]$Version -ge [version]'2.1.0'){$requiredFiles+=@('Course-Native.ps1','Setup-Podman.ps1')}
        foreach ($required in $requiredFiles) {
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
                $engineEntry=Join-Path $envSkill 'scripts\Setup-Podman.ps1'
                if(Test-Path -LiteralPath $engineEntry){
                    . $engineEntry
                    if (-not (Get-SetupWsl).Ready) {$installerFiles += Resolve-SetupInstaller 'wsl' '' $manifest}
                    if (-not (Get-PodmanPaths).Cli) {$installerFiles += Resolve-PodmanComponent $workspacePath 'engine'}
                    $installerFiles += Resolve-PodmanComponent $workspacePath 'compose'
                }else{
                    # Explicit historical releases retain their original setup route.
                    . (Join-Path $envSkill 'scripts\Setup-PodmanDesktop.ps1')
                    if (-not (Get-SetupWsl).Ready) {$installerFiles += Resolve-SetupInstaller 'wsl' '' $manifest}
                    if (-not (Get-PodmanPaths).Desktop) {$installerFiles += Resolve-PodmanInstaller $workspacePath ''}
                }
            } else {
                $installerFiles += Resolve-SetupInstaller 'wsl' '' $manifest
                $installerFiles += Resolve-SetupInstaller 'docker' '' $manifest
            }
        } finally { Set-Location -LiteralPath $priorLocation }
    }
    $result = [ordered]@{ PreparedAt = (Get-Date).ToString('o'); CourseVersion = $Version; DistributionId=$Preview; DistributionStatus=$(if($Preview){'candidate'}else{'release'}); ContainerRuntime=$Runtime; PackageUrl = $url; PackageSha256 = $expectedHash; PackageRoot = $courseRoot; SetupGuide = (Join-Path $courseRoot 'setup-guide.md'); SkillScope = 'user'; SkillsDirectory = (Split-Path $installedSkills[0].Destination -Parent); SkillNames = @($installedSkills.Name); InstallerFiles = $installerFiles; InstallersSkipped = [bool]$WithoutInstallers; EnvironmentVerified = $false }
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $records 'materials.json') -Encoding UTF8
    @{ContainerRuntime=$Runtime;SelectedAt=(Get-Date).ToString('o')} | ConvertTo-Json | Set-Content (Join-Path $records 'container-runtime.json') -Encoding UTF8
    $agents = Join-Path $workspacePath 'AGENTS.md'
    $entry = "<!-- ai-coding:materials-entry:1 -->`n## Course preparation entry`nRead .course-setup/materials.json to locate setup-guide.md and user-level SkillsDirectory. For a full preparation request, read ai-coding-env/references/preparation-workflow.md and continue E-01 tools -> E-06 CloudBase -> E-07 GitHub -> E-08 SiliconFlow -> E-05 summary in the same task. Tools ready is only one stage; do not stop and ask the learner to say continue. Save the current stage and resume after necessary identity/terms/fees/restart actions. A tool-only troubleshooting request keeps its scope. Reuse existing installers and valid service results; register user-level preparation and service references for a new B. Downloads, installed skills, saved configuration and real service checks are separate. Preserve work; do not create a product or copy secrets/skills into a project.`n<!-- ai-coding:materials-entry:end -->"
    $entry=$entry.Replace('Read .course-setup/materials.json', "Selected container runtime: $Runtime. Prepare only this runtime; use its local engine, Compose and reports. New preparations use Podman CLI plus managed standalone Docker Compose, without either Desktop. Existing project runtime bindings remain authoritative; selection is never verification. Read .course-setup/materials.json")
    $text = if (Test-Path -LiteralPath $agents) { Get-Content -LiteralPath $agents -Raw } else { '' }
    if ($text -match '(?s)<!-- ai-coding:materials-entry:1 -->.*?<!-- ai-coding:materials-entry:end -->') { $text = [regex]::Replace($text, '(?s)<!-- ai-coding:materials-entry:1 -->.*?<!-- ai-coding:materials-entry:end -->', $entry) } else { $text = $text.TrimEnd() + "`n`n" + $entry }
    Set-Content -LiteralPath $agents -Value $text -Encoding UTF8
    $rule=Join-Path $workspacePath '.trae\rules\course-preparation.md'
    $ruleText="---`nalwaysApply: true`n---`n<!-- ai-coding:preparation-rule:2 -->`nRead the root AGENTS.md course preparation entry before starting or resuming this workspace. Keep original product rules. Use the selected user-level course skills and recorded preparation source; never treat tool readiness as full account/service readiness.`n"
    if(Test-Path -LiteralPath $rule){
        if([IO.File]::ReadAllText($rule) -notmatch 'ai-coding:preparation-rule:2'){throw 'Existing preparation rule is not course-managed; preserved.'}
    }
    [void](New-Item -ItemType Directory -Path (Split-Path $rule -Parent) -Force)
    Set-Content -LiteralPath $rule -Value $ruleText -Encoding UTF8
    return [pscustomobject]$result
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    if (-not $WorkingDirectory) { $WorkingDirectory = (Get-Location).Path }
    $arguments=@{Workspace=$WorkingDirectory;Version=$CourseVersion;Preview=$PreviewId;WithoutInstallers=$SkipInstallers}
    if($PSBoundParameters.ContainsKey('ContainerRuntime')){$arguments.Runtime=$ContainerRuntime}
    Get-CourseMaterials @arguments
}
