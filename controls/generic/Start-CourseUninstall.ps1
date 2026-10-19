#Requires -Version 5.1
[CmdletBinding()]
param([switch]$ListOnly,[string]$PreparationDirectory)
. (Join-Path $PSScriptRoot 'Course-Uninstall.ps1')

function Start-CourseUninstall {
    param([switch]$List,[string]$Preparation)
    $catalog=Read-CourseLifecycle
    $installs=@($catalog.installations|Where-Object status -ne 'removed')
    if($List){return @($installs|Select-Object installationId,version,workspace,status)}
    if(-not $installs.Count){
        if(-not $Preparation){$Preparation=Read-Host '没有新安装记录。请输入原准备目录 A（留空取消）'}
        if(-not $Preparation){return 0}
        $installs=@(Import-CourseLegacyInstallation $Preparation)
    }
    Write-Host '环境卸载：云端作品、手机应用和 Windows 系统组件默认保留。'
    for($n=0;$n -lt $installs.Count;$n++){Write-Host (($n+1).ToString()+'. '+$installs[$n].workspace+' ['+$installs[$n].status+']')}
    $choice=Read-Host '输入安装编号（留空取消）'
    if(-not $choice){return 0}
    $index=0;if(-not [int]::TryParse($choice,[ref]$index) -or $index -lt 1 -or $index -gt $installs.Count){throw 'INVALID_INSTALLATION_SELECTION'}
    $install=$installs[$index-1]
    if($install.status -eq 'uninstalling'){
        Write-Host '该安装已有卸载正在执行。请使用原报告中的 Resume 命令，或等待正在执行的窗口完成。';return 4
    }
    $scopeChoice=Read-Host '1 保留作品（默认）；2 清理本次测试安装'
    $scope=if($scopeChoice -eq '2'){'TestClean'}elseif($scopeChoice -in @('','1')){'KeepWork'}else{throw 'INVALID_SCOPE_SELECTION'}
    $projects=@()
    if($scope -eq 'TestClean' -and $install.projects.Count){
        Write-Host '删除选中的测试项目将包括其中的源码、数据、Git历史和签名；请先保存需要的内容。未选项目保留。'
        for($n=0;$n -lt $install.projects.Count;$n++){Write-Host (($n+1).ToString()+'. '+$install.projects[$n].path)}
        $selection=Read-Host '输入要删除的测试项目编号，逗号分隔（留空全部保留）'
        if($selection){foreach($value in ($selection -split ',')){$num=0;if(-not [int]::TryParse($value.Trim(),[ref]$num) -or $num -lt 1 -or $num -gt $install.projects.Count){throw 'INVALID_PROJECT_SELECTION'};$projects+=@($install.projects[$num-1].projectId)}}
    }
    $output=Read-Host '卸载报告保存目录（留空使用用户级操作记录目录）'
    $removePreparation=$false
    if($scope -eq 'TestClean'){$removePreparation=(Read-Host '是否删除整个选定测试准备目录 A，包括其中全部资料、报告和配置？输入 DELETE，其余保留') -ceq 'DELETE'}
    $machines=@((Read-CourseLifecycle).resources|Where-Object {$_.kind -eq 'machine' -and $_.ownership -eq 'created' -and $_.references -contains $install.installationId -and $_.status -eq 'present'})
    $removeMachines=@()
    if($machines.Count){
        for($n=0;$n -lt $machines.Count;$n++){Write-Host (($n+1).ToString()+'. '+$machines[$n].locator)}
        $selection=Read-Host '删除虚拟机会清除其全部数据（包括手工放入的文件）。确认仅此环境使用后输入要删除的编号，逗号分隔；留空保留'
        if($selection){foreach($value in ($selection -split ',')){$num=0;if(-not [int]::TryParse($value.Trim(),[ref]$num) -or $num -lt 1 -or $num -gt $machines.Count){throw 'INVALID_MACHINE_SELECTION'};$removeMachines+=@($machines[$num-1].locator)}}
    }
    $plan=New-CourseUninstallPlan $install.installationId $scope $projects $output -RemovePreparationDirectory:$removePreparation -RemoveMachineNames $removeMachines
    Write-Host ([IO.File]::ReadAllText($plan.report))
    Write-Host ('计划：'+$plan.planPath)
    Write-Host ('若保留本地程序仍使用的凭证，请先取消并在助手中调整清单。共享凭证不会删除。')
    $answer=Read-Host '核对清单后输入 YES 执行，其余输入取消'
    if($answer -cne 'YES'){Write-Host '已取消，环境未删除。';return 0}
    & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Uninstall-Course.ps1') -Mode Apply -PlanPath $plan.planPath -PlanSha256 $plan.planSha256 | Out-Host
    $code=$LASTEXITCODE
    Write-Host ('结果：'+(Join-Path (Split-Path $plan.report -Parent) 'result.md'))
    Write-Host ('接续：powershell.exe -NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path (Get-CourseUninstallOperationDirectory $plan.operationId) 'runner\Uninstall-Course.ps1')+'" -Mode Resume -OperationId '+$plan.operationId)
    return $code
}
if($MyInvocation.InvocationName -ne '.'){
    $ErrorActionPreference='Stop'
    try{if($ListOnly){Start-CourseUninstall -List|ConvertTo-Json -Depth 4;exit 0};exit (Start-CourseUninstall -Preparation $PreparationDirectory)}catch{Write-Host '卸载未完成。请保留原计划和报告，由助手检查目标、冲突和权限后接续。';exit 1}
}
