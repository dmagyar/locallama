<# Build llama-server.exe with SYCL + CPU backend for Windows #>
#> Prerequisites: oneAPI installed, CMake, Ninja, VS Build Tools
#> Run AFTER sourcing oneAPI: & 'C:\Program Files (x86)\Intel\oneAPI\setvars.ps1'; .\build-windows-sycl.ps1

$ErrorActionPreference = "Stop"

function Log { param($msg) Write-Host "[BUILD] $msg" -ForegroundColor Cyan }
function Done { param($msg) Write-Host "[DONE]  $msg" -ForegroundColor Green }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$rootDir = Split-Path -Parent $scriptDir
$llamaSrc = Join-Path $scriptDir "llama-src"
$buildDir = Join-Path $llamaSrc "build-sycl"
$outputDir = Join-Path $scriptDir "servers\windows-sycl"

# ============================================================
# Verify prerequisites
# ============================================================
Log "Verifying prerequisites..."

# oneAPI
$oneapiRoot = $null
foreach ($p in @("C:\Intel", "C:\Program Files (x86)\Intel\oneAPI")) {
    if (Test-Path "$p\setvars.bat") { $oneapiRoot = $p; break }
}
if (-not $oneapiRoot) {
    Write-Host "[ERROR] oneAPI not found. Install to C:\Intel or C:\Program Files (x86)\Intel\oneAPI" -ForegroundColor Red
    exit 1
}
Log "Sourcing oneAPI from: $oneapiRoot"
& "$oneapiRoot\setvars.bat"

# Check compiler
$icxPath = Get-Command icx 2>$null
if (-not $icxPath) {
    # Also check in oneAPI bin directly
    foreach ($cp in @("$oneapiRoot\compiler\latest\bin", "$oneapiRoot\compiler\2026.0\bin")) {
        if (Test-Path "$cp\icx.exe") {
            $env:PATH = "$cp;$env:PATH"
            $icxPath = Get-Command icx 2>$null
            break
        }
    }
}
if (-not $icxPath) {
    Write-Host "[ERROR] Intel compiler (icx.exe) not found" -ForegroundColor Red
    Write-Host "oneAPI may need VS Build Tools installed first" -ForegroundColor Yellow
    exit 1
}
Log "Intel compiler: $($icxPath.Source)"

# Check CMake
try { cmake --version | Select-String "cmake version" } catch {
    Write-Host "[ERROR] CMake not found. Run setup-windows-sycl.ps1 first." -ForegroundColor Red
    exit 1
}

# Check Ninja
try { ninja --version } catch {
    Write-Host "[ERROR] Ninja not found. Run setup-windows-sycl.ps1 first." -ForegroundColor Red
    exit 1
}

# Check llama-src
if (!(Test-Path (Join-Path $llamaSrc "CMakeLists.txt"))) {
    Write-Host "[ERROR] llama-src/CMakeLists.txt not found" -ForegroundColor Red
    Write-Host "Clone llama.cpp to: $llamaSrc" -ForegroundColor Yellow
    exit 1
}

# ============================================================
# Configure
# ============================================================
Log "Configuring SYCL build..."
if (!(Test-Path $buildDir)) {
    New-Item -ItemType Directory -Path $buildDir -Force | Out-Null
}

