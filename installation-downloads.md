# 在 Trae 准备资料

新环境准备统一使用 **Podman CLI + 独立 Docker Compose**，由 Trae 下载、配置和实际验证。无需 Docker Desktop 或 Podman Desktop，也无需为编排安装 Python。已有作品沿用原 runtime、connection 和镜像；助手保留数据并处理必要迁移，使用者不执行命令。


1. 按准备网页从官网安装并打开 Trae，已有安装直接用。
2. 在 Trae 打开一个练习文件夹，复制环境准备第二步的提示。
3. Trae 连续完成资料下载、安装和工具检查；不用自己下载、解压或移动文件，也不用再发送一条准备提示。
4. 按提示处理本人条款、授权或重启；重启后回到同一任务继续。

通用准备使用 GitHub 中的小资料包 `ai-coding-toolkit.zip`；明确选择项目案例时再补充相应案例资料。WSL、Podman CLI 和独立 Docker Compose 的固定安装包默认从 GitCode 下载，失败后按 GHFast → gh-proxy.com → SourceForge → 原始 GitHub 顺序回退。SourceForge 使用 `https://downloads.sourceforge.net/project/` 开头的文件直链。连接、摘要或签名验证失败即尝试下一来源，各来源使用同一固定 SHA256；WSL 和 Podman 另核发布者签名。已验证本地包继续复用；不再使用 GitHub Release 的完整软件合集。

下载失败时把提示告诉 Trae，让它从已有记录继续。你只需处理它指出的当前一步。

## 2.0 工程接续

环境在 A 准备，作品在新的 B 初始化；ai-coding-project 自动从用户级索引发现准备，接入 GitHub/CloudBase/AI，准备 Android 并生成项目根 AGENTS、技术基线和接续记录。大型环境数据优先非系统盘（如 D:\ENV），只有 C 盘时用 C:\ENV；本地运行、Web 编译和 APK 构建使用准备阶段同一已验证工具链镜像。API Key 使用用户级加密存储与项目引用，不逐项目复制。

通用技能名单以 course-contract.json（维护源 course-contract/skills.json）为准：七项通用，明确选择某项目案例时另加其案例技能。通用开发调用 ai-coding-development，Android 调用 ai-coding-android；明确选择案例才读取案例业务。本人只做必要授权/费用决定、需求设计与亲自试用。配置、实际服务、构建、安装与本人试用分别留证。

环境准备软件下载安装和验证在后台运行，前台按 GitHub → 硅基流动 → CloudBase 顺序引导账号注册与必要授权；需要本人确认时提醒，重启前保存注册进度，最后两路全部通过才完成准备。
