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
    [string]$StorageRoot = 'D:\AI-Coding',
    [ValidateRange(1, 600)][int]$EngineTimeoutSeconds = 120
)

function Test-SetupAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-SetupArgument {
    param([string]$Value)
    if ($Value -ne '' -and $Value -notmatch '[\s"]') { return $Value }
    return '"' + ([regex]::Replace($Value, '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

function ConvertFrom-SetupBytes {
    param([byte[]]$Bytes)
    if (-not $Bytes -or $Bytes.Length -eq 0) { return '' }
    $oddNulls = 0
    for ($i = 1; $i -lt $Bytes.Length; $i += 2) { if ($Bytes[$i] -eq 0) { $oddNulls++ } }
    $encoding = [Text.Encoding]::UTF8
    if (($Bytes.Length -ge 2 -and $Bytes[0] -eq 255 -and $Bytes[1] -eq 254) -or $oddNulls -gt ($Bytes.Length / 8)) {
        $encoding = [Text.Encoding]::Unicode
    } elseif ($Bytes.Length -ge 2 -and $Bytes[0] -eq 254 -and $Bytes[1] -eq 255) {
        $encoding = [Text.Encoding]::BigEndianUnicode
    }
    return $encoding.GetString($Bytes).TrimStart([char]0xFEFF).Trim()
}

function Invoke-SetupNative {
    param([string]$FilePath, [string[]]$Arguments, [int]$TimeoutSeconds = 30, [string]$WorkingDirectory)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $FilePath
    if($WorkingDirectory){$start.WorkingDirectory=$WorkingDirectory}
    # Quote only when necessary: older wsl.exe treats a quoted flag as a Linux command.
    # Escape quotes and trailing backslashes using Windows argv rules for paths with spaces.
    $start.Arguments = (($Arguments | ForEach-Object { ConvertTo-SetupArgument $_ }) -join ' ')
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    # Verification must never inherit a remote Docker endpoint from the user's environment.
    $start.EnvironmentVariables.Remove('DOCKER_HOST')
    $start.EnvironmentVariables.Remove('DOCKER_CONTEXT')
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $outBuffer = [IO.MemoryStream]::new()
    $errBuffer = [IO.MemoryStream]::new()
    try {
        [void]$process.Start()
        # Read both pipes concurrently as bytes; wsl.exe redirects UTF-16, Docker emits UTF-8.
        $stdout = $process.StandardOutput.BaseStream.CopyToAsync($outBuffer)
        $stderr = $process.StandardError.BaseStream.CopyToAsync($errBuffer)
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill()
            $process.WaitForExit()
            return [pscustomobject]@{ ExitCode = -1; Output = 'Command timed out'; TimedOut = $true }
        }
        $process.WaitForExit()
        if (-not $stdout.Wait(2000) -or -not $stderr.Wait(2000)) {
            return [pscustomobject]@{ ExitCode = -1; Output = 'Command output timed out'; TimedOut = $true }
        }
        $stdoutText=ConvertFrom-SetupBytes $outBuffer.ToArray()
        $stderrText=ConvertFrom-SetupBytes $errBuffer.ToArray()
        $output = ($stdoutText + "`n" + $stderrText).Trim()
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $output; Stdout=$stdoutText; Stderr=$stderrText; TimedOut = $false }
    } catch {
        return [pscustomobject]@{ ExitCode = -1; Output = $_.Exception.Message; TimedOut = $false }
    } finally { $process.Dispose(); $outBuffer.Dispose(); $errBuffer.Dispose() }
}

function Get-SetupWsl {
    $exe = Join-Path $env:SystemRoot 'System32\wsl.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        return [pscustomobject]@{ Ready = $false; Version = $null; Detail = '尚未安装 WSL'; Raw = '' }
    }
    $result = Invoke-SetupNative $exe @('--version')
    $match = [regex]::Match($result.Output, '(?m)^[^\r\n\d]*(\d+\.\d+\.\d+(?:\.\d+)?)\s*$')
    $version = $null
    if ($result.ExitCode -eq 0 -and $match.Success) { $version = [version]$match.Groups[1].Value }
    $ready = $null -ne $version -and $version -ge [version]'2.1.5'
    $detail = '未确认现代 WSL 已安装；仅有 wsl.exe 或旧版 WSL 不算通过'
    if ($version) { $detail = "WSL $version（要求至少 2.1.5；WSL 2 能否运行由最终 Docker 引擎验证）" }
    return [pscustomobject]@{ Ready = $ready; Version = $version; Detail = $detail; Raw = $result.Output }
}

