@echo off
setlocal enabledelayedexpansion

echo ========================================
echo Building llama-server with SYCL
echo ========================================

REM Setup VS environment
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"

REM Add oneAPI to PATH and LIB
set PATH=C:\Intel\compiler\latest\bin;%PATH%
set LIB=C:\Intel\compiler\latest\lib;%LIB%

REM Verify tools
echo.
echo === Checking prerequisites ===
where cmake
where ninja
where dpcpp
echo.

REM Setup build directory
cd /d C:\Users\testuser\llama-src
if not exist "build-sycl" mkdir build-sycl
cd build-sycl

echo === Configuring CMake ===
cmake .. -G "Ninja" ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DGGML_SYCL=ON ^
  -DGGML_SYCL_TARGET=INTEL ^
  -DGGML_SYCL_DNN=ON ^
  -DGGML_SYCL_SUPPORT_LEVEL_ZERO_API=ON ^
  -DGGML_SYCL_F16=OFF ^
  -DGGML_SYCL_GRAPH=ON ^
  -DGGML_CPU=ON ^
  -DGGML_OPENMP=ON ^
  -DBUILD_SHARED_LIBS=OFF ^
  -DLLAMA_SERVER=ON ^
  -DLLAMA_BUILD_EXAMPLES=OFF ^
  -DLLAMA_BUILD_TESTS=OFF

if !ERRORLEVEL! neq 0 (
    echo CMAKE CONFIGURE FAILED
    exit /b !ERRORLEVEL!
)

echo.
echo === Building llama-server ===
ninja llama-server

if !ERRORLEVEL! neq 0 (
    echo BUILD FAILED
    exit /b !ERRORLEVEL!
)

echo.
echo === Build Complete ===
if exist "bin\llama-server.exe" (
    dir "bin\llama-server.exe"
    echo SUCCESS
) else (
    echo WARNING: llama-server.exe not found in bin\
    dir bin\ 2>nul
)
