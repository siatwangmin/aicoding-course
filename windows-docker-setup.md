# Windows Docker 安装：助手连续准备，学员只处理授权



助手负责定位资料、解压技能、主动提权、安装 WSL 和 Docker、启动程序、轮询引擎、拉取镜像及写验收记录。普通技术步骤连续执行，不等待用户逐项确认，也不要求学员复制命令或观察引擎状态。



## 第 1 步：确定资料位置与技能映射



把开始任务时的当前目录保存为 `workspace`。资料包根目录优先为当前目录；没有 `setup-guide.md` 时，按距离向上和向子目录查找最近的说明。`Install-CourseSkills.ps1` 的 `Find-CoursePackageRoot` 实现此规则，优先当前目录，不依赖固定盘符或某个用户的桌面。等距离找到多个完整包或找不到时报告实际搜索结果，不猜测。



在确定的根目录查找 `ai-coding-env-skill.zip`、`ai-coding-project-skill.zip` 及各自 `.sha256`。自动校验、解压并核对根部 SKILL 的名称：



| ZIP | 解压目标 |

| --- | --- |

| ai-coding-env-skill.zip | `<workspace>\.trae\skills\ai-coding-env\` |

| ai-coding-project-skill.zip | `<workspace>\.trae\skills\ai-coding-project\` |



`Install-CourseSkills.ps1 -WorkingDirectory <workspace>` 可以连续完成发现、校验和安装。只有外层资料 ZIP 时，助手先检查其真实条目包含 setup-guide.md 与两份技能 ZIP，再自动解压到当前目录的资料子目录，之后发现根目录；无需用户逐次解压或上传插件市场。



课前下载入口见[安装包下载与摆放说明](installation-downloads.md)。E-01 由助手取得课程资料和官方安装包；从 `.course-setup/materials.json` 定位资料，本地优先复用已有 `release`、`releases` 或 `software`，或助手从实际文件位置传入 `-InstallerDirectory`。也兼容资料目录内 `release` 和旧 `releases`。两个大文件不内嵌在小工具包里：



```text

<保存课程资料的本地文件夹>/

  ai-coding-toolkit.zip

  ai-coding-toolkit/

    setup-guide.md

    Install-CourseSkills.ps1

    ai-coding-env-skill.zip

    ai-coding-project-skill.zip

  software/

    wsl.3.0.1.0.x64.msi

    Docker Desktop Installer.exe

```



缺目录或所需文件时，脚本自动创建 `release` 并从清单指定的官方 URL 下载，不等待学员另发指令。WSL 固定 3.0.1.0 x64，摘要不一致就停止。Docker 官网下载可能更新：课程摘要匹配的本地包直接使用；其他 Docker 版本及所有新下载文件必须有效签名且主体匹配，实际来源、版本、SHA-256、签名保存到 workspace 的 `.docker-setup/installer-<种类>.json`。下载失败、签名不符或文件损坏时明确未完成并按实际原因继续处理官方地址，不改用软件合集，不循环重装。已有合格 WSL 保留，不额外装 Ubuntu。



## 第 2 步：运行脚本，助手主动提权



Prepare 和 Verify 都默认使用管理员 PowerShell。不得先非管理员运行失败后才重试提权。发起前只告知：**“请在接下来的 UAC 窗口点击‘是’，随后助手会继续准备或验证。”**



命令模板由助手填入真实脚本路径；包含空格的路径需在 ArgumentList 内保留引号：



```powershell

Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass',

  '-File','"<脚本路径>"','-Mode','<Prepare|Verify>',

  '-WorkingDirectory','"<当前工作目录>"' -Verb RunAs -Wait

```



实际运行示例完全使用环境变量和已发现路径，不固定任何用户或资料盘符：



```powershell

$workspace = (Get-Location).Path

$skill = Join-Path $workspace '.trae\skills\ai-coding-env'

$scriptPath = Join-Path $skill 'scripts\Setup-DockerDesktop.ps1'

# $packageRoot 由第 1 步发现；不可凭猜测赋值。

$installerDirectory = Join-Path (Split-Path $packageRoot -Parent) 'software'

