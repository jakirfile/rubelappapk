@echo off
setlocal EnableExtensions EnableDelayedExpansion
pushd "%~dp0"
if errorlevel 1 (
    echo Could not open the RRE project folder.
    exit /b 1
)

set "SOURCE=%CD%"
set "REPO_URL=https://github.com/properfixerit/PFAPK.git"
set "WORK=%TEMP%\RRE-PFAPK-upload-%RANDOM%-%RANDOM%"
set "MANIFEST=%SOURCE%\Update.json"
set "APK=%SOURCE%\app\build\outputs\apk\release\app-release.apk"
set "INDEX=%SOURCE%\index.html"
set "QR=%SOURCE%\qr.png"
set "SDK=%ANDROID_SDK_ROOT%"
if not defined SDK set "SDK=%ANDROID_HOME%"
if not defined SDK set "SDK=%LOCALAPPDATA%\Android\Sdk"
set "UNSIGNED_APK=%SOURCE%\app\build\outputs\apk\release\app-release-unsigned.apk"
set "APK_METADATA=%SOURCE%\app\build\outputs\apk\release\output-metadata.json"
set "STAGED_APK=%SOURCE%\app\build\outputs\apk\release\app-release-upload.apk"
set "DEBUG_KEYSTORE=%USERPROFILE%\.android\debug.keystore"

where git >nul 2>nul
if errorlevel 1 (
    echo Git was not found. Install Git for Windows and try again.
    goto fail
)

