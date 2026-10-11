@echo off
chcp 65001 >nul
echo 这个助手先检查电脑，再补齐 Docker Desktop 所需条件。
echo Windows 权限窗口出现时，请选择“是”。重启前请先保存工作。
set "AICODING_MANIFEST=%~dp0..\assets\windows-installers.json"
if exist "%~dp0windows-installers.json" set "AICODING_MANIFEST=%~dp0windows-installers.json"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-DockerDesktop.ps1" -Mode Prepare -ManifestPath "%AICODING_MANIFEST%" -WorkingDirectory "%CD%"
set "AICODING_SETUP_RESULT=%ERRORLEVEL%"
echo.
if "%AICODING_SETUP_RESULT%"=="0" echo 检查通过。回到 Trae，让它继续准备课程工具箱。
if "%AICODING_SETUP_RESULT%"=="3010" echo 请保存工作，选择 Windows 的“重启”，回来后双击同一个入口。
if not "%AICODING_SETUP_RESULT%"=="0" if not "%AICODING_SETUP_RESULT%"=="3010" echo 请按上面的“下一步”完成操作，再双击同一个入口。
echo 检查记录保存在当前目录的 .docker-setup 文件夹。
pause
exit /b %AICODING_SETUP_RESULT%
