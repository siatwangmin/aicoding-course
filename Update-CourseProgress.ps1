#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ProjectDirectory,
 [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,47}$')][string]$Stage,
 [ValidateSet('running','waiting','blocked','verified','learner-pending')][string]$Status='running',
 [switch]$NewRun,[string]$Objective,[string]$SpecPath,[string]$EvidencePath,[string]$NextAction,
 [ValidateSet('none','download','migration','deployment','model','learner','diagnosis')][string]$WaitKind='none')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Course-Context.ps1')
. (Join-Path $PSScriptRoot 'Course-ProjectRoot.ps1')
$root=Resolve-CourseProjectRoot $ProjectDirectory
$p=Read-CourseJson (Join-Path $root '.ai-coding\project.json')
$progress=Join-Path $root '.ai-coding\progress.json'
$old=if(Test-Path -LiteralPath $progress){Read-CourseJson $progress}else{$null}
function Resolve-ProgressPath([string]$Relative){
 $path=[IO.Path]::GetFullPath((Join-Path $root $Relative));Assert-CoursePlainPath $path
 if(-not $path.StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'PROGRESS_PATH_ESCAPES_PROJECT'}
 return $path
}
if(-not $SpecPath){$SpecPath='docs/specs/'+$Stage+'.md'}
$spec=Resolve-ProgressPath $SpecPath
if(-not(Test-Path -LiteralPath $spec)){
 if(-not $Objective){throw 'STAGE_OBJECTIVE_REQUIRED'}
 [void](New-Item -ItemType Directory -Path (Split-Path $spec -Parent) -Force)
 [IO.File]::WriteAllText($spec,"# $Stage 实施方案`n`n目标：$(Protect-CourseOutput $Objective)`n`n准备来源：$($p.preparationId)；源码：$($p.sourceDirectory)；设计：$($p.designDirectory)。`n`n实施前由助手按 docs/specs/_template.md 补齐本轮具体步骤、接口/身份、失败恢复和验收依据。此文件初建不代表方案已填写或功能已完成。`n",[Text.UTF8Encoding]::new($false))
}
$evidence=$null
if($EvidencePath){$evidence=Resolve-ProgressPath $EvidencePath;if(-not(Test-Path -LiteralPath $evidence -PathType Leaf)){throw 'PROGRESS_EVIDENCE_MISSING'}}
if($Status -eq 'verified' -and -not $evidence){throw 'ACTUAL_STAGE_EVIDENCE_REQUIRED'}
$same=$old -and $old.stage -eq $Stage -and -not $NewRun
$now=(Get-Date).ToUniversalTime().ToString('o')
$value=@{schemaVersion=2;operationId=$(if($same){$old.operationId}else{[guid]::NewGuid().ToString('N')});stage=$Stage;status=$Status;startedAt=$(if($same){$old.startedAt}else{$now});checkedAt=$now;spec=$SpecPath;waitKind=$WaitKind;nextAction=(Protect-CourseOutput $NextAction);evidence=$EvidencePath;learnerTrial='separate'}
if($evidence){$value.evidenceSha256=(Get-FileHash -LiteralPath $evidence).Hash.ToLowerInvariant()}
if($Status -in @('verified','learner-pending')){$value.finishedAt=$now}
Write-CourseJson $progress $value
$current=Join-Path $root 'docs\progress\current.md';Assert-CoursePlainPath $current
[void](New-Item -ItemType Directory -Path (Split-Path $current -Parent) -Force)
$text=if(Test-Path -LiteralPath $current){[IO.File]::ReadAllText($current)}else{'# 当前进度'}
$block="<!-- ai-coding:progress:start -->`n阶段：$Stage；技术状态：$Status；记录：$now。`n方案：$SpecPath；证据：$EvidencePath。`n本人试用单列。下一步：$($value.nextAction)`n<!-- ai-coding:progress:end -->"
if($text.Contains('<!-- ai-coding:progress:start -->')){$text=[regex]::Replace($text,'(?s)<!-- ai-coding:progress:start -->.*?<!-- ai-coding:progress:end -->',[Text.RegularExpressions.MatchEvaluator]{param($m)$block})}else{$text+="`n`n$block`n"}
[IO.File]::WriteAllText($current,$text,[Text.UTF8Encoding]::new($false))
Write-CourseEvent $root @{operationId=$value.operationId;stage=$Stage;action='Progress';status=$Status;startedAt=$value.startedAt;finishedAt=$now;waitKind=$WaitKind;nextAction=$value.nextAction;evidence=$EvidencePath}
[pscustomobject]$value|ConvertTo-Json
