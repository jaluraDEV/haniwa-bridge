# tools/build_host.ps1 — 1-Click Autonomous Builder for HaniwaHost.exe
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $PSScriptRoot
Set-Location $ScriptDir

function Set-BuildProgress([double]$percent, [string]$msg) {
    Write-Host $msg
    $content = "$percent`n$msg"
    try { [System.IO.File]::WriteAllText("$ScriptDir\build_progress.txt", $content) } catch {}
}

Set-BuildProgress 5 "[1/4] Discovering compiler toolchain..."

# 1. Discover Toolchain
$MsysCandidates = @(
    "$env:USERPROFILE\msys64",
    "C:\msys64",
    "D:\msys64",
    "$ScriptDir\tools\compiler"
)

$MsysDir = ""
foreach ($cand in $MsysCandidates) {
    if ((Test-Path "$cand\mingw32\bin\gcc.exe") -and (Test-Path "$cand\mingw32\bin\ninja.exe")) {
        $MsysDir = $cand
        break
    }
}

if ($MsysDir -ne "") {
    Set-BuildProgress 25 "[1/4] Found MinGW32 toolchain at: $MsysDir"
    $env:PATH = "$MsysDir\mingw32\bin;$MsysDir\usr\bin;" + $env:PATH
} else {
    # Check if gcc and ninja are already in PATH
    $gccCheck = Get-Command gcc -ErrorAction SilentlyContinue
    $ninjaCheck = Get-Command ninja -ErrorAction SilentlyContinue
    if (-not $gccCheck -or -not $ninjaCheck) {
        Set-BuildProgress 10 "[1/4] Preparing portable build tools..."
        $CompilerDir = Join-Path $ScriptDir "tools\compiler"
        if (-not (Test-Path $CompilerDir)) {
            New-Item -ItemType Directory -Force -Path $CompilerDir | Out-Null
        }

        # Check if winget is available for automatic installation
        $winget = Get-Command winget -ErrorAction SilentlyContinue
        if ($winget) {
            Set-BuildProgress 15 "Attempting silent setup via Windows Package Manager (winget)..."
            try {
                & winget install --id MSYS2.MSYS2 --silent --accept-source-agreements --accept-package-agreements --disable-interactivity
                if (Test-Path "C:\msys64\mingw32\bin\gcc.exe") {
                    $MsysDir = "C:\msys64"
                    $env:PATH = "$MsysDir\mingw32\bin;$MsysDir\usr\bin;" + $env:PATH
                }
            } catch {
                Write-Host "winget installation skipped, trying direct archive download..." -ForegroundColor Gray
            }
        }

        # Fallback: direct portable toolchain download
        if ($MsysDir -eq "") {
            $DownloadUrl = "https://github.com/jaluraDEV/haniwa-bridge/releases/download/tools-v1.0/haniwa-toolchain-win32.zip"
            $ZipPath = Join-Path $CompilerDir "toolchain.zip"
            Set-BuildProgress 18 "Downloading portable toolchain archive (~45 MB)..."
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                Invoke-WebRequest -Uri $DownloadUrl -OutFile $ZipPath -UseBasicParsing
                Set-BuildProgress 22 "Extracting toolchain via native tar..."
                tar -xf $ZipPath -C $CompilerDir
                Remove-Item -Force $ZipPath -ErrorAction SilentlyContinue
                if (Test-Path "$CompilerDir\mingw32\bin\gcc.exe") {
                    $MsysDir = "$CompilerDir"
                    $env:PATH = "$MsysDir\mingw32\bin;$MsysDir\usr\bin;" + $env:PATH
                }
            } catch {
                Write-Warning "Direct toolchain download failed: $_"
            }
        }

        if ($MsysDir -eq "") {
            Write-Error "Could not configure a 32-bit MinGW toolchain. Please install MSYS2 manually (https://www.msys2.org/) with mingw-w64-i686-gcc and mingw-w64-i686-ninja."
            exit 1
        }
    } else {
        Set-BuildProgress 25 "[1/4] Using system PATH toolchain..."
    }
}

