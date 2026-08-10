@echo off
setlocal enabledelayedexpansion

:: Get current directory
set SCRIPT_DIR=%~dp0
cd %SCRIPT_DIR%

:: Set environment variables for using local toolchain
set DEPOT_TOOLS_WIN_TOOLCHAIN=0

:: Setup ANGLE if needed
if not exist angle (
    echo ANGLE not found. Running setup script...
    call setup-angle-windows.bat
    if %ERRORLEVEL% NEQ 0 (
        echo Setup failed. Exiting.
        exit /b 1
    )
)

:: Add depot_tools to PATH
set PATH=%SCRIPT_DIR%depot_tools;%PATH%

:: Go to ANGLE directory
cd angle

:: Create the chrome/VERSION file that is required by compute_build_timestamp.py
if not exist chrome\VERSION (
    echo Creating mock chrome VERSION file...
    mkdir chrome 2>nul
    (
        echo MAJOR=1
        echo MINOR=0
        echo BUILD=0
        echo PATCH=0
    ) > chrome\VERSION
)

:: ANGLE pins an exact (often preview) Windows SDK version in
:: build/toolchain/win/setup_toolchain.py that isn't installed on CI runners.
:: Rewrite it to the newest SDK actually installed on this machine.
echo Patching Windows SDK version to match the installed SDK...
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%patch-sdk-version-windows.ps1"
if %ERRORLEVEL% NEQ 0 (
    echo Failed to patch Windows SDK version. Exiting.
    exit /b 1
)

:: Common GN args for all Windows builds
set COMMON_ARGS=^
    is_debug=false ^
    is_component_build=false ^
    angle_standalone=true ^
    angle_build_tests=false ^
    angle_enable_swiftshader=false ^
    chrome_pgo_phase=0 ^
    is_official_build=true ^
    use_custom_libcxx=false ^
    strip_debug_info=true ^
    symbol_level=0 ^
    angle_enable_trace=false ^
    angle_enable_d3d9=false ^
    angle_enable_gl=false ^
    angle_enable_vulkan=false ^
    angle_enable_null=false ^
    angle_enable_metal=false ^
    angle_enable_wgpu=false ^
    angle_enable_d3d11=true ^
    angle_enable_essl=false ^
    angle_enable_glsl=true ^
    build_with_chromium=false ^
    is_clang=true ^
    clang_use_chrome_plugins=false ^
    treat_warnings_as_errors=false

:: Create output directories with new structure
if not exist ..\build\windows\x64\bin mkdir ..\build\windows\x64\bin
if not exist ..\build\windows\x64\lib mkdir ..\build\windows\x64\lib
if not exist ..\build\windows\x64\include mkdir ..\build\windows\x64\include

if not exist ..\build\windows\arm64\bin mkdir ..\build\windows\arm64\bin
if not exist ..\build\windows\arm64\lib mkdir ..\build\windows\arm64\lib
if not exist ..\build\windows\arm64\include mkdir ..\build\windows\arm64\include

:: Create header directories
if not exist ..\build\windows\x64\include\EGL mkdir ..\build\windows\x64\include\EGL
if not exist ..\build\windows\x64\include\GLES2 mkdir ..\build\windows\x64\include\GLES2
if not exist ..\build\windows\x64\include\GLES3 mkdir ..\build\windows\x64\include\GLES3
if not exist ..\build\windows\x64\include\KHR mkdir ..\build\windows\x64\include\KHR

if not exist ..\build\windows\arm64\include\EGL mkdir ..\build\windows\arm64\include\EGL
if not exist ..\build\windows\arm64\include\GLES2 mkdir ..\build\windows\arm64\include\GLES2
if not exist ..\build\windows\arm64\include\GLES3 mkdir ..\build\windows\arm64\include\GLES3
if not exist ..\build\windows\arm64\include\KHR mkdir ..\build\windows\arm64\include\KHR

:: Copy headers for both architectures
echo Copying headers...
xcopy /Y include\EGL\*.h ..\build\windows\x64\include\EGL\
xcopy /Y include\GLES2\*.h ..\build\windows\x64\include\GLES2\
xcopy /Y include\GLES3\*.h ..\build\windows\x64\include\GLES3\
xcopy /Y include\KHR\*.h ..\build\windows\x64\include\KHR\

xcopy /Y include\EGL\*.h ..\build\windows\arm64\include\EGL\
xcopy /Y include\GLES2\*.h ..\build\windows\arm64\include\GLES2\
xcopy /Y include\GLES3\*.h ..\build\windows\arm64\include\GLES3\
xcopy /Y include\KHR\*.h ..\build\windows\arm64\include\KHR\

