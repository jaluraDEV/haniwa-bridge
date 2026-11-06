@echo off
cd /d "%~dp0"
if exist "ACGC_Launcher.exe" (
    start "" "ACGC_Launcher.exe"
    exit /b 0
)
if exist "dist\ACGC_Launcher.exe" (
    cd /d "%~dp0dist"
    start "" "ACGC_Launcher.exe"
    exit /b 0
)
if exist "Godot_v4.7.2-stable_win64.exe" (
    start "" "Godot_v4.7.2-stable_win64.exe" --path godot
    exit /b 0
)
echo [HaniwaBridge] No prebuilt ACGC_Launcher.exe or Godot_v4.7.2-stable_win64.exe found in this source checkout.
echo Please download the ready-to-play release package (HaniwaBridge-v0.1.0-Windows-x64.zip) from:
echo   https://github.com/jaluraDEV/haniwa-bridge/releases/latest
pause
