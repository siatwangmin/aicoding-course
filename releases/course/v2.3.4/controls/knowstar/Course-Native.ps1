#Requires -Version 5.1
# Shared native process and download helpers; importing never starts an engine.
. (Join-Path $PSScriptRoot 'Course-Context.ps1')

function ConvertFrom-CourseComposeJson([string]$Text) {
    # Compose preserves Linux environment keys such as HTTP_PROXY/http_proxy.
    # PS 5.1 ConvertFrom-Json cannot represent those in a PSObject.
    if((Get-Command ConvertFrom-Json).Parameters.ContainsKey('AsHashtable')){
        return ConvertFrom-Json -InputObject $Text -AsHashtable
    }
    Add-Type -AssemblyName System.Web.Extensions
    $serializer=New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $serializer.MaxJsonLength=8388608
    return $serializer.DeserializeObject($Text)
}

function Get-CoursePodmanManifest {
    $path=Join-Path $PSScriptRoot '..\assets\podman-installers.json'
    if(-not(Test-Path -LiteralPath $path)){$path=Join-Path $PSScriptRoot 'podman-installers.json'}
    return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
}
function Get-CoursePodmanBinding {
    $file=Join-Path $env:USERPROFILE '.ai-coding\tool-paths.json'
    if(Test-Path -LiteralPath $file){
        Assert-CoursePlainPath $file
        return (Get-Content -LiteralPath $file -Raw -Encoding UTF8|ConvertFrom-Json).podman
    }
    return $null
}
function Get-CourseComposeBinding {
    $binding=Get-CoursePodmanBinding
    $path=$binding.compose
    if(-not $path -or -not [IO.Path]::IsPathRooted($path) -or -not(Test-Path -LiteralPath $path -PathType Leaf)){throw 'MANAGED_COMPOSE_REQUIRED: run Setup-Podman.ps1 -Mode Prepare.'}
    Assert-CoursePlainPath $path
    if($path -match '(?i)[\\/]Docker[\\/]Docker[\\/]|podman-desktop'){throw 'DESKTOP_COMPOSE_REFUSED'}
    $entry=(Get-CoursePodmanManifest).compose
    $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if($hash -cne $entry.sha256){throw 'MANAGED_COMPOSE_SHA256_MISMATCH'}
    return [pscustomobject]@{provider='docker-compose';path=$path;version=$entry.version;sha256=$hash;source=$entry.downloadUrl}
}
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
    $start.EnvironmentVariables.Remove('DOCKER_TLS_VERIFY')
    $start.EnvironmentVariables.Remove('DOCKER_CERT_PATH')
    if ([IO.Path]::GetFileNameWithoutExtension($FilePath) -eq 'podman') {
        $binding=Get-CoursePodmanBinding
        if($binding.dataHome){$start.EnvironmentVariables['XDG_DATA_HOME']=$binding.dataHome}
        if($Arguments -contains 'compose') {
            $provider=Get-CourseComposeBinding
            $start.EnvironmentVariables['PODMAN_COMPOSE_PROVIDER']=$provider.path
            $start.EnvironmentVariables['PODMAN_COMPOSE_WARNING_LOGS']='false'
        }
    }
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
    if ($version) { $detail = "WSL $version（要求至少 2.1.5；WSL 2 能否运行由最终所选引擎验证）" }
    return [pscustomobject]@{ Ready = $ready; Version = $version; Detail = $detail; Raw = $result.Output }
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