function Get-SetupDockerPaths {
    $desktop = $null
    $cli = $null
    $command = Get-Command 'Docker Desktop.exe' -ErrorAction SilentlyContinue
    $discovered = $null
    if ($command) { $discovered = $command.Source }
    if ($DockerDesktopPath) { $discovered = $DockerDesktopPath }
    if ($discovered -and (Test-Path -LiteralPath $discovered -PathType Leaf)) {
        $desktop = $discovered
        $candidate = Join-Path (Split-Path $desktop -Parent) 'resources\bin\docker.exe'
        if (Test-Path -LiteralPath $candidate) { $cli = $candidate }
    }
    # Fall back to standard, per-user and registered installation locations.
    $folders = @(
        (Join-Path $env:ProgramFiles 'Docker\Docker'),
        (Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop')
    )
    foreach ($folder in $folders) {
        if ($desktop) { break }
        if (Test-Path -LiteralPath (Join-Path $folder 'Docker Desktop.exe')) {
            $desktop = Join-Path $folder 'Docker Desktop.exe'
            $candidate = Join-Path $folder 'resources\bin\docker.exe'
            if (Test-Path -LiteralPath $candidate) { $cli = $candidate }
            break
        }
    }
    foreach ($registry in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Docker Desktop',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Docker Desktop'
    )) {
        if (-not $desktop -and (Test-Path $registry)) {
            $location = (Get-ItemProperty $registry -ErrorAction SilentlyContinue).InstallLocation
            if ($location -and (Test-Path -LiteralPath (Join-Path $location 'Docker Desktop.exe'))) {
                $desktop = Join-Path $location 'Docker Desktop.exe'
                $candidate = Join-Path $location 'resources\bin\docker.exe'
                if (Test-Path -LiteralPath $candidate) { $cli = $candidate }
            }
        }
    }
    if (-not $cli) {
        $command = Get-Command docker.exe -ErrorAction SilentlyContinue
        if ($command) { $cli = $command.Source }
    }
    return [pscustomobject]@{ Desktop = $desktop; Cli = $cli }
}

function Get-SetupDocker {
    param([int]$TimeoutSeconds = 5)
    $paths = Get-SetupDockerPaths
    $result = [ordered]@{
        Installed = [bool]$paths.Desktop; Desktop = $paths.Desktop; Cli = $paths.Cli
        Ready = $false; Detail = '尚未确认 Docker Desktop 已安装并启动'
        Endpoint = $null; Info = $null; Version = $null; Compose = $null; ServerVersion = $null
    }
    if (-not $paths.Cli) { return [pscustomobject]$result }
    # Explicit local named pipes prevent a remote context from producing a false pass.
    foreach ($endpoint in @('npipe:////./pipe/dockerDesktopLinuxEngine', 'npipe:////./pipe/docker_engine')) {
        $info = Invoke-SetupNative $paths.Cli @('--host', $endpoint, 'info', '--format', '{{json .}}') $TimeoutSeconds
        $result.Info = $info.Output
        if ($info.ExitCode -ne 0) { continue }
        try { $data = $info.Output | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        $result.Endpoint = $endpoint
        if ($data.OSType -ne 'linux') {
            $result.Detail = '当前是 Windows containers；在 Docker 托盘菜单选择 Switch to Linux containers'
            break
        }
        if ($data.OperatingSystem -notmatch 'Docker Desktop') {
            $result.Detail = '本地引擎不是 Docker Desktop；请打开课程使用的 Docker Desktop'
            break
        }
        $version = Invoke-SetupNative $paths.Cli @('--host', $endpoint, 'version', '--format', '{{json .}}') $TimeoutSeconds
        $compose = Invoke-SetupNative $paths.Cli @('compose', 'version') $TimeoutSeconds
        $result.Version = $version.Output
        $result.Compose = $compose.Output
        $server = $null
        try { $server = ($version.Output | ConvertFrom-Json -ErrorAction Stop).Server.Version } catch { }
        $result.ServerVersion = $server
        $result.Ready = $result.Installed -and $version.ExitCode -eq 0 -and [bool]$server -and $compose.ExitCode -eq 0
        if ($result.Ready) { $result.Detail = "本机 Docker Desktop 的 Linux 引擎可用；Server $server；Compose 可用" }
        else { $result.Detail = '引擎已有响应，但 Desktop、Server 或 Compose 检查未全部通过' }
        break
    }
    if (-not $result.Endpoint) { $result.Detail = 'Docker 本机引擎尚未就绪；助手将启动程序并自动检查 Server/Compose' }
    return [pscustomobject]$result
}

function Start-SetupDockerDesktop {
    $paths = Get-SetupDockerPaths
    if (-not $paths.Desktop) { throw '动态探测未找到 Docker Desktop.exe；需要提供真实安装路径，不能猜测。' }
    if (-not (Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue)) {
        Write-Host '助手正在启动 Docker Desktop。首次出现条款页面时，请本人阅读并决定是否接受；接受后助手会自动检查引擎。'
        Start-Process -FilePath $paths.Desktop | Out-Null
    }
}

function Wait-SetupDocker {
    param([int]$TimeoutSeconds = 120)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        $docker = Get-SetupDocker -TimeoutSeconds 3
        if ($docker.Ready) { return $docker }
        if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) { break }
        Start-Sleep -Milliseconds ([int][math]::Min(3000, ($TimeoutSeconds - $timer.Elapsed.TotalSeconds) * 1000))
    } while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    return $docker
}