foreach ($folder in @($installerDirectory, (Join-Path $packageRoot 'software'), (Join-Path (Split-Path $packageRoot -Parent) 'release'), (Join-Path $packageRoot 'release'), (Join-Path $packageRoot 'releases'))) {

    if ((Test-Path -LiteralPath (Join-Path $folder 'wsl.3.0.1.0.x64.msi')) -or

        (Test-Path -LiteralPath (Join-Path $folder 'Docker Desktop Installer.exe'))) {

        $installerDirectory = $folder

        break

    }

}

$setupMode = 'Prepare' # 验收时改为 Verify

$expectedUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value

$startedAt = Get-Date

$run = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -WorkingDirectory $workspace -ArgumentList @(

  '-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $scriptPath + '"'),

  '-Mode',$setupMode,'-WorkingDirectory',('"' + $workspace + '"'),

  '-InstallerDirectory',('"' + $installerDirectory + '"'),'-ExpectedUserSid',$expectedUserSid

)

# 助手核对 $run.ExitCode，并确认 report.json.CheckedAt 不早于 $startedAt。

# 取消/拒绝授权或本轮失败时，旧的 Ready 报告不能作为本次通过证据。

```



脚本对直接调用 Prepare/Verify 同样在检查前发起 UAC，传递原工作目录与原用户身份；助手应优先主动采用上面的 RunAs 入口。执行策略只针对本次进程，不改变永久设置。UAC 被取消、单位策略阻止或使用另一人的账号时报告实际授权障碍，不把另一 profile 当作学员环境。



## 第 3 步：自动检查并补齐条件



脚本读取 Windows/x64/内存、虚拟化/SLAT、虚拟机平台、待重启状态、现代 WSL、所需服务、Desktop、本机 Linux Server 与 Compose。开启虚拟机平台使用：



```powershell

Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All -NoRestart

```



WSL 与 Docker 安装由助手连续执行。Docker 安装固定 `--backend=wsl-2 --quiet`，不代替用户接受许可。不存在或没有执行的检查一律标为未确认。



**实际阻塞**：BIOS 未开启不能由普通 PowerShell 修改；脚本按 CIM 结果报告电脑型号及状态，不能让学员靠猜测选择设置。确实需要时，按对应型号的固件指引开启 Intel VT-x / AMD SVM；无权处理则交 IT。检测 Unknown 时不能认定已禁用或已启用。开启 Windows 功能或安装包明确要求重启时，先保存工作，完成 Windows 重启后助手在原工作目录继续；不能自动丢弃未保存内容或跳过重启。这些是系统条件，不是把普通自动化拆成多轮确认。



## 第 4 步：助手直接首次启动 Docker Desktop



助手先动态探测：



```powershell

$dd = Get-Command 'Docker Desktop.exe' -ErrorAction SilentlyContinue

if ($dd) { $dd = $dd.Source }

