# 在 Trae 准备资料

新环境准备统一使用 **Podman CLI + 独立 Docker Compose**，由 Trae 下载、配置和实际验证。无需 Docker Desktop 或 Podman Desktop，也无需为编排安装 Python。已有作品沿用原 runtime、connection 和镜像；助手保留数据并处理必要迁移，使用者不执行命令。


1. 按准备网页从官网安装并打开 Trae，已有安装直接用。
2. 在 Trae 打开一个练习文件夹，复制环境准备第二步的提示。
3. Trae 连续完成资料下载、安装和工具检查；不用自己下载、解压或移动文件，也不用再发送一条准备提示。
4. 按提示处理本人条款、授权或重启；重启后回到同一任务继续。

通用准备使用 GitHub 中的小资料包 `ai-coding-toolkit.zip`；明确选择项目案例时再补充相应案例资料。WSL、Podman CLI 和独立 Docker Compose 的固定安装包默认从 GitCode 下载，失败后按 GHFast → gh-proxy.com → SourceForge → 原始 GitHub 顺序回退。SourceForge 使用 `https://downloads.sourceforge.net/project/` 开头的文件直链。连接、摘要或签名验证失败即尝试下一来源，各来源使用同一固定 SHA256；WSL 和 Podman 另核发布者签名。已验证本地包继续复用；不再使用 GitHub Release 的完整软件合集。

下载失败时把提示告诉 Trae，让它从已有记录继续。你只需处理它指出的当前一步。

GitHub CLI（gh）同样纳入统一工具准备。已有安装核验后复用；缺少时在已选环境目录安装固定版本的官方便携包。公开安装包按 GHFast → gh-proxy.com → 原始 GitHub 回退，并验证官方版本对应的 SHA-256 和程序摘要；这两个站点是第三方下载加速，不是 GitHub 官方国内源，也不保证大陆可用。可以复用已验证的本地安装包；当前没有把尚未上传、核验的 GitCode 地址列为可用来源。GitHub 登录、API 和推送仍连接原服务，不能用安装包下载成功代替这些检查。卸载仅处理本次准备创建且未被修改、未被其他准备引用的文件，保留原有 gh、Git 与账号授权。

## 作品接续

用户级只安装ai-coding-project。环境准备目录A使用本地env/github/cloudbase；作品B按需求添加本项目的github/cloudbase/android，明确选择案例才添加案例技能。通用开发工作流、Spec和进度随作品保存。公共执行包与已验证镜像跨项目复用，资源目标与技能选择按作品隔离。

工具下载验证在后台，前台依GitHub→CloudBase准备必要账号和授权，再汇总真实结果。不要求模型供应商账号、Key或模型调用；当前需要AI功能时再按本项目需求配置。
