# 正式环境发布

本仓库是发布产物仓库。维护源在相邻 know-star-gpt/docs/teaching。
正式发布必须调用维护源 teacher/Publish-Environment.ps1 -Version 目标版本；换窗口用 -Status 查询，失败用 -Resume 接续。禁止把直接 push、Pages 成功或单独 Release 当作发布完成。
唯一成功凭据是对应版本、提交和 Actions 运行的 release-verification.json，包含准备路径、附件、Pages、公开 Latest 全部 passed。历史版本与标签不得覆盖或移动。
自动化流程见 .release/README.md；发布实现维护于源码 teacher/release，不手改分发副本。
