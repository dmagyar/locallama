@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
set PATH=C:\Intel\compiler\latest\bin;%PATH%
set LIB=C:\Intel\compiler\latest\lib;%LIB%
echo === Compiling SYCL test ===
dpcpp -fsycl C:\TEMP\t.cpp -o C:\TEMP\t.exe
echo Exit: %ERRORLEVEL%
if exist C:\TEMP\t.exe (
    echo SUCCESS: t.exe created
    dir C:\TEMP\t.exe
) else (
    echo FAILED: t.exe not created
)
