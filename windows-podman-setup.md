# Windows：Podman Desktop 路线

仅在本人选择 Podman Desktop，或有效作品记录已选择 podman 时使用。Docker 路线保持原脚本；不要同时安装两套。选择来源按本轮明确指令、已有作品 manifest、workspace 的 `.course-setup/container-runtime.json` / `materials.json` 读取；冲突时保留现状并澄清，不以网页进度或安装成功代替验收。

## 准备和复查

1. 使用当前用户安装的 ai-coding-env；诊断写在原 workspace `.podman-setup/`。读取 `assets/podman-installers.json`。已有 Desktop、Podman CLI、WSL 和 machine 直接复用，不重装、不删除或重建 machine。CLI 不在 PATH 时自动探测 LocalAppData/Programs/Podman 与 ProgramFiles/RedHat/Podman，不让学员寻找路径。
2. 缺少 Desktop 时由助手运行 `scripts/Setup-PodmanDesktop.ps1 -Mode Prepare -WorkingDirectory <workspace>`；它只从 Podman 官方 GitHub 固定版本下载 x64 安装程序，核对 SHA-256 和 Red Hat, LLC 的有效 Authenticode 签名。已有安装不要求降级至清单版本。记录来源，不运行 HTML、签名失败文件或第三方重打包程序。
3. 系统虚拟化、虚拟机平台、WSL 未满足时，由助手检查并安装必要组件。需要系统提权时用当前本人账号的提升权限执行；本人只处理 UAC、重启与实际出现的条款，不替助手检查日志。WSL 安装包沿用 windows-installers.json 的官方固定版本和摘要，有效安装不降级；不要运行会顺带安装 Docker 的完整 Docker Prepare。系统限制、拒绝提权、必须重启或本人身份不一致时记录阻塞，重启后续接。
4. Desktop 缺少 Podman 引擎时，助手按[官方 Windows 安装说明](https://podman-desktop.io/docs/installation/windows-install)完成 onboarding 和必要引擎安装；缺少 Compose 时按[官方 Compose 设置说明](https://podman-desktop.io/docs/compose/setting-up-compose)补齐。`podman compose` 可以调用独立 Compose 客户端；不要求启动 Docker Desktop 引擎。Desktop 安装、引擎安装、machine 启动和 Compose 各自检查，缺任一项不得报 Ready。

   当前Prepare已从podman-installers.json补固定Podman 6.1.4 MSI与Compose 5.6.0，按官方release摘要核对，MSI再验Red Hat签名；不会用缺项为由只停在“onboarding incomplete”。新程序默认D盘，实际绝对入口登记用户.ai-coding/tool-paths.json；后续进程读取，不要求学员改PATH。官方核对来源：[Podman固定版本](https://github.com/podman-container-tools/podman/releases/tag/v6.1.4)、[Compose固定版本](https://github.com/docker/compose/releases/tag/v5.6.0)。

   新建且没有其他machine时，为Podman进程设置D盘XDG_DATA_HOME，覆盖machine镜像缓存与WSL导入目标；依据固定版本[数据目录实现](https://github.com/podman-container-tools/podman/blob/v6.1.4/pkg/machine/env/dir.go)和[WSL实现](https://github.com/podman-container-tools/podman/blob/v6.1.4/pkg/machine/wsl/machine.go)。仅本进程/子进程生效，不改其他应用全局XDG配置；记录供后续课程进程复用。已有machine不切数据根，迁移须按保留资源路线另做并实测；新参数与源码依据不能冒充真实安装/VHD位置通过。
5. Prepare 只会初始化缺失的本机 `podman-machine-default`（rootless）或启动已停止的同名 machine；Verify 不修改现有 machine。运行 `Setup-PodmanDesktop.ps1 -Mode Verify -WorkingDirectory <workspace>`，检查本次退出码 0、`.podman-setup/report.json` 的新时间、`ContainerRuntime=podman`、`Decision=Ready`、本机 connection 与 Linux amd64 Server、Compose。脚本显式使用经本机 machine 核对的 loopback SSH connection，不把任意远程服务当本机。

## 已实测的兼容处理

- `podman info` 和 `compose version` 通过仍可能缺少 Windows API 转发管道。Verify 还必须执行只读 `podman --connection <本机连接> compose ls --format json`。Prepare 在已核对本机 SSH connection 且仅缺该 machine 自己管道时，可恢复随 Podman 安装的 win-sshproxy.exe；状态保存在 workspace 的 .podman-setup/api-proxy，不占用或修改 docker_engine，不停止已有工作负载。参数来自 [Podman v6.0.2 官方源码](https://github.com/podman-container-tools/podman/blob/v6.0.2/pkg/machine/machine_windows.go)；其他版本若不兼容，记录实际错误并核对该版本源码，不重复重建 machine。管道存在但 API 仍失败时停止自动修复，保留故障，不杀其他进程。

- 本机 Podman 6.0.2 / WSL 2.5.7 / Linux 6.6.87.1 出现 rootful bridge 的 nftables 错误。若当前机器实测同类错误，优先采用 rootless + pasta；不把这个案例当所有版本必然故障。切换前读取两种存储及运行容器；停止会影响已有任务时需先与本人协调。切换使用 `machine stop`、`machine set --rootful=false`、`machine start`，串行检查终态；保留原 rootful 存储，不 reset/remove machine，不关闭防火墙或改 host 网络。根据[官方 machine 说明](https://docs.podman.io/en/latest/markdown/podman-machine-set.1.html)，两种模式不共享存储，切换后须在所选 connection 重新检查镜像。
- 新 Podman 工程默认使用 rootless + pasta，端口只映射 `127.0.0.1`。已有健康 rootful 工程可保留 bridge，将 NetworkMode=bridge 记录并传给项目生成器；不要无故切换。
- 继承 `127.0.0.1` 代理而出现 ECONNREFUSED 时，先实际检查容器直连。仅直连成功后可在该工程的构建使用 `--http-proxy=false`、运行清空代理变量。不要改变宿主机代理、禁用 TLS 验证或把代理凭证放进镜像。直连不可用时按[官方代理说明](https://podman-desktop.io/docs/proxy)配置可达代理，不将一次本机案例变成强制直连规则。

## 固定镜像与工具验收

运行 `Verify-Toolchain.ps1 -ContainerRuntime podman -WorkingDirectory <workspace>`。它转交 `Verify-PodmanToolchain.ps1`，使用同一个课程工具镜像和同一个只读 `check-environment.sh`。没有业务挂载，不创建作品。

在线按 toolchain.json 的不可变 image@sha256 拉取；核对 linux/amd64 和 RepoDigests 精确匹配。仓库不可达且已有批准离线包时，加 `-ImageArchive <真实路径> -SkipPull`：每次重新核对 toolchain.json 中批准的归档 SHA-256，再核对导入镜像配置 ID 与平台；只凭标签、ID 或旧报告不通过。已存在匹配内容时复用，不重复导入。

Docker archive 导入可能重建本地 manifest。该路线的离线证据记为 `VerificationMethod=archive-sha256+image-config`、`RegistryDigestVerified=false`，不能声称远端 RepoDigest 已核对；在线证据为 `registry-digest`。两者都必须实际运行断网容器，退出码 0 且输出 TOOLCHAIN_READY。批准归档校验是镜像来源证据，不代替工具执行。

共同记录 `toolchain-verification.json` 与 `environment-checklist.md`，包含 ContainerRuntime、Image、imageDigest、Architecture、Os、Machine、Connection、Endpoint、ServerVersion、ComposeVersion、Rootless、NetworkMode、VerificationMethod、RegistryDigestVerified、ArchiveSha256、ToolchainCheck、VerifiedAt、NotVerified；另以 SkillInstallationVerified 和 SkillsVerificationPath 记录按完整准备名单实测的用户级技能安装，清单逐项列出用户目录、名称及项目同名副本。缺名单、缺用户副本或存在同名项目副本不能通过。位置检查不代替 Trae 实际识别加载。失败时 VerifiedAt=null，旧成功记录不能替代新结果。DockerEndpoint/DockerServerVersion 是 Docker 旧报告专用字段，不冒充 Podman 证据。

项目启动时把报告里的实际 Image、containerRuntime=podman、NetworkMode 传给 ai-coding-project；`podman compose` 使用所选本机 connection。构建、源码热更新、浏览器保存、云端与 APK/真机分别记录。工具验收不意味着作品或服务全部通过。