function Get-SetupSnapshot {
    param([string]$RecordDirectory)
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $system = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $processors = @(Get-CimInstance Win32_Processor -ErrorAction Stop)
    # Installed module capacity avoids rejecting an 8 GB laptop with hardware-reserved RAM.
    $memoryBytes = $system.TotalPhysicalMemory
    try {
        $modules = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop)
        $installedBytes = ($modules | Measure-Object -Property Capacity -Sum).Sum
        if ($installedBytes -gt 0) { $memoryBytes = $installedBytes }
    } catch { }
    $admin = Test-SetupAdministrator
    $boot = $os.LastBootUpTime.ToUniversalTime().ToString('o')
    $machine = $env:COMPUTERNAME
    $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $state = $null
    $stateFile = Join-Path $RecordDirectory 'restart.json'
    if (Test-Path -LiteralPath $stateFile) {
        $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json -ErrorAction Stop
    }
    $rebootReasons = @()
    foreach ($key in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )) { if (Test-Path $key) { $rebootReasons += $key } }
    if ($state -and $state.Boot -eq $boot) { $rebootReasons += $state.Reason }
    $feature = 'Unknown'
    $featureError = ''
    $featureSource = 'Unconfirmed'
    if ($admin) {
        try {
            $feature = [string](Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction Stop).State
            $featureSource = 'LiveAdministratorQuery'
        }
        catch { $featureError = $_.Exception.Message }
    } else {
        $priorFile = Join-Path $RecordDirectory 'report.json'
        if (Test-Path -LiteralPath $priorFile) {
            try {
                $proof = (Get-Content -LiteralPath $priorFile -Raw | ConvertFrom-Json).FeatureConfirmation
                if ($proof -and $proof.State -eq 'Enabled' -and $proof.Boot -eq $boot -and $proof.Machine -eq $machine -and $proof.UserSid -eq $userSid -and $proof.ConfirmedAsAdministrator -eq $true) {
                    $feature = 'Enabled'; $featureSource = 'PersistedAdministratorQuery'
                }
            } catch { $featureError = '旧报告不可读取，不能复用确认结果' }
        }
    }
    if ($feature -match 'Pending') { $rebootReasons += "VirtualMachinePlatform: $feature" }
    $hypervisor = [bool]$system.HypervisorPresent
    $virtualization = 'Unknown'
    $slat = 'Unknown'
    if ($hypervisor) { $virtualization = 'Enabled'; $slat = 'Enabled' }
    elseif ($processors.Count -gt 0) {
        $vf = @($processors | Where-Object { $null -ne $_.VirtualizationFirmwareEnabled })
        if ($vf.Count -eq $processors.Count) {
            $virtualization = 'Enabled'
            if (@($vf | Where-Object { -not $_.VirtualizationFirmwareEnabled }).Count) { $virtualization = 'Disabled' }
        }
        $sf = @($processors | Where-Object { $null -ne $_.SecondLevelAddressTranslationExtensions })
        if ($sf.Count -eq $processors.Count) {
            $slat = 'Enabled'
            if (@($sf | Where-Object { -not $_.SecondLevelAddressTranslationExtensions }).Count) { $slat = 'Disabled' }
        }
    }
    $launchOff = $false
    $bcdRaw = ''
    if ($admin) {
        $bcd = Invoke-SetupNative (Join-Path $env:SystemRoot 'System32\bcdedit.exe') @('/enum', '{current}')
        $bcdRaw = $bcd.Output
        # Missing setting means the Windows default, Auto. Do not rely on localized systeminfo text.
        $launchOff = $bcd.ExitCode -eq 0 -and $bcd.Output -match '(?im)^\s*hypervisorlaunchtype\s+Off\s*$'
    }
    $service = Get-CimInstance Win32_Service -Filter "Name='LanmanServer'" -ErrorAction Stop
    $arch = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITEW6432')
    if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
    $build = [int]$os.BuildNumber
    $windowsReady = $os.ProductType -eq 1 -and (($build -ge 19045 -and $build -lt 22000) -or $build -ge 22631)
    return [pscustomobject]@{
        WindowsReady = $windowsReady; Windows = $os.Caption; Build = $build
        Architecture = $arch; MemoryGB = [math]::Round($memoryBytes / 1GB, 1)
        Manufacturer = $system.Manufacturer; Model = $system.Model
        Admin = $admin; Boot = $boot; Machine = $machine; UserSid = $userSid; RebootReasons = $rebootReasons
        Virtualization = $virtualization; Slat = $slat; Feature = $feature; FeatureError = $featureError
        FeatureSource = $featureSource
        HypervisorLaunchOff = $launchOff; BcdRaw = $bcdRaw
        ServiceReady = $null -ne $service -and $service.StartMode -eq 'Auto' -and $service.State -eq 'Running'
        Service = $service | Select-Object Name, StartMode, State
        Wsl = Get-SetupWsl; Docker = Get-SetupDocker
    }
}

function Get-SetupDecision {
    param($Snapshot)
    if (-not $Snapshot.WindowsReady -or $Snapshot.Architecture -ne 'AMD64' -or $Snapshot.MemoryGB -lt 8) { return 'Unsupported' }
    if ($Snapshot.Virtualization -ne 'Enabled' -or $Snapshot.Slat -ne 'Enabled') { return 'Firmware' }
    if ($Snapshot.Feature -eq 'Unknown' -or (-not $Snapshot.Admin -and $Snapshot.FeatureSource -ne 'PersistedAdministratorQuery')) { return 'Permissions' }
    if (@($Snapshot.RebootReasons).Count) { return 'Restart' }
    if ($Snapshot.HypervisorLaunchOff) { return 'BootConfiguration' }
    if ($Snapshot.Feature -ne 'Enabled') { return 'Feature' }
    if (-not $Snapshot.Wsl.Ready) { return 'Wsl' }
    if (-not $Snapshot.ServiceReady) { return 'Service' }
    if (-not $Snapshot.Docker.Installed) { return 'DockerInstall' }
    if (-not $Snapshot.Docker.Ready) { return 'DockerStart' }
    return 'Ready'
}

