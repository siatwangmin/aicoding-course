#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'Course-Context.ps1')
function Test-CourseStorageLocation([string]$Workspace,[string]$Runtime='podman',[string]$Root='D:\AI-Practice') {
    $plan=Get-CourseStoragePlan $Root 0
    $paths=@();$programs=@();$cachePaths=@();$cacheVerified=$true
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
        if(-not(Get-Command Get-PodmanPaths -ErrorAction SilentlyContinue)){. (Join-Path $PSScriptRoot 'Setup-Podman.ps1')}
        $installed=Get-PodmanPaths;$programs=@($installed.Cli,$installed.Compose)|Where-Object {$_ -and (Test-Path -LiteralPath $_)}
        $cacheVerified=[bool]$installed.DataHome -and (Test-Path -LiteralPath $installed.DataHome -PathType Container)
        if($installed.DataHome){$cachePaths+=@([IO.Path]::GetFullPath($installed.DataHome))}
        $selected=$null
        foreach($relative in @('.course-setup\container-runtime.json','.podman-setup\report.json')){
            $metadata=Join-Path $Workspace $relative
            if(Test-Path -LiteralPath $metadata){$selected=(Read-CourseJson $metadata).Machine;if($selected){break}}
        }
        $distributions=@()
        if(Test-Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'){
            foreach($item in Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'){
                $distro=Get-ItemProperty $item.PSPath
                if($distro.DistributionName -like 'podman-machine-*' -and (-not $selected -or $distro.DistributionName -eq $selected)){$distributions+=@($distro)}
            }
        }
        if($distributions.Count -eq 1){$paths+=[string]$distributions[0].BasePath}
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
    $programsVerified=$programs.Count -gt 0 -and ($Runtime -ne 'podman' -or $programs.Count -eq 2)
    foreach($program in $programs){Assert-CoursePlainPath $program;if([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($program)) -ne [IO.Path]::GetPathRoot($plan.desiredRoot)){$programsVerified=$false}}
    foreach($cache in $cachePaths){Assert-CoursePlainPath $cache;if(-not $cache.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)){$cacheVerified=$false}}
    $passed=$programsVerified -and $cacheVerified -and $actual.Count -gt 0 -and @($actual|Where-Object {-not $_.withinRoot -or $_.vhdCount -eq 0}).Count -eq 0
    $record=@{schemaVersion=2;desiredRoot=$plan.desiredRoot;runtime=$Runtime;checkedAt=(Get-Date).ToString('o');programPaths=$programs;actualPaths=$actual;cachePaths=$cachePaths;cacheVerified=$cacheVerified;status=$(if($passed){'verified'}else{'pending'});notVerified=@('Windows system components may remain on system drive.','OS restart and original workload trial need separate evidence.');nextAction=$(if($passed){$null}else{'Verify program installation and supported runtime/WSL data-location migration; preserve existing resources, then verify again.'})}
    Write-CourseJson (Join-Path $Workspace '.course-setup\storage.json') $record
    return [pscustomobject]$record
}
