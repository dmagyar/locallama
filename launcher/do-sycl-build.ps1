<#
Full SYCL build script for Windows.
Prerequisites: oneAPI at C:\Intel, VS Build Tools installed, CMake, Ninja, llama-src present.
Run as Administrator.
#>
$ErrorActionPreference = "Stop"

function Log { param($msg) Write-Host "[BUILD] $msg" -ForegroundColor Cyan }
function Done { param($msg) Write-Host "[DONE]  $msg" -ForegroundColor Green }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$llamaSrc = Join-Path $scriptDir "llama-src"
$buildDir = Join-Path $llamaSrc "build-sycl"
$outputDir = Join-Path $scriptDir "servers\windows-sycl"

# ============================================================
# 1. Setup environment
# ============================================================
Log "Setting up oneAPI environment..."
$oneapiRoot = $null
foreach ($p in @("C:\Intel", "C:\Program Files (x86)\Intel\oneAPI")) {
    if (Test-Path "$p\setvars.bat") { $oneapiRoot = $p; break }
}
if (-not $oneapiRoot) {
    Write-Host "[ERROR] oneAPI not found" -ForegroundColor Red; exit 1
}
& "$oneapiRoot\setvars.bat"
Log "oneAPI: $oneapiRoot"

# Source VS environment
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vswhere) {
    $vsPath = & "$vswhere" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
    if ($vsPath) {
        Log "VS Build Tools: $vsPath"
        & "$vsPath\VC\Auxiliary\Build\vcvars64.bat" | Invoke-Expression
    }
}

# Verify compiler
$icx = Get-Command icx 2>$null
if (-not $icx) {
    Write-Host "[ERROR] icx compiler not found after sourcing environments" -ForegroundColor Red; exit 1
}
Log "Compiler: $($icx.Source)"

# ============================================================
# 2. Configure CMake
# ============================================================
Log "Configuring SYCL build..."
if (!(Test-Path $buildDir)) { New-Item -ItemType Directory -Path $buildDir -Force | Out-Null }

Push-Location $buildDir
try {
    $cmakeArgs = @(
        "..", "-G", "Ninja",
        "-DCMAKE_BUILD_TYPE=Release",
        "-DGGML_SYCL=ON",
        "-DGGML_SYCL_TARGET=INTEL",
        "-DGGML_SYCL_DNN=ON",
        "-DGGML_SYCL_SUPPORT_LEVEL_ZERO_API=ON",
        "-DGGML_SYCL_F16=OFF",
        "-DGGML_SYCL_GRAPH=ON",
        "-DGGML_CPU=ON",
        "-DGGML_OPENMP=ON",
        "-DBUILD_SHARED_LIBS=OFF",
        "-DLLAMA_SERVER=ON",
        "-DLLAMA_BUILD_EXAMPLES=OFF",
        "-DLLAMA_BUILD_TESTS=OFF"
    )

    Log "Running: cmake $($cmakeArgs -join ' ')"
    cmake @cmakeArgs
    if ($LASTEXITCODE -ne 0) { Write-Host "[ERROR] CMake configure failed" -ForegroundColor Red; exit 1 }
    Done "CMake configure complete"
} finally { Pop-Location }

# ============================================================
# 3. Build
# ============================================================
Log "Building llama-server with SYCL..."
Log "This will take 15-30 minutes (SYCL compilation is slow)..."

Push-Location $buildDir
try {
    $jobs = [Math]::Max(1, $([Environment]::ProcessorCount) - 1)
    Log "Using $jobs parallel jobs"
    ninja llama-server -j $jobs
    if ($LASTEXITCODE -ne 0) { Write-Host "[ERROR] Build failed" -ForegroundColor Red; exit 1 }
    Done "llama-server built successfully"
} finally { Pop-Location }

# ============================================================
# 4. Collect artifacts
# ============================================================
Log "Collecting server + DLLs..."
if (Test-Path $outputDir) { Remove-Item $outputDir -Recurse -Force }
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

# Server binary
Copy-Item (Join-Path $buildDir "bin\llama-server.exe") $outputDir
$serverSize = (Get-Item (Join-Path $outputDir "llama-server.exe")).Length
Log "llama-server.exe: $([math]::Round($serverSize/1MB, 1)) MB"

# oneAPI runtime DLLs
$compilerBin = "$oneapiRoot\compiler\latest\windows"
$redistDir = "$oneapiRoot\compiler\latest\redist\windows"
if (!(Test-Path $compilerBin)) { $compilerBin = "$oneapiRoot\compiler\2026.0\bin" }
if (!(Test-Path $redistDir)) { $redistDir = "$oneapiRoot\compiler\2026.0\redist\windows" }

$dllPatterns = @(
    "svml_dispmd.dll", "libsvml.dll", "libirngmd.dll", "libintlcmd.dll",
    "libimfmd.dll", "libircmd.dll", "libopenclmd.dll", "pi_level_zero.dll",
    "ze_loader.dll", "tbb*", "mkl_*", "libippvp*", "libippcore*",
    "libmimalloc-*"
)

$foundDlls = 0
foreach ($dir in @($compilerBin, $redistDir)) {
    if (!(Test-Path $dir)) { continue }
    foreach ($pattern in $dllPatterns) {
        Get-ChildItem $dir -Filter $pattern -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item $_.FullName $outputDir -Force
            $foundDlls++
            Log "  + $($_.Name)"
        }
    }
}

# MinGW runtime DLLs
$mingwDir = Join-Path $scriptDir "servers\windows"
foreach ($dll in @("libgcc_s_seh-1.dll", "libstdc++-6.dll", "libwinpthread-1.dll")) {
    $src = Join-Path $mingwDir $dll
    if (Test-Path $src) {
        Copy-Item $src $outputDir; $foundDlls++
        Log "  + $dll (MinGW runtime)"
    }
}

# Level Zero loader (system)
if (Test-Path "C:\Windows\System32\ze_loader.dll") {
    Copy-Item "C:\Windows\System32\ze_loader.dll" $outputDir -Force
    Log "  + ze_loader.dll (system)"
}

# ============================================================
# 5. Summary
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