function Write-SetupSummary {
    param($Snapshot)
    Write-Host "`n正在检查这台电脑。下面是本次的真实检查结果：" -ForegroundColor Cyan
    $stateNames = @{ Enabled = '已开启'; Disabled = '尚未开启'; Unknown = '暂时无法确认'; EnablePending = '等待重启'; DisablePending = '等待重启' }
    $firmwareDetail = $stateNames[$Snapshot.Virtualization]
    $slatDetail = $stateNames[$Snapshot.Slat]
    $featureDetail = $stateNames[$Snapshot.Feature]
    if (-not $featureDetail) { $featureDetail = $Snapshot.Feature }
    $rows = @(
        @('Windows 与硬件', ($Snapshot.WindowsReady -and $Snapshot.Architecture -eq 'AMD64' -and $Snapshot.MemoryGB -ge 8), "$($Snapshot.Windows)，版本 $($Snapshot.Build)，$($Snapshot.Architecture)，内存 $($Snapshot.MemoryGB) GB"),
        @('CPU 虚拟化', ($Snapshot.Virtualization -eq 'Enabled'), $firmwareDetail),
        @('CPU 二级地址转换', ($Snapshot.Slat -eq 'Enabled'), $slatDetail),
        @('Windows 功能读取权限', ($Snapshot.Admin -or $Snapshot.FeatureSource -eq 'PersistedAdministratorQuery'), '管理员实时读取或同机同启动的已确认结果'),
        @('虚拟机平台', ($Snapshot.Feature -eq 'Enabled'), $featureDetail),
        @('重启状态', (@($Snapshot.RebootReasons).Count -eq 0), '有待重启时先保存工作，再自行重启'),
        @('WSL', $Snapshot.Wsl.Ready, $Snapshot.Wsl.Detail),
        @('Windows Server 服务', $Snapshot.ServiceReady, 'Docker 所需的 LanmanServer 服务须自动启动且正在运行'),
        @('Docker Desktop', $Snapshot.Docker.Installed, '安装程序完成后还要首次启动'),
        @('Docker 引擎与 Compose', $Snapshot.Docker.Ready, $Snapshot.Docker.Detail)
    )
    foreach ($row in $rows) {
        $label = '需要处理'; $color = 'Yellow'
        if ($row[1]) { $label = '已满足'; $color = 'Green' }
        Write-Host ("[{0}] {1}：{2}" -f $label, $row[0], $row[2]) -ForegroundColor $color
    }
}

function Get-SetupNextStep {
    param([string]$Decision, $Snapshot)
    switch ($Decision) {
        'Unsupported' { return '请把检查记录交给课程支持人员：本地安装包仅用于 x64 的 Windows 10 22H2 / Windows 11 23H2 及以上、至少 8 GB 内存，不用于 Windows Server 或 ARM 电脑。Windows 版本是否仍受支持另按官方说明核对。' }
        'Firmware' { return "请按 Ctrl+Shift+Esc 打开任务管理器 → 性能 → CPU，看右侧‘虚拟化’。若显示‘已禁用’，保存工作，通过 Windows 设置 → 系统 → 恢复（Windows 10：更新和安全 → 恢复）→ 高级启动 → 疑难解答 → 高级选项 → UEFI 固件设置进入 BIOS，把 Intel Virtualization Technology / VT-x / AMD SVM 设为 Enabled，保存退出，再运行助手。这台电脑是 $($Snapshot.Manufacturer) $($Snapshot.Model)。不同品牌菜单不同，找不到或有密码时请课程支持人员协助；虚拟机/远程云电脑需管理员开启嵌套虚拟化。检测为 Unknown 或任务管理器已开启时，先核实记录，不能直接判定未开启。" }
        'Permissions' { return '助手会以管理员身份运行 Prepare/Verify；UAC 窗口出现时请点击“是”。若单位策略拒绝或必须使用别人的管理员账号，请 IT 协助，不能把另一账号的状态当作你的检查结果。' }
        'Restart' { return '系统条件需要重启才能生效。请先保存工作，通过 Windows 电源菜单重启；返回后助手在原工作目录继续同一脚本。不会跳过重启或自动丢弃未保存内容。' }
        'BootConfiguration' { return 'Windows 的虚拟机启动项被关闭。安装助手的 Prepare 模式会把 hypervisorlaunchtype 设为 Auto，然后请你保存工作并重启。' }
        'Feature' { return '下一步开启 Windows 虚拟机平台。安装助手的 Prepare 模式执行 Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All -NoRestart，完成后请保存工作并重启，再运行同一助手。' }
        'Wsl' { return '下一步使用课程提供的 wsl.3.0.1.0.x64.msi 本地安装 WSL；Prepare 模式会校验并安装，不需要下载 Ubuntu，也不要求注册 Linux 账号。' }
        'Service' { return 'Docker 所需的 Windows Server 服务尚未自动运行。Prepare 模式将 LanmanServer 设为自动并启动；如果单位策略禁止操作，请让 IT 协助。' }
        'DockerInstall' { return '助手将运行已校验的本地 Docker 安装程序，固定使用 WSL 2，随后自动启动并验收；首次条款由你本人决定。' }
        'DockerStart' { return "助手负责启动 Docker Desktop 并自动轮询 Server/Compose；首次条款出现时请本人阅读并决定是否接受。当前结果：$($Snapshot.Docker.Detail)。超时仍未就绪时读取本机报告中的错误，不能凭窗口字样判定通过。" }
        'Ready' { return 'Docker Desktop 已安装，本机 Linux 引擎和 Compose 已通过检查；这只代表 Docker 就绪，课程工具箱尚未验收。助手应立即继续执行 Verify-Toolchain.ps1，自动拉取镜像并检查容器内工具，不等待学员再发指令。' }
    }
}

