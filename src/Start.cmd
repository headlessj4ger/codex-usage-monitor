@echo off
setlocal DisableDelayedExpansion
title Codex Usage Monitor
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -File "%~dp0launch.ps1" %*
set "monitor_exit=%errorlevel%"
if not "%monitor_exit%"=="0" (
  echo.
  echo Startup failed. See the message above or data\startup-error.log.
  pause
)
exit /b %monitor_exit%
