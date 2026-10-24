# IJTC version and update checklist

## Current release configuration

- Gradle project name: `IJTC` (`settings.gradle.kts`)
- App name: `RRE` (`app/src/main/res/values/strings.xml`)
- Android application ID: `com.ijtc.rre`
- Android version: `versionName = "1.0"`, `versionCode = 2`
  (`app/build.gradle.kts`)
- Update manifest and APK: GitHub `properfixerit/PFAPK`, `RRE/Update.json`
  and `RRE/app-release.apk`
- Download page: `https://properfixerit.github.io/PFAPK/RRE`
- QR fallback: `https://github.com/properfixerit/PFAPK/tree/main/RRE`
- Update source: GitHub raw `RRE/Update.json`. GitHub hosts the app update and
  exam data.

## Debug build and device test

Run `.\gradlew.bat assembleDebug` from the project root. This task runs
`testDebugUnitTest` first; after tests pass, it runs
`Install-Update-Run.bat` using the APK at
`app\build\outputs\apk\debug\app-debug.apk` to install/update and launch the app
on a connected Android device. A failed test prevents the
install-and-run step. Updating an already-installed release requires the APK to
use the same signing key; the default debug key will be rejected if it differs.
The installer offers a fresh-install option for a signing mismatch; uninstalling
the existing app erases its local app data.
To build without attempting device installation, add `-PskipInstallAndRun=true`
to the Gradle command.

## To publish the next update

1. Run `Version-Update.bat` to view and adjust `versionName` and `versionCode`.
   Enter `Version Name 1.1, Version Code 3` to save both values and automatically
   build and sign `app-release.apk`, refresh the `Update.json` checksum, update
   the version shown in `index.html`, and regenerate `qr.png` for the stable
   GitHub fallback link. These files are updated locally; use `App-Upload.bat`
   separately to publish them. The menu's Save option performs the same updates.
   Keep the package name `com.ijtc.rre` if users should update the existing app.
2. Keep the login footer in
   `app/src/main/java/com/ijtc/rre/MainActivity.kt` in sync with the
   version display behavior.
3. From `J:\My Drive\AndroidData\RRE`, build with
   `.\gradlew.bat assembleRelease`. Sign
   `app\build\outputs\apk\release\app-release-unsigned.apk` with the same
   release key used for the installed app. Verify package, version, and
   signature, then calculate SHA-256 from the final signed APK.
4. For a release build, place the final signed APK at
   `RRE/app-release.apk` in `properfixerit/PFAPK` and update `RRE/Update.json`.
   The JSON must contain:
   - `versionCode` and `versionName` matching `app/build.gradle.kts`
   - `apkUrl`: `https://raw.githubusercontent.com/properfixerit/PFAPK/main/RRE/app-release.apk`
   - `apkFileName`: `app-release.apk`
   - `sha256`: lowercase SHA-256 of the final signed APK
5. Update the version shown in `RRE/index.html`. The QR code links to the RRE
   GitHub folder as a fallback if the GitHub Pages hostname cannot be resolved.
   Verify GitHub Pages deployment and the live version text when available.
6. Upload the signed release APK and matching `Update.json` to
   `properfixerit/PFAPK` after verifying the manifest checksum. The app's
   update checker downloads only this configured release APK.

## Package and signing warning

Android treats a changed application ID as a different app. The current ID is
`com.ijtc.rre`. Because the ID changed during the rename, this app installs
separately from previously published installs and does not share their local
data. Preserve the current ID for future RRE updates.
Use the existing release keystore for every release. A different signing key
cannot update the installed app, and uninstalling the old app may erase its
data. Always increase `versionCode`; do not reset it for releases intended to
update existing installations.
