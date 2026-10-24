@echo off
setlocal EnableExtensions
pushd "%~dp0"
if errorlevel 1 (
    echo Could not open the RRE project folder.
    exit /b 1
)

set "SOURCE=%CD%"
set "REPO_URL=https://github.com/jakirfile/Source-Code.git"
set "WORK=%TEMP%\RRE-Source-Code-upload-%RANDOM%-%RANDOM%"
set "APK=%SOURCE%\app\build\outputs\apk\debug\app-debug.apk"
set "APK_META=%SOURCE%\app\build\outputs\apk\debug\output-metadata.json"

where git >nul 2>nul
if errorlevel 1 (
    echo Git was not found. Install Git for Windows and try again.
    goto fail
)

git config --global user.name >nul 2>nul
if errorlevel 1 (
    echo Git author name is not configured.
    echo Configure git user.name, then click this file again.
    goto fail
)
git config --global user.email >nul 2>nul
if errorlevel 1 (
    echo Git author email is not configured.
    echo Configure git user.email, then click this file again.
    goto fail
)

echo.
echo Building and testing RRE...
call "%SOURCE%\gradlew.bat" :app:testDebugUnitTest :app:assembleDebug -PskipInstallAndRun=true
if errorlevel 1 (
    echo Build or unit tests failed. Nothing was uploaded.
    goto fail
)
if not exist "%APK%" (
    echo Debug APK was not produced. Nothing was uploaded.
    goto fail
)
if not exist "%APK_META%" (
    echo APK metadata was not produced. Nothing was uploaded.
    goto fail
)

echo.
echo Cloning %REPO_URL%...
echo Using the saved jakirfile GitHub sign-in; authenticate in the browser if requested.
set "GCM_INTERACTIVE=always"
git -c credential.helper=manager -c credential.interactive=always -c credential.username=jakirfile clone "%REPO_URL%" "%WORK%"
set "GIT_RESULT=%ERRORLEVEL%"
set "GCM_INTERACTIVE="
if not "%GIT_RESULT%"=="0" (
    echo Clone failed. Sign in to GitHub and verify repository access and the main branch.
    goto fail
)

git -C "%WORK%" show-ref --verify --quiet refs/remotes/origin/main
if errorlevel 1 (
    git -C "%WORK%" rev-parse --verify HEAD >nul 2>nul
    if errorlevel 1 (
        git -C "%WORK%" symbolic-ref HEAD refs/heads/main
    ) else (
        git -C "%WORK%" switch -C main
    )
) else (
    git -C "%WORK%" switch -C main --track origin/main
)
if errorlevel 1 (
    echo Could not prepare the main branch in the upload copy.
    goto fail
)

echo.
echo Copying project source and assets...
set "PROJECT_DEST=%WORK%\RRE"
robocopy "%SOURCE%" "%PROJECT_DEST%" /E /COPY:DAT /DCOPY:DAT /R:2 /W:2 ^
    /XD "%SOURCE%\.git" "%SOURCE%\.gradle" "%SOURCE%\.kotlin" ^
        "%SOURCE%\.idea\caches" "%SOURCE%\build" "%SOURCE%\app\build" ^
    /XF local.properties workspace.xml
if errorlevel 8 (
    echo Project files could not be copied completely. Nothing was pushed.
    goto fail
)

if exist "%SOURCE%\Data\" (
    echo.
    echo Copying all files from Data...
    robocopy "%SOURCE%\Data" "%PROJECT_DEST%\Data" /E /COPY:DAT /DCOPY:DAT /R:2 /W:2
    if errorlevel 8 (
        echo Data files could not be copied completely. Nothing was pushed.
        goto fail
    )
)

set "APK_DEST=%PROJECT_DEST%\app\build\outputs\apk\debug"
if not exist "%APK_DEST%" mkdir "%APK_DEST%"
if errorlevel 1 (
    echo Could not create the APK output directory.
    goto fail
)
copy /Y "%APK%" "%APK_DEST%\app-debug.apk" >nul
if errorlevel 1 (
    echo Could not copy the debug APK.
    goto fail
)
copy /Y "%APK_META%" "%APK_DEST%\output-metadata.json" >nul
if errorlevel 1 (
    echo Could not copy APK metadata.
    goto fail
)

git -C "%WORK%" add -A
if errorlevel 1 (
    echo Could not stage project files.
    goto fail
)
if exist "%SOURCE%\Data\" (
    git -C "%WORK%" add -f -A -- RRE/Data
    if errorlevel 1 (
        echo Could not stage all files from Data.
        goto fail
    )
)
git -C "%WORK%" add -f -- RRE/app/build/outputs/apk/debug/app-debug.apk RRE/app/build/outputs/apk/debug/output-metadata.json
if errorlevel 1 (
    echo Could not stage the debug APK artifacts.
    goto fail
)

git -C "%WORK%" diff --cached --check
if errorlevel 1 (
    echo Staged files contain whitespace errors. Nothing was pushed.
    goto fail
)

git -C "%WORK%" diff --cached --quiet
if not errorlevel 1 (
    echo GitHub already has all current project files. Nothing to upload.
    goto success
)

git -C "%WORK%" commit -m "Update RRE source and debug APK" ^
    -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
if errorlevel 1 (
    echo Commit failed. Check Git author configuration.
    goto fail
)

echo.
echo Pushing the complete project to GitHub...
set "GCM_INTERACTIVE=always"
git -c credential.helper=manager -c credential.interactive=always -c credential.username=jakirfile -C "%WORK%" push origin main
set "GIT_RESULT=%ERRORLEVEL%"
set "GCM_INTERACTIVE="
if not "%GIT_RESULT%"=="0" (
    echo Push failed. The temporary upload copy is kept here:
    echo %WORK%
    echo Check GitHub sign-in, write access, and remote changes, then retry.
    goto failKeepWork
)

echo.
echo RRE source and debug APK were uploaded to the RRE folder successfully.
goto success

:fail
if exist "%WORK%\.git" (
    echo Upload staging copy kept for inspection:
    echo %WORK%
    goto finishFail
)
if exist "%WORK%" rmdir /S /Q "%WORK%"
goto finishFail

:failKeepWork

:finishFail
popd
exit /b 1

:success
if exist "%WORK%" rmdir /S /Q "%WORK%"
popd
exit /b 0
