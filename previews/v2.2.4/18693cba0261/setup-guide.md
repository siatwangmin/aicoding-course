# 通用准备说明｜供 Trae 读取

本说明是助手执行入口；学员在课程网站阅读手册。固定版本与候选参数只用于 Get-CourseMaterials.ps1，不附加到存储、运行或项目脚本。

学员把课前网页的简短请求发给 Trae 即可。助手负责下载、安装、配置、检查和记录；本人只确认保存位置、需求设计、必要身份/条款/费用/重启及真实试用。正常技术步骤连续完成，必要本人动作一次一个，完成后接续。

## 当前路线与范围

新准备统一 Windows 11 x64 / WSL2 + Podman CLI + 独立 Docker Compose EXE，容器由 Podman 运行。无需 Docker Desktop、Podman Desktop 或编排用 Python。固定工具镜像由准备记录提供，后续 Web、测试、APK 构建均使用同一镜像，不在宿主安装 Node/JDK/Android 工具链。

已有作品以 .ai-coding/project.json 为准；已有准备先读原始报告和 .course-setup/materials.json、container-runtime.json。没有 runtime 的旧报告按原 Docker 兼容处理，不因课程新默认静默换引擎。Docker 旧工程按用户级 ai-coding-env/references/windows-docker-setup.md 恢复；不运行 Docker Prepare 来补 Podman 缺项。

本课程课前连续完成工具→CloudBase→GitHub→AI账号→汇总，不能工具就绪即停止；已有结果复用。明确只请求工具排障或缩小学习范围时保持该范围。本阶段不创建业务工程、项目专用数据库表、函数或 APK。

## E-01：从零取得课程资料

1. 保持 Trae 当前文件夹为 A。若无课程资料，下载并读取 `https://siatwangmin.github.io/aicoding-course/previews/v2.2.4/18693cba0261/Get-CourseMaterials.ps1`，保存 A/.course-setup/Get-CourseMaterials.ps1，用 Windows PowerShell 执行 `-WorkingDirectory <A> -CourseVersion 2.2.4 -PreviewId 18693cba0261 -ContainerRuntime podman -PackageProfile generic`。默认取得七项通用技能执行包；已明确选择案例可传 -PackageProfile knowstar；已有同版本通用准备时只增量取得案例Skill。该入口从 VERSION.json 选择固定版本资料与 SHA256，先校验再安全解压。候选版本使用其明确的 distributionId，不能把候选当正式发布。
2. 从 A/.course-setup/materials.json 定位实际 PackageRoot、SetupGuide 和 SkillsDirectory。按 course-contract/skills.json 安装七项通用技能及明确选定案例；同名用户副本先备份再更新，项目同名副本先备份移出发现目录，不复制 Skill 到 B。
3. 已有完整本地包时，运行其 Install-CourseSkills.ps1 -WorkingDirectory <A> -PackageRoot <实际目录>，脚本保护旧文件并核对 ZIP 摘要和根部 SKILL.md 名称；缺文件或多个等距来源时报告真实缺项，不猜用户名或盘符。
4. 下载与用户级安装完成后，立即调用已安装 ai-coding-env 的 references/preparation-workflow.md，继续准备、工具验收与服务阶段。不得下载 GitHub Release 完整软件合集，不要求学员自行解压、搬文件或改 PATH。

## 工具准备与恢复

1. 运行用户级 ai-coding-env/scripts/Prepare-CourseStorage.ps1 -WorkingDirectory <A> -ContainerRuntime podman，检查 D:/AI-Practice 的空间和目录计划。A 留原始报告，用户级 .ai-coding 存发现索引/工具引用/加密凭证，D 盘存大型数据，B 存项目事实。计划不等于实际位置通过。
2. 读 ai-coding-env/references/windows-podman-setup.md；运行 scripts/Setup-Podman.ps1 -Mode Prepare -WorkingDirectory <A>，随后 -Mode Verify。复用已有 Podman、WSL 和 machine，不降级、不重建。缺 WSL/虚拟化时按真实系统检测处理；需要提权时保持本人 SID 和 A，出现 UAC/必要重启给一个本人动作，禁止自动重启。
3. Podman MSI 与独立 Compose EXE 从 assets/podman-installers.json 的官方固定来源取得并核 SHA256；MSI 另核发布者签名。Compose 安装到 D:/AI-Practice/programs/compose/docker-compose.exe，登记用户级 tool-paths.json；不得借用 Docker Desktop 安装目录。旧 Setup-PodmanDesktop.ps1 仅兼容转交，不安装或启动 GUI。
4. 共同 Course-Native.ps1/Course-Runtime.ps1 将 PODMAN_COMPOSE_PROVIDER 仅注入本次子进程，绑定受管 EXE、项目 connection 及目标 API；隔离旧 DOCKER_HOST/CONTEXT/TLS 变量。不得修改全局默认连接或抢占 docker_engine 管道。Podman info、Compose version、真实 API 与容器操作分别验证。
5. Prepare/Verify 后立即运行 Verify-Toolchain.ps1 -ContainerRuntime podman -WorkingDirectory <A>。在线核精确 RepoDigest；官方仓库不可达且存在批准离线镜像时，用 -ImageArchive <明确来源> -SkipPull，重新核归档 SHA256、镜像配置 ID 与 linux/amd64。不能拿标签或旧报告代替身份。
6. 固定镜像内执行断网 check-environment.sh，要求退出码 0 和 TOOLCHAIN_READY；保存本次 toolchain-verification.json、environment-checklist.md 与用户级准备索引。Verify 失败保留 VerifiedAt=null、实际错误和续接点，不沿用旧成功。
7. 用 Prepare-CourseStorage.ps1 -Verify 记录程序/Compose、WSL VHD 与实际大型数据位置；旧 C 盘资源保持 pending，不为满足 D 盘要求重建或自动搬动正在使用的 VHD。本人已选 D 盘不等于技术验证通过。

