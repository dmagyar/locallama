@echo off
set PATH=C:\Intel\compiler\latest\bin;C:\LLVM\bin;%PATH%
echo Testing SYCL compilation...
icx -fsycl C:\TEMP\test-sycl.cpp -o C:\TEMP\test-sycl.exe 2>&1 | tee C:\TEMP\sycl-test.log
echo Exit: %ERRORLEVEL%
type C:\TEMP\sycl-test.log
