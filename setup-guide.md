# 通用准备说明｜供 Trae 读取

学员不用阅读本文件；把课前网页的提示发给 Trae 即可。

学员只需发简短准备请求，安装、实际运行检查和报告保存都由助手默认执行，不要求学员在提示中重复技术约束或勾选助手完成状态。本阶段只准备工具，不创建作品；需要本人登录、条款或重启时给一个动作，结束用一句话说明结果。案例阶段的逐步技术检查由对应课程 Skill 的内部检查资料承担，不显示在学员手册。

用户可能完全没有编程经验。收到“准备 AI Coding 工具”“安装资料包里的助手”时读取本文。环境准备、项目启动和产品业务分别执行；前两项可以用于任何兼容作品。

## E-01：还没有课程资料时

当前网页先安装打开 Trae（E-02），再由 Trae 连续准备工具（E-01，含原 E-04）。此入口不依赖课程 Skill 已安装，也不要求学员先手工下载或解压。

1. 保持 Trae 当前打开的文件夹为 workspace。下载官方课程仓库的 `https://siatwangmin.github.io/aicoding-course/Get-CourseMaterials.ps1` 到 workspace 的 `.course-setup/Get-CourseMaterials.ps1`，读取脚本后用 Windows PowerShell 运行，传入 `-WorkingDirectory workspace`。脚本从公开 VERSION.json 确定课程版本，再从固定版本 GitHub Pages 地址取得 `aicoding-student-kit.zip` 和 SHA-256，先校验再安全解压；不需先注册 GitHub。
2. 脚本保护已有文件，在 workspace 内建立版本化资料目录，将六项课程技能安装到当前用户的 `%USERPROFILE%\.trae-cn\skills`，保存 `.course-setup/materials.json` 和 AGENTS 的资料入口。下载结束后立即从这份记录定位实际说明，继续安装与工具验收，不要求学员重开文件夹或搬文件。
3. 脚本调用所下载的安装包解析器，已有安装程序直接用，缺项分别从下面两个原始地址下载。WSL 必须匹配固定摘要；Docker 官网版本变化时检查有效 Docker Inc 签名。只有实际工具检查证明已安装且可复用时才用 `-SkipInstallers`，并记录跳过理由；下载完成不代表安装或环境验收通过。
   - Docker：`https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe`
   - WSL：`https://github.com/microsoft/WSL/releases/download/3.0.1/wsl.3.0.1.0.x64.msi`
4. E-01 包含资料下载、用户级技能安装、Prepare、Verify 与工具箱实际验收（已合并原 E-04）。Get-CourseMaterials.ps1 只负责下载及技能安装，完成后必须继续下文的环境助手流程；不在下载后停止，不要求学员再发送一条安装提示。权限、条款、登录和重启由本人按当前一步处理。不得使用 GitHub Release 的 aicoding-course-kit.zip 或 software.zip 作为新下载路线，不改变原有代理或把网络失败当下载通过。

## 直接安装本地助手

1. 保留当前工作目录为 workspace。已有 .course-setup/materials.json 时先核对其中的版本、实际 PackageRoot 与 SetupGuide，使用该资料根；无有效记录时，资料包根目录优先为当前目录；没有 `setup-guide.md` 时向上和向子目录按距离搜索最近的说明。使用资料包中的 `Install-CourseSkills.ps1`（或已安装环境助手的同名脚本）自动定位与安装：`-WorkingDirectory workspace`。多个等距离完整包、搜索上限或缺文件时报告实际结果，不猜测盘符、用户名或桌面位置。只有外层 ZIP 时先核对实际条目，再自动解压到当前目录内的资料子目录。确定根目录后，查找两个技能 ZIP 与各自 SHA-256；不下载未知替代版。

