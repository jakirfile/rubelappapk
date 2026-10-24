@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001 >nul
pushd "%~dp0"
if errorlevel 1 (
    echo Could not open the RRE project folder.
    pause
    exit /b 1
)

rem ============================================================
rem  Upload the WHOLE RRE project (all folders) to:
rem  https://github.com/jakirfile/RRE
rem ============================================================
set "SOURCE=%CD%"
set "REPO_URL=https://github.com/jakirfile/RRE.git"
set "BRANCH=main"
set "GIT_PAGER=cat"
set "WORK=%TEMP%\RRE-jakirfile-upload-%RANDOM%-%RANDOM%"

where git >nul 2>nul
if errorlevel 1 (
    echo Git was not found. Install Git for Windows and try again.
    goto fail
)

git config --global user.name >nul 2>nul
if errorlevel 1 (
    echo Git author name is not configured.
    echo Run: git config --global user.name "Your Name"
    goto fail
)
git config --global user.email >nul 2>nul
if errorlevel 1 (
    echo Git author email is not configured.
    echo Run: git config --global user.email "you@example.com"
    goto fail
)

echo.
echo Cloning %REPO_URL% ...
echo Sign in to GitHub in the browser if Git Credential Manager asks.
set "GCM_INTERACTIVE=always"
git -c credential.helper=manager -c credential.interactive=always clone "%REPO_URL%" "%WORK%"
set "GIT_RESULT=!ERRORLEVEL!"
set "GCM_INTERACTIVE="
if not "!GIT_RESULT!"=="0" (
    echo Clone failed. Verify GitHub sign-in and access to jakirfile/RRE.
    goto fail
)

rem Works for both an empty repo and a repo that already has commits
git -C "%WORK%" checkout -B %BRANCH% >nul 2>nul
git -C "%WORK%" rev-parse --verify origin/%BRANCH% >nul 2>nul
if not errorlevel 1 git -C "%WORK%" reset --hard origin/%BRANCH% >nul

echo.
echo Copying all project folders and files...
rem /MIR keeps GitHub an exact mirror of this folder (files deleted here are deleted there too).
rem Skipped: Git data, Gradle/Kotlin caches, build outputs, machine-specific local.properties.
robocopy "%SOURCE%" "%WORK%" /MIR /R:1 /W:1 /NFL /NDL /NJH /NJS /NP ^
    /XD .git .gradle .kotlin build captures .cxx .externalNativeBuild ^
    /XF local.properties *.iml
if errorlevel 8 (
    echo Copy failed. Nothing was uploaded.
    goto failKeepWork
)

git -C "%WORK%" add -A
if errorlevel 1 (
    echo Could not stage the project files.
    goto failKeepWork
)

git -C "%WORK%" diff --cached --quiet
if not errorlevel 1 (
    echo GitHub already has exactly these files. Nothing to upload.
    goto success
)

echo.
echo Changes in this upload:
git --no-pager -C "%WORK%" diff --cached --stat

git -C "%WORK%" commit -q -m "Upload RRE project (%DATE% %TIME%)"
if errorlevel 1 (
    echo Commit failed. Check Git author configuration.
    goto failKeepWork
)

echo.
echo Uploading to GitHub...
set "GCM_INTERACTIVE=always"
git -c credential.helper=manager -c credential.interactive=always -C "%WORK%" push -u origin %BRANCH%
set "GIT_RESULT=!ERRORLEVEL!"
set "GCM_INTERACTIVE="
if not "!GIT_RESULT!"=="0" (
    echo Upload failed. Complete GitHub sign-in, verify write access to jakirfile/RRE, then retry.
    goto failKeepWork
)

echo.
echo Done. The full RRE project is now at:
echo https://github.com/jakirfile/RRE
goto success

:fail
if exist "%WORK%" rmdir /S /Q "%WORK%"
popd
pause
exit /b 1

:failKeepWork
echo Upload staging copy kept for inspection:
echo %WORK%
popd
pause
exit /b 1

:success
if exist "%WORK%" rmdir /S /Q "%WORK%"
popd
echo.
echo Closing in 3 seconds...
timeout /t 3 /nobreak >nul
exit 0
