#Requires -Version 5.1
<#
Windows classroom installer. Check/Verify never modify Windows configuration.
Prepare can be rerun after reboot; every decision uses fresh machine state.
Dot-source to load functions for the isolated scenario tests.
#>
[CmdletBinding()]
param(
    [ValidateSet('Check', 'Prepare', 'Verify')][string]$Mode = 'Check',
    [string]$InstallerDirectory,
    [string]$ManifestPath,
    [string]$ExpectedUserSid,
    [string]$WorkingDirectory,
    [string]$DockerDesktopPath,
    [string]$StorageRoot = 'D:\AI-Practice',
    [ValidateRange(1, 600)][int]$EngineTimeoutSeconds = 120
)

. (Join-Path $PSScriptRoot 'Course-Docker.ps1')

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    if (-not $WorkingDirectory) { $WorkingDirectory = (Get-Location).Path }
    $WorkingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory -ErrorAction Stop).Path
    Set-Location -LiteralPath $WorkingDirectory
    # PowerShell 5.1 does not reliably populate PSScriptRoot in parameter defaults.
    if (-not $ManifestPath) {
        $ManifestPath = Join-Path $PSScriptRoot 'windows-installers.json'
        if (-not (Test-Path -LiteralPath $ManifestPath)) {
            $ManifestPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\assets\windows-installers.json'))
        }
    } else { $ManifestPath = [IO.Path]::GetFullPath($ManifestPath) }
    if ($InstallerDirectory) { $InstallerDirectory = [IO.Path]::GetFullPath($InstallerDirectory) }
    if ([Environment]::OSVersion.Platform -ne 'Win32NT') {
        Write-Host '请在 Windows 宿主机的 PowerShell 中运行，不要在 WSL、Linux 容器或隔离环境运行。'
        exit 2
    }
    if (-not [Environment]::Is64BitProcess) {
        Write-Host '请使用 Windows 64 位 PowerShell（开始菜单中的 Windows PowerShell），不要使用 x86 版本。'
        exit 2
    }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ($ExpectedUserSid -and $ExpectedUserSid -ne $sid) {
        Write-Host '权限窗口使用了不同的 Windows 账号。请让 IT 协助在原学员账号中完成准备，避免检查或安装到另一个人的用户环境。'
        exit 2
    }
    if ($Mode -in @('Prepare', 'Verify') -and -not (Test-SetupAdministrator)) {
        Write-Host '助手正在发起管理员权限窗口，请点击“是”；随后助手会继续准备或验证，无需手动打开 PowerShell。'
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (ConvertTo-SetupArgument $PSCommandPath), '-Mode', $Mode, '-ManifestPath', (ConvertTo-SetupArgument $ManifestPath), '-ExpectedUserSid', $sid, '-WorkingDirectory', (ConvertTo-SetupArgument $WorkingDirectory), '-EngineTimeoutSeconds', $EngineTimeoutSeconds)
        if ($InstallerDirectory) { $arguments += @('-InstallerDirectory', (ConvertTo-SetupArgument $InstallerDirectory)) }
        if ($DockerDesktopPath) { $arguments += @('-DockerDesktopPath', (ConvertTo-SetupArgument $DockerDesktopPath)) }
        $arguments += @('-StorageRoot', (ConvertTo-SetupArgument $StorageRoot))
        # Use an absolute manifest path: elevated PowerShell can start in a different directory.
        try {
            $elevationStarted = Get-Date
            $child = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Verb RunAs -ArgumentList $arguments -WorkingDirectory $WorkingDirectory -WindowStyle Hidden -Wait -PassThru
            # The elevated window closes at exit. Repeat the actionable result in the original window.
            $reportPath = Join-Path $WorkingDirectory '.docker-setup\report.json'
            if (Test-Path -LiteralPath $reportPath) {
                $lastReport = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
                if ([datetime]$lastReport.CheckedAt -ge $elevationStarted) {
                    if ($lastReport.Snapshot) { Write-SetupSummary $lastReport.Snapshot }
                    Write-Host ("`n下一步：" + $lastReport.NextStep) -ForegroundColor Cyan
                    if ($lastReport.Error) { Write-Host $lastReport.Error -ForegroundColor Red }
                    Write-Host "检查记录：$reportPath"
                } else { Write-Host '本次未产生新检查记录，请确认提升权限使用的是原学员账号，并请课程支持人员协助。' }
            } else {
                Write-Host '本次未产生检查记录，请确认提升权限使用的是原学员账号，并请课程支持人员协助。'
            }
            exit $child.ExitCode
        } catch {
            Write-Host '没有获得管理员权限；助手会依据实际授权结果处理。UAC 被取消时请允许下次请求，单位策略拒绝时请 IT 协助。'
            exit 2
        }
    }
    exit (Invoke-DockerSetup $Mode $InstallerDirectory $ManifestPath $WorkingDirectory $EngineTimeoutSeconds)
}
