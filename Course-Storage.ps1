#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'Course-Context.ps1')
function Test-CourseStorageLocation([string]$Workspace,[string]$Runtime='docker',[string]$Root='D:\AI-Coding') {
    $plan=Get-CourseStoragePlan $Root 0
    $paths=@();$programs=@()
    if($Runtime -eq 'docker'){
        $candidates=@((Join-Path $plan.programs 'docker\Docker Desktop.exe'),(Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'),(Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop\Docker Desktop.exe'))
        if(Get-Command Get-SetupDockerPaths -ErrorAction SilentlyContinue){$candidates=@((Get-SetupDockerPaths).Desktop)+$candidates}
        $programs=@($candidates|Where-Object {$_ -and (Test-Path -LiteralPath $_)}|Select-Object -First 1)
        foreach($name in @('settings-store.json','settings.json')){
            $settingsPath=Join-Path $env:APPDATA ('Docker\'+$name)
            if(Test-Path -LiteralPath $settingsPath){
                Assert-CoursePlainPath $settingsPath
                $settings=Read-CourseJson $settingsPath
                foreach($key in @('dataFolder','diskImageLocation')){if($settings.$key){$paths+=[string]$settings.$key}}
            }
        }
    }elseif($Runtime -eq 'podman'){
        $programs=@((Join-Path $plan.programs 'podman-desktop\Podman Desktop.exe'),(Join-Path $env:LOCALAPPDATA 'Programs\Podman Desktop\Podman Desktop.exe'),(Join-Path $env:ProgramFiles 'Podman Desktop\Podman Desktop.exe'))|Where-Object {Test-Path -LiteralPath $_}|Select-Object -First 1
        if(Get-Command Get-PodmanPaths -ErrorAction SilentlyContinue){$installed=Get-PodmanPaths;$programs=@($installed.Desktop,$installed.Cli)|Where-Object {$_ -and (Test-Path -LiteralPath $_)}}
        if(Test-Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'){
            foreach($item in Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'){
                $distro=Get-ItemProperty $item.PSPath
                if($distro.DistributionName -like 'podman-machine-*'){$paths+=[string]$distro.BasePath}
            }
        }
    }else{throw 'Invalid runtime.'}
    $rootPrefix=[IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'
    $actual=@()
    foreach($path in @($paths|Select-Object -Unique)){
        $normalized=[IO.Path]::GetFullPath(($path -replace '^\\\\\?\\',''))
        Assert-CoursePlainPath $normalized
        $vhd=@(Get-ChildItem -LiteralPath $normalized -Filter '*.vhdx' -File -Recurse -ErrorAction SilentlyContinue)
        $actual+=@{path=$normalized;withinRoot=$normalized.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase);vhdCount=$vhd.Count}
    }
    $programs=@($programs)
    $programsVerified=$programs.Count -gt 0
    foreach($program in $programs){Assert-CoursePlainPath $program;if([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($program)) -ne [IO.Path]::GetPathRoot($plan.desiredRoot)){$programsVerified=$false}}
    $passed=$programsVerified -and $actual.Count -gt 0 -and @($actual|Where-Object {-not $_.withinRoot -or $_.vhdCount -eq 0}).Count -eq 0
    $record=@{schemaVersion=2;desiredRoot=$plan.desiredRoot;runtime=$Runtime;checkedAt=(Get-Date).ToString('o');programPaths=$programs;actualPaths=$actual;status=$(if($passed){'verified'}else{'pending'});notVerified=@('Windows system components may remain on system drive.');nextAction=$(if($passed){$null}else{'Verify program installation and supported Desktop/WSL data-location migration; preserve existing resources, then verify again.'})}
    Write-CourseJson (Join-Path $Workspace '.course-setup\storage.json') $record
    return [pscustomobject]$record
}
