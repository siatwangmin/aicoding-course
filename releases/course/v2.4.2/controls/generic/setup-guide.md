# 环境准备与项目初始化

在准备目录A让助手取得当前发布小包，校验版本与摘要，调用 Install-CourseSkills.ps1 -WorkingDirectory <A> -PackageRoot <真实目录>。该入口只在用户级安装 ai-coding-project，在A/.trae/skills安装env/github/cloudbase；Android和可选案例缓存于公共执行包，等待作品按需安装。

读取A内env的references/preparation-workflow.md；后台Start-CourseToolPreparation下载安装并验证工具、实际存储和固定镜像，前台依次接续GitHub与CloudBase。已有有效状态直接复用，需要本人授权/费用/重启时一次给一个动作。环境准备不要求模型供应商账号、Key或调用。工具、平台、实际Trae加载和汇总分别验证。

新环境使用Podman CLI与独立Docker Compose，优先非系统盘ENV，只有系统盘时使用C:/ENV；已有准备和作品保持原storageRoot、引擎、镜像与连接。宿主只承担编辑、Git、授权和引擎控制，项目构建在同一准备镜像中执行。

任意新作品目录B调用用户级ai-coding-project。需求未明确时确认公开静态网址、云端保存/多端同步、Android安装包三项，可暂不需要；需求已明确不重复询问。仅向B/.trae/skills安装所需github/cloudbase/android；明确选择案例才安装项目案例技能。未选能力不作为初始化缺项。

项目生成AGENTS、工程工作流、Spec模板和进度后，助手按本项目规则直接开发。本地功能不依赖独立开发技能；GitHub承担静态发布，CloudBase承担云端及AI后端，Android承担手机交付。当前请求的能力需要实际接续验证，不能把已装技能或本地构建当作平台已接入。

运行时解析B的公共执行包绑定。A移走后可复用用户发现摘要与完整执行包，不扫描用户目录找秘密、不新建第二套工具；旧工程增量升级保留源码、设计、稳定标识和有效资源绑定。

卸载在原A调用env或双击卸载环境.cmd，先列真实清单，按已明确范围执行，保留作品与云端资源。升级通过原资料Update-CourseMaterials.ps1，在校验新包后更新相应作用域；历史发布不可覆盖。本人试用、真实发布、模型调用与自动检查分别记录。
