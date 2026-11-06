# tools/build_release_package.ps1 — Builds 32-bit Host, 64-bit SHM Client DLL, and packages dist/
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

Write-Host "[1/4] Building 32-bit Headless Host (acgc_host_x86.exe)..."
$MsysDir = if (Test-Path "$env:USERPROFILE\msys64") { "$env:USERPROFILE\msys64" } else { "C:\msys64" }
$env:PATH = "$MsysDir\mingw32\bin;$MsysDir\usr\bin;" + $env:PATH
Push-Location "port/pc/build32"
ninja
bash -c "find CMakeFiles/ac_pc.dir -name '*.obj' > objects.rsp && ar rcs libacgc_port.a @objects.rsp && rm -f objects.rsp"
Pop-Location
bash -c "gcc -m32 -O2 -static-libgcc -static-libstdc++ -Wl,--large-address-aware -Wl,--disable-dynamicbase -Wl,--allow-multiple-definition -Ibridge/include -Iport/pc/include -Iport/include bridge/src/acgc_host.c bridge/src/acgc_api_impl.c -Lport/pc/build32 -Wl,--start-group port/pc/build32/libacgc_port.a port/pc/build32/libglad.a -Wl,--end-group -lSDL2 -lopengl32 -lwinmm -limm32 -lversion -lsetupapi -lkernel32 -luser32 -lgdi32 -lshell32 -lole32 -loleaut32 -luuid -lcomdlg32 -ladvapi32 -lstdc++ -o acgc_host_x86.exe"

Write-Host "[2/4] Preparing clean dist/ directory..."
if (Test-Path "dist") {
    Remove-Item -Recurse -Force "dist"
}
New-Item -ItemType Directory -Force -Path "dist/bin" | Out-Null
Copy-Item -Force "acgc_host_x86.exe" "dist/acgc_host_x86.exe"
Copy-Item -Force "SDL2.dll" "dist/SDL2.dll"
Copy-Item -Force "libgcc_s_dw2-1.dll" "dist/libgcc_s_dw2-1.dll"
Copy-Item -Force "libstdc++-6.dll" "dist/libstdc++-6.dll"
Copy-Item -Force "libwinpthread-1.dll" "dist/libwinpthread-1.dll"
Copy-Item -Force "godot/bin/acgc_shm_client_x64.dll" "dist/acgc_shm_client_x64.dll"
Copy-Item -Force "godot/bin/acgc_shm_client_x64.dll" "dist/bin/acgc_shm_client_x64.dll"
Copy-Item -Force "README.md" "dist/README.md"
Copy-Item -Force "LICENSE" "dist/LICENSE"

Write-Host "[3/4] Exporting ACGC_Launcher.exe via Godot 4 (64-bit)..."
if (Test-Path "Godot_v4.7.2-stable_win64.exe") {
    $distPath = (Resolve-Path "dist").Path.Replace("\", "/") + "/ACGC_Launcher.exe"
    .\Godot_v4.7.2-stable_win64.exe --headless --path godot --export-release "Windows Desktop" "$distPath"
}

Write-Host "[4/4] Package ready in dist/!"