function Test-SetupInstallerFile {
    param([string]$File, $Entry, [switch]$Downloaded)
    $hash = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash.ToLowerInvariant()
    $matches = $hash -eq $Entry.sha256
    if (-not $matches -and -not $Entry.allowPublisherSignedUpdate) { throw "安装包校验不一致：$($Entry.file)，不继续运行。" }
    $publisher = $null; $signatureStatus = 'NotChecked'
    if ($Downloaded -or -not $matches) {
        $signature = Get-AuthenticodeSignature -LiteralPath $File
        $signatureStatus = [string]$signature.Status
        if ($signature.SignerCertificate) {
            $publisher = $signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
        }
        if ($signatureStatus -ne 'Valid' -or -not $Entry.publisher -or $publisher -cne $Entry.publisher) {
            throw "安装包签名未通过：$($Entry.file)，Status=$signatureStatus，Publisher=$publisher。"
        }
    }
    return @{ Sha256 = $hash; MatchesCourseHash = $matches; Publisher = $publisher; SignatureStatus = $signatureStatus }
}

function Receive-SetupInstaller {
    param([string]$Url, [string]$Destination)
    $priorTls = [Net.ServicePointManager]::SecurityProtocol
    $response=$null;$inputStream=$null;$outputStream=$null
    try {
        [Net.ServicePointManager]::SecurityProtocol = $priorTls -bor [Net.SecurityProtocolType]::Tls12
        $request=[Net.HttpWebRequest]::Create($Url);$request.Timeout=30000;$request.ReadWriteTimeout=15000
        $response=$request.GetResponse();$inputStream=$response.GetResponseStream()
        $outputStream=[IO.File]::Open($Destination,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $buffer=New-Object byte[] 65536;$watch=[Diagnostics.Stopwatch]::StartNew();[long]$received=0
        while(($count=$inputStream.Read($buffer,0,$buffer.Length)) -gt 0){
            $outputStream.Write($buffer,0,$count);$received+=$count
            if($watch.Elapsed.TotalSeconds -gt 1800){throw 'DOWNLOAD_TOTAL_TIMEOUT: partial file retained.'}
            if($watch.Elapsed.TotalSeconds -ge 20 -and $received/$watch.Elapsed.TotalSeconds -lt 65536){throw 'DOWNLOAD_SLOW: check reachable network/proxy for the same official source; partial file retained.'}
        }
    } finally {
        if($outputStream){$outputStream.Dispose()};if($inputStream){$inputStream.Dispose()};if($response){$response.Dispose()}
        [Net.ServicePointManager]::SecurityProtocol = $priorTls
    }
}

function Save-SetupInstallerEvidence {
    param([string]$Kind, [string]$File, [string]$Source, $Validation)
    $records = Join-Path (Get-Location).Path '.docker-setup'
    [void](New-Item -ItemType Directory -Path $records -Force)
    @{ CheckedAt = (Get-Date).ToString('o'); Kind = $Kind; File = $File; Source = $Source
        Version = (Get-Item -LiteralPath $File).VersionInfo.FileVersion; Validation = $Validation } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $records ("installer-$Kind.json")) -Encoding UTF8
}

function Resolve-SetupInstaller {
    param([string]$Kind, [string]$Directory, [string]$Manifest)
    if (-not (Test-Path -LiteralPath $Manifest)) { throw '找不到安装包校验清单 windows-installers.json，请重新解压完整资料包。' }
    $entry = (Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json).$Kind
    if (-not $entry -or $entry.sha256 -notmatch '^[0-9a-fA-F]{64}$') { throw '安装包清单格式不正确，请使用完整课程资料。' }
    $folders = @()
    if ($Directory) { $folders += $Directory }
    $starts = @()
    if (-not $Directory) { $starts = @((Get-Location).Path, $PSScriptRoot) }
    foreach ($start in $starts) {
        $cursor = $start
        for ($i = 0; $i -lt 4 -and $cursor; $i++) {
            $folders += Join-Path $cursor 'software'
            $folders += Join-Path $cursor 'release'
            $folders += Join-Path $cursor 'releases'
            $folders += $cursor
            $cursor = Split-Path $cursor -Parent
        }
    }
    foreach ($folder in $folders) {
        $candidate = Join-Path $folder $entry.file
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        Write-Host "正在校验本地安装包：$candidate"
        $validation = Test-SetupInstallerFile $candidate $entry
        Save-SetupInstallerEvidence $Kind $candidate 'Local' $validation
        return (Resolve-Path -LiteralPath $candidate).Path
    }
    $approvedUrl = switch ($Kind) {
        'wsl' { 'https://github.com/microsoft/WSL/releases/download/3.0.1/wsl.3.0.1.0.x64.msi' }
        'docker' { 'https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe' }
    }
    if (-not $approvedUrl -or $entry.downloadUrl -cne $approvedUrl) { throw "没有找到 $($entry.file)，清单没有匹配的官方自动下载地址。" }
    $destinationDirectory = $Directory
    if (-not $destinationDirectory) {
        . (Join-Path $PSScriptRoot 'Course-Context.ps1')
        $plan = Get-CourseStoragePlan $StorageRoot
        $destinationDirectory = $plan.installers
    }
    [void](New-Item -ItemType Directory -Path $destinationDirectory -Force)
    $destination = Join-Path $destinationDirectory $entry.file
    $staging = Join-Path $destinationDirectory ('.installer-download-' + [guid]::NewGuid())
    [void](New-Item -ItemType Directory -Path $staging)
    $temporary = Join-Path $staging $entry.file
    try {
        Write-Host "未找到本地 $($entry.file)，助手正在从官方来源下载：$approvedUrl"
        Receive-SetupInstaller $approvedUrl $temporary
        $validation = Test-SetupInstallerFile $temporary $entry -Downloaded
        Move-Item -LiteralPath $temporary -Destination $destination -Force
        Save-SetupInstallerEvidence $Kind $destination $approvedUrl $validation
        return (Resolve-Path -LiteralPath $destination).Path
    } catch {
        throw "安装包获取未完成：$($_.Exception.Message)。助手应读取下载记录，复用已有安装程序或从上述官方地址继续处理；不要求学员下载软件合集或移动文件。"
    } finally {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    }
}

