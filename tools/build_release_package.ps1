# tools/build_release_package.ps1 — Assembles 100% Clean BYO-ROM Self-Builder Release Package
param(
    [string]$Version = "v0.2.0",
    [switch]$IncludePrebuiltHost = $false
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

Write-Host "=== Building HaniwaBridge Clean Release Package ($Version) ===" -ForegroundColor Cyan

# 1. Clean and prepare dist directory
$Dist = Join-Path $Root "dist"
if (Test-Path $Dist) {
    Remove-Item -Recurse -Force $Dist
}
New-Item -ItemType Directory -Force -Path "$Dist\bin" | Out-Null
New-Item -ItemType Directory -Force -Path "$Dist\tools" | Out-Null
New-Item -ItemType Directory -Force -Path "$Dist\bridge" | Out-Null
New-Item -ItemType Directory -Force -Path "$Dist\port" | Out-Null

# 2. Export 64-Bit Godot Launcher
Write-Host "[1/5] Exporting HaniwaLauncher.exe via Godot 4 (64-bit)..." -ForegroundColor Yellow
if (Test-Path "Godot_v4.7.2-stable_win64.exe") {
    $launcherPath = ($Dist.Replace("\", "/")) + "/HaniwaLauncher.exe"
    .\Godot_v4.7.2-stable_win64.exe --headless --path godot --export-release "Windows Desktop" "$launcherPath"
} else {
    throw "Godot_v4.7.2-stable_win64.exe not found in project root."
}

# 3. Copy GDExtension bridge & open-source runtime DLLs
Write-Host "[2/5] Copying open-source runtime DLLs & GDExtension..." -ForegroundColor Yellow
Copy-Item -Force "godot\bin\acgc_shm_client_x64.dll" "$Dist\acgc_shm_client_x64.dll"
Copy-Item -Force "godot\bin\acgc_shm_client_x64.dll" "$Dist\bin\acgc_shm_client_x64.dll"
Copy-Item -Force "SDL2.dll" "$Dist\SDL2.dll"
Copy-Item -Force "libgcc_s_dw2-1.dll" "$Dist\libgcc_s_dw2-1.dll"
Copy-Item -Force "libstdc++-6.dll" "$Dist\libstdc++-6.dll"
Copy-Item -Force "libwinpthread-1.dll" "$Dist\libwinpthread-1.dll"
Copy-Item -Force "README.md" "$Dist\README.md"
Copy-Item -Force "LICENSE" "$Dist\LICENSE"

# 4. Copy build scripts & clean C sources for local compilation
Write-Host "[3/5] Copying clean source code & autonomous build tools..." -ForegroundColor Yellow
Copy-Item -Force "tools\build_host.bat" "$Dist\tools\build_host.bat"
Copy-Item -Force "tools\build_host.ps1" "$Dist\tools\build_host.ps1"

# Copy bridge/
Copy-Item -Recurse -Force "bridge" "$Dist\"

# Copy port/ excluding build32 cache & binary outputs
robocopy "port" "$Dist\port" /E /XD build32 /XF *.exe *.dll *.a *.obj *.o > $null
if ($LASTEXITCODE -ge 8) {
    throw "robocopy failed with exit code $LASTEXITCODE"
}

# Optional: developer test mode (strictly excluded from official release)
if ($IncludePrebuiltHost) {
    Write-Warning "DEVELOPER FLAG: Including prebuilt HaniwaHost.exe in dist/ for local testing."
    Copy-Item -Force "HaniwaHost.exe" "$Dist\HaniwaHost.exe"
} else {
    Write-Host "[4/5] Zero-Asset Guarantee: Prebuilt host is NOT included. User will compile locally via 1-click launcher." -ForegroundColor Green
}

# 5. Create Release ZIP Archive
Write-Host "[5/5] Creating release zip archive..." -ForegroundColor Yellow
$ArtifactsDir = Join-Path $Root "release_artifacts"
if (-not (Test-Path $ArtifactsDir)) {
    New-Item -ItemType Directory -Force -Path $ArtifactsDir | Out-Null
}
$ZipName = "HaniwaBridge-$Version-Windows-x64-Setup.zip"
$ZipPath = Join-Path $ArtifactsDir $ZipName
if (Test-Path $ZipPath) {
    Remove-Item -Force $ZipPath
}

# Native zip compression via tar or Compress-Archive
Push-Location $Dist
try {
    tar -a -cf $ZipPath *
} finally {
    Pop-Location
}

$zipSize = [math]::Round((Get-Item $ZipPath).Length / 1MB, 2)
Write-Host "=== SUCCESS: Release archive created! ===" -ForegroundColor Green
Write-Host "Path: $ZipPath ($zipSize MB)" -ForegroundColor Cyan
