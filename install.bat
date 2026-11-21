@echo off
setlocal
cd /d "%~dp0"
echo ============================================
echo   YQ CE-MCP  installer
echo ============================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
echo.
pause