function Save-SetupRestart {
    param([string]$RecordDirectory, [string]$Boot, [string]$Reason)
    @{ Boot = $Boot; Reason = $Reason } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $RecordDirectory 'restart.json') -Encoding UTF8
}

function Invoke-SetupAction {
    param([string]$Decision, $Snapshot, [string]$Directory, [string]$Manifest, [string]$RecordDirectory)
    switch ($Decision) {
        'BootConfiguration' {
            $result = Invoke-SetupNative (Join-Path $env:SystemRoot 'System32\bcdedit.exe') @('/set', 'hypervisorlaunchtype', 'auto')
            if ($result.ExitCode -ne 0) { throw "无法开启虚拟机启动项：$($result.Output)" }
            Save-SetupRestart $RecordDirectory $Snapshot.Boot '已开启虚拟机启动项'
            return 'Restart'
        }
        'Feature' {
            Write-Host '正在开启虚拟机平台，请等待；助手不会自动重启。'
            $result = Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All -NoRestart -ErrorAction Stop
            if ((Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction Stop).State -notmatch '^Enabled$|^EnablePending$') {
                throw '开启虚拟机平台后未确认成功，请把记录交给课程支持人员。'
            }
            # Reboot even if DISM reports no restart: this run changed the prerequisite.
            Save-SetupRestart $RecordDirectory $Snapshot.Boot '已开启虚拟机平台'
            return 'Restart'
        }
        'Wsl' {
            $msi = Resolve-SetupInstaller 'wsl' $Directory $Manifest
            $log = Join-Path $RecordDirectory 'wsl-install.log'
            Write-Host '正在从本地安装 WSL；安装日志保存在检查记录目录。'
            $process = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') -ArgumentList @('/i', ('"' + $msi + '"'), '/passive', '/norestart', '/L*v', ('"' + $log + '"')) -Wait -PassThru
            if ($process.ExitCode -in @(3010, 1641)) {
                Save-SetupRestart $RecordDirectory $Snapshot.Boot 'WSL 安装要求重启'
                return 'Restart'
            }
            if ($process.ExitCode -ne 0) { throw "WSL 安装未完成，返回码 $($process.ExitCode)。查看 wsl-install.log；取消或策略拒绝不能视为成功。" }
            if (-not (Get-SetupWsl).Ready) { throw '安装程序返回完成，但 WSL 版本检查仍未通过。请查看安装日志，不继续安装 Docker。' }
            return 'Continue'
        }
        'Service' {
            Set-Service -Name LanmanServer -StartupType Automatic -ErrorAction Stop
            Start-Service -Name LanmanServer -ErrorAction Stop
            return 'Continue'
        }
        'DockerInstall' {
            $installer = Resolve-SetupInstaller 'docker' $Directory $Manifest
            Write-Host '助手正在自动安装 Docker Desktop，固定使用 WSL 2；首次条款由你本人决定。' -ForegroundColor Cyan
            # Automate installation; legal acceptance remains in Desktop's first-run page.
            . (Join-Path $PSScriptRoot 'Course-Context.ps1')
            $plan = Get-CourseStoragePlan $StorageRoot
            Write-CourseJson (Join-Path (Split-Path $RecordDirectory -Parent) '.course-setup\storage-plan.json') $plan
            $installArgs = @('install', '--backend=wsl-2', '--quiet', ('--installation-dir=' + (Join-Path $plan.programs 'docker')), ('--wsl-default-data-root=' + $plan.dockerData))
            $process = Start-Process -FilePath $installer -ArgumentList (($installArgs | ForEach-Object { ConvertTo-SetupArgument $_ }) -join ' ') -WindowStyle Hidden -Wait -PassThru
            if ($process.ExitCode -in @(3010, 1641)) {
                Save-SetupRestart $RecordDirectory $Snapshot.Boot 'Docker 安装要求重启'
                return 'Restart'
            }
            if ($process.ExitCode -ne 0) { throw "Docker 安装未完成，返回码 $($process.ExitCode)。请记录安装窗口提示，排除取消、权限或磁盘空间问题后再运行。" }
            if (-not (Get-SetupDockerPaths).Desktop) { throw '安装程序已退出，但未找到 Docker Desktop。请将安装目录或错误画面交给课程支持人员，不把它算作通过。' }
            return 'Continue'
        }
        default { return $Decision }
    }
}

