# Windows Docker 准备

使用当前用户 ai-coding-env；读取实际 A 的 materials.json。用户级 Skill 安装由 Install-CourseSkills 完成，名单读 course-contract.json，不能在项目 .trae/skills 安装。下载、安装、配置和真实检查由助手连续完成，使用者只处理必要本人授权、条款和重启。

1. Prepare-CourseStorage.ps1 -WorkingDirectory <A> 按统一目录策略选择新安装位置：优先非系统盘（有 D 盘用 D:/ENV，否则选其他本地 NTFS 非系统盘的 ENV）；只有 C 盘时用 C:/ENV。检查所选位置的 NTFS、空间与权限，写 storage-plan.json；空间或权限不足保留现场并明确选择替代位置，不静默换盘。已有 storageRoot 继续复用；先复用已有批准安装包，缺文件下载到所选根目录的 downloads/installers。
2. Setup-DockerDesktop.ps1 -Mode Prepare -WorkingDirectory <A> -StorageRoot <实际根> 使用本人管理员身份，保持原 A，不把 System32 当 workspace。新 Docker 程序和 WSL 数据分别指定 D 下 programs/docker 与 runtime-data/docker；系统 WSL 组件按 Windows 要求安装，不额外装 Ubuntu。已有镜像/卷/容器/VHD 保留，不直接移动正在使用的文件，不卸载重建绕过。
3. 必须实际运行 -Mode Verify；UAC 取消、旧 Ready、下载完成都不是成功。参数、管理员身份、重启与同机证据按脚本检查。后台启动使用隐藏窗口，安装条款仍由本人决定。
4. Verify-Toolchain.ps1 用固定 image@sha256 检查 linux/amd64 与真实断网工具容器。镜像在本机且摘要匹配时使用 -SkipPull，不重复下载。离线证据按批准清单，不拿标签当 digest。
5. Prepare-CourseStorage.ps1 -Verify 检查实际 VHD 位置；位置不明或仍在 C 则保持未完成，由助手按当前官方 Desktop/WSL 支持方式安全迁移后再查。程序在 D 不能替代数据在 D 的证据。
6. Register-CoursePreparation.ps1 登记实际通过工具记录，用户级 preparation-index 让 B 找到 A；原始报告仍在 A。E-05 检查存储、工具、所有所需技能与各服务分别通过。

Prepare/Verify 的 Start-Process 使用 -Verb RunAs -WindowStyle Hidden -Wait -PassThru，参数安全引用并传实际 StorageRoot/WorkingDirectory。本人身份改变时停止，不能把管理员另一个账号当作使用者。
