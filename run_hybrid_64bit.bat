@echo off
setlocal
rem ACGC Hybrid (Plan B) — 32-bit headless host + 64-bit Godot renderer.
rem Run from the project root. Requires acgc_host_x86.exe (tools/build_host.sh)
rem and godot/bin/acgc_shm_client_x64.dll (tools/build_client_x64.sh) to be built.
cd /d "%~dp0"

rem Quick start follows the normal save/player load; never force demo scene 7.
set "GODOT_PLAYTEST_ARGS="
if /I "%~1"=="--quick-start" set "GODOT_PLAYTEST_ARGS=-- --quick-start"
if defined GODOT_PLAYTEST_ARGS echo [Hybrid] Quick start: auto-confirm title/player greeting; Escape cancels.

rem Terminate any stale host process that might still lock shared memory.
taskkill /IM acgc_host_x86.exe /F >nul 2>&1

echo [Hybrid] Starting 32-bit headless host (acgc_host_x86.exe)...
start "acgc_host_x86" /min cmd /c "acgc_host_x86.exe --rom rom/animal_crossing.iso > host.log 2>&1"

rem Give the host a moment to create the shared-memory mapping and boot.
timeout /t 2 /nobreak >nul

echo [Hybrid] Starting 64-bit Godot renderer...
rem Run the SHM consumer entry point (shm_main.tscn), NOT the default main.tscn:
rem main.tscn uses the in-process 32-bit ACGCBridge which cannot load in 64-bit Godot.
Godot_v4.7.2-stable_win64.exe --path godot res://shm_main.tscn %GODOT_PLAYTEST_ARGS%

echo [Hybrid] Godot exited; stopping the 32-bit host...
rem Graceful path: main.gd calls send_exit_signal() on shutdown (sets the SHM
rem exit flag). taskkill below is the reliable fallback for crashes/aborts.
timeout /t 1 /nobreak >nul
taskkill /IM acgc_host_x86.exe /F >nul 2>&1

echo [Hybrid] Done.