for %%F in ("%MANIFEST%" "%INDEX%" "%QR%") do (
    if not exist "%%~F" (
        echo Required upload file is missing: "%%~F"
        goto fail
    )
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

set "APKSIGNER="
set "AAPT="
for /f "delims=" %%D in ('dir /b /ad /o-n "%SDK%\build-tools" 2^>nul') do (
    if not defined APKSIGNER if exist "%SDK%\build-tools\%%D\apksigner.bat" set "APKSIGNER=%SDK%\build-tools\%%D\apksigner.bat"
    if not defined AAPT if exist "%SDK%\build-tools\%%D\aapt.exe" set "AAPT=%SDK%\build-tools\%%D\aapt.exe"
)
if not defined APKSIGNER (
    echo Android SDK apksigner was not found under "%SDK%\build-tools".
    goto fail
)
if not defined AAPT (
    echo Android SDK aapt.exe was not found under "%SDK%\build-tools".
    goto fail
)
if not exist "%DEBUG_KEYSTORE%" (
    echo Android debug keystore was not found: "%DEBUG_KEYSTORE%"
    goto fail
)

echo.
echo Building the latest RRE release APK...
call "%SOURCE%\gradlew.bat" :app:assembleRelease -PskipInstallAndRun=true --console=plain
if errorlevel 1 (
    echo Release APK build failed. Nothing was uploaded.
    goto fail
)
if not exist "%UNSIGNED_APK%" (
    echo Release build completed, but the unsigned APK was not found.
    goto fail
)

if exist "%STAGED_APK%" del /q "%STAGED_APK%"
call "%APKSIGNER%" sign --ks "%DEBUG_KEYSTORE%" --ks-key-alias androiddebugkey --ks-pass pass:android --key-pass pass:android --out "%STAGED_APK%" "%UNSIGNED_APK%"
if errorlevel 1 (
    echo Could not sign the new RRE release APK.
    goto fail
)
call "%APKSIGNER%" verify "%STAGED_APK%"
if errorlevel 1 (
    echo New release APK signature verification failed.
    goto fail
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $m=Get-Content -LiteralPath $env:MANIFEST -Raw | ConvertFrom-Json; $meta=Get-Content -LiteralPath $env:APK_METADATA -Raw | ConvertFrom-Json; if ([long]$m.versionCode -ne [long]$meta.elements[0].versionCode -or [string]$m.versionName -cne [string]$meta.elements[0].versionName -or $meta.applicationId -ne 'com.ijtc.rre') { throw ('Update.json version ' + $m.versionName + ' (' + $m.versionCode + ') does not match APK version ' + $meta.elements[0].versionName + ' (' + $meta.elements[0].versionCode + '). Run Version-Update.bat and retry.'); }; Write-Output ('Verified RRE version ' + $meta.elements[0].versionName + ' (code ' + $meta.elements[0].versionCode + ').')"
if errorlevel 1 (
    echo APK and Update.json versions do not match. Nothing was uploaded.
    del "%STAGED_APK%" >nul 2>nul
    goto fail
)

move /Y "%STAGED_APK%" "%APK%" >nul
if errorlevel 1 (
    echo Could not replace the old release APK.
    goto fail
)

call "%APKSIGNER%" verify "%APK%"
if errorlevel 1 (
    echo The release APK is not signed correctly. Nothing was uploaded.
    goto fail
)

echo.
echo Updating Update.json SHA-256 to match the signed release APK...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $m=Get-Content -LiteralPath $env:MANIFEST -Raw | ConvertFrom-Json; if ($m.apkFileName -ne 'app-release.apk' -or $m.apkUrl -ne 'https://raw.githubusercontent.com/properfixerit/PFAPK/main/RRE/app-release.apk') { throw 'Update.json must target properfixerit/PFAPK/RRE/app-release.apk.' }; $m.sha256=(Get-FileHash -LiteralPath $env:APK -Algorithm SHA256).Hash.ToLowerInvariant(); [IO.File]::WriteAllText($env:MANIFEST, (ConvertTo-Json -InputObject $m -Depth 10) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false)); Write-Output ('Manifest SHA-256: ' + $m.sha256)"
if errorlevel 1 (
    echo Could not validate or update the release manifest.
    goto fail
)

echo.
echo Cloning %REPO_URL%...
echo Sign in to GitHub in the browser if Git Credential Manager requests it.
set "GCM_INTERACTIVE=always"
git -c credential.helper=manager -c credential.interactive=always clone --branch main --single-branch "%REPO_URL%" "%WORK%"
set "GIT_RESULT=!ERRORLEVEL!"
set "GCM_INTERACTIVE="
if not "!GIT_RESULT!"=="0" (
    echo Clone failed. Verify GitHub sign-in and access to properfixerit/PFAPK.
    goto fail
)

set "DEST=%WORK%\RRE"
if not exist "%DEST%" mkdir "%DEST%"
if errorlevel 1 (
    echo Could not create the RRE upload folder.
    goto failKeepWork
)

fc /b "%QR%" "%DEST%\qr.png" >nul 2>nul
if errorlevel 1 (
    echo qr.png differs from GitHub; the updated QR will be included in the upload.
) else (
    echo qr.png already exists on GitHub and is byte-for-byte identical to the local QR.
)

copy /Y "%MANIFEST%" "%DEST%\Update.json" >nul
if errorlevel 1 goto copyFailed
copy /Y "%APK%" "%DEST%\app-release.apk" >nul
if errorlevel 1 goto copyFailed
copy /Y "%INDEX%" "%DEST%\index.html" >nul
if errorlevel 1 goto copyFailed
copy /Y "%QR%" "%DEST%\qr.png" >nul
if errorlevel 1 goto copyFailed

git -C "%WORK%" add -f -- RRE/Update.json RRE/app-release.apk RRE/index.html RRE/qr.png
if errorlevel 1 (
    echo Could not stage the four RRE release files.
    goto failKeepWork
)

git -C "%WORK%" diff --cached --check
if errorlevel 1 (
    echo Staged files contain whitespace errors. Nothing was pushed.
    goto failKeepWork
)

git -C "%WORK%" diff --cached --quiet
if not errorlevel 1 (
    echo GitHub already has these exact files, including qr.png. Nothing to upload.
    goto success
)

echo.
echo Files included in this upload:
git -C "%WORK%" diff --cached --name-only

git -C "%WORK%" commit -m "Publish RRE release APK and download page" ^
    -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
if errorlevel 1 (
    echo Commit failed. Check Git author configuration.
    goto failKeepWork
)

echo.
echo Uploading the release files to GitHub...
set "GCM_INTERACTIVE=always"
git -c credential.helper=manager -c credential.interactive=always -C "%WORK%" push origin main
set "GIT_RESULT=!ERRORLEVEL!"
set "GCM_INTERACTIVE="
if not "!GIT_RESULT!"=="0" (
    echo Upload failed. The prepared files are kept here:
    echo %WORK%
    echo Complete GitHub sign-in, verify write access, then retry.
    goto failKeepWork
)

echo.
echo Uploaded Update.json, app-release.apk, index.html, and qr.png to:
echo https://github.com/properfixerit/PFAPK/tree/main/RRE
goto success

:copyFailed
echo Could not copy all four release files into the upload folder.
goto failKeepWork

:fail
if exist "%WORK%\.git" goto failKeepWork
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
exit /b 0