if (-not $dd) { $dd = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe' }

if (Test-Path -LiteralPath $dd) { Start-Process -FilePath $dd }

```



脚本另外探测用户安装目录和注册的自定义目录。只有全部真实探测失败时，才请用户指定真实安装路径，通过 `-DockerDesktopPath` 传入；不要求用户去开始菜单搜索或手动启动。



首次启动出现条款/许可协议页面时，**由用户本人阅读并决定是否接受**。助手只告知“请在程序窗口中阅读并决定，接受后助手自动验收”，不自动接受、不添加 `--accept-license`。普通启动和状态查询不再交给学员。



## 第 5 步：助手自动验证引擎



主动以管理员身份运行 `Setup-DockerDesktop.ps1 -Mode Verify`。脚本必要时启动 Desktop，自动轮询本机 Server/Compose，默认最多 120 秒（`-EngineTimeoutSeconds` 可设为 1–600 秒）。用户无需观察或报告左下角字样。



以工作目录 `.docker-setup/report.json` 的 **Decision=Ready** 为过关标志。Verify 可以独立给出 Ready，不要求先运行 Prepare。虚拟机平台的管理员确认保存在 FeatureConfirmation；非管理员兼容调用只复用同一电脑、同一用户、同一次启动的有效结果。重启、换用户、读取失败或未知状态不能沿用旧结果。默认 Prepare/Verify 仍主动提权。



检测始终连接明确的本机 named pipe，远程 context、只有 CLI 或 Windows containers 不算通过。超时保留本次实际错误和未就绪状态，由助手读取记录诊断；不能声称用户还没接受条款或引擎已经运行，除非有对应证据。用户处理条款后，助手继续 Verify，不要求用户自己重跑命令。



## 第 6 步：按 digest 验收工具箱并写记录



连续运行已安装 Skill 的 `scripts/Verify-Toolchain.ps1 -WorkingDirectory <workspace>`。它固定用 toolchain.json 中的 `image@sha256:...` 拉取，核对 RepoDigests 精确包含 `imageDigest`，以及 Architecture=amd64、Os=linux。containerd snapshotter 下 `.Id` 可能是清单摘要而非配置摘要；imageId 只作参考，不能作为通过或失败依据。



`Decision=Ready` 只是 Docker 阶段通过，助手必须立即执行以上脚本，不能结束任务或要求学员再说“继续”。读取实际退出码及本次生成的 `toolchain-verification.json`，按 SKILL 的完成条件核对时间、镜像、平台和容器检查。没有工具记录时先排查漏执行/脚本启动失败；VerifiedAt 为空时从 NotVerified 与 ToolchainCheck 定位实际失败阶段。未取得学员电脑记录时不能声称已确认是网络或下载失败。



镜像正确后，助手自动用断网临时容器检查工具，覆盖默认入口，只读挂载检查脚本，不挂载产品目录。离线导入可传 `-ImageArchive <真实tar路径> -SkipPull`；如果导入后没有 RepoDigests，明确未验证，不能拿标签或 `.Id` 替代。



工具验收记录固定为当前工作目录的 **`.\toolchain-verification.json`**，字段固定：



```text

VerifiedAt, Image, imageDigest, Architecture, Os,

DockerEndpoint, DockerServerVersion, ComposeVersion,

ToolchainCheck, NotVerified

```



Docker 报告、运行日志、WSL 安装日志、重启状态都在当前目录的 **`.docker-setup\`**，其中包括 report.json、setup-日期时间.log、wsl-install.log、restart.json。所有记录均由助手直接读取，**不得写入 AppData、工作目录外或任何固定的用户/机器绝对路径**。提权后沿用原 workspace；用户级技能目录只用于安装技能，不能拿来保存验收记录。



工具检查通过才报告“工具箱已准备，可以创建作品”。尚未构建作品网页/APK、尚未验证云账号或 AI 授权时，保留在 NotVerified。



学员可读的验收 checklist 写在当前工作目录的 **`.\environment-checklist.md`**，Docker 阶段和工具箱阶段自动更新，包含系统条件、WSL、Docker、镜像获取、RepoDigests、linux/amd64 平台和容器检查的实际证据。仅 Docker Ready 时总结仍为“未完成”；完整检查通过才为“已完成”，失败时覆盖旧成功结论。助手给学员打开或链接这份报告，学员不需要手工打勾。



## 模式与返回码



| 模式 | 行为 |

| --- | --- |

| Check | 可选的只读诊断，不作为默认安装前的失败尝试；不启动程序 |

| Prepare | 主动提权，补齐必要条件，自动安装、启动和验证 |

| Verify | 主动提权，独立检查，必要时自动启动并验证；不修改 Windows 功能 |



Setup 返回码：0 仅 Docker 阶段已验收，必须继续工具箱检查；3010 必须重启；2 真实条件阻塞/引擎未就绪；1 操作失败。`开始安装Docker.cmd` 仅保留为无助手时的备用入口，默认使用助手连续执行。



官方依据：[Docker Windows 安装](https://docs.docker.com/desktop/setup/install/windows-install/)、[Microsoft WSL MSI](https://learn.microsoft.com/en-us/windows/wsl/install#offline-install)、[Docker WSL 2](https://docs.docker.com/desktop/features/wsl/)、[containerd 的 inspect 实现](https://github.com/moby/moby/blob/master/daemon/containerd/image_inspect.go)。基础系统门槛通过不代表厂商仍支持该 Windows 版本；ARM 或过期系统依据实际条件另行验证。

