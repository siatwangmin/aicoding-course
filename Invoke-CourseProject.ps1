#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ProjectDirectory,
      [ValidateSet('Start','Verify','RunScript','Install','Add','Remove','Repair')][string]$Action='Verify',
      [string]$Script,[string[]]$Packages,[string[]]$ScriptArguments,[switch]$DevDependency,
      [ValidateRange(10,3600)][int]$TimeoutSeconds=600)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Course-Runtime.ps1')
function Invoke-CourseProjectAction {
    param([string]$Root,[string]$Operation,[string]$NpmScript,[string[]]$PackageNames,[string[]]$ExtraArguments,[bool]$Development,[int]$Timeout)
    if($Operation -eq 'RunScript' -and $NpmScript -notmatch '^[a-zA-Z][a-zA-Z0-9:_-]*$'){throw 'PROJECT_SCRIPT_NAME_REQUIRED'}
    if($Operation -in @('Add','Remove') -and (-not $PackageNames.Count -or @($PackageNames|Where-Object {$_ -match '^-' -or $_ -match '\s'}).Count)){throw 'EXPLICIT_PACKAGE_NAMES_REQUIRED'}
    $maintenance=$Operation -in @('Install','Add','Remove','Repair')
    $result=$null
    $ctx=Get-CourseProjectRuntime $Root -Start -ForDependencyMaintenance:$maintenance
    $recordPath=Join-Path $ctx.Root '.ai-coding\command.json'
    $record=@{schemaVersion=2;action=$Operation;image=$ctx.Project.image;imageId=$ctx.ImageId;containerRuntime=$ctx.Project.containerRuntime;startedAt=(Get-Date).ToString('o');status='running'}
    Write-CourseJson $recordPath $record
    try{
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
            $arguments=$ctx.Prefix+@('compose','exec','-T','app','npm','run',$NpmScript)
            if($ExtraArguments){$arguments+=@('--')+$ExtraArguments}
            $result=Invoke-SetupNative $ctx.Cli $arguments $Timeout $ctx.Root
            if($result.ExitCode -ne 0){throw 'CONTAINER_PROJECT_SCRIPT_FAILED'}
        }
        $record.status='verified'
    }catch{
        $record.status='failed';$record.error=$_.Exception.Message
        throw
    }finally{
        if($result){
            $log=Join-Path $ctx.Root '.local\course-command.log';Assert-CoursePlainPath $log
            [void](New-Item -ItemType Directory -Path (Split-Path $log -Parent) -Force)
            [IO.File]::WriteAllText($log,$result.Output,[Text.UTF8Encoding]::new($false))
            $record.exitCode=$result.ExitCode;$record.log=$log
        }
        $record.finishedAt=(Get-Date).ToString('o');Write-CourseJson $recordPath $record
    }
    return [pscustomobject]@{status=$record.status;projectDirectory=$ctx.Root;action=$Operation;url=('http://127.0.0.1:'+$ctx.Project.port);evidence=$recordPath}
}
if($MyInvocation.InvocationName -ne '.'){
    Invoke-CourseProjectAction $ProjectDirectory $Action $Script $Packages $ScriptArguments ([bool]$DevDependency) $TimeoutSeconds|ConvertTo-Json
}
