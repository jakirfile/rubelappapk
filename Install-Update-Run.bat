@echo off
setlocal EnableDelayedExpansion
cd /d "%~dp0"

set "ADB=%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe"
set "DEVICE_SERIAL=%ADB_SERIAL%"
set "ONLINE_DEVICE_COUNT=0"

if not exist "%ADB%" (
    echo Android Debug Bridge was not found.
    timeout /t 5 /nobreak >nul
    exit /b 1
)

if not defined DEVICE_SERIAL (
    for /f "skip=1 tokens=1,2" %%A in ('"%ADB%" devices') do (
        if "%%B"=="device" (
            set /a ONLINE_DEVICE_COUNT+=1
            if not defined DEVICE_SERIAL set "DEVICE_SERIAL=%%A"
        )
    )
)

if not defined DEVICE_SERIAL (
    echo No authorized Android device is connected.
    "%ADB%" devices -l
    timeout /t 5 /nobreak >nul
    exit /b 1
)

echo Using Android device: %DEVICE_SERIAL%
if %ONLINE_DEVICE_COUNT% GTR 1 echo Multiple devices are connected. Set ADB_SERIAL to choose another device.

set "APK=%~dp0app\build\outputs\apk\debug\app-debug.apk"
set "APP_PACKAGE=com.ijtc.rre"
set "NO_INSTALL=0"
set "INSTALL_RESTRICTED=0"
if /I "%~1"=="noinstall" set "NO_INSTALL=1"
if /I "%~1"=="--no-install" set "NO_INSTALL=1"
if /I "%~1"=="/noinstall" set "NO_INSTALL=1"

if "%NO_INSTALL%"=="0" if not exist "%APK%" (
    echo Debug APK was not found: "%APK%"
    timeout /t 5 /nobreak >nul
    exit /b 1
)

if "%NO_INSTALL%"=="0" (
    echo Using App: "%APK%"
    "%ADB%" -s "%DEVICE_SERIAL%" shell pm list packages | findstr /I /X /C:"package:%APP_PACKAGE%" >nul
    if errorlevel 1 (
        echo Package %APP_PACKAGE% is not installed. Installing fresh.
        set "INSTALL_LOG=!TEMP!\rre-install-!RANDOM!-!RANDOM!.log"
        "!ADB!" -s "!DEVICE_SERIAL!" install "!APK!" >"!INSTALL_LOG!" 2>&1
        set "INSTALL_RESULT=!ERRORLEVEL!"
        type "!INSTALL_LOG!"
        if "!INSTALL_RESULT!"=="0" (
            del "!INSTALL_LOG!" >nul 2>nul
            goto installed
        )
        findstr /C:"INSTALL_FAILED_USER_RESTRICTED" "!INSTALL_LOG!" >nul
        if not errorlevel 1 set "INSTALL_RESTRICTED=1"
        del "!INSTALL_LOG!" >nul 2>nul
        goto installFailed
    ) else (
        echo Package %APP_PACKAGE% is installed. Overwriting it.
        set "INSTALL_LOG=!TEMP!\rre-install-!RANDOM!-!RANDOM!.log"
        "!ADB!" -s "!DEVICE_SERIAL!" install -r -d "%APK%" >"!INSTALL_LOG!" 2>&1
        set "INSTALL_RESULT=!ERRORLEVEL!"
        type "!INSTALL_LOG!"
        if "!INSTALL_RESULT!"=="0" goto installed
        findstr /C:"INSTALL_FAILED_USER_RESTRICTED" "!INSTALL_LOG!" >nul
        if not errorlevel 1 set "INSTALL_RESTRICTED=1"
        findstr /C:"INSTALL_FAILED_UPDATE_INCOMPATIBLE" "!INSTALL_LOG!" >nul
        if errorlevel 1 (
            del "!INSTALL_LOG!" >nul 2>nul
            goto installFailed
        )
        echo.
        echo The installed app uses a different signing key.
        echo Uninstalling it will erase its local app data.
        choice /C YN /N /M "Uninstall the existing app and install fresh? [Y/N] "
        if errorlevel 2 (
            del "!INSTALL_LOG!" >nul 2>nul
            echo Fresh installation cancelled.
            timeout /t 5 /nobreak >nul
            exit /b 1
        )
        "%ADB%" -s "%DEVICE_SERIAL%" uninstall "%APP_PACKAGE%"
        if errorlevel 1 (
            del "!INSTALL_LOG!" >nul 2>nul
            goto installFailed
        )
        del "!INSTALL_LOG!" >nul 2>nul
        set "INSTALL_LOG=!TEMP!\rre-install-!RANDOM!-!RANDOM!.log"
        "!ADB!" -s "!DEVICE_SERIAL!" install "!APK!" >"!INSTALL_LOG!" 2>&1
        set "INSTALL_RESULT=!ERRORLEVEL!"
        type "!INSTALL_LOG!"
        if "!INSTALL_RESULT!"=="0" (
            del "!INSTALL_LOG!" >nul 2>nul
        ) else (
            findstr /C:"INSTALL_FAILED_USER_RESTRICTED" "!INSTALL_LOG!" >nul
            if not errorlevel 1 set "INSTALL_RESTRICTED=1"
            del "!INSTALL_LOG!" >nul 2>nul
            goto installFailed
        )
    )
)

:installed
:launch
if "%NO_INSTALL%"=="1" (
    "%ADB%" -s "%DEVICE_SERIAL%" shell pm list packages "%APP_PACKAGE%" | findstr /I /C:"%APP_PACKAGE%" >nul
    if errorlevel 1 (
        echo Package %APP_PACKAGE% is not installed on the connected device.
        echo Run the installer first: Install-Update-Run.bat
        timeout /t 5 /nobreak >nul
        exit /b 1
    )
)

"%ADB%" -s "%DEVICE_SERIAL%" shell monkey -p %APP_PACKAGE% 1
if errorlevel 1 (
    echo The app was installed, but could not be launched.
    timeout /t 5 /nobreak >nul
    exit /b 1
)

echo App was launched successfully.
if "%NO_INSTALL%"=="0" echo App was installed and launched successfully.
exit /b 0

:installFailed
if "%INSTALL_RESTRICTED%"=="1" (
    echo.
    echo Android blocked the installation because installation is restricted on the device.
    echo Unlock the device and approve any installation confirmation prompt.
    echo Check the device's Developer options and security settings for USB installation restrictions.
    echo A work-managed or parental-control policy may also prevent sideloading; contact the device administrator.
)
echo Installation failed. Review the ADB error above and check the device connection and APK.
timeout /t 5 /nobreak >nul
exit /b 1
