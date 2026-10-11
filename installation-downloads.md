# 放好两个安装包

## 第 1 步：下载

**在哪操作**：电脑浏览器。

任选一个入口，下载 `wsl.3.0.1.0.x64.msi` 和 `Docker Desktop Installer.exe`。已有文件直接使用。

- [公司内下载](https://clouddrive.huawei.com/p/2c5dce71d71908a8c0c64574ee5ba886)
- [公司外下载](https://pan.baidu.com/s/1so3HddPOXQVl790421DczQ?pwd=egiy)，提取码 **egiy**

**完成后**：两个文件都下载完成。先不用运行。

## 第 2 步：放好文件

**在哪操作**：Windows 文件夹。

在解压后的课程资料文件夹旁，新建 `release`，把两个安装包放进去，文件名保持不变。

```text
你的课程文件夹/
  knowstar-student-kit/       ← 解压后的资料
    index.html
    setup-guide.md
  release/                   ← 新建，与资料文件夹并列
    wsl.3.0.1.0.x64.msi
    Docker Desktop Installer.exe
```

通用资料包 `ai-coding-toolkit` 也采用同样摆放方式。

**检查**：release 里能看到两个完整安装文件。

## 第 3 步：交给 Trae

**在哪操作**：Trae。

打开解压后的资料文件夹，发送：

```text
请读取 setup-guide.md，安装课程助手，使用旁边 release 中的安装包准备并验证开发工具，完成后打开检查报告。现在先不创建作品。
```

**完成后**：`environment-checklist.md` 显示“已完成”。

<details><summary>下载或安装受限时</summary>

没有安装包时，助手会从官方地址自动下载、校验。安装受限时按助手指引自行安装，回到同一任务继续。

- [WSL 官方固定安装包](https://github.com/microsoft/WSL/releases/download/3.0.1/wsl.3.0.1.0.x64.msi)
- [Docker Desktop 官方下载与安装](https://docs.docker.com/desktop/setup/install/windows-install/)

Docker 是运行工具箱的程序，WSL 是它需要的系统组件。已有合格软件由助手检查后复用。

</details>
