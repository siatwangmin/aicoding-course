@echo off
setlocal EnableExtensions DisableDelayedExpansion
chcp 65001 >nul
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-CourseUninstall.ps1"
set "AICODING_UNINSTALL_RESULT=%ERRORLEVEL%"
echo.
echo 请保留上方的结果与接续入口。未完成项不能当作已卸载。
pause
exit /b %AICODING_UNINSTALL_RESULT%