Compose 客户端不需要 Python、PyYAML 或 python-dotenv。课程文档/ZIP 生成用的已有管理运行时与学员项目工具链分开。网络失败先分层探测宿主、machine、容器和服务代理，不关闭 TLS、防火墙或改 host 网络来绕过失败。

## 服务接续和最终检查

工具检查后继续调用 ai-coding-cloudbase、ai-coding-github、ai-coding-siliconflow。复用有效身份、授权和服务引用；登录/实名/验证码/费用由本人在官网处理。E-08 由本人登录、查看当前优惠和费用并决定充值；只记录账号准备，不要求提前保存 Key 或调用模型。V4 程序设置就绪后，由本人在“设置 → AI 服务”填写自己的 Key 和模型；Key仅经受保护接口保存至服务端，不写聊天、前端产物、Git、镜像或 APK。旧用户级加密存储只作明确来源的兼容恢复。不扫描 HOME 找秘密；只按明确旧来源安全导入，验证加密存储前保留来源。

使用 Invoke-CoursePreparation.ps1 -WorkingDirectory <A> -Action Status/Record 保存工具→CloudBase→GitHub→AI→汇总的进度。云端管理授权、PostgreSQL 能力、GitHub 身份/邮箱、AI 账号与费用准备分别留证；V4 的模型调用按已授权范围另行验收；配置成功不等于真实授权/调用成功。

E-05 按完整 SkillNames 执行 Install-CourseSkills.ps1 -VerifyOnly，复查根部名称、用户目录及项目同名副本；在真实 Trae 新会话观察加载，安装位置正确不等于实际加载。报告本次工具、存储、技能、平台和账号准备各自结果；缺项不标整体完成。给学员可打开的清单和当前一个必要动作，不让学员逐项审日志或手工勾助手结果。

## 新目录 B 的使用

P-01由ai-coding-project完成发现准备、空B创建/已有工程恢复、本地运行/构建、规范与起始页/热更新/规则检查。先建立本地底座；本项目当前已确认需要GitHub/CloudBase/AI等能力时，可在初始化入口传 -Capabilities 和 -CapabilityReason，按Enable-ProjectCapability接续对应Skill，助手在同一任务继续实际接入。需求尚未明确时仅local，不创建未来资源；旧绑定保留，未启用项不作为初始化缺项。A 暂不可用时只用用户索引允许的脱敏摘要；不创建第二套凭证或工具镜像。后续开发由 ai-coding-development，Android 由 ai-coding-android/Build-Android.ps1 执行。Web、服务、APK、安装、启动、同步和本人试用分别留证；本人未试不得记通过。

本地候选资料不表示线上已发布；新版本仅由 teacher/build-distribution.py 生成页面、章节、Skill 副本和 ZIP，历史发布不可覆盖。
## 升级后的课程环境卸载

保留作品时，在 Trae 中说“调用 ai-coding-env 卸载课程环境，保留我的作品”；也可双击资料包根目录的 **卸载课程环境.cmd**。助手或引导先列出真实清单，再按已明确范围执行。

测试后可选择 TestClean 并指定测试项目；删除整个准备目录 A 必须单独选择。旧版缺少归属证据、共享资源或用户修改会保留并报告。失败后使用报告中的独立入口接续，不手动清空整个 D:/AI-Practice、用户配置目录或所有容器。

云端资源、手机应用和系统组件保留；重新安装从课程下载入口重新解析已发布版本与摘要。技术细节见用户级 ai-coding-env/references/uninstall.md，学员说明见在线求助页。此功能为候选，整机软件卸载及 Trae 实际加载/移除需按真实验证结果记录。

