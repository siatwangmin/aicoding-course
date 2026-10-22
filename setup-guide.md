# 环境准备的稳定入口

本地址不随版本变化。当前正式版本为 **v2.5.4**。首次准备和主动更新通过网站的 `VERSION.json`、`release-index.json` 选择正式版本，锁定固定版本清单并核验 SHA-256；不要让助手自行寻找下载包。本人指定版本时严格使用该版本，找不到或摘要不符时停止并说明原因。

## 首次准备

保持 Trae 当前文件夹为准备目录 A。A 尚无 `.course-setup/materials.json` 时，在 Windows PowerShell 5.1 执行以下命令（不是 PowerShell 7）。不要把 `<A>` 当作实际路径；以下直接使用当前目录。

```powershell
$ErrorActionPreference = 'Stop'
$workspace = (Get-Location).Path
$records = Join-Path $workspace '.course-setup'
New-Item -ItemType Directory -Path $records -Force | Out-Null
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$bootstrap = Join-Path $records 'Get-CourseMaterials.ps1'
Invoke-WebRequest -Uri 'https://siatwangmin.github.io/aicoding-course/Get-CourseMaterials.ps1' -OutFile $bootstrap -UseBasicParsing
& $bootstrap -WorkingDirectory $workspace -PackageProfile generic -ContainerRuntime podman -SkipInstallers
if (-not $?) { throw 'Preparation package installation failed.' }
```

该命令先获取并核验固定版本执行包，再安装所需作用域的技能。`-SkipInstallers` 只跳过此入口中的工具安装包预下载；后续仍须按下方工作流后台准备并验证工具、存储和镜像。新环境默认 Podman；已有环境保留原引擎与存储位置。

## 已有准备目录与主动更新

先读原 A 的 `.course-setup/materials.json`。仅恢复未完成任务时沿记录的原版本继续；本人要求“最新版准备”或“更新到 v2.5.4”时，必须使用更新入口，不能把旧版恢复成功当作新版准备成功。保留原工具、存储、账号绑定和作品。

在原 A 的 Windows PowerShell 5.1 执行以下命令。它获取并校验目标版本的更新执行包，调用新版更新器，避免旧更新器沿用旧的技能安装作用域。默认从索引取得最新正式版本；本人指定版本时把 `$targetVersion` 改为指定值。

```powershell
$ErrorActionPreference = 'Stop'
$workspace = (Get-Location).Path
$records = Join-Path $workspace '.course-setup'
if (-not (Test-Path -LiteralPath (Join-Path $records 'materials.json'))) { throw 'Use the first preparation entry.' }
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$bootstrap = Join-Path $records 'Get-CourseMaterials.ps1'
Invoke-WebRequest -Uri 'https://siatwangmin.github.io/aicoding-course/Get-CourseMaterials.ps1' -OutFile $bootstrap -UseBasicParsing
. $bootstrap
$targetVersion = ''
$selection = Resolve-CourseRelease -Workspace $workspace -Version $targetVersion
if ($selection.entry.status -ne 'release' -or $selection.entry.legacy) { throw 'A current formal release is required.' }
$targetVersion = $selection.entry.version
$prior = Get-Content -LiteralPath (Join-Path $records 'materials.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$profile = if ($prior.SkillNames -contains 'knowstar-course') { 'knowstar' } else { 'generic' }
$package = $selection.manifest.profiles.$profile
$archive = Join-Path $records ('update-entry-v' + $targetVersion + '-' + $profile + '.zip')
Receive-CourseFile ($selection.entry.baseUrl + '/' + $package.archive) $archive
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -cne $package.sha256) { throw 'Update archive checksum mismatch.' }
$entryRoot = Join-Path $records ('update-entry-' + [guid]::NewGuid().ToString('N'))
Expand-CourseMaterials -Archive $archive -Staging $entryRoot
if ((Get-FileHash -LiteralPath (Join-Path $entryRoot 'bundle-manifest.json') -Algorithm SHA256).Hash.ToLowerInvariant() -cne $package.bundleManifestSha256) { throw 'Update bundle checksum mismatch.' }
$updater = Join-Path $entryRoot 'Update-CourseMaterials.ps1'
& $updater -WorkingDirectory $workspace -CourseVersion $targetVersion -PackageProfile $profile -Action Check
if (-not $?) { throw 'Update compatibility check failed.' }
& $updater -WorkingDirectory $workspace -CourseVersion $targetVersion -PackageProfile $profile -Action Apply
if (-not $?) { throw 'Update application failed.' }
```

