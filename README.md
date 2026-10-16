# AI Coding 实操课

环境准备现在可在 preparation.html 的“让 Trae 准备工具”中选择 **Docker Desktop** 或 **Podman Desktop**；已有哪一个就选哪一个，只安装一种。页面记住选择，并带入复制给助手的提示。助手负责安装、配置和实际检查，本人只处理必要授权、条款或重启。已有作品沿用工具记录，不重新初始化。Podman 路线、machine/Compose、rootless/pasta 与离线镜像证据由用户级 ai-coding-env 的 references/windows-podman-setup.md 维护；下文已有 Docker 命令仅为 Docker 路线示例。


**课前：打开 `preparation.html`，先安装 Trae，后续下载和准备由助手完成。上课：打开 `index.html`。** 在线与离线都有两个入口：[课前环境准备](course/preparation.html)和[AI Coding 操作手册](course/index.html)。

当前资料版本见 [VERSION.json](VERSION.json)，变化见 [更新记录](CHANGELOG.md)。每个正式版本都有固定资料包；在线旧版入口见 [版本下载](https://siatwangmin.github.io/aicoding-course/releases/course/)。

课前环境准备带你完成工具、云服务、GitHub 账号和 AI 服务准备。AI Coding 操作手册从建立作品开始，依次完成需求与原型、本地网页、云端网页、安卓和 AI。每次上课按当前未完成步骤继续。

每步都写清：**在哪操作 → 这样做 → 何时发送提示 → 完成后**。需要你判断的结果单独列出；有勾选框时只记录自己的操作。

- 你看网页，Trae 读课程助手；准备阶段会安装助手，不用打开技能文件。
- 在 Gemini 写需求，在 Canvas 试页面；保存 `PRD.md` 和 `know-star.html`，交给 Trae 实现与测试。
- 你确认需求、页面和实际体验。登录、授权、费用决定和手机试用由本人处理。
- 每次增加功能，先更新需求和页面设计，再开发、亲自试用。
- V4 的模型可以在作品“设置 → AI 模型”中更换；网页和安卓版共用选择，不用自己修改代码或填写 Key。
- 学生错题本是练习案例。工具可复用，做自己的作品时另建项目。

## 发给学员什么

发送[课前环境准备网页](https://siatwangmin.github.io/aicoding-course/preparation.html)即可。先安装打开 Trae，再复制页面提示，让它下载小课程资料包、所选 Docker/Podman 和 WSL；不要求学员手动下载或解压软件合集。已有安装程序和工具直接用。资料不含成品、个人平台密码或 AI 凭证；作品使用指定公开课堂演示账号。

环境由 Trae 按 `setup-guide.md` 准备。学员处理需要本人完成的授权、条款和重启；最后由助手汇总准备结论，不要求学员审查配置或日志。

课前按网页“接好云服务”调用随包安装的云服务助手；注册、实名和授权在本人页面完成，配置与连接检查交给助手。还没有作品也可以准备，建立作品后由助手接入；V2 只检查和补齐缺项。单独安装助手也可让 Trae 读取 [setup-guide.md](setup-guide.md)，直接安装本地技能。

课前“准备 GitHub 账号”由注册陪练一步一步引导，已有账号直接复用并检查邮箱验证。V2 先把已确认的 HTML 页面发布到 github.io，点击看到页面即可；这一步只做静态展示。后续再接入 CloudBase 保存与共享。V2 作品演示账号由助手准备，学员打开后直接练习保存和同步，不用设置账号或密码。

## 2.0 工程接续

环境在 A 准备，作品在新的 B 初始化；ai-coding-project 自动从用户级索引发现准备，接入 GitHub/CloudBase/AI，准备 Android 并生成项目根 AGENTS、技术基线和接续记录。大型环境数据默认 D 盘；本地运行、Web 编译和 APK 构建使用准备阶段同一 Docker 镜像。API Key 使用用户级加密存储与项目引用，不逐项目复制。

通用技能名单以 course-contract.json（维护源 course-contract/skills.json）为准：七项通用，学生错题本课程另加案例技能。通用开发调用 ai-coding-development，Android 调用 ai-coding-android；明确选择案例才读取案例业务。本人只做必要授权/费用决定、需求设计与亲自试用。配置、实际服务、构建、安装与本人试用分别留证。

跟随学生错题本案例使用 [操作手册](course/index.html)；做其他业务使用 [自己的作品](course/custom.html)。两者复用相同环境和技术能力，业务要求分别确认。
