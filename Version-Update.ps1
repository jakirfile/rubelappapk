$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$gradlePath = Join-Path $projectRoot 'app\build.gradle.kts'
$manifestPath = Join-Path $projectRoot 'Update.json'

function Read-VersionFiles {
    $gradle = [IO.File]::ReadAllText($gradlePath)
    $defaultConfigMatch = [regex]::Match(
        $gradle,
        '(?s)defaultConfig\s*\{(?<body>.*?)^\s{4}\}',
        [Text.RegularExpressions.RegexOptions]::Multiline
    )
    if (-not $defaultConfigMatch.Success) {
        throw 'Could not find the android.defaultConfig block in app/build.gradle.kts.'
    }

    $codeMatch = [regex]::Match($defaultConfigMatch.Groups['body'].Value, '(?m)^\s*versionCode\s*=\s*(?<value>\d+)\s*$')
    $nameMatch = [regex]::Match($defaultConfigMatch.Groups['body'].Value, '(?m)^\s*versionName\s*=\s*"(?<value>[^"]+)"\s*$')
    if (-not $codeMatch.Success -or -not $nameMatch.Success) {
        throw 'Could not read versionCode and versionName from app/build.gradle.kts.'
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.apkFileName -ne 'app-release.apk') {
        throw 'Update.json does not target app-release.apk.'
    }

    [pscustomobject]@{
        Gradle       = $gradle
        DefaultBlock = $defaultConfigMatch
        VersionCode  = [int]$codeMatch.Groups['value'].Value
        VersionName  = $nameMatch.Groups['value'].Value
        Manifest     = $manifest
    }
}

function Adjust-VersionName([string]$VersionName, [int]$Amount) {
    $match = [regex]::Match($VersionName, '^(?<numbers>\d+(?:\.\d+)*)(?<suffix>.*)$')
    if (-not $match.Success) {
        throw 'Version Name must start with numeric segments (for example 1.0 or 1.2.3) to increase/decrease it.'
    }

    $segments = @($match.Groups['numbers'].Value.Split('.'))
    $lastIndex = $segments.Count - 1
    $segmentValue = [int]$segments[$lastIndex]
    if ($Amount -lt 0 -and $segmentValue -eq 0) {
        Write-Host 'The last Version Name segment is already 0; it cannot go lower.' -ForegroundColor Yellow
        return $VersionName
    }

    $segments[$lastIndex] = [string]($segmentValue + $Amount)
    return (($segments -join '.') + $match.Groups['suffix'].Value)
}

