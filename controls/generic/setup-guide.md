# 环境准备与项目初始化

在准备目录 A 让助手取得当前发布小包，校验版本与摘要，调用 Install-CourseSkills.ps1 -WorkingDirectory <A> -PackageRoot <真实目录>。该入口在用户级安装 ai-coding-project/github/cloudbase/android，A/.trae/skills 仅保留 env。公共执行包位于技能发现目录之外，案例不进入默认链。

读取A内env的references/preparation-workflow.md；后台Start-CourseToolPreparation下载安装并验证工具、实际存储和固定镜像，前台依次接续GitHub与CloudBase。已有有效状态直接复用，需要本人授权/费用/重启时一次给一个动作。环境准备不要求模型供应商账号、Key或调用。工具、平台、实际Trae加载和汇总分别验证。

新环境使用Podman CLI与独立Docker Compose，优先非系统盘ENV，只有系统盘时使用C:/ENV；已有准备和作品保持原storageRoot、引擎、镜像与连接。宿主准备 Git for Windows（已有复用，缺失时优先 npmmirror、华为云镜像，固定摘要校验）及 Node.js LTS、npm/npx供官方CloudBase技能、本地MCP与CLI使用，安装包优先国内npmmirror、南大备用，npm默认国内registry；项目构建在同一准备镜像中执行。

任意新作品目录 B 调用用户级 ai-coding-project。先检查全部拟生成文件的冲突，再原样复制标准 app、绑定准备环境，在容器中构建运行。默认端口 5187，占用时自动尝试其他端口，并核验、输出完整访问地址。初始化不询问三项平台选择，不复制平台或案例技能；后续按当前需求直接调用用户级平台技能，资源与授权仍按作品绑定。Android 配置在首次实际需要时生成。

项目生成AGENTS、工程工作流、Spec模板和进度后，助手按本项目规则直接开发。本地功能不依赖独立开发技能；GitHub承担静态发布，CloudBase承担云端及AI后端，Android承担手机交付。当前请求的能力需要实际接续验证，不能把已装技能或本地构建当作平台已接入。

运行时解析 B 的公共执行包绑定。Initialize 只新建；Resume 接续；Verify 检查；Upgrade 只在明确要求时更新受管内容；Connect 连接明确准备环境或服务。复制失败按事务回滚，构建失败保留工程并接续。A 移走后可复用登记摘要与完整执行包，不扫描用户目录找秘密；旧工程保留源码、设计、稳定标识和有效资源绑定。

卸载在原A调用env或双击卸载环境.cmd，先列真实清单，按已明确范围执行，保留作品与云端资源。升级通过原资料Update-CourseMaterials.ps1，在校验新包后更新相应作用域；历史发布不可覆盖。本人试用、真实发布、模型调用与自动检查分别记录。
