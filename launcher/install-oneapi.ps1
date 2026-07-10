<# Install Intel oneAPI toolkit for SYCL compilation #>
#> Uses online installer (small bootstrap, downloads on demand)
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

function Log { param($msg) Write-Host "[ONEAPI] $msg" -ForegroundColor Cyan }
function Done { param($msg) Write-Host "[DONE]   $msg" -ForegroundColor Green }

# Check if already installed
$oneapiSetvars = "C:\Program Files (x86)\Intel\oneAPI\setvars.ps1"
if (Test-Path $oneapiSetvars) {
    Done "oneAPI already installed"
    exit 0
}

# Check disk space
$freeGB = [math]::Round((Get-PSDrive C).Free / 1GB, 1)
Log "Free disk space: ${freeGB} GB"

# Try multiple download URLs for the online installer
$urls = @(
    # Online installer URLs (small bootstrap ~50MB)
    "https://registrationcenter-download.intel.com/akdlm/IRC_NAS/f2b344e7-abfa-4915-8ade-2b44e46bd78d/w_BaseKit_p_latest_online.exe",
    "https://devicecloud.intel.com/Intel%20oneAPI/w_BaseKit_p_latest_online.exe",
    # Fallback: try to get URL from Intel's redirect page
)

$installer = "C:\TEMP\oneapi-online.exe"
if (!(Test-Path "C:\TEMP")) {
    New-Item -ItemType Directory -Path "C:\TEMP" -Force | Out-Null
}

$downloaded = $false
foreach ($url in $urls) {
    Log "Trying: $url"
    try {
        Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing -TimeoutSec 30
        $sizeMB = [math]::Round((Get-Item $installer).Length / 1MB, 1)
        Log "Downloaded: ${sizeMB} MB"
        if ($sizeMB -gt 10) {  # Online installer should be at least 10MB
            $downloaded = $true
            break
        }
        Remove-Item $installer -Force
    } catch {
        Log "Failed: $_"
    }
}

if (-not $downloaded) {
    Log "Direct URLs failed. Trying Intel download page redirect..."
    try {
        # Try the Intel download portal
        $response = Invoke-WebRequest -Uri "https://www.intel.com/content/www/us/en/developer/tools/oneapi/base-toolkit/download.html" -UseBasicParsing -MaximumRedirection 0 -ErrorAction SilentlyContinue
        if ($response.BaseResponse.ResponseUri) {
            Log "Redirect found: $($response.BaseResponse.ResponseUri)"
            Invoke-WebRequest -Uri $response.BaseResponse.ResponseUri -OutFile $installer -UseBasicParsing
            $downloaded = (Test-Path $installer) -and ((Get-Item $installer).Length -gt 1MB)
        }
    } catch {}
}

if (-not $downloaded) {
    Log "All automated download methods failed."
    Log "Manual option: Download from https://www.intel.com/content/www/us/en/developer/tools/oneapi/base-toolkit/download.html"
    Log "Select 'Windows' and 'Online Installer', save to C:\TEMP\oneapi-online.exe"
    Log "Then re-run this script."

    # Try one more approach - the Intel API endpoint
    Log "Trying Intel API endpoint..."
    try {
        $apiUrl = "https://api.intel.com/downloads/v1/basekit/windows/latest"
        $apiResp = Invoke-WebRequest -Uri $apiUrl -UseBasicParsing -TimeoutSec 15
        Log "API response: $($apiResp.Content.Substring(0, [Math]::Min(200, $apiResp.Content.Length)))"
    } catch {
        Log "API also failed: $_"
    }

    exit 1
}

# Install silently
Log "Installing oneAPI Base Toolkit (online installer, silent mode)..."
Log "This will download ~2GB of components and install. Expect 15-30 minutes..."

# The online installer is an executable that we run with silent flags
$proc = Start-Process $installer -ArgumentList "--silent --eula accept --action install --install-dir `"C:\Program Files (x86)\Intel\oneAPI`" --include-path" -Wait -NoNewWindow -PassThru

Log "Installer exit code: $($proc.ExitCode)"

# Verify
if (Test-Path $oneapiSetvars) {
    Done "oneAPI Base Toolkit installed successfully"

    # Check for key components
    $compilerDir = "C:\Program Files (x86)\Intel\oneAPI\compiler"
    $mklDir = "C:\Program Files (x86)\Intel\oneAPI\mkl"

    if (Test-Path $compilerDir) { Done "Compiler found" } else { Log "Compiler NOT found" }
    if (Test-Path $mklDir) { Done "MKL found" } else { Log "MKL NOT found (may need HPC Toolkit)" }

    # Cleanup
    Remove-Item $installer -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "[ERROR] oneAPI installation may have failed" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "oneAPI installation complete!" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
