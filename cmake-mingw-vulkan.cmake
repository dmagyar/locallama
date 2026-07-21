# CMake toolchain for cross-compiling to Windows x64 with MinGW-w64 + Vulkan
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)

set(CMAKE_C_COMPILER x86_64-w64-mingw32-gcc)
set(CMAKE_CXX_COMPILER x86_64-w64-mingw32-g++)

# Vulkan headers and library for Windows target
set(VULKAN_HEADERS_INSTALL_DIR "/home/coder/LOCALLAMA/vulkan-mingw")
set(Vulkan_INCLUDE_DIR "/home/coder/LOCALLAMA/vulkan-mingw/include")
set(Vulkan_LIBRARY "/home/coder/LOCALLAMA/vulkan-mingw/libvulkan-1.a")

# Force find_package to use our paths
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