function Write-EnvironmentChecklist {
    param([string]$Workspace, $Setup, $Toolchain, $Steps, $CurrentDocker, $SkillsVerification)
    if (-not (Get-Command Get-WorkspaceSkillsVerification -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'Install-CourseSkills.ps1') }
    if (-not $SkillsVerification) { $SkillsVerification = Get-WorkspaceSkillsVerification $Workspace }
    function Get-ChecklistState($Value) {
        if ($null -eq $Value) { return '未检查' }
        if ($Value) { return '通过' }
        return '未通过'
    }
    function ConvertTo-ChecklistCell($Value) {
        return ([string]$Value -replace '\|', '\\|' -replace '[\r\n]+', ' ')
    }
    $snapshot = $Setup.Snapshot
    $docker = $snapshot.Docker
    if ($CurrentDocker) { $docker = $CurrentDocker }
    $complete = $Setup.Decision -eq 'Ready' -and [bool]$Toolchain.VerifiedAt -and $Toolchain.ToolchainCheck.ExitCode -eq 0 -and $SkillsVerification.UserInstallationVerified
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('# AI Coding 环境验收 checklist')
    $lines.Add('')
    $lines.Add('') # Filled only after every required row has been checked.
    $lines.Add('')
    $lines.Add('报告生成时间：' + (Get-Date).ToString('o'))
    $lines.Add('Docker 检查时间：' + $Setup.CheckedAt)
    $lines.Add('工具箱通过时间：' + $Toolchain.VerifiedAt)
    $lines.Add('')
    $lines.Add('| 必要检查项 | 结果 | 实际证据 |')
    $lines.Add('| --- | --- | --- |')
    $rows = @(
        @('Windows / x64 / 至少 8 GB 内存', $(if ($snapshot) { $snapshot.WindowsReady -and $snapshot.Architecture -eq 'AMD64' -and $snapshot.MemoryGB -ge 8 } else { $null }), "$($snapshot.Windows)，build $($snapshot.Build)，$($snapshot.Architecture)，$($snapshot.MemoryGB) GB"),
        @('CPU 虚拟化与 SLAT', $(if ($snapshot) { $snapshot.Virtualization -eq 'Enabled' -and $snapshot.Slat -eq 'Enabled' } else { $null }), "虚拟化=$($snapshot.Virtualization)，SLAT=$($snapshot.Slat)"),
        @('Windows 虚拟机平台', $(if ($snapshot.Feature -and $snapshot.Feature -ne 'Unknown') { $snapshot.Feature -eq 'Enabled' } else { $null }), "$($snapshot.Feature)，证据来源=$($snapshot.FeatureSource)"),
        @('系统无需重启且虚拟机启动项正常', $(if ($snapshot -and $null -ne $snapshot.RebootReasons -and $null -ne $snapshot.HypervisorLaunchOff) { @($snapshot.RebootReasons).Count -eq 0 -and -not $snapshot.HypervisorLaunchOff } else { $null }), "Decision=$($Setup.Decision)；$($snapshot.RebootReasons -join '；')"),
        @('WSL 版本满足要求', $snapshot.Wsl.Ready, $snapshot.Wsl.Detail),
        @('Windows Server 服务', $snapshot.ServiceReady, "LanmanServer，StartMode=$($snapshot.Service.StartMode)，State=$($snapshot.Service.State)"),
        @('Docker Desktop 已安装', $docker.Installed, $docker.Desktop),
        @('本机 Linux 引擎与 Compose', $docker.Ready, "$($docker.Detail)；endpoint=$($docker.Endpoint)；Compose=$($docker.Compose)")
    )
    foreach ($row in $rows) {
        $lines.Add('| ' + $row[0] + ' | ' + (Get-ChecklistState $row[1]) + ' | ' + (ConvertTo-ChecklistCell $row[2]) + ' |')
        if ($null -eq $row[1] -or -not $row[1]) { $complete = $false }
    }
    foreach ($name in @('镜像获取', '镜像摘要精确匹配', '镜像平台 linux/amd64', '临时容器内开发工具')) {
        $state = '未检查'; $detail = '尚未执行工具箱验收；Docker Ready 不能代替本项通过。'
        if ($Steps -and $Steps.Contains($name)) { $state = $Steps[$name].State; $detail = $Steps[$name].Detail }
        if ($state -ne '通过' -and -not ($name -eq '镜像获取' -and $state -eq '已跳过')) { $complete = $false }
        $lines.Add('| ' + $name + ' | ' + $state + ' | ' + (ConvertTo-ChecklistCell $detail) + ' |')
    }
    $storage=Get-WorkspaceStorageEvidence $Workspace
    if($storage.Required){
        $lines.Add('| D 盘实际程序与数据位置 | '+$(if($storage.Verified){'通过'}else{'未通过'})+' | '+$storage.EvidencePath+' |')
        if(-not $storage.Verified){$complete=$false}
    }
    $outcome = '未完成'
    if ($complete) { $outcome = '已完成：工具箱已准备，可以创建新作品' }
    $lines[2] = "**结论：$outcome**"
    $lines.Add('')
    if (-not $complete) {
        $lines.Add('需要继续处理：' + $Setup.NextStep)
        if ($Toolchain) { $lines.Add('工具箱未验证项：' + ($Toolchain.NotVerified -join '；')) }
    }
    $lines.Add('')
    $lines.Add('本报告只验收开发环境。作品网页/APK 构建、云账号和 AI 授权需在对应阶段另行验证。')
    $lines.Add('实际记录：`.docker-setup/report.json`、`toolchain-verification.json`；工具记录尚未生成时以未检查为准。')
    $lines.Add('')
    foreach ($line in (Get-SkillsChecklistLines $SkillsVerification)) { $lines.Add($line) }
    Set-Content -LiteralPath (Join-Path $Workspace 'environment-checklist.md') -Value $lines -Encoding UTF8
}

