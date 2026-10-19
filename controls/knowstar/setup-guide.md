# 通用准备说明｜供 Trae 读取

本说明是稳定的助手执行入口；使用者复制的地址不随版本变化。首次安装或主动升级未指定版本时取最新已发布版本；恢复已有任务沿 materials.json / pending-update.json 中的原版本。本人明确指定版本时严格使用该版本，找不到不改成 latest。发布统一使用正式 release，历史候选仍按其原始标识恢复。固定版本参数只用于资料入口，不附加到存储、运行或项目脚本。

使用者把准备网页的简短请求发给 Trae 即可。助手负责下载、安装、配置、检查和记录；本人只确认保存位置、需求设计、必要身份/条款/费用/重启及真实试用。正常技术步骤连续完成，必要本人动作一次一个，完成后接续。

仅要求更新资料或技能时，直接执行本文“独立更新资料和技能”，保持该范围，不进入下面的全新环境与账号准备。

## 当前路线与范围

当前准备网页按顺序显示 E-01安装Trae、E-02启动准备、E-03 GitHub、E-04硅基流动、E-05 CloudBase、E-06汇总。使用者报告网页编号时按当前版本步骤数据的displayId定位；本文历史编号和内部检查使用稳定id，映射由环境Skill的preparation-workflow维护，不让使用者自行转换。

新准备统一 Windows 11 x64 / WSL2 + Podman CLI + 独立 Docker Compose EXE，容器由 Podman 运行。无需 Docker Desktop、Podman Desktop 或编排用 Python。固定工具镜像由准备记录提供，后续 Web、测试、APK 构建均使用同一镜像，不在宿主安装 Node/JDK/Android 工具链。

已有作品以 .ai-coding/project.json 为准；已有准备先读原始报告和 .course-setup/materials.json、container-runtime.json。没有 runtime 的旧报告按原 Docker 兼容处理，不因新的默认设置静默换引擎。Docker 旧工程按用户级 ai-coding-env/references/windows-docker-setup.md 恢复；不运行 Docker Prepare 来补 Podman 缺项。

本流程环境准备分两路并行：后台自动下载、安装和验证工具，前台依次完成 GitHub→硅基流动→CloudBase 账号及必要授权，最后汇总两路结果。不能工具就绪即停止，也不等待工具就绪才开始注册；已有结果复用。明确只请求工具排障或缩小任务范围时保持该范围。本阶段不创建业务工程、项目专用数据库表、函数或 APK。

## E-01：从零取得资料

1. 保持 Trae 当前文件夹为 A。若无资料，下载并读取 `https://siatwangmin.github.io/aicoding-course/Get-CourseMaterials.ps1`，保存 A/.course-setup/Get-CourseMaterials.ps1，用 Windows PowerShell 执行 `-WorkingDirectory <A> -ContainerRuntime podman -PackageProfile generic`。默认取得七项通用技能执行包；已明确选择案例可传 -PackageProfile knowstar；已有同版本通用准备时只增量取得案例Skill。该入口从 VERSION.json 选择固定版本资料与 SHA256，先校验再安全解压。历史版本按索引中的原始发布标识恢复。
2. 从 A/.course-setup/materials.json 定位实际 PackageRoot、SetupGuide 和 SkillsDirectory。按 course-contract/skills.json 安装七项通用技能及明确选定案例；同名用户副本先备份再更新，项目同名副本先备份移出发现目录，不复制 Skill 到 B。
3. 已有完整本地包时，运行其 Install-CourseSkills.ps1 -WorkingDirectory <A> -PackageRoot <实际目录>，脚本保护旧文件并核对 ZIP 摘要和根部 SKILL.md 名称；缺文件或多个等距来源时报告真实缺项，不猜用户名或盘符。
4. 下载与用户级安装完成后，立即调用已安装 ai-coding-env 的 references/preparation-workflow.md，立即启动后台工具准备，同时在前台开始 GitHub 账号引导。不得下载 GitHub Release 完整软件合集，不要求使用者自行解压、搬文件或改 PATH。

## 工具准备与恢复

WSL、Podman CLI 和独立 Docker Compose 的固定安装包按 GHFast → gh-proxy.com → SourceForge → 原始 GitHub 顺序下载。SourceForge 使用 `https://downloads.sourceforge.net/project/` 开头的文件直链。连接、摘要或签名验证失败即尝试下一来源，各来源使用同一固定 SHA256；WSL 和 Podman 另核发布者签名。已验证本地包继续复用。

