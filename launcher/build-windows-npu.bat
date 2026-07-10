@echo off
setlocal enabledelayedexpansion

REM ============================================================
REM Build llama-server.exe with Vulkan + OpenVINO (GPU + NPU)
REM Run on Windows. Output: servers\windows-npu\ directory
REM Then copy that dir to your Linux build machine and run
REM   ./assemble-windows-npu.sh  (auto-created, or see README)
REM ============================================================

echo ============================================
REM Check for admin
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo WARNING: Not running as Administrator.
    echo Some installs (winget, mklink) may fail.
    echo Right-click and "Run as administrator" for best results.
    echo.
)
echo Ollama Local — GPU + NPU Server Build
echo ============================================
echo.

REM --- Configuration ---
set "OPENVINO_VERSION_MAJOR=2026.2"
set "OPENVINO_VERSION_FULL=2026.2.0.21903.52ddc073857"

set "SCRIPT_DIR=%~dp0"
set "CD_ROOT=%SCRIPT_DIR%.."
set "LLAMA_SRC=%SCRIPT_DIR%llama-src"
set "VCPKG_DIR=C:\vcpkg"
set "OPENVINO_INSTALL_DIR=C:\Intel\openvino_%OPENVINO_VERSION_MAJOR%"
set "OPENVINO_LINK_DIR=C:\Intel\openvino"
set "OPENVINO_ZIP=%CD_ROOT%\openvino.zip"
set "OPENVINO_URL=https://storage.openvinotoolkit.org/repositories/openvino/packages/%OPENVINO_VERSION_MAJOR%/windows/openvino_toolkit_windows_%OPENVINO_VERSION_FULL%_x86_64.zip"
set "OUTPUT_DIR=%SCRIPT_DIR%servers\windows-npu"

REM ============================================================
REM STEP 0: Prerequisites
REM ============================================================
echo [0/5] Checking prerequisites...

where git >nul 2>nul || (
    echo [+] Installing Git...
    winget install --id Git.Git -e --accept-source-agreements --accept-package-agreements
)
where ninja >nul 2>nul || (
    echo [+] Installing Ninja...
    winget install --id Ninja-build.Ninja -e --accept-source-agreements --accept-package-agreements
)
where cmake >nul 2>nul || (
    echo [+] Installing CMake...
    winget install --id Kitware.CMake -e --accept-source-agreements --accept-package-agreements
)