function Save-SetupReport {
    param($Snapshot, [string]$SetupMode, [string]$RecordDirectory, [string]$Decision)
    if (-not $Decision) { $Decision = Get-SetupDecision $Snapshot }
    $proof = $null
    if ($Snapshot.Admin -and $Snapshot.Feature -eq 'Enabled') {
        $proof = @{ State = 'Enabled'; Boot = $Snapshot.Boot; Machine = $Snapshot.Machine; UserSid = $Snapshot.UserSid; ConfirmedAsAdministrator = $true; ConfirmedAt = (Get-Date).ToString('o') }
    } elseif ($Snapshot.FeatureSource -eq 'PersistedAdministratorQuery') {
        $prior = Join-Path $RecordDirectory 'report.json'
        if (Test-Path -LiteralPath $prior) { $proof = (Get-Content -LiteralPath $prior -Raw | ConvertFrom-Json).FeatureConfirmation }
    }
    $report = [ordered]@{
        CheckedAt = (Get-Date).ToString('o'); Mode = $SetupMode; Decision = $Decision
        NextStep = (Get-SetupNextStep $Decision $Snapshot); Snapshot = $Snapshot
        FeatureConfirmation = $proof
        NotVerified = @('镜像下载/导入', '容器实际运行', '具体作品构建')
    }
    $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $RecordDirectory 'report.json') -Encoding UTF8
    Write-EnvironmentChecklist (Split-Path $RecordDirectory -Parent) $report $null $null $null
}

function Invoke-DockerSetup {
    param([string]$SetupMode, [string]$Directory, [string]$Manifest, [string]$Workspace = (Get-Location).Path, [int]$StartupTimeout = 120)
    $recordDirectory = Join-Path $Workspace '.docker-setup'
    [void](New-Item -ItemType Directory -Path $recordDirectory -Force)
    $transcript = Join-Path $recordDirectory ('setup-' + (Get-Date -Format 'yyyyMMdd-HHmmssfff') + '.log')
    Start-Transcript -Path $transcript -ErrorAction Stop | Out-Null
    try {
        # A run has at most five actions; stop if an action does not change observed state.
        for ($attempt = 0; $attempt -lt 6; $attempt++) {
            $snapshot = Get-SetupSnapshot $recordDirectory
            $decision = Get-SetupDecision $snapshot
            Save-SetupReport $snapshot $SetupMode $recordDirectory $decision
            if ($decision -eq 'DockerStart' -and $SetupMode -in @('Prepare', 'Verify')) {
                Start-SetupDockerDesktop
                Write-Host "助手正在自动验证本机引擎与 Compose（最多 $StartupTimeout 秒），无需观察窗口状态。"
                $snapshot.Docker = Wait-SetupDocker $StartupTimeout
                $decision = Get-SetupDecision $snapshot
                Save-SetupReport $snapshot $SetupMode $recordDirectory $decision
            }
            Write-SetupSummary $snapshot
            Write-Host ("`n下一步：" + (Get-SetupNextStep $decision $snapshot)) -ForegroundColor Cyan
            Write-Host "检查记录：$recordDirectory"
            if ($decision -eq 'Ready') { return 0 }
            if ($SetupMode -ne 'Prepare') {
                if ($decision -eq 'Restart') { return 3010 }
                return 2
            }
            if ($decision -notin @('BootConfiguration', 'Feature', 'Wsl', 'Service', 'DockerInstall')) {
                if ($decision -eq 'Restart') { return 3010 }
                return 2
            }
            $outcome = Invoke-SetupAction $decision $snapshot $Directory $Manifest $recordDirectory
            if ($outcome -eq 'Restart') {
                Write-Host (Get-SetupNextStep 'Restart' $snapshot) -ForegroundColor Yellow
                # Re-read state so report.json describes the next action after the mutation.
                $snapshot = Get-SetupSnapshot $recordDirectory
                Save-SetupReport $snapshot $SetupMode $recordDirectory 'Restart'
                return 3010
            }
            $fresh = Get-SetupSnapshot $recordDirectory
            if ((Get-SetupDecision $fresh) -eq $decision) { throw '本步操作后状态没有改变。请把检查记录交给课程支持人员，不重复安装。' }
        }
        throw '本轮步骤已达到上限，请检查记录后继续。'
    } catch {
        Write-Host "`n本轮未完成：$($_.Exception.Message)" -ForegroundColor Red
        $failure = @{ CheckedAt = (Get-Date).ToString('o'); Mode = $SetupMode; Decision = 'Error'; Error = $_.Exception.Message; NextStep = '请将本次日志与 report.json 交给课程支持人员，解决原因后重跑同一助手。' }
        $failure | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $recordDirectory 'report.json') -Encoding UTF8
        Write-EnvironmentChecklist $Workspace $failure $null $null $null
        Write-Host "检查记录：$recordDirectory"
        return 1
    } finally { Stop-Transcript | Out-Null }
}

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