Push-Location $buildDir
try {
    cmake .. -G Ninja `
        -DCMAKE_BUILD_TYPE=Release `
        -DGGML_SYCL=ON `
        -DGGML_SYCL_TARGET=INTEL `
        -DGGML_SYCL_DNN=ON `
        -DGGML_SYCL_SUPPORT_LEVEL_ZERO_API=ON `
        -DGGML_SYCL_F16=OFF `
        -DGGML_SYCL_GRAPH=ON `
        -DGGML_CPU=ON `
        -DGGML_OPENMP=ON `
        -DBUILD_SHARED_LIBS=OFF `
        -DLLAMA_SERVER=ON `
        -DLLAMA_BUILD_EXAMPLES=OFF `
        -DLLAMA_BUILD_TESTS=OFF `
        -DCMAKE_C_COMPILER=icx `
        -DCMAKE_CXX_COMPILER=icx

    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] CMake configure failed" -ForegroundColor Red
        exit 1
    }
    Done "CMake configure complete"
} finally {
    Pop-Location
}

# ============================================================
# Build
# ============================================================
Log "Building llama-server with SYCL..."
Log "This will take 15-30 minutes (SYCL compilation is slow)..."

Push-Location $buildDir
try {
    ninja llama-server -j $(([Environment]::ProcessorCount) - 1)

    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Build failed" -ForegroundColor Red
        exit 1
    }
    Done "llama-server built successfully"
} finally {
    Pop-Location
}

# ============================================================
# Collect artifacts
# ============================================================
Log "Collecting server + DLLs..."

if (Test-Path $outputDir) {
    Remove-Item $outputDir -Recurse -Force
}
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

# Server binary
$serverSrc = Join-Path $buildDir "bin\llama-server.exe"
Copy-Item $serverSrc $outputDir
$serverSize = (Get-Item (Join-Path $outputDir "llama-server.exe")).Length
Log "llama-server.exe: $([math]::Round($serverSize/1MB, 1)) MB"

# ============================================================
# Collect oneAPI runtime DLLs
# ============================================================
$oneapiBin = "$oneapiRoot\compiler\latest\windows"
if (!(Test-Path $oneapiBin)) { $oneapiBin = "$oneapiRoot\compiler\2026.0\bin" }

# Intel runtime DLLs needed at runtime
$requiredDlls = @(
    "libmimalloc-*",
    "svml_dispmd.dll",
    "libsvml.dll",
    "libirngmd.dll",
    "libintlcmd.dll",
    "libimfmd.dll",
    "libircmd.dll",
    "libopenclmd.dll",
    "pi_level_zero.dll",
    "ze_loader.dll",
    "mkl_*",
    "tbb*",
    "libippvp*",
    "libippcore*"
)

$foundDlls = 0
foreach ($pattern in $requiredDlls) {
    $matches = Get-ChildItem $oneapiBin -Filter $pattern -ErrorAction SilentlyContinue
    foreach ($dll in $matches) {
        Copy-Item $dll.FullName $outputDir
        $foundDlls++
        Log "  + $($dll.Name)"
    }
}

# Also check the redist folder
$redistDir = "$oneapiRoot\compiler\latest\redist\windows"
if (!(Test-Path $redistDir)) { $redistDir = "$oneapiRoot\compiler\2026.0\redist\windows" }
if (Test-Path $redistDir) {
    Log "Collecting redistributable DLLs..."
    Get-ChildItem $redistDir -Filter "*.dll" -Recurse | ForEach-Object {
        Copy-Item $_.FullName $outputDir -ErrorAction SilentlyContinue
        $foundDlls++
    }
}

# MinGW runtime DLLs (from existing windows build)
$mingwDir = Join-Path $scriptDir "servers\windows"
foreach ($dll in @("libgcc_s_seh-1.dll", "libstdc++-6.dll", "libwinpthread-1.dll")) {
    $src = Join-Path $mingwDir $dll
    if (Test-Path $src) {
        Copy-Item $src $outputDir
        Log "  + $dll (MinGW runtime)"
    }
}

# Level Zero loader
$zeLoaderPaths = @(
    "C:\Windows\System32\ze_loader.dll",
    "$oneapiRoot\level-zero\latest\bin\ze_loader.dll",
    "$oneapiRoot\compiler\latest\redist\windows\ze_loader.dll"
)
foreach ($zePath in $zeLoaderPaths) {
    if (Test-Path $zePath) {
        Copy-Item $zePath $outputDir -Force
        Log "  + ze_loader.dll (Level Zero)"
        break
    }
}

# ============================================================
# Summary
# ============================================================
$dllCount = (Get-ChildItem $outputDir -Filter "*.dll").Count
$totalSize = (Get-ChildItem $outputDir | Measure-Object -Property Length -Sum).Sum

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "SYCL Build Complete!" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host "Output: $outputDir" -ForegroundColor Cyan
Write-Host "Files: llama-server.exe + $dllCount DLLs" -ForegroundColor Cyan
Write-Host "Total: $([math]::Round($totalSize/1MB, 1)) MB" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next: Copy $outputDir to Linux build machine" -ForegroundColor Yellow
Write-Host "Then run: ./launcher/assemble-windows-sycl.sh" -ForegroundColor Yellow
Write-Host "============================================" -ForegroundColor Green
