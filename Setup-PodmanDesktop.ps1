#Requires -Version 5.1
[CmdletBinding()]
param([ValidateSet('Check','Prepare','Verify')][string]$Mode='Check', [string]$WorkingDirectory,
      [string]$MachineName='podman-machine-default', [string]$InstallerDirectory)

$podmanInvocation=@{Mode=$Mode;WorkingDirectory=$WorkingDirectory;MachineName=$MachineName;InstallerDirectory=$InstallerDirectory}
. (Join-Path $PSScriptRoot 'Setup-DockerDesktop.ps1')
$Mode=$podmanInvocation.Mode; $WorkingDirectory=$podmanInvocation.WorkingDirectory
$MachineName=$podmanInvocation.MachineName; $InstallerDirectory=$podmanInvocation.InstallerDirectory

function Get-PodmanPaths {
    $cli = Get-Command podman.exe -ErrorAction SilentlyContinue
    $cliPath = if ($cli) { $cli.Source } else { $null }
    foreach ($candidate in @("$env:LOCALAPPDATA\Programs\Podman\podman.exe", "$env:ProgramFiles\RedHat\Podman\podman.exe")) {
        if (-not $cliPath -and (Test-Path -LiteralPath $candidate)) { $cliPath=$candidate }
    }
    $desktop = @("$env:ProgramFiles\Podman Desktop\Podman Desktop.exe", "$env:LOCALAPPDATA\Programs\Podman Desktop\Podman Desktop.exe", "$env:LOCALAPPDATA\Programs\podman-desktop\Podman Desktop.exe") |
        Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    return [pscustomobject]@{ Cli=$cliPath; Desktop=$desktop }
}

function Resolve-PodmanInstaller {
    param([string]$Workspace, [string]$Directory)
    $manifest=Join-Path $PSScriptRoot '..\assets\podman-installers.json'
    if (-not (Test-Path -LiteralPath $manifest)) {$manifest=Join-Path $PSScriptRoot 'podman-installers.json'}
    $entry=(Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json).desktop
    if ($entry.sha256 -notmatch '^[a-f0-9]{64}$' -or $entry.downloadUrl -notmatch '^https://github\.com/podman-desktop/podman-desktop/releases/download/v[0-9.]+/podman-desktop-[0-9.]+-setup-x64\.exe$') { throw 'Invalid official Podman installer manifest.' }
    $folders=@($Directory, (Join-Path $Workspace 'release'), (Join-Path $Workspace 'releases'), (Join-Path $Workspace 'software')) | Where-Object { $_ }
    $file=$folders | ForEach-Object { Join-Path $_ $entry.file } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    $source='Local'
    if (-not $file) {
        $folder=Join-Path $Workspace 'release'; [void](New-Item -ItemType Directory -Path $folder -Force)
        $file=Join-Path $folder $entry.file
        $partial=$file+'.partial'
        Receive-SetupInstaller $entry.downloadUrl $partial
        # Exact official asset hash is required before installation, including local copies.
        if ((Get-FileHash -LiteralPath $partial).Hash.ToLowerInvariant() -ne $entry.sha256) { throw 'Podman installer SHA-256 mismatch; partial file retained for diagnosis.' }
        Move-Item -LiteralPath $partial -Destination $file -Force
        $source=$entry.downloadUrl
    }
    if ((Get-FileHash -LiteralPath $file).Hash.ToLowerInvariant() -ne $entry.sha256) { throw 'Podman installer SHA-256 mismatch.' }
    $signature=Get-AuthenticodeSignature -LiteralPath $file
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName,$false) -cne $entry.publisher) { throw 'Podman installer publisher signature mismatch.' }
    $record=Join-Path $Workspace '.podman-setup'; [void](New-Item -ItemType Directory -Path $record -Force)
    @{File=$file;Source=$source;Sha256=$entry.sha256;Publisher=$entry.publisher;CheckedAt=(Get-Date).ToString('o')} |
        ConvertTo-Json | Set-Content (Join-Path $record 'installer-desktop.json') -Encoding UTF8
    return $file
}