# 2. Configure CMake if build.ninja is missing
$BuildDir = Join-Path $ScriptDir "port\pc\build32"
if (-not (Test-Path $BuildDir)) {
    New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
}

Push-Location $BuildDir
try {
    if (-not (Test-Path "build.ninja")) {
        Set-BuildProgress 35 "[2/4] Configuring CMake project with Ninja..."
        cmake -G Ninja ..
        if ($LASTEXITCODE -ne 0) { throw "CMake configuration failed." }
    } else {
        Set-BuildProgress 40 "[2/4] CMake project already configured."
    }

    # 3. Compile port objects via Ninja
    Set-BuildProgress 45 "[3/4] Checking build targets (Ninja)..."
    & ninja 2>&1 | ForEach-Object {
        $line = $_.ToString().Trim()
        if ($line -match '\[\s*(\d+)/(\d+)\]\s*(.*)') {
            $cur = [int]$matches[1]
            $tot = [int]$matches[2]
            $pct = 45 + [math]::Round(($cur / [math]::Max($tot, 1)) * 35, 1)
            $action = $matches[3]
            if ($action.Length -gt 55) { $action = "..." + $action.Substring($action.Length - 52) }
            Set-BuildProgress $pct "[$cur/$tot] $action"
        } elseif ($line -ne "") {
            Write-Host $line
            if ($line -like "*no work to do*") {
                Set-BuildProgress 75 "[3/4] All objects up to date."
            }
        }
    }
    if ($LASTEXITCODE -ne 0) { throw "Ninja compilation failed." }

    # Pack libacgc_port.a
    Set-BuildProgress 82 "Packing static archive libacgc_port.a..."
    bash -c "find CMakeFiles/ac_pc.dir -name '*.obj' > objects.rsp && ar rcs libacgc_port.a @objects.rsp && rm -f objects.rsp"
} finally {
    Pop-Location
}

# 4. Link HaniwaHost.exe
Set-BuildProgress 88 "[4/4] Linking HaniwaHost.exe..."
bash -c "gcc -m32 -O2 -static-libgcc -static-libstdc++ -Wl,--large-address-aware -Wl,--disable-dynamicbase -Wl,--allow-multiple-definition -Ibridge/include -Iport/pc/include -Iport/include bridge/src/acgc_host.c bridge/src/acgc_api_impl.c -Lport/pc/build32 -Wl,--start-group port/pc/build32/libacgc_port.a port/pc/build32/libglad.a -Wl,--end-group -lSDL2 -lopengl32 -lwinmm -limm32 -lversion -lsetupapi -lkernel32 -luser32 -lgdi32 -lshell32 -lole32 -loleaut32 -luuid -lcomdlg32 -ladvapi32 -lstdc++ -o HaniwaHost.exe"

# Copy runtime DLLs next to HaniwaHost.exe
Set-BuildProgress 95 "Verifying runtime DLLs..."
if ($MsysDir -ne "") {
    Copy-Item -Force "$MsysDir\mingw32\bin\SDL2.dll" "$ScriptDir\SDL2.dll" -ErrorAction SilentlyContinue
    Copy-Item -Force "$MsysDir\mingw32\bin\libgcc_s_dw2-1.dll" "$ScriptDir\libgcc_s_dw2-1.dll" -ErrorAction SilentlyContinue
    Copy-Item -Force "$MsysDir\mingw32\bin\libstdc++-6.dll" "$ScriptDir\libstdc++-6.dll" -ErrorAction SilentlyContinue
    Copy-Item -Force "$MsysDir\mingw32\bin\libwinpthread-1.dll" "$ScriptDir\libwinpthread-1.dll" -ErrorAction SilentlyContinue
}

if (Test-Path "$ScriptDir\HaniwaHost.exe") {
    Set-BuildProgress 100 "=== SUCCESS: HaniwaHost.exe is ready! ==="
    exit 0
} else {
    Write-Error "Link finished but HaniwaHost.exe was not created."
    exit 1
}
