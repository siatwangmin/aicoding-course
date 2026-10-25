#Requires -Version 5.1
# Resume an incomplete installation; never uninstall its tools or detach projects.
. (Join-Path $PSScriptRoot 'Course-Lifecycle.ps1')
. (Join-Path $PSScriptRoot 'Course-UninstallAdapters.ps1')
. (Join-Path $PSScriptRoot 'Course-Upgrade.ps1')

function Repair-CourseInstallationForInstall([string]$Workspace) {
    $workspacePath=(Resolve-Path -LiteralPath $Workspace -ErrorAction Stop).Path
    Assert-CoursePlainPath $workspacePath
    $upgradeGate=Enter-CourseUpgradeLock
    $gate=$null
    try {
        $gate=Get-CourseCheckedLifecycleLock
        $db=Read-CourseLifecycle
        $found=@($db.installations|Where-Object {$_.workspace -ieq $workspacePath -and $_.status -ne 'removed'})
        if($found.Count -gt 1){throw 'AMBIGUOUS_INSTALLATION'}
        if(-not $found.Count -or $found[0].status -eq 'active'){return [pscustomobject]@{status='not-needed';removed=0;retained=0}}
        $install=Get-CourseInstallation $found[0].installationId
        if($install.status -notin @('partial','uninstalling')){throw ('INSTALLATION_STATE_UNSUPPORTED: status='+$install.status)}
        if(@($db.leases|Where-Object {Test-CourseLeaseAlive $_}).Count){throw 'LIFECYCLE_BUSY: an installation or project operation is still running.'}
        $id=$install.installationId
        $directory=Join-Path (Get-CourseLifecycleRoot) ('install-recovery/'+[guid]::NewGuid().ToString('N'))
        $null=Protect-CourseDirectory $directory
        $null=Copy-Item -LiteralPath (Join-Path (Get-CourseLifecycleRoot) 'catalog.json') -Destination (Join-Path $directory 'catalog-before.json')
        $report=[ordered]@{schemaVersion=1;installationId=$id;workspace=$workspacePath;previousStatus=$install.status;status='cleaning';items=@();pendingIntents=@($db.intents|Where-Object {$_.installationId -eq $id -and $_.status -eq 'pending'}|ForEach-Object id);checkedAt=[datetimeoffset]::UtcNow.ToString('o')}
        $reportPath=Join-Path $directory 'result.json'
        $resources=@($db.resources|Where-Object {($_.references -contains $id -or $_.owner -eq $id) -and $_.status -eq 'present'})
        foreach($resource in $resources){
            $reason=$null
            if($resource.owner -ne $id -or @($resource.references|Where-Object {$_ -and $_ -ne $id}).Count){$reason='shared'}
            elseif($resource.ownership -ne 'created'){$reason='ownership-not-exclusive'}
            elseif($resource.kind -notin @('file','directory','skill') -or $resource.dataClass -in @('source','businessData','signature','credential')){$reason='protected-resource'}
            elseif($resource.backupPath){$reason='previous-copy-required'}
            elseif(Test-CoursePathWithin (Join-Path $env:USERPROFILE '.trae-cn/skills') $resource.locator){$reason='shared-user-skill'}
            elseif(-not(Test-CoursePathWithin $workspacePath $resource.locator) -and -not($resource.metadata.backupFor -and (Test-CoursePathWithin (Join-Path $env:USERPROFILE '.trae-cn/course-skill-backups') $resource.locator))){$reason='outside-preparation'}
            elseif((Test-CoursePathWithin $resource.locator $PSScriptRoot -AllowEqual) -or (Test-Path -LiteralPath (Join-Path $resource.locator 'execution-manifest.json'))){$reason='execution-package-preserved'}
            if(-not $reason -and $resource.kind -eq 'directory'){
                if(@($db.resources|Where-Object {$_.status -eq 'present' -and $_.resourceKey -ne $resource.resourceKey -and $_.allowedRoot -and (Test-CoursePathWithin $resource.locator $_.locator)}).Count){$reason='contains-registered-resource'}
                if(@($db.installations|ForEach-Object {$_.projects}|Where-Object {$_.path -and (Test-CoursePathWithin $resource.locator $_.path -AllowEqual)}).Count){$reason='contains-project'}
                if(@($db.installations|Where-Object {$_.installationId -ne $id -and $_.status -ne 'removed' -and (Test-CoursePathWithin $resource.locator $_.workspace -AllowEqual)}).Count){$reason='contains-installation'}
            }
            if(-not $reason -and $resource.metadata.backupFor){
                $dependent=@($db.resources|Where-Object resourceKey -eq $resource.metadata.backupFor)
                $required=@($db.resources|Where-Object {$_.status -eq 'present' -and $_.backupPath -and $_.backupPath -ieq $resource.locator})
                if($required.Count){$reason='backup-still-referenced'}
                elseif($dependent.Count -ne 1){$reason='backup-target-unverified'}
            }
            $item=[ordered]@{resourceKey=$resource.resourceKey;locator=$resource.locator;action='retain';reason=$reason;status='retained'}
            $report.items+=@($item)
            if($reason){continue}
            $check=Get-CourseResourceCheck $resource 'remove'
            if($check.status -eq 'blocked'){$item.reason=$check.reason;continue}
            $item.action='remove';$item.status='intent';$item.reason='owned-unmodified'
            Write-CourseJson $reportPath $report
            # The shared adapter rechecks the baseline and absolute delete boundary.
            try {
                Invoke-CourseResourceRemoval $resource 'remove'
                if(-not(Test-CourseResourceRemoved $resource 'remove')){throw 'REMOVAL_NOT_VERIFIED'}
            } catch {
                $item.status='failed';$item.reason=[string]$_.Exception.Message
                $report.status='failed';Write-CourseJson $reportPath $report
                throw ('INSTALLATION_CLEANUP_FAILED: inspect '+$reportPath)
            }
            $item.status='removed'
            $resource.references=@($resource.references|Where-Object {$_ -ne $id})
            $resource.status='removed';$resource.revision=[guid]::NewGuid().ToString('N')
        }
        # Keep this installation identity and all project/service bindings. A new
        # generation invalidates interrupted uninstall plans before reactivation.
        $generation=if($found[0].PSObject.Properties['recoveryGeneration']){[int]$found[0].recoveryGeneration}else{0}
        $found[0]|Add-Member NoteProperty recoveryGeneration ($generation+1) -Force
        $found[0].status='active';$found[0].recovered=$true
        $null=Write-CourseLifecycle $db
        $report.status='ready-to-install';Write-CourseJson $reportPath $report
        return [pscustomobject]@{status='ready-to-install';installationId=$id;removed=@($report.items|Where-Object status -eq 'removed').Count;retained=@($report.items|Where-Object status -eq 'retained').Count;report=$reportPath}
    } finally {$null=Close-CourseLifecycleLock $gate;$null=Exit-CourseUpgradeLock $upgradeGate}
}