1. 运行用户级 ai-coding-env/scripts/Prepare-CourseStorage.ps1 -WorkingDirectory <A> -ContainerRuntime podman，检查环境根目录的空间和目录计划。新安装优先非系统盘：有 D 盘用 D:/ENV，无 D 盘则选其他本地 NTFS 非系统盘的 ENV；只有 C 盘时使用 C:/ENV，与手册中的准备文件夹一致；已有项目、A 的存储记录或用户级工具绑定按原 storageRoot 复用（包括旧 D:/AI-Practice），不因资料升级迁移、重装或重建。本人明确指定其他位置时使用该位置。A 留原始报告，用户级 .ai-coding 存发现索引/工具引用/加密凭证，根目录内 downloads/installers、programs、runtime-data 分别保存安装包、工具和运行时数据，B 存项目事实。计划不等于实际位置通过。
2. 读 ai-coding-env/references/windows-podman-setup.md；调用 scripts/Start-CourseToolPreparation.ps1 -WorkingDirectory <A> -Action Start -ContainerRuntime podman，立即返回前台引导账号注册。后台自动执行下载、安装、引擎验证、存储核验与工具链镜像检查；不等待整个 PowerShell 任务结束。用同一入口 -Action Status 检查状态和 attention；运行中重复 Start 复用原任务，失败/重启后从原 A 接续。复用已有 Podman、WSL 和 machine，不降级、不重建。缺 WSL/虚拟化时按真实系统检测处理；需要提权时保持本人 SID 和 A，出现 UAC 提示时立即提醒本人；必要重启先保存账号步骤与工作，由本人决定何时重启，禁止自动重启。
3. Podman MSI 与独立 Compose EXE 从 assets/podman-installers.json 的官方固定来源取得并核 SHA256；MSI 另核发布者签名。Compose 安装到已确认 storageRoot 下的 programs/compose/docker-compose.exe（例如 D:/ENV/programs/compose/docker-compose.exe；只有 C 盘时为 C:/ENV/programs/compose/docker-compose.exe），登记用户级 tool-paths.json；不得借用 Docker Desktop 安装目录。旧 Setup-PodmanDesktop.ps1 仅兼容转交，不安装或启动 GUI。
4. 共同 Course-Native.ps1/Course-Runtime.ps1 将 PODMAN_COMPOSE_PROVIDER 仅注入本次子进程，绑定受管 EXE、项目 connection 及目标 API；隔离旧 DOCKER_HOST/CONTEXT/TLS 变量。不得修改全局默认连接或抢占 docker_engine 管道。Podman info、Compose version、真实 API 与容器操作分别验证。
5. 后台在 Prepare/Verify 和实际存储核验后自动运行 Verify-Toolchain.ps1 -ContainerRuntime podman -WorkingDirectory <A>。在线核精确 RepoDigest；官方仓库不可达且存在批准离线镜像时，用 -ImageArchive <明确来源> -SkipPull，重新核归档 SHA256、镜像配置 ID 与 linux/amd64。不能拿标签或旧报告代替身份。
6. 固定镜像内执行断网 check-environment.sh，要求退出码 0 和 TOOLCHAIN_READY；保存本次 toolchain-verification.json、environment-checklist.md 与用户级准备索引。Verify 失败保留 VerifiedAt=null、实际错误和续接点，不沿用旧成功。
7. 用 Prepare-CourseStorage.ps1 -Verify 记录程序/Compose、WSL VHD、缓存与实际大型数据位置，按已确认 storageRoot 核验；只有 C 盘时 C:/ENV 可正常通过。未核实的位置保持 pending，不为更换默认目录重建或自动搬动正在使用的 VHD。选定目录不等于技术验证通过。

Compose 客户端不需要 Python、PyYAML 或 python-dotenv。维护文档/ZIP 生成用的已有管理运行时与使用者项目工具链分开。网络失败先分层探测宿主、machine、容器和服务代理，不关闭 TLS、防火墙或改 host 网络来绕过失败。

## 服务接续和最终检查

后台启动后立即在前台依次调用 ai-coding-github、ai-coding-siliconflow、ai-coding-cloudbase。不以工具下载、安装或镜像验收完成作为账号准备前置条件；账号步骤之间及等待本人操作时检查后台 Status，出现 attention 只提示当前必要动作。软件后台失败不清空或重做已完成账号；账号注册等待也不停止后台工具任务。复用有效身份、授权和服务引用；登录/实名/验证码/费用由本人在官网处理。E-08 由本人登录、查看当前优惠和费用并决定充值；只记录账号准备，不要求提前保存 Key 或调用模型。V4 程序设置就绪后，由本人在“设置 → AI 服务”填写自己的 Key 和模型；Key仅经受保护接口保存至服务端，不写聊天、前端产物、Git、镜像或 APK。旧用户级加密存储只作明确来源的兼容恢复。不扫描 HOME 找秘密；只按明确旧来源安全导入，验证加密存储前保留来源。