2. 将两个 ZIP 分别解压到 当前用户的 Trae 全局技能目录 `%USERPROFILE%\.trae-cn\skills\ai-coding-env` 和 `%USERPROFILE%\.trae-cn\skills\ai-coding-project`。先备份再更新同名目录，不改其他技能；当前 workspace 的同名项目副本保存在 .course-setup/skill-backups 后移出发现目录。按 [Trae 官方目录说明](https://docs.trae.cn/ide_skills)使用当前平台位置，直接本地安装，不要求用户上传插件市场。

3. 两个根部 `SKILL.md` 的 name 必须分别为 `ai-coding-env`、`ai-coding-project`；保留脚本与资产目录，检查引用完整，实际确认能被工具识别和加载。复制成功不等于启用成功；不能识别时报告实际客户端障碍，不能猜测已启用。

4. 若资料包有 `case-profile.json`，安装脚本必须读取其中声明的案例技能 ZIP 与名称，核对 SHA-256、ZIP 根部 SKILL.md 的 name 与引用，安装到当前用户的对应全局技能目录；声明的文件缺失时报告失败，不能静默跳过。只有用户明确选择该案例时才使用。通用环境与启动器不依赖案例资料。没有案例包仍能创建其他作品。

5. 将通用技能位置合并到当前资料目录已有的 `AGENTS.md`，让后续功能语言请求能发现助手，不覆盖已有约束。作品启动后，将助手引用合并进作品 AGENTS；业务规则从该作品自己的材料读取。

当前资料包另含 `ai-coding-cloudbase-skill.zip` 与校验文件。安装脚本会一并校验并安装到 `%USERPROFILE%\.trae-cn\skills\ai-coding-cloudbase`，同样保留根部 `SKILL.md` 并检查识别状态；旧的两技能包仍可使用。将此助手也加入技能引用。课程在 E-06 课前云服务准备中调用它，提前完成账号、实名、官方接入、管理授权及练习环境。Docker 助手只验收工具；云端操作由 CloudBase 陪练调用官方 Skill 执行，不创建业务数据或发布作品。

当前资料包还含 `ai-coding-github-skill.zip` 与校验文件。安装脚本一并安装到 `%USERPROFILE%\.trae-cn\skills\ai-coding-github` 并保留其他技能；旧包没有此项时仍可安装原有助手。课程 E-07 调用它，一步一步带本人注册或登录 GitHub 免费个人账号、完成邮箱验证，已有账号直接复用。检查准备结果后继续 E-08 的 AI 服务准备，不在课前创建仓库或配置推送凭据；平台要求的本人验证与条款在官网完成。

已有对话仍报告案例技能不可调用时，先核对案例技能确已安装，再在同一作品新建对话，请求使用该助手并读取当前步骤。应看到技能调用记录和正确项目路径；只读资料里的 SKILL.md 不算加载成功。安装位置固定为当前用户的 Trae 全局技能目录，切换作品继续使用，不再复制到项目 .trae/skills。旧用户副本由脚本先备份再更新；当前 workspace 的同名项目副本先备份再移出技能目录，避免旧规则遮蔽。其他已打开作品若仍有同名副本，按实际路径备份后迁出，不删除其他技能或源码。

## 准备工具，与创建作品分开

当前安装包由 E-01 的助手从官方原始地址获取；位置和来源记录在 workspace 的 `.course-setup`、`.docker-setup`。复用已有 release、releases 或 software 中的安装程序；缺项才按固定清单自动下载。不要求学员选择安装包目录、解压软件合集或移动文件，从实际位置传入 InstallerDirectory。不要把公司云盘分享页当安装程序直接执行，也不使用带到期时间的临时 WSL 链接。下载、摘要与签名检查由脚本完成；失败后检查实际网络和下载记录，按官方地址继续处理；不退回 GitHub Release 完整包或旧网盘安装包，不能声称已安装。

调用 `ai-coding-env`，读取其 Windows 路线。助手连续执行自动定位/解压、`Start-Process powershell.exe ... -Verb RunAs -Wait` 运行 Prepare、自动安装和启动 Desktop、同样主动提权 Verify、digest 拉取和容器内检查，最后写 `workspace\toolchain-verification.json`。Prepare/Verify 不得先非管理员失败后再提权。仅在 UAC 前告知“请点击是”及首次条款前告知“请本人阅读并决定是否接受”；普通步骤不中断征询，不要求用户手动打开程序或观察 Engine running。诊断和安装记录只在 workspace 的 `.docker-setup`，不写 AppData。BIOS 未开启、系统需要重启或材料/策略确实阻塞时报告证据，不能自动跳过或声称完成。

工具箱验收完成只报告工具可用并记录结果；本助手不创建产品目录或云资源。课程接着在 E-06 调用 CloudBase 陪练完成课前云准备，两项分别记录。用户要启动作品时才调用 `ai-coding-project`，只问作品名称、用途和保存位置。空白页面、案例开发、工具验收和云准备分别检查。

**结束前必须核对工具箱验收，不能在 Docker 就绪后停止。** Prepare/Verify 返回 `Decision=Ready` 后，直接执行已安装环境助手的 `scripts\Verify-Toolchain.ps1 -WorkingDirectory <原工作目录>`，不要求学员再发“继续”指令。实际退出码为 0，且本次生成的 `toolchain-verification.json` 中 VerifiedAt 有效、Image/imageDigest 匹配固定配置、Architecture=amd64、Os=linux、ToolchainCheck.ExitCode=0 并有检查输出，才可报告工具箱准备完成。缺记录或未通过时报告实际停在哪一步，读取安装/工具记录继续诊断。

脚本同时生成当前工作目录的 `environment-checklist.md`，展示系统、WSL、Docker、镜像获取、摘要、平台和容器工具的逐项结果及证据。助手结束时打开或链接这份报告；“未检查”或“未通过”的必要项不能当作完成。

## 课前准备 CloudBase，作品建立后复用

项目 SDK/离线编译依赖不代表 CloudBase Skill/MCP 已连接。课程 E-06 在课前调用 CloudBase 陪练，按 `https://docs.cloudbase.net/skill.md` 和实际客户端官方说明完成云服务准备，核对 MCP 的进程位置及授权。若通过本地 npx 启动，必须检查其所在环境的 Node/npx 和首次下载条件；容器里有 Node 不能代表 Windows 已满足。不要承诺云服务完全离线。必须本人安装额外工具时给一步官方指引，不静默改变其系统。

账号登录、实名认证、开通费用、管理授权及模型调用凭证由本人在指定页面完成。只记录状态，秘密不进聊天、通用镜像、资料包或代码。

开通课堂 CloudBase 时调用已安装的 `ai-coding-cloudbase`。用 Trae BrowserUse 一次一个动作带学员完成注册、登录与实名；再实际读取 `https://docs.cloudbase.net/skill.md`，在学员当前 Trae 环境中接入腾讯云官方 Skill，由其 MCP 或官方 CLI 完成免费资格核对、PostgreSQL 环境与同环境 Publishable Key 的所有云端操作。取得值后实际绑定、读取环境，并保存检查两个连接值。没有作品时使用当前工作区 `.cloudbase-setup/connection.env` 和准备记录；已有作品时合并到真实源码 `.env`。创建作品后由助手自动读取准备结果并接入，不切换 V1 本地模式。已有账号可直接发送“帮我把 CloudBase 接好，按官方说明完成接入并建议下一步”。不能把配置保存、插件安装或控制台登录当作管理接入成功，也不能把管理接入当作作品的数据同步成功。密码、实名资料与授权批准由本人在页面处理，管理密钥仍由本人保管。

## 功能开发的交接顺序

工具检查与当前作品打开完成后（首次新建空白项目，已有作品直接恢复），进入通用项目 Skill 的功能迭代流程。每一次本机、云端、安卓或 AI 功能迭代都由用户在 Gemini 更新 PRD.md、在 Canvas 更新设计 HTML 并试用确认，再交 Trae 实现与测试、亲自验收。资料已覆盖本轮目标且用户已确认时直接继续，不重复确认。账号或技术准备不能代替产品需求与设计。

## E-08：课前准备硅基流动

资料包包含 ai-coding-siliconflow-skill.zip 和校验文件，安装到当前用户的 %USERPROFILE%/.trae-cn/skills/ai-coding-siliconflow，旧资料包没有此项仍保留原助手。调用此陪练用 BrowserUse 带本人登录、核对余额/额度有效期与模型当前费用、创建或复用 Key；基础 URL 自动填好，本人只在隐藏输入窗口粘贴 Key。私有文件固定为 workspace/.ai-setup/siliconflow.env，限制访问并整体排除 Git、分享、镜像和前端产物。知错星模型 ID 由案例 Skill 的 implementation/siliconflow-models.json 提供；课前检查直接测试硅基流动，不需要产品或云函数已存在。费用决定由本人处理，配置已保存和真实调用通过分别记录。作品创建后由助手安全迁移准备结果，V4-04 只复查补缺，V4-05 才将 Key 接到本轮对应云函数服务端。

## 学员网页入口

课前先看在线 preparation.html；资料下载由 Trae 完成，已有离线页面也可直接使用，只完成当前七个准备步骤。工具、云服务、GitHub 与硅基流动分别检查，勾选不代替真实验收。上课打开 index.html 的 AI Coding 操作手册，从建立作品开始；已有作品按原进度继续。两页相邻存放，切换不要求重新解压或重新准备。

当前使用 GitHub Pages 中的 aicoding-student-kit.zip 小资料包。Trae 从官方地址取得 Docker 和 WSL，不下载完整软件合集。课前顺序为 E-02 → E-01 → E-06 → E-07 → E-08 → E-05，共六步；原 E-03/E-04 进度映射到合并后的 E-01。E-05 最后由课程助手汇总工具、云服务、GitHub 与 AI 的各自准备证据；必要项通过后进入操作手册，不要求学员审查配置或日志。
