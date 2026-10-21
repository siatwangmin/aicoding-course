# 统一正式发布入口

正式发布只调用维护源 `docs/teaching/teacher/Publish-Environment.ps1`。直接推送、单独创建 Release 或 Pages 成功都不能代替完整验收。维护源的 `teacher/release` 是实现源，发布仓库的 `.release` 与 `.github/workflows/release.yml` 由导出器同步。

## 发布与查询

在 know-star-gpt 根目录运行（版本按本次实际目标替换）：

```powershell
# 先在 course/release-history.json、course/flow.json 完成本次版本和修改。
.\docs\teaching\teacher\Publish-Environment.ps1 -Version 2.4.3

# 只触发远端任务，返回后可以关闭窗口。
.\docs\teaching\teacher\Publish-Environment.ps1 -Version 2.4.3 -NoWait

# 在任何新窗口查询；成功必须下载并核验对应运行的验收报告。
.\docs\teaching\teacher\Publish-Environment.ps1 -Version 2.4.3 -Status

# 接续本地尚未推送的发布，或重跑失败的远端任务。
.\docs\teaching\teacher\Publish-Environment.ps1 -Version 2.4.3 -Resume

# 只验证现有发布产物，不上传、不部署。
.\docs\teaching\teacher\Publish-Environment.ps1 -Version 2.4.2 -CheckOnly
```

发布仓库默认使用维护仓库相邻的 `aicoding-course`；需要时传 `-SitePath`。本地需要 Git、Python 3.13（py 启动器）和可复用的 GitHub 授权。脚本优先使用当前进程 GH_TOKEN/GITHUB_TOKEN，否则复用官方 Git 凭证管理器；不把令牌放入命令行、文件或报告。

本地构建完成后才触发服务器；远端任务触发后不依赖聊天窗口或本机持续在线。尚未触发就中断时，用 -Resume 接续本地阶段。-NoWait 或运行中的 -Status 明确显示“尚未完成”，不作为发布成功。失败命令返回非零退出码。

## 固定执行顺序

1. 本地验证目标版本；新版本调用统一构建、文档验证、发布协议测试并冻结。源码通过独立 Git 索引保存到 `refs/environment-releases/source/v版本`，保留真实分支、暂存区和其他业务修改。源快照是本机 Git 记录，保留维护仓库即可追溯。
2. 导出已冻结产物，核对清单、所有包和嵌套 Skill 摘要；拒绝任何已存在 releases/previews 文件变化。稳定准备说明由 teacher/stable-bootstrap.md 独立生成，固定包不改写。发布仓库必须先无未审查改动，且 main 与远端一致。
3. 提交发布产物并保存提交、来源、触发关联 ID。首次接入将本仓库现有 main 根目录 Pages 来源切换为 workflow；之后统一走该工作流。其他异常 Pages 来源直接报错。
4. publication.json 推送自动触发；没有新 publication 的既有版本复核通过 workflow_dispatch 触发。触发响应丢失时先按关联 ID 查任务，再有界重试；同一生产流水线不并行发布，旧提交在准备及晋升前必须仍是 main。
5. Actions Windows 作业先跑失败注入测试，并在隔离用户目录按稳定说明原命令验证首次准备与 v2.3.14 升级到目标版本。使用真实版本包和兼容报告 fixture，不启停真实引擎、不操作真实账号。
6. 后续作业核验标签和固定包，创建草稿 Release，上传并核对完整附件。已完成的附件不覆盖；摘要冲突即停止。中断遗留的零字节 starter 草稿占位可清除后重试。已有标签仅检查原固定清单，不移动到新提交。
7. 部署 Pages，实际下载入口、脚本、版本、索引、清单、当前与固定 ZIP；核对文件摘要和包内版本，缓存等待采用有界重试。
8. 仅本地、准备路径、附件与 Pages 都通过时正式发布并设置 Latest；再次通过公开 API 确认 Release、附件及 Latest，保存完整验收报告。

## 验收与恢复

Actions 保存 `release-verification-运行ID-尝试次数` 附件 90 天，Summary 同时显示 JSON；报告包含版本、源码快照、发布提交、运行 ID、各项检查、Release 和 Pages 地址。客户端只有在 Actions 成功、报告身份匹配且五项检查全部 passed 时才输出成功。本机状态与报告保存在维护仓库 `.local/environment-releases`。报告过期或丢失时重新复核，不能凭旧成功状态猜测。

同一版本重复执行复核原产物，标签和已发布附件保持不变。修改已发布固定包必须另起版本。流水线自身修复后，-Resume 允许接续到保持 publication 摘要不变的新 main 提交；发布内容改变则拒绝。修复应先在维护源修改，再同步生成副本、提交并推送。

GitHub/网络失败仍可能发生；程序保证失败不能被当作成功，并保留可查询、可接续的结果。两个远端系统不能原子切换，Pages 已部署但 Release 未晋升时报告仍是失败或运行中，接续完成最终跨入口核验。