使用 Invoke-CoursePreparation.ps1 -WorkingDirectory <A> -Action Status/Record 保存前台 GitHub→AI（硅基流动）→CloudBase 与后台工具两路进度。nextStage 优先返回未完成账号；backgroundTools 单独给出工具状态和人工提醒。工具未就绪时 Register-CourseServices.ps1 暂存允许的账号摘要，不阻止注册；后台 Verified 后由前台调用 Save-PreparationEvidence.ps1 -WorkingDirectory <A> -Stage tools 登记实际证据，再调用 Register-CourseServices.ps1 登记账号结果，避免两路同时写 preparation-progress.json；所有账号与工具都通过才进入 summary。云端管理授权、PostgreSQL 能力、GitHub 身份/邮箱、AI 账号与费用准备分别留证；V4 的模型调用按已授权范围另行验收；配置成功不等于真实授权/调用成功。

E-05 按完整 SkillNames 执行 Install-CourseSkills.ps1 -VerifyOnly，复查根部名称、用户目录及项目同名副本；在真实 Trae 新会话观察加载，安装位置正确不等于实际加载。报告本次工具、存储、技能、平台和账号准备各自结果；缺项不标整体完成。给使用者可打开的清单和当前一个必要动作，不让使用者逐项审日志或手工勾助手结果。

## 新目录 B 的使用

P-01由ai-coding-project完成发现准备、空B创建/已有工程恢复、本地运行/构建、规范与起始页/热更新/规则检查。先建立本地底座；本项目当前已确认需要GitHub/CloudBase/AI等能力时，可在初始化入口传 -Capabilities 和 -CapabilityReason，按Enable-ProjectCapability接续对应Skill，助手在同一任务继续实际接入。需求尚未明确时仅local，不创建未来资源；旧绑定保留，未启用项不作为初始化缺项。A 暂不可用时只用用户索引允许的脱敏摘要；不创建第二套凭证或工具镜像。后续开发由 ai-coding-development，Android 由 ai-coding-android/Build-Android.ps1 执行。Web、服务、APK、安装、启动、同步和本人试用分别留证；本人未试不得记通过。

本地生成不表示线上已发布；新版本仅由 teacher/build-distribution.py 生成页面、章节、Skill 副本和 ZIP，历史发布不可覆盖。
## 升级后的环境卸载

保留作品时，在 Trae 中说“调用 ai-coding-env 卸载环境，保留我的作品”；也可双击资料包根目录的 **卸载环境.cmd**。助手或引导先列出真实清单，再按已明确范围执行。

测试后可选择 TestClean 并指定测试项目；删除整个准备目录 A 必须单独选择。旧版缺少归属证据、共享资源或用户修改会保留并报告。失败后使用报告中的独立入口接续，不手动清空整个 D:/ENV、用户配置目录或所有容器。

云端资源、手机应用和系统组件保留；重新安装从资料下载入口重新解析已发布版本与摘要。技术细节见用户级 ai-coding-env/references/uninstall.md，使用者说明见在线求助页。整机软件卸载及 Trae 实际加载/移除需按真实验证结果记录。


## 独立更新资料和技能

本人说更新资料或技能时，先读原 A/.course-setup/materials.json，并按其 PackageRoot / SkillsDirectory 定位明确来源。使用当前资料 ai-coding-env/scripts/Update-CourseMaterials.ps1 -WorkingDirectory <A> -Action Check 查看兼容结果，再以 -Action Apply 连续执行；指定版本加 -CourseVersion，未指定时由 release-index.json 选最新并锁定清单。旧包尚无此脚本时，从稳定网站取得 Get-CourseMaterials.ps1，以 Resolve-CourseRelease 验清单摘要，再按清单取得并校验最新 controls/generic 中的更新入口与依赖；不能直接用旧安装器覆盖新共享 Skill。

默认 Apply 更新完整小包和变化技能；仅取得 ZIP 用 -Action Download，报告已下载待应用；只更新 Skill 用 -Action Skills，可选 -SkillNames 逗号分隔，自动展开依赖。下载校验、用户级安装、Trae 实际加载分别记录。安装前和验收时说明实际资料版本与发布标识。重启/进程中断先 -Action Recover 恢复，随后原命令接续。

升级不运行 Prepare、不下载环境安装包、不拉镜像、不触发 UAC、不注册账号、不改模型/Key/项目源码。兼容性读取原验证报告与实际已登记绑定；未知或不兼容保留当前可用状态并说明缺项。新环境或环境升级另外走已确认准备路线，不以资料升级结果代替完整准备验收。

共享技能有全局锁、文件摘要和事务备份。检测到本地修改先保留和定位；执行协议、资料内摘要、依赖及已登记项目须匹配，失败整组回滚。更新完成只报告实际文件结果，Trae 加载未观察到时留待核对；通知必要的刷新或新会话动作，不让使用者手工覆盖目录。
