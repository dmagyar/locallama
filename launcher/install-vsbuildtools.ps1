<# Install Visual Studio 2022 Build Tools (C++ workload) #>
#> Required for the MSVC linker when building with oneAPI on Windows
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

function Log { param($msg) Write-Host "[VS] $msg" -ForegroundColor Cyan }
function Done { param($msg) Write-Host "[DONE] $msg" -ForegroundColor Green }

# Check if already installed
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vswhere) {
    $vsPath = & "$vswhere" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
    if ($vsPath) {
        Done "VS Build Tools already at: $vsPath"
        exit 0
    }
}

Log "Installing Visual Studio 2022 Build Tools..."
Log "This will take 10-15 minutes and download ~3-5 GB..."

# Download the bootstrap installer
$bootstrap = "C:\TEMP\vs_buildtools.exe"
if (!(Test-Path "C:\TEMP")) {
    New-Item -ItemType Directory -Path "C:\TEMP" -Force | Out-Null
}

if (!(Test-Path $bootstrap)) {
    Log "Downloading VS Build Tools bootstrap..."
    Invoke-WebRequest -Uri "https://aka.ms/vs/17/release/vs_buildtools.exe" -OutFile $bootstrap -UseBasicParsing
}

# Install with C++ workload (passive mode - shows progress but doesn't require interaction)
Log "Installing C++ Build Tools workload..."
$proc = Start-Process $bootstrap -ArgumentList `
    "--wait", "--passive", `
    "--add", "Microsoft.VisualStudio.Workload.VCTools", `
    "--includeRecommended", `
    "--norestart" `
    -Wait -PassThru -NoNewWindow

Log "Exit code: $($proc.ExitCode)"

# Verify
if (Test-Path $vswhere) {
    Start-Sleep -Seconds 5  # Give it time to register
    $vsPath = & "$vswhere" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
    if ($vsPath) {
        Done "VS Build Tools installed at: $vsPath"
    } else {
        Log "VS installer completed but vswhere didn't detect it. May need reboot or manual install."
        Log "Manual: https://visualstudio.microsoft.com/visual-cpp-build-tools/"
    }
} else {
    Log "VS Build Tools installation may have failed or needs reboot."
}

# Cleanup
Remove-Item $bootstrap -Force -ErrorAction SilentlyContinue
