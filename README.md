# RRE Android app

The Android app opens `https://ijtc.jakirfile.workers.dev` in a full-screen
WebView. The website provides the app experience; the Android app no longer
contains the former native screens, account flows, or local-data features.

The WebView enables JavaScript and DOM storage, keeps website navigation inside
the app, restores its current page after recreation, and uses the Android Back
button to navigate WebView history before closing the app. The app requires an
internet connection to load the site.

Existing files under `Data/` are preserved but are not read by the Android app.
The standalone website, Apps Script sources, and build/publishing helpers remain
separate project assets.

## Build and test

Run the focused configuration test with:

```powershell
.\gradlew.bat testDebugUnitTest -PskipInstallAndRun=true
```

Build the debug APK without installing it with:

```powershell
.\gradlew.bat assembleDebug -PskipInstallAndRun=true
```

The debug APK is at `app\build\outputs\apk\debug\app-debug.apk`.