:: Build for Windows x64
echo Building ANGLE for Windows x64...
call gn gen out/windows-x64 --args="%COMMON_ARGS% target_cpu=\"x64\""
if %ERRORLEVEL% NEQ 0 (
    echo Failed to generate x64 build files. Exiting.
    exit /b 1
)

call ninja -C out/windows-x64 libEGL libGLESv2
if %ERRORLEVEL% NEQ 0 (
    echo Failed to build x64 version. Exiting.
    exit /b 1
)

:: Copy the DLLs and libs to build directory with new structure
echo Copying x64 files to build directory...
copy /Y out\windows-x64\libEGL.dll ..\build\windows\x64\bin\
copy /Y out\windows-x64\libGLESv2.dll ..\build\windows\x64\bin\
copy /Y out\windows-x64\libEGL.dll.lib ..\build\windows\x64\lib\libEGL.lib
copy /Y out\windows-x64\libGLESv2.dll.lib ..\build\windows\x64\lib\libGLESv2.lib

:: Copy d3dcompiler_47.dll for x64
echo Copying d3dcompiler_47.dll for x64...
if exist "out\windows-x64\d3dcompiler_47.dll" (
    echo Found d3dcompiler_47.dll in ANGLE build, using it.
    copy /Y out\windows-x64\d3dcompiler_47.dll ..\build\windows\x64\bin\
) else if exist "C:\Windows\System32\d3dcompiler_47.dll" (
    echo d3dcompiler_47.dll not found in ANGLE build, copying from System32.
    copy /Y "C:\Windows\System32\d3dcompiler_47.dll" ..\build\windows\x64\bin\
) else (
    echo ERROR: d3dcompiler_47.dll not found. You need to install the Windows SDK.
    exit /b 1
)

:: Build for Windows ARM64
echo Building ANGLE for Windows ARM64...
call gn gen out/windows-arm64 --args="%COMMON_ARGS% target_cpu=\"arm64\""
if %ERRORLEVEL% NEQ 0 (
    echo Failed to generate ARM64 build files. Exiting.
    exit /b 1
)

call ninja -C out/windows-arm64 libEGL libGLESv2
if %ERRORLEVEL% NEQ 0 (
    echo Failed to build ARM64 version. Exiting.
    exit /b 1
)

:: Copy the DLLs and libs to build directory with new structure
echo Copying ARM64 files to build directory...
copy /Y out\windows-arm64\libEGL.dll ..\build\windows\arm64\bin\
copy /Y out\windows-arm64\libGLESv2.dll ..\build\windows\arm64\bin\
copy /Y out\windows-arm64\libEGL.dll.lib ..\build\windows\arm64\lib\libEGL.lib
copy /Y out\windows-arm64\libGLESv2.dll.lib ..\build\windows\arm64\lib\libGLESv2.lib

:: Copy d3dcompiler_47.dll for ARM64
echo Copying d3dcompiler_47.dll for ARM64...
if exist "out\windows-arm64\d3dcompiler_47.dll" (
    echo Found d3dcompiler_47.dll in ANGLE ARM64 build, using it.
    copy /Y out\windows-arm64\d3dcompiler_47.dll ..\build\windows\arm64\bin\
) else if exist "C:\Windows\SysArm64\d3dcompiler_47.dll" (
    echo d3dcompiler_47.dll not found in ANGLE ARM64 build, copying from SysArm64.
    copy /Y "C:\Windows\SysArm64\d3dcompiler_47.dll" ..\build\windows\arm64\bin\
) else if exist "C:\Windows\System32\d3dcompiler_47.dll" (
    echo WARNING: Using x64 version of d3dcompiler_47.dll for ARM64 build. This may not work correctly.
    copy /Y "C:\Windows\System32\d3dcompiler_47.dll" ..\build\windows\arm64\bin\
) else (
    echo ERROR: d3dcompiler_47.dll not found. You need to install the Windows SDK.
    exit /b 1
)

:: Return to script directory
cd %SCRIPT_DIR%

echo.
echo Windows builds complete! Files are available in:
echo   - build\windows\x64\bin (DLLs for Windows x64)
echo   - build\windows\x64\lib (Libraries for Windows x64)
echo   - build\windows\x64\include (Headers for Windows x64)
echo   - build\windows\arm64\bin (DLLs for Windows ARM64)
echo   - build\windows\arm64\lib (Libraries for Windows ARM64)
echo   - build\windows\arm64\include (Headers for Windows ARM64)