@echo off
setlocal

set "VS_DEV_CMD=C:\Program Files (x86)\Microsoft Visual Studio\2019\Community\Common7\Tools\VsDevCmd.bat"
set "SWIFT_EXE=C:\Users\janke\AppData\Local\Programs\Swift\Toolchains\6.3.1+Asserts\usr\bin\swift.exe"
set "WINDOWS_SDK_DIR=C:\Program Files (x86)\Windows Kits\10"
set "WINDOWS_SDK_VERSION=10.0.10240.0"

if not exist "%VS_DEV_CMD%" (
  echo Visual Studio developer command script not found: %VS_DEV_CMD%
  exit /b 1
)

if not exist "%SWIFT_EXE%" (
  echo Swift executable not found: %SWIFT_EXE%
  exit /b 1
)

call "%VS_DEV_CMD%" -arch=x64 -host_arch=x64 >nul
if errorlevel 1 exit /b 1

set "WindowsSdkDir=%WINDOWS_SDK_DIR%\"
set "WindowsSDKVersion=%WINDOWS_SDK_VERSION%\"

"%SWIFT_EXE%" %*
exit /b %errorlevel%

