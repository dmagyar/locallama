@echo off
setlocal enabledelayedexpansion

echo === Collecting SYCL runtime DLLs ===

REM Setup environments
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" 2>nul
set PATH=C:\Intel\compiler\latest\bin;%PATH%

REM Output directory
set OUTDIR=C:\Users\testuser\llama-src\servers-windows-sycl
if exist "%OUTDIR%" rmdir /s /q "%OUTDIR%"
mkdir "%OUTDIR%"

REM Copy the built server
copy "C:\Users\testuser\llama-src\build-sycl\bin\llama-server.exe" "%OUTDIR%"
for %%F in ("%OUTDIR%\llama-server.exe") do echo Server: %%~zF bytes

REM === oneAPI compiler runtime DLLs ===
set ONEDIR=C:\Intel\compiler\latest
if not exist "%ONEDIR%" set ONEDIR=C:\Intel\compiler\2026.0

echo.
echo --- Compiler DLLs ---
for %%F in (
    %ONEDIR%\windows\svml_dispmd.dll
    %ONEDIR%\windows\libsvml.dll
    %ONEDIR%\windows\libirngmd.dll
    %ONEDIR%\windows\libintlcmd.dll
    %ONEDIR%\windows\libimfmd.dll
    %ONEDIR%\windows\libircmd.dll
    %ONEDIR%\windows\libopenclmd.dll
    %ONEDIR%\windows\pi_level_zero.dll
    %ONEDIR%\lib\libiomp5md.dll
) do (
    if exist "%%F" (
        copy "%%F" "%OUTDIR%" >nul
        echo + %%~nxF
    )
)

REM === Level Zero loader ===
echo.
echo --- Level Zero ---
for %%P in (
    C:\Windows\System32
    %ONEDIR%\redist\windows
    C:\Intel\level-zero\latest\bin
) do (
    if exist "%%P\ze_loader.dll" (
        copy "%%P\ze_loader.dll" "%OUTDIR%" >nul
        echo + ze_loader.dll
    )
)

REM === oneMKL DLLs ===
echo.
echo --- oneMKL DLLs ---
set MKLDIR=C:\Intel\mkl\2026.0
if exist "%MKLDIR%\bin\" (
    for %%F in (%MKLDIR%\bin\*.dll) do (
        copy "%%F" "%OUTDIR%" >nul
        echo + %%~nxF
    )
)

REM === oneDNN DLLs ===
echo.
echo --- oneDNN DLLs ---
set DNNLDIR=C:\Intel\dnnl\2026.0
if exist "%DNNLDIR%\bin\" (
    for %%F in (%DNNLDIR%\bin\*.dll) do (
        copy "%%F" "%OUTDIR%" >nul
        echo + %%~nxF
    )
)

REM === TBB ===
echo.
echo --- TBB ---
set TBBDIR=C:\Intel\tbb\2023.0
if exist "%TBBDIR%\bin\" (
    for %%F in (%TBBDIR%\bin\*.dll) do (
        copy "%%F" "%OUTDIR%" >nul
        echo + %%~nxF
    )
)

REM === MKL redist DLLs ===
echo.
echo --- MKL Redist ---
if exist "%MKLDIR%\redist\intel64_64\" (
    for %%F in (%MKLDIR%\redist\intel64_64\*.dll) do (
        copy "%%F" "%OUTDIR%" >nul
        echo + %%~nxF
    )
)

REM === Summary ===
echo.
echo ============================================
echo Collection Complete!
echo ============================================
set DLCCOUNT=0
for %%F in (%OUTDIR%\*.dll) do set /a DLCCOUNT+=1
echo DLLs: %DLCCOUNT%
for %%F in (%OUTDIR%\llama-server.exe) do echo Server: %%~zF bytes
dir "%OUTDIR%"
echo ============================================