function Get-SetupPodman {
    param([string]$Machine='podman-machine-default', [string]$RepairWorkspace)
    $paths=Get-PodmanPaths
    if (-not $paths.Cli -or -not $paths.Desktop) { throw 'Podman Desktop or Podman CLI is missing; follow references/windows-podman-setup.md.' }
    $inspection=Invoke-SetupNative $paths.Cli @('machine','inspect',$Machine)
    if ($inspection.ExitCode -ne 0) { throw "Local Podman machine unavailable: $($inspection.Output)" }
    $machineList=ConvertFrom-Json -InputObject $inspection.Output
    $machineInfo=@($machineList)[0]
    if ($machineInfo.Name -ne $Machine) { throw 'Unexpected Podman machine.' }
    $connection=if ($machineInfo.Rootful) { "$Machine-root" } else { $Machine }
    $connections=Invoke-SetupNative $paths.Cli @('system','connection','list','--format','json')
    if ($connections.ExitCode -ne 0) { throw $connections.Output }
    $connectionList=ConvertFrom-Json -InputObject $connections.Output
    $local=@($connectionList | Where-Object { $_.Name -eq $connection -and $_.IsMachine -eq $true -and $_.URI -match '^ssh://(?:root|user)@127\.0\.0\.1:\d+/run/(?:user/\d+/)?podman/podman\.sock$' })
    if (@($local).Count -ne 1) { throw 'Podman verification requires the selected local machine connection; remote services cannot substitute.' }
    $info=Invoke-SetupNative $paths.Cli @('--connection',$connection,'info','--format','json')
    if ($info.ExitCode -ne 0) { throw $info.Output }
    $engine=$info.Output | ConvertFrom-Json
    $compose=Invoke-SetupNative $paths.Cli @('--connection',$connection,'compose','version')
    if ($engine.host.os -ne 'linux' -or $engine.host.arch -ne 'amd64' -or $compose.ExitCode -ne 0) { throw 'Linux amd64 Podman Server and Compose must both be available.' }
    # compose version alone works even when the Windows API forwarding pipe is absent.
    $composeApi=Invoke-SetupNative $paths.Cli @('--connection',$connection,'compose','ls','--format','json')
    if ($composeApi.ExitCode -ne 0 -and $RepairWorkspace) {
        $pipe=$machineInfo.ConnectionInfo.PodmanPipe.Path
        $helper=Join-Path (Split-Path $paths.Cli -Parent) 'win-sshproxy.exe'
        if ($pipe -eq "\\.\pipe\$Machine" -and -not (Test-Path -LiteralPath $pipe) -and (Test-Path -LiteralPath $helper)) {
            # Arguments match Podman's bundled Windows forwarding helper (v6.0.2).
            # Restore only the machine's own local pipe; never touch docker_engine or restart workloads.
            $proxyDir=Join-Path $RepairWorkspace '.podman-setup\api-proxy'
            [void](New-Item -ItemType Directory -Path $proxyDir -Force)
            $arguments=@($Machine,$proxyDir,"npipe:////./pipe/$Machine",$local[0].URI,$local[0].Identity)
            Start-Process -FilePath $helper -ArgumentList (($arguments | ForEach-Object {ConvertTo-SetupArgument $_}) -join ' ') -WindowStyle Hidden | Out-Null
            for ($attempt=0;$attempt -lt 8;$attempt++) {
                $composeApi=Invoke-SetupNative $paths.Cli @('--connection',$connection,'compose','ls','--format','json')
                if ($composeApi.ExitCode -eq 0) {break}
                Start-Sleep -Milliseconds 250
            }
        }
    }
    if ($composeApi.ExitCode -ne 0) {throw "Compose cannot reach the selected local Podman API: $($composeApi.Output)"}
    return [pscustomobject]@{ Cli=$paths.Cli; Desktop=$paths.Desktop; Machine=$Machine; Connection=$connection; Endpoint=$local.URI;
        ServerVersion=$engine.version.Version; Rootless=[bool]$engine.host.security.rootless; Compose=$compose.Output;
        NetworkMode=$(if($engine.host.security.rootless){'pasta'}else{'bridge'}) }
}

function Invoke-PodmanSetup {
    param([string]$Workspace, [string]$Action='Verify', [string]$Machine='podman-machine-default', [string]$Directory)
    if ($Machine -notmatch '^podman-machine-[a-zA-Z0-9_-]+$') { throw 'Use a local named Podman machine.' }
    $folder=Join-Path $Workspace '.podman-setup'; [void](New-Item -ItemType Directory -Path $folder -Force)
    $record=[ordered]@{CheckedAt=(Get-Date).ToString('o');ContainerRuntime='podman';Mode=$Action;Decision='Incomplete';Machine=$Machine;Snapshot=$null;NotVerified=@()}
    try {
        if ($Action -eq 'Prepare') {
            $paths=Get-PodmanPaths
            if (-not $paths.Desktop) {
                $installer=Resolve-PodmanInstaller $Workspace $Directory
                Write-Host 'Installing official Podman Desktop. Any terms or elevation prompt must be handled by the learner.'
                $installed=Invoke-SetupNative $installer @('/S','/currentuser') 900
                if ($installed.ExitCode -ne 0) { throw $installed.Output }
                $paths=Get-PodmanPaths
            }
            if ($paths.Desktop -and -not (Get-Process -Name 'Podman Desktop' -ErrorAction SilentlyContinue)) { Start-Process -FilePath $paths.Desktop -WindowStyle Hidden | Out-Null }
            if (-not $paths.Cli) { throw 'Desktop installed, but engine onboarding is incomplete. Assistant must follow the Podman reference, not report readiness.' }
            $machines=Invoke-SetupNative $paths.Cli @('machine','list','--format','json')
            if ($machines.ExitCode -ne 0) { throw $machines.Output }
            $machineList=ConvertFrom-Json -InputObject $machines.Output
            $existing=@($machineList | Where-Object Name -eq $Machine)
            $operation=$null
            if (-not $existing) { $operation=Invoke-SetupNative $paths.Cli @('machine','init','--rootful=false','--now',$Machine) 900 }
            elseif (-not $existing.Running) { $operation=Invoke-SetupNative $paths.Cli @('machine','start',$Machine) 300 }
            if ($operation -and $operation.ExitCode -ne 0) { throw $operation.Output }
        }
        $record.Snapshot=if($Action -eq 'Prepare'){Get-SetupPodman $Machine $Workspace}else{Get-SetupPodman $Machine}
        $record.Decision='Ready'
        return 0
    } catch { $record.NotVerified+= $_.Exception.Message; Write-Host $_.Exception.Message; return 2 }
    finally {
        $record | ConvertTo-Json -Depth 7 | Set-Content (Join-Path $folder 'report.json') -Encoding UTF8
        $choice=Join-Path $Workspace '.course-setup'; [void](New-Item -ItemType Directory -Path $choice -Force)
        @{ContainerRuntime='podman';Machine=$Machine;SelectedAt=(Get-Date).ToString('o')} | ConvertTo-Json | Set-Content (Join-Path $choice 'container-runtime.json') -Encoding UTF8
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference='Stop'
    if (-not $WorkingDirectory) {$WorkingDirectory=(Get-Location).Path}
    exit (Invoke-PodmanSetup (Resolve-Path -LiteralPath $WorkingDirectory).Path $Mode $MachineName $InstallerDirectory)
}
