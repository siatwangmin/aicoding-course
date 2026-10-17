# Windows：Podman CLI + 独立 Docker Compose

新课程准备主线，Windows 11 x64 / WSL2。无需两个 Desktop，不引入 Python 版 podman-compose。旧 Docker 作品沿原记录恢复；已有 Podman 保留 connection、镜像、数据、rootful/rootless，不能 reset/remove/recreate machine。

## Prepare / Verify

1. 保持原 A，准备记录在 .podman-setup。运行用户级 scripts/Prepare-CourseStorage.ps1，再运行 scripts/Setup-Podman.ps1 -Mode Prepare -WorkingDirectory <A>。已有 CLI/WSL/machine 复用；缺 engine 按 assets/podman-installers.json 安装 Podman MSI，SHA256 与 Red Hat 签名必须通过。已有引擎不强制降级到清单版本。
2. 缺系统组件时先检查 Windows/x64、虚拟化和 VirtualMachinePlatform；必要提权自动保持本人 SID 和 A，拒绝另一账号结果。WSL 使用 windows-installers.json 的官方固定 MSI/摘要；必要重启保存缺项、由本人处理，完成后继续同一 Prepare。不得用 Docker 安装器或 Desktop onboarding 补 Podman。
3. 独立下载 Docker 官方 docker-compose-windows-x86_64.exe，按固定 SHA256 校验，安装为 D:/AI-Practice/programs/compose/docker-compose.exe。旧受管文件更新前备份；用户级 .ai-coding/tool-paths.json 保存 CLI、Compose 和 dataHome，原记录备份在 A。不能把 PATH 或 Desktop 目录命中当作独立准备通过。
4. 新建 machine 仅在没有既有 machine 且明确属于课程时执行。进程级 XDG_DATA_HOME 指向 D 盘，使新 machine 缓存/WSL 导入使用计划位置；既有 machine 不切根。依据固定 [Podman 数据目录源码](https://github.com/podman-container-tools/podman/blob/v6.1.4/pkg/machine/env/dir.go)，实际 VHD 位置仍需验证。
5. Verify 不安装、不启动 machine；Prepare 可启动已停止的同名 machine。检查最新 report.json：退出码 0、ContainerRuntime=podman、Decision=Ready、loopback SSH/IsMachine 连接、Linux amd64、ComposeBinding 的绝对路径/版本/hash/来源和真实 Compose API。远程服务不能代替本机。

共同 Course-Native.ps1 对每个 Podman compose 子进程重新校验受管 EXE，并注入 PODMAN_COMPOSE_PROVIDER；不改父进程或全局环境。所有调用者使用 --connection 固定项目连接，清除子进程继承的 DOCKER_HOST/CONTEXT/TLS 配置。Docker Compose 提供编排，容器实际运行在 Podman；不用 Docker CLI 或 Docker 引擎。

## 连接恢复

Podman info 与 compose version 不代表 Windows Docker 兼容 API 可用，还要实际 compose ls/config/up/exec。先核 machine 状态，再核所选 SSH 连接、API pipe 和 provider。连接错误不切到其他 machine 或 Docker，引擎健康但 API 缺失时保留分层错误。

Prepare 在已核所选本机连接、machine 自己 pipe 缺失且客户端版本为 6.0.2/6.1.4 时，可使用其同目录官方 win-sshproxy.exe 恢复该 pipe，记录 helper hash/PID/版本/日志目录和停止条件。参数依据 [v6.1.4 官方实现](https://github.com/podman-container-tools/podman/blob/v6.1.4/pkg/machine/machine_windows.go)。不占 docker_engine，不杀其他进程，不重启共享工作负载。其他版本或 pipe 已存在但 API 失败时记录故障并查相应版本；不循环重建 machine。重启后的 Start 入口复查并仅恢复缺项。

新准备默认 rootless+pasta，端口只绑定 127.0.0.1。既有健康 rootful 可保留 bridge。历史 6.0.2/WSL 2.5.7 的 nftables 故障仅为案例证据；切换模式会使用不同存储，必须先核工作负载和影响，不自动切换。代理按宿主/machine/容器分别实测，直连确实可用时才选择项目级清空代理；不禁 TLS 或防火墙。

## 固定镜像、工程与证据

Setup Ready 后立即运行 Verify-Toolchain.ps1 -ContainerRuntime podman -WorkingDirectory <A>。在线按 toolchain.json 固定 image@sha256 核精确 RepoDigest。批准离线归档必须当次核 SHA256、配置 ID 与 linux/amd64，记 VerificationMethod=archive-sha256+image-config、RegistryDigestVerified=false；不能声称远端 RepoDigest 已验证。镜像存在则复用。

在同一镜像内断网执行 check-environment.sh，退出码 0 且 TOOLCHAIN_READY；完整名单用户 Skill 安装通过后，才写有效 VerifiedAt 并登记索引。报告含 Machine/Connection/Endpoint/ApiEndpoint/ServerVersion/ComposeBinding/ComposeVersion/Rootless/NetworkMode、镜像与工具输出、SkillInstallationVerified、NotVerified。失败 VerifiedAt=null；真实 Trae 加载另验。

B 继承 runtime=podman、原 connection、同镜像、网络模式和 compose.provider=docker-compose。共同 Course-Runtime.ps1 -Start 核镜像、源码挂载、独立 Linux 依赖卷和锁文件，使用显式 --wait-timeout；配置 JSON 与实际容器 inspect/HTTP/双向挂载分别核对。缺 EXE、摘要改变、API 不通、错误端点、健康失败均不能报通过。

准备、实际存储、服务授权、Web/APK、安装启动同步和本人试用分别记录。C 盘旧资源或干净机器/重启/Trae 加载未验证时保留 pending，不以本机已有 Docker 成功代替 Podman 验收。


2.1 镜像获取前先验实际存储：新 machine 的 VHDX、受管程序与 dataHome 必须落在选定非系统盘，再执行大镜像拉取/导入。已有有效本地镜像直接核验，不联系仓库。旧离线镜像在原归档摘要、固定配置ID、原connection和实际镜像ID均匹配时可复用历史归档证据，报告明确 ArchiveEvidenceReused，不声称本轮重验归档或在线RepoDigest。旧C盘环境保留资源并进入定位/迁移流程，不在C盘继续获取大镜像。


已验证的CLI 6.1.4 / server 6.0.2组合同样支持原machine管道恢复，仍核helper路径/摘要和真实Compose API；其他组合保留诊断，不循环重建。迁移计划与Apply使用同一参数，不导入带param的可执行安装器；目标为空目录可以安全移除空目录，已有内容保留。VerifyAfterRestart同步restartStatus与资源证据。

API失败现由Course-PodmanDiagnostics记录所选connection、pipe与可确认代理状态；Prepare沿现有官方helper在新的受管目录恢复，不停共享负载。旧socket归属/占用不明时保留，不按0字节或通配符删除。迁移写入完整restart-continuation，重启后用A内生成的resume-preparation.ps1接续；已知旧时间字段有来源地规范化，冲突不猜。

Podman项目模板的HTTP健康探针支持AI_CODING_HEALTH_TIMEOUT，默认10s；来自实测请求约4.8s而原3s误判的修复，不是任意加sleep。旧工程只自动更新完全匹配的旧受管模板，自定义健康检查按项目Spec和测量调整；标记文件等不同探针不套用该预算。