REM Visual Studio Build Tools
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
set "VS_INSTALLED="
if exist "%VSWHERE%" (
    for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2^>nul`) do (
        set "VS_INSTALLED=%%i"
    )
)
if defined VS_INSTALLED (
    echo [ok] VS Build Tools: !VS_INSTALLED!
    call "!VS_INSTALLED!\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
) else (
    echo [+] Installing VS Build Tools...
    winget install --id Microsoft.VisualStudio.2022.BuildTools -e --override "--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended" --accept-source-agreements --accept-package-agreements
    if errorlevel 1 (
        echo [!!] Install VS Build Tools manually: https://aka.ms/vs/17/release/vs_BuildTools.exe
        echo     Then re-run from "Developer Command Prompt for VS 2022"
        pause & exit /b 1
    )
)
echo.

REM ============================================================
REM STEP 1: vcpkg + Vulkan
REM ============================================================
echo [1/5] Setting up vcpkg + Vulkan...
if not exist "%VCPKG_DIR%\vcpkg.exe" (
    echo [+] Cloning vcpkg...
    git clone https://github.com/microsoft/vcpkg "%VCPKG_DIR%"
    cd /d "%VCPKG_DIR%"
    call bootstrap-vcpkg.bat >nul 2>&1
    call vcpkg integrate install >nul 2>&1
)
cd /d "%VCPKG_DIR%"
call vcpkg install vulkan-hpp:x64-windows opencl:x64-windows
cd /d "%SCRIPT_DIR%"
echo.

REM ============================================================
REM STEP 2: OpenVINO Runtime
REM ============================================================
echo [2/5] Setting up OpenVINO...
if exist "%OPENVINO_INSTALL_DIR%\setupvars.bat" (
    echo [ok] OpenVINO already at "%OPENVINO_INSTALL_DIR%"
) else (
    if not exist "%OPENVINO_ZIP%" (
        echo [+] Downloading OpenVINO (~500MB)...
        powershell -Command "& {[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri '%OPENVINO_URL%' -OutFile '%OPENVINO_ZIP%'}"
        if errorlevel 1 (echo [!!] Download failed & pause & exit /b 1)
    )
    echo [+] Extracting...
    if not exist "%OPENVINO_INSTALL_DIR%" mkdir "%OPENVINO_INSTALL_DIR%"
    powershell -Command "& {Add-Type -AssemblyName System.IO.Compression.FileSystem; [System.IO.Compression.ZipFile]::ExtractToDirectory('%OPENVINO_ZIP%', '%OPENVINO_INSTALL_DIR%_tmp')}"
    for /d %%D in ("%OPENVINO_INSTALL_DIR%_tmp\*") do (
        robocopy "%%D" "%OPENVINO_INSTALL_DIR%" /E /NJH /NJS /NFL /NDL >nul
    )
    rmdir /s /q "%OPENVINO_INSTALL_DIR%_tmp" 2>nul
)

if exist "%OPENVINO_LINK_DIR%\setupvars.bat" (
    call "%OPENVINO_LINK_DIR%\setupvars.bat"
) else (
    call "%OPENVINO_INSTALL_DIR%\setupvars.bat"
)
echo [ok] OpenVINO: %OPENVINO_ROOT%
echo.

REM ============================================================
REM STEP 3: Build llama.cpp (Vulkan + OpenVINO)
REM ============================================================
echo [3/5] Building llama.cpp with Vulkan + OpenVINO...
cd /d "%LLAMA_SRC%"
if not exist "build-npu" mkdir "build-npu"
cd "build-npu"

cmake .. -G Ninja ^
    -DCMAKE_BUILD_TYPE=Release ^
    -DCMAKE_TOOLCHAIN_FILE=%VCPKG_DIR%\scripts\buildsystems\vcpkg.cmake ^
    -DGGML_VULKAN=ON ^
    -DGGML_OPENVINO=ON ^
    -DGGML_CPU=ON ^
    -DBUILD_SHARED_LIBS=OFF ^
    -DLLAMA_SERVER=ON ^
    -DLLAMA_BUILD_EXAMPLES=OFF ^
    -DLLAMA_BUILD_TESTS=OFF

if errorlevel 1 (echo [!!] CMake configure failed & pause & exit /b 1)

cmake --build . --target llama-server -j%NUMBER_OF_PROCESSORS%
if errorlevel 1 (echo [!!] Build failed & pause & exit /b 1)

echo.
echo [ok] Available devices:
bin\llama-server.exe --list-devices
echo.

REM ============================================================
REM STEP 4: Collect artifacts
REM ============================================================
echo [4/5] Collecting server + DLLs...
if exist "%OUTPUT_DIR%" rmdir /s /q "%OUTPUT_DIR%"
mkdir "%OUTPUT_DIR%"

REM The server binary
copy /y "bin\llama-server.exe" "%OUTPUT_DIR%\"

REM MinGW runtime DLLs (from existing windows build)
for %%F in (libgcc_s_seh-1.dll libstdc++-6.dll libwinpthread-1.dll) do (
    if exist "%SCRIPT_DIR%servers\windows\%%F" (
        copy /y "%SCRIPT_DIR%servers\windows\%%F" "%OUTPUT_DIR%\" >nul
        echo [ok] %%F
    )
)

REM Vulkan DLL
if exist "%VCPKG_DIR%\installed\x64-windows\bin\vulkan-1.dll" (
    copy /y "%VCPKG_DIR%\installed\x64-windows\bin\vulkan-1.dll" "%OUTPUT_DIR%\" >nul
    echo [ok] vulkan-1.dll
)

REM OpenVINO runtime DLLs
set "OV_BIN="
if exist "%OPENVINO_ROOT%\runtime\bin\intel64\Release" set "OV_BIN=%OPENVINO_ROOT%\runtime\bin\intel64\Release"
if exist "%OPENVINO_ROOT%\runtime\bin\intel64\Release" set "OV_BIN=%OPENVINO_ROOT%\runtime\bin\intel64\Release"
if exist "%OPENVINO_INSTALL_DIR%\runtime\bin\intel64\Release" set "OV_BIN=%OPENVINO_INSTALL_DIR%\runtime\bin\intel64\Release"

if defined OV_BIN exist "%OV_BIN%\*.dll" (
    echo [+] Copying OpenVINO DLLs from %OV_BIN%
    for %%F in ("%OV_BIN%\*.dll") do (
        copy /y "%%F" "%OUTPUT_DIR%\" >nul
    )
) else (
    echo [!!] WARNING: OpenVINO runtime bin not found. NPU may not work at runtime.
    echo     Check: %OPENVINO_ROOT%\runtime\bin\intel64\Release
)

echo.
echo Output directory:
dir "%OUTPUT_DIR%" | findstr "llama-server\|\.dll"
echo.

REM ============================================================
REM STEP 5: Summary
REM ============================================================
echo [5/5] Done!
echo.
echo ============================================
echo Next steps:
echo ============================================
echo 1. Copy the "%OUTPUT_DIR%" folder to your Linux build machine
echo 2. Place it at: launcher/servers/windows-npu/
echo 3. Run:  ./launcher/assemble-windows-npu.sh
echo.
echo    This will cross-compile Go + embed the GPU+NPU server
echo    + append models, producing Windows .exe files.
echo.
echo    The resulting binaries will auto-detect GPU + NPU.
echo ============================================
pause