function Build-SignedReleaseApk([int]$VersionCode, [string]$VersionName) {
    $sdk = $env:ANDROID_SDK_ROOT
    if ([string]::IsNullOrWhiteSpace($sdk)) { $sdk = $env:ANDROID_HOME }
    if ([string]::IsNullOrWhiteSpace($sdk)) { $sdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk' }

    $buildToolsRoot = Join-Path $sdk 'build-tools'
    $buildTools = Get-ChildItem -LiteralPath $buildToolsRoot -Directory |
        Sort-Object { [version]$_.Name } -Descending |
        Where-Object {
            (Test-Path (Join-Path $_.FullName 'apksigner.bat')) -and
            (Test-Path (Join-Path $_.FullName 'aapt.exe'))
        } |
        Select-Object -First 1
    if (-not $buildTools) {
        throw "Android SDK build-tools with apksigner and aapt were not found under $buildToolsRoot."
    }

    $gradleWrapper = Join-Path $projectRoot 'gradlew.bat'
    $unsignedApk = Join-Path $projectRoot 'app\build\outputs\apk\release\app-release-unsigned.apk'
    $signedApk = Join-Path $projectRoot 'app\build\outputs\apk\release\app-release.apk'
    $stagedApk = Join-Path $projectRoot 'app\build\outputs\apk\release\app-release-version-update.apk'
    $qrPath = Join-Path $projectRoot 'qr.png'
    $stagedQr = Join-Path $projectRoot 'app\build\outputs\apk\release\qr-version-update.png'
    $indexPath = Join-Path $projectRoot 'index.html'
    $keystore = Join-Path $env:USERPROFILE '.android\debug.keystore'
    $apksigner = Join-Path $buildTools.FullName 'apksigner.bat'
    $aapt = Join-Path $buildTools.FullName 'aapt.exe'

    if (-not (Test-Path $gradleWrapper)) { throw 'gradlew.bat was not found.' }
    if (-not (Test-Path $keystore)) { throw "Android debug keystore was not found: $keystore" }

    Write-Host ''
    Write-Host 'Building the release APK...' -ForegroundColor Cyan
    Push-Location $projectRoot
    try {
        & $gradleWrapper ':app:assembleRelease' '-PskipInstallAndRun=true' '--console=plain'
        $buildExitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($buildExitCode -ne 0) {
        throw "Release APK build failed with exit code $buildExitCode."
    }
    if (-not (Test-Path $unsignedApk)) {
        throw "Release build succeeded, but the unsigned APK was not found: $unsignedApk"
    }

    if (Test-Path $stagedApk) { Remove-Item -LiteralPath $stagedApk -Force }
    Write-Host 'Signing and verifying the release APK...' -ForegroundColor Cyan
    & $apksigner sign --ks $keystore --ks-key-alias androiddebugkey --ks-pass pass:android --key-pass pass:android --out $stagedApk $unsignedApk
    if ($LASTEXITCODE -ne 0) { throw 'Could not sign the release APK.' }
    & $apksigner verify $stagedApk
    if ($LASTEXITCODE -ne 0) { throw 'Release APK signature verification failed.' }

    $badging = & $aapt dump badging $stagedApk
    if ($LASTEXITCODE -ne 0) { throw 'Could not read release APK version metadata.' }
    $packageLine = $badging | Where-Object { $_ -match '^package:' } | Select-Object -First 1
    if (
        $packageLine -notmatch "name='com\.ijtc\.rre' versionCode='$VersionCode' versionName='([^']+)'" -or
        $Matches[1] -cne $VersionName
    ) {
        throw "Built APK version does not match Version Name $VersionName and Version Code $VersionCode."
    }

    $curl = Get-Command 'curl.exe' -ErrorAction SilentlyContinue
    if (-not $curl) { throw 'curl.exe is required to refresh the QR image.' }
    $qrUrl = 'https://api.qrserver.com/v1/create-qr-code/?size=600x600&format=png&data=https%3A%2F%2Fgithub.com%2Fproperfixerit%2FPFAPK%2Ftree%2Fmain%2FRRE'
    if (Test-Path $stagedQr) { Remove-Item -LiteralPath $stagedQr -Force }
    Write-Host 'Refreshing the GitHub fallback QR image...' -ForegroundColor Cyan
    & $curl.Source '--fail' '--location' '--silent' '--show-error' '--max-time' '30' '--output' $stagedQr $qrUrl
    if ($LASTEXITCODE -ne 0) { throw "Could not refresh qr.png (curl exit code $LASTEXITCODE)." }
    $qrBytes = [IO.File]::ReadAllBytes($stagedQr)
    if (
        $qrBytes.Length -lt 100 -or
        $qrBytes[0] -ne 137 -or $qrBytes[1] -ne 80 -or
        $qrBytes[2] -ne 78 -or $qrBytes[3] -ne 71
    ) {
        throw 'The refreshed QR image is not a valid PNG.'
    }

    $indexHtml = [IO.File]::ReadAllText($indexPath)
    $expectedQr = '<img(?<attributes>[^>]*\bsrc="\./qr\.png(?:\?[^"]*)?"[^>]*)>'
    if ($indexHtml -notmatch $expectedQr) {
        throw 'Could not find the QR image element in index.html.'
    }
    $versionedQrSource = 'src="./qr.png?v=' + $VersionCode + '"'
    $indexHtml = [regex]::Replace(
        $indexHtml,
        $expectedQr,
        [System.Text.RegularExpressions.MatchEvaluator]{
            param($match)
            [regex]::Replace($match.Value, '\bsrc="\./qr\.png(?:\?[^"]*)?"', $versionedQrSource, 1)
        },
        1
    )
    $versionHtml = [regex]::Escape('<p class="version" id="version" aria-live="polite">') +
        '.*?' +
        [regex]::Escape('</p>')
    if ($indexHtml -notmatch $versionHtml) {
        throw 'Could not find the version display in index.html.'
    }
    $fallbackVersion = "Latest version $VersionName (Version code $VersionCode)"
    $indexHtml = [regex]::Replace(
        $indexHtml,
        $versionHtml,
        ('<p class="version" id="version" aria-live="polite">' + $fallbackVersion + '</p>'),
        1
    )
    if (
        $indexHtml -notmatch 'fetch\("\./Update\.json"' -or
        $indexHtml -notmatch 'https://raw\.githubusercontent\.com/properfixerit/PFAPK/main/RRE/app-release\.apk' -or
        $indexHtml -notmatch 'https://github\.com/properfixerit/PFAPK/tree/main/RRE'
    ) {
        throw 'index.html is missing the configured update manifest, release APK, or GitHub fallback URL.'
    }

    Move-Item -LiteralPath $stagedApk -Destination $signedApk -Force
    Move-Item -LiteralPath $stagedQr -Destination $qrPath -Force
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $manifest.versionCode = $VersionCode
    $manifest.versionName = $VersionName
    $manifest.sha256 = (Get-FileHash -LiteralPath $signedApk -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText(
        $manifestPath,
        (ConvertTo-Json -InputObject $manifest -Depth 10) + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText($indexPath, $indexHtml, [Text.UTF8Encoding]::new($false))

    Write-Host "Release APK built and signed: $signedApk" -ForegroundColor Green
    Write-Host "SHA-256: $($manifest.sha256)"
    Write-Host "Updated local files: Update.json, index.html, and qr.png."
}

function Save-VersionAndBuild([int]$VersionCode, [string]$VersionName) {
    if ($VersionCode -lt $current.VersionCode) {
        Write-Host 'Warning: a lower Version Code cannot update installs that already have a higher code.' -ForegroundColor Yellow
        $confirm = Read-Host 'Save the lower code anyway? (Y/N)'
        if ($null -eq $confirm -or $confirm.Trim() -notmatch '^(Y|YES)$') { return $false }
    }

    $blockBody = $current.DefaultBlock.Groups['body'].Value
    $blockBody = [regex]::Replace(
        $blockBody,
        '(?m)^(\s*versionCode\s*=\s*)\d+(\s*)$',
        "`${1}$VersionCode`$2",
        1
    )
    $escapedName = $VersionName.Replace('\', '\\').Replace('"', '\"')
    $blockBody = [regex]::Replace(
        $blockBody,
        '(?m)^(\s*versionName\s*=\s*")[^"]+("\s*)$',
        "`${1}$escapedName`$2",
        1
    )
    $newGradle = $current.Gradle.Substring(0, $current.DefaultBlock.Groups['body'].Index) +
        $blockBody +
        $current.Gradle.Substring($current.DefaultBlock.Groups['body'].Index + $current.DefaultBlock.Groups['body'].Length)

    $current.Manifest.versionCode = $VersionCode
    $current.Manifest.versionName = $VersionName
    [IO.File]::WriteAllText($gradlePath, $newGradle, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText(
        $manifestPath,
        (ConvertTo-Json -InputObject $current.Manifest -Depth 10) + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )

    Write-Host ''
    Write-Host "Saved Version Name $VersionName and Version Code $VersionCode." -ForegroundColor Green
    Build-SignedReleaseApk $VersionCode $VersionName
    return $true
}

$current = Read-VersionFiles
$pendingCode = $current.VersionCode
$pendingName = $current.VersionName

while ($true) {
    Clear-Host
    Write-Host 'RRE Version Update' -ForegroundColor Cyan
    Write-Host ''
    Write-Host "Current: Version Name $($current.VersionName)  |  Version Code $($current.VersionCode)"
    Write-Host "Pending: Version Name $pendingName  |  Version Code $pendingCode" -ForegroundColor Green
    Write-Host ''
    Write-Host '1. Increase Version Name (last number)'
    Write-Host '2. Decrease Version Name (last number)'
    Write-Host '3. Increase Version Code (+1)'
    Write-Host '4. Decrease Version Code (-1)'
    Write-Host '5. Set Version Name manually'
    Write-Host '6. Set Version Code manually'
    Write-Host 'S. Save changes'
    Write-Host 'Q. Quit without saving'
    Write-Host 'Enter both on one line to save and build, e.g. Version Name 1.1, Version Code 3' -ForegroundColor DarkGray
    $choice = (Read-Host 'Choose 1-6, S, Q, or enter both versions').Trim()

    switch -Regex ($choice) {
        '^1$' { $pendingName = Adjust-VersionName $pendingName 1; break }
        '^2$' { $pendingName = Adjust-VersionName $pendingName -1; break }
        '^3$' {
            if ($pendingCode -eq [int]::MaxValue) {
                Write-Host 'Version Code cannot exceed the Android integer limit.' -ForegroundColor Yellow
            } else {
                $pendingCode++
            }
            break
        }
        '^4$' {
            if ($pendingCode -le 1) {
                Write-Host 'Version Code must be at least 1.' -ForegroundColor Yellow
            } else {
                $pendingCode--
            }
            break
        }
        '^5$' {
            $newName = (Read-Host 'Enter Version Name (for example 1.1 or 2.0)').Trim()
            if ([string]::IsNullOrWhiteSpace($newName) -or $newName -match '["\r\n]') {
                Write-Host 'Version Name cannot be blank or contain quotes/newlines.' -ForegroundColor Yellow
            } else {
                $pendingName = $newName
            }
            break
        }
        '^6$' {
            $newCodeText = (Read-Host 'Enter Version Code (positive whole number)').Trim()
            $newCode = 0
            if ([int]::TryParse($newCodeText, [ref]$newCode) -and $newCode -ge 1) {
                $pendingCode = $newCode
            } else {
                Write-Host 'Version Code must be a positive whole number.' -ForegroundColor Yellow
            }
            break
        }
        '^Version\s+Name\s+([^,]+),\s*Version\s+Code\s+(\d+)$' {
            $newName = $Matches[1].Trim()
            $newCodeText = $Matches[2]
            $newCode = 0
            if (
                [string]::IsNullOrWhiteSpace($newName) -or
                $newName -match '["\r\n]' -or
                -not [int]::TryParse($newCodeText, [ref]$newCode) -or
                $newCode -lt 1
            ) {
                Write-Host 'Enter a valid Version Name and positive whole-number Version Code.' -ForegroundColor Yellow
            } else {
                $pendingName = $newName
                $pendingCode = $newCode
                Write-Host "Saving Version Name $pendingName and Version Code $pendingCode, then building the release APK..." -ForegroundColor Cyan
                if (Save-VersionAndBuild $pendingCode $pendingName) { exit 0 }
            }
            break
        }
        '^(S|SAVE)$' {
            if (Save-VersionAndBuild $pendingCode $pendingName) { exit 0 }
            break
        }
        '^(Q|QUIT)$' { exit 0 }
        default { Write-Host 'Choose one of the listed options.' -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
    }
}
