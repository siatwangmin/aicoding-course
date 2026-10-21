#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ProjectDirectory,
      [ValidateSet('Start','Verify','RunScript','Install','Add','Remove','Repair')][string]$Action='Verify',
      [switch]$ReuseBuild,
      [string]$Script,[string[]]$Packages,[string[]]$ScriptArguments,[switch]$DevDependency,
      [ValidateRange(10,3600)][int]$TimeoutSeconds=600)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Course-Runtime.ps1')
function Get-CourseFilesDigest([string]$Base,[string[]]$Paths) {
    $parts=@()
    foreach($relative in $Paths){
        $path=Join-Path $Base $relative
        if(-not(Test-Path -LiteralPath $path)){continue}
        Assert-CoursePlainPath $path
        $files=if(Test-Path -LiteralPath $path -PathType Container){@(Get-ChildItem -LiteralPath $path -Recurse -File)}else{@(Get-Item -LiteralPath $path)}
        foreach($file in $files|Sort-Object FullName){Assert-CoursePlainPath $file.FullName;$parts+=($file.FullName.Substring($Base.Length)+':'+(Get-FileHash -LiteralPath $file.FullName).Hash)}
    }
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($parts -join "`n"))))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}
function Invoke-CourseProjectAction {
    param([string]$Root,[string]$Operation,[string]$NpmScript,[string[]]$PackageNames,[string[]]$ExtraArguments,[bool]$Development,[int]$Timeout,[bool]$Reuse)
    if($Operation -eq 'RunScript' -and $NpmScript -notmatch '^[a-zA-Z][a-zA-Z0-9:_-]*$'){throw 'PROJECT_SCRIPT_NAME_REQUIRED'}
    if($Operation -in @('Add','Remove') -and (-not $PackageNames.Count -or @($PackageNames|Where-Object {$_ -match '^-' -or $_ -match '\s'}).Count)){throw 'EXPLICIT_PACKAGE_NAMES_REQUIRED'}
    $maintenance=$Operation -in @('Install','Add','Remove','Repair')
    $resolvedRoot=Resolve-CourseProjectRoot $Root
    $result=$null;$lifecycleLease=$null
    if(Get-Command Enter-CourseOperation -ErrorAction SilentlyContinue){$lifecycleLease=Enter-CourseOperation $resolvedRoot $Operation}
    $started=(Get-Date).ToUniversalTime().ToString('o');$timer=[Diagnostics.Stopwatch]::StartNew()
    $recordPath=Join-Path $resolvedRoot '.ai-coding\command.json'
    $record=@{schemaVersion=2;operationId=[guid]::NewGuid().ToString('N');action=$Operation;startedAt=$started;status='running'}
    Write-CourseJson $recordPath $record
    try{
        $ctx=Get-CourseProjectRuntime $resolvedRoot -Start -ForDependencyMaintenance:$maintenance
        $record.image=$ctx.Project.image;$record.imageId=$ctx.ImageId;$record.containerRuntime=$ctx.Project.containerRuntime
        if($maintenance){
            $backup=Join-Path $ctx.Root ('.local\dependency-changes\'+[guid]::NewGuid().ToString('N'))
            Assert-CoursePlainPath $backup;[void](New-Item -ItemType Directory -Path $backup -Force)
            foreach($name in @('package.json','package-lock.json')){
                $file=Join-Path $ctx.Source $name;Assert-CoursePlainPath $file
                if(-not(Test-Path -LiteralPath $file)){throw 'PROJECT_PACKAGE_AND_LOCK_REQUIRED'}
                Copy-Item -LiteralPath $file -Destination (Join-Path $backup $name)
            }
            $record.backup=$backup;Write-CourseJson $recordPath $record
            # Stop only this project's app so it cannot use partially modified dependencies.
            $stopped=Invoke-SetupNative $ctx.Cli ($ctx.Prefix+@('compose','stop','app')) 90 $ctx.Root
            if($stopped.ExitCode -ne 0){throw 'PROJECT_APP_STOP_FAILED'}
            $npm=switch($Operation){
                Add {@('install','--no-audit','--no-fund')+$(if($Development){@('--save-dev')}else{@()})+@('--')+$PackageNames}
                Remove {@('uninstall','--no-audit','--no-fund','--')+$PackageNames}
                default {@('ci','--prefer-offline','--no-audit','--no-fund')}
            }
            $arguments=$ctx.Prefix+@('compose','run','--rm','--no-deps','--pull','never','--workdir','/workspace','--entrypoint','npm','app')+$npm
            $result=Invoke-SetupNative $ctx.Cli $arguments $Timeout $ctx.Root
            if($result.ExitCode -ne 0){throw 'CONTAINER_DEPENDENCY_OPERATION_FAILED: inspect command log and preserved package backups; no host fallback.'}
            # The legacy image seeds template dependencies when its marker is absent.
            # npm ci removes markers; restore them only after a successful operation so
            # the next app start cannot overwrite freshly installed locked dependencies.
            $toolchain=Read-CourseJson (Join-Path $PSScriptRoot '..\assets\toolchain.json')
            if(-not $toolchain.templatePath -or $toolchain.templatePath -notmatch '^/[a-zA-Z0-9/_-]+$'){throw 'IMAGE_TEMPLATE_PATH_REQUIRED'}
            $markerCode='const fs=require("node:fs"),crypto=require("node:crypto");const hash=crypto.createHash("sha256").update(fs.readFileSync(process.argv[1]+"/package-lock.json")).digest("hex");for(const name of [".knowstar-image-seeded-"+hash,".knowstar-image-seeded"])fs.writeFileSync("/workspace/node_modules/"+name,"");'
            $marked=Invoke-SetupNative $ctx.Cli ($ctx.Prefix+@('compose','run','--rm','--no-deps','--pull','never','--workdir','/workspace','--entrypoint','node','app','-e',$markerCode,$toolchain.templatePath)) 30 $ctx.Root
            if($marked.ExitCode -ne 0){throw 'DEPENDENCY_SEED_MARKER_UPDATE_FAILED: keep app stopped and inspect.'}
            $ctx=Get-CourseProjectRuntime $ctx.Root -Start
        }elseif($Operation -eq 'RunScript'){
            $build=$NpmScript -eq 'build' -and -not $ExtraArguments
            $buildFile=Join-Path $ctx.Root '.ai-coding\web-build.json'
            $fingerprint=Get-CourseFilesDigest $ctx.Source @('src','public','package.json','package-lock.json','index.html','vite.config.ts','tsconfig.json','tailwind.config.js','postcss.config.js','.env','.env.local','.env.production','.env.production.local')
            $cached=if($build -and $Reuse -and (Test-Path -LiteralPath $buildFile)){Read-CourseJson $buildFile}else{$null}
            $reuseValid=$cached -and $cached.imageId -eq $ctx.ImageId -and $cached.inputFingerprint -eq $fingerprint -and (Test-Path -LiteralPath (Join-Path $ctx.Source 'dist\index.html')) -and $cached.outputFingerprint -eq (Get-CourseFilesDigest $ctx.Source @('dist'))
            if($reuseValid){$record.reused=$true;$record.inputFingerprint=$fingerprint}
            else{
                $arguments=$ctx.Prefix+@('compose','exec','-T','app','npm','run',$NpmScript)
                if($ExtraArguments){$arguments+=@('--')+$ExtraArguments}
                $result=Invoke-SetupNative $ctx.Cli $arguments $Timeout $ctx.Root
                if($result.ExitCode -ne 0){throw 'CONTAINER_PROJECT_SCRIPT_FAILED'}
                if($build){
                    if(-not(Test-Path -LiteralPath (Join-Path $ctx.Source 'dist\index.html'))){throw 'CURRENT_WEB_OUTPUT_MISSING'}
                    Write-CourseJson $buildFile @{schemaVersion=2;imageId=$ctx.ImageId;inputFingerprint=$fingerprint;outputFingerprint=(Get-CourseFilesDigest $ctx.Source @('dist'));checkedAt=(Get-Date).ToUniversalTime().ToString('o')}
                    $record.inputFingerprint=$fingerprint
                }
            }
        }
        $record.status='verified'
    }catch{
        $record.status='failed';$record.error=Protect-CourseOutput $_.Exception.Message
        throw
    }finally{
        if($lifecycleLease){Exit-CourseOperation $lifecycleLease}
        if($result){
            $log=Join-Path $ctx.Root '.local\course-command.log';Assert-CoursePlainPath $log
            [void](New-Item -ItemType Directory -Path (Split-Path $log -Parent) -Force)
            [IO.File]::WriteAllText($log,(Protect-CourseOutput $result.Output),[Text.UTF8Encoding]::new($false))
            $record.exitCode=$result.ExitCode;$record.log=$log
        }
        $record.finishedAt=(Get-Date).ToUniversalTime().ToString('o');$record.durationMs=$timer.ElapsedMilliseconds;Write-CourseJson $recordPath $record
        Write-CourseEvent $resolvedRoot @{operationId=$record.operationId;stage='project-command';action=$Operation;status=$record.status;startedAt=$started;finishedAt=$record.finishedAt;durationMs=$record.durationMs;runtime=$record.containerRuntime;imageId=$record.imageId;inputFingerprint=$record.inputFingerprint;evidence='.ai-coding/command.json'}
    }
    return [pscustomobject]@{status=$record.status;projectDirectory=$ctx.Root;action=$Operation;url=$ctx.Url;port=$ctx.Project.port;evidence=$recordPath}
}
if($MyInvocation.InvocationName -ne '.'){
    Invoke-CourseProjectAction $ProjectDirectory $Action $Script $Packages $ScriptArguments ([bool]$DevDependency) $TimeoutSeconds ([bool]$ReuseBuild)|ConvertTo-Json
}