若存在未完成的更新事务，先按该更新器的 `-Action Recover` 恢复，再接续上述命令；兼容检查失败时保留原状态并报告具体原因。不要清空记录或重新安装环境来规避检查。

## 版本核验与继续执行

开始时说明目标版本及固定清单地址；下载后核对清单、ZIP SHA-256、包内 `VERSION.json` 与目标版本一致。安装或更新后再次读取 A 的 `.course-setup/materials.json`，确认 `CourseVersion`、`PackageRoot` 和实际技能文件属于同一目标版本。主动更新本次应为 v2.5.4；若本人另指定版本或发布索引已有更新，则以锁定目标为准。未达到目标时明确报告失败及当前版本，不能改用旧包并称为成功。

资料安装、Trae 实际加载、工具验证、平台授权分别验收；文件已更新不等于整套准备已完成。继续执行下面的环境准备与项目初始化工作流。

---

# 环境准备与项目初始化

在准备目录 A 让助手取得当前发布小包，校验版本与摘要，调用 Install-CourseSkills.ps1 -WorkingDirectory <A> -PackageRoot <真实目录>。该入口在用户级安装 ai-coding-project/github/cloudbase/android，A/.trae/skills 仅保留 env。公共执行包位于技能发现目录之外，案例不进入默认链。

读取A内env的references/preparation-workflow.md；后台Start-CourseToolPreparation下载安装并验证工具、实际存储和固定镜像，前台依次接续GitHub与CloudBase。已有有效状态直接复用，需要本人授权/费用/重启时一次给一个动作。环境准备不要求模型供应商账号、Key或调用。工具、平台、实际Trae加载和汇总分别验证。

新环境使用Podman CLI与独立Docker Compose，优先非系统盘ENV，只有系统盘时使用C:/ENV；已有准备和作品保持原storageRoot、引擎、镜像与连接。宿主准备 Git for Windows（已有复用，缺失时优先 npmmirror、华为云镜像，固定摘要校验）及 Node.js LTS、npm/npx供官方CloudBase技能、本地MCP与CLI使用，安装包优先国内npmmirror、南大备用，npm默认国内registry；项目构建在同一准备镜像中执行。

任意新作品目录 B 调用用户级 ai-coding-project。先检查全部拟生成文件的冲突，再原样复制标准 app、绑定准备环境，在容器中构建运行。默认端口 5187，占用时自动尝试其他端口，并核验、输出完整访问地址。初始化不询问三项平台选择，不复制平台或案例技能；后续按当前需求直接调用用户级平台技能，资源与授权仍按作品绑定。Android 配置在首次实际需要时生成。

项目生成AGENTS、工程工作流、Spec模板和进度后，助手按本项目规则直接开发。本地功能不依赖独立开发技能；GitHub承担静态发布，CloudBase承担云端及AI后端，Android承担手机交付。当前请求的能力需要实际接续验证，不能把已装技能或本地构建当作平台已接入。

运行时解析 B 的公共执行包绑定。Initialize 只新建；Resume 接续；Verify 检查；Upgrade 只在明确要求时更新受管内容；Connect 连接明确准备环境或服务。复制失败按事务回滚，构建失败保留工程并接续。A 移走后可复用登记摘要与完整执行包，不扫描用户目录找秘密；旧工程保留源码、设计、稳定标识和有效资源绑定。

卸载在原A调用env或双击卸载环境.cmd，先列真实清单，按已明确范围执行，保留作品与云端资源。升级通过原资料Update-CourseMaterials.ps1，在校验新包后更新相应作用域；历史发布不可覆盖。本人试用、真实发布、模型调用与自动检查分别记录。
