@echo off
setlocal
cd /d "%~dp0\.."
echo [HaniwaBridge] Starting autonomous build for HaniwaHost.exe...
powershell -ExecutionPolicy Bypass -File tools\build_host.ps1
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo [ERROR] Build failed! Check the output above.
    pause
    exit /b %ERRORLEVEL%
)
echo.
echo [HaniwaBridge] Build finished successfully. You can now launch HaniwaLauncher.exe!
pause
