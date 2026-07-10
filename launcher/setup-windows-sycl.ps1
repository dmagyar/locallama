<# Setup script for Windows SYCL build environment #>
#> Run as Administrator
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

function Log { param($msg) Write-Host "[SETUP] $msg" -ForegroundColor Cyan }
function Done { param($msg) Write-Host "[DONE]  $msg" -ForegroundColor Green }

# ============================================================
# STEP 1: Install CMake
# ============================================================
Log "Checking CMake..."
if (Get-Command cmake -ErrorAction SilentlyContinue) {
    Done "CMake already installed"
} else {
    Log "Installing CMake..."
    $cmakeUrl = "https://github.com/Kitware/CMake/releases/download/v3.31.6/cmake-3.31.6-windows-x86_64.msi"
    $cmakeMsi = "$env:TEMP\cmake.msi"
    if (!(Test-Path $cmakeMsi)) {
        Log "Downloading CMake..."
        Invoke-WebRequest -Uri $cmakeUrl -OutFile $cmakeMsi -UseBasicParsing
    }
    Log "Installing CMake silently..."
    Start-Process msiexec.exe -ArgumentList "/i `"$cmakeMsi`" /quiet /norestart ALLUSERS=1 ADD_CMAKE_TO_PATH=1" -Wait -NoNewWindow
    Done "CMake installed"
}

# ============================================================
# STEP 2: Install Ninja
# ============================================================
Log "Checking Ninja..."
if (Get-Command ninja -ErrorAction SilentlyContinue) {
    Done "Ninja already installed"
} else {
    Log "Installing Ninja..."
    $ninjaZip = "$env:TEMP\ninja.zip"
    $ninjaDir = "C:\ninja"
    if (!(Test-Path $ninjaZip)) {
        $ninjaUrl = "https://github.com/ninja-build/ninja/releases/download/v1.12.1/ninja-win.zip"
        Log "Downloading Ninja..."
        Invoke-WebRequest -Uri $ninjaUrl -OutFile $ninjaZip -UseBasicParsing
    }
    if (!(Test-Path $ninjaDir)) {
        New-Item -ItemType Directory -Path $ninjaDir -Force | Out-Null
    }
    Expand-Archive -Path $ninjaZip -DestinationPath $ninjaDir -Force
    [Environment]::SetEnvironmentVariable("PATH", "$ninjaDir;$([Environment]::GetEnvironmentVariable('PATH','Machine'))", "Machine")
    Done "Ninja installed"
}

# ============================================================
# STEP 3: Install VS Build Tools (if not present)
# ============================================================
Log "Checking Visual Studio Build Tools..."
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsInstalled = $false
if (Test-Path $vswhere) {
    $vsPath = & "$vswhere" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
    if ($vsPath) {
        Log "VS Build Tools found at: $vsPath"
        $vsInstalled = $true
    }
}

if (-not $vsInstalled) {
    Log "Visual Studio Build Tools not found. Installing via winget..."
    Log "NOTE: This may take 10-15 minutes and require reboot."
    winget install --id Microsoft.VisualStudio.2022.BuildTools `
        --override "--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended" `
        --accept-source-agreements --accept-package-agreements 2>$null
    if ($LASTEXITCODE -eq 0) {
        Done "VS Build Tools installed"
    } else {
        Write-Host "[WARN] VS Build Tools install may need manual completion or reboot" -ForegroundColor Yellow
    }
} else {
    Done "VS Build Tools already installed"
}

# ============================================================
# STEP 4: Check if oneAPI is installed
# ============================================================
Log "Checking oneAPI..."
$oneapiSetvars = "C:\Program Files (x86)\Intel\oneAPI\setvars.ps1"
if (Test-Path $oneapiSetvars) {
    Done "oneAPI already installed"
} else {
    Log "oneAPI NOT installed yet. Run install-oneapi.ps1 next."
}

# ============================================================
# SUMMARY
# ============================================================
Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "Setup Status:" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green

try { cmake --version | Select-String "cmake version" } catch { Write-Host "CMake: MISSING" -ForegroundColor Red }
try { ninja --version } catch { Write-Host "Ninja: MISSING" -ForegroundColor Red }

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vswhere) {
    $vsPath = & "$vswhere" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
    if ($vsPath) { Write-Host "VS Build Tools: OK" -ForegroundColor Green } else { Write-Host "VS Build Tools: MISSING" -ForegroundColor Red }
} else { Write-Host "VS Build Tools: MISSING" -ForegroundColor Red }

if (Test-Path $oneapiSetvars) { Write-Host "oneAPI: OK" -ForegroundColor Green } else { Write-Host "oneAPI: NOT INSTALLED (run install-oneapi.ps1)" -ForegroundColor Yellow }

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
