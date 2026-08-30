<#
.SYNOPSIS
    Builds a release APK - or, with -Bundle, an AAB for Google Play - on this
    Windows box, working around a broken `.flutter-plugins-dependencies`.

.DESCRIPTION
    `flutter build apk` does not work here. Every `flutter pub get` (and every
    `analyze`, `test` and `build`, which each run one) writes
    `.flutter-plugins-dependencies` with *double-escaped* paths: the raw JSON
    holds `\\\\` where it should hold `\\`, so the parsed value is
    `C:\\Users\\kuzme\\...` instead of `C:\Users\kuzme\...`.

    Gradle's plugin loader then does `File(path, "android").exists()`
    (FlutterAppPluginLoaderPlugin.kt) and gets false, and the build dies in ~2s
    with:

        Plugin directory does not exist: ...\geocoding_android-5.0.2\android

    That path *does* exist, and the error prints it normalised - which makes it
    look like a corrupt pub cache. It is not. Do not go reinstalling packages.

    So: run pub get first, repair the file, then invoke Gradle *directly*.
    Going through `flutter build apk` would just rewrite the file broken again
    before Gradle ever reads it.

    The script also pins android/local.properties to the version in
    pubspec.yaml. A direct-Gradle build reads versionName/versionCode from
    there, not from pubspec, so without this step a bumped pubspec silently
    ships a stale versionCode and testers cannot tell two APKs apart.

.PARAMETER Bundle
    Build an AAB instead of an APK. Google Play accepts nothing else.

    `flutter build appbundle` is broken here for exactly the same reason
    `flutter build apk` is - it rewrites the plugin list before Gradle reads it
    - so the workaround has to cover both, and the only difference downstream is
    which Gradle task runs and where the artifact lands.

    Two things about an AAB that do not apply to the APK:

    - Play re-signs it. The keystore below is the *upload* key from Play's point
      of view, and the certificate that actually reaches phones is Google's. Any
      fingerprint restriction - the Maps key's above all - has to name the SHA-1
      from Play Console, not the one this keystore produces.
    - Nothing here can install it. An AAB is not a package; Play splits it per
      device. To test the exact artifact, pull the APKs back out with bundletool.

.PARAMETER Clean
    Run `flutter clean` first. Slower by several minutes; use when a build
    fails in ways that smell like stale intermediates.

.PARAMETER SkipPubGet
    Skip `flutter pub get`. Only safe when nothing has touched pubspec.yaml or
    regenerated the plugin list since the last run.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tool\build_apk.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tool\build_apk.ps1 -Bundle
#>
[CmdletBinding()]
param(
    [switch]$Bundle,
    [switch]$Clean,
    [switch]$SkipPubGet
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
function Step($text) { Write-Host "==> $text" -ForegroundColor Cyan }
function Warn($text) { Write-Host "    ! $text" -ForegroundColor Yellow }

# --- Locate the toolchain ----------------------------------------------------
# Flutter is not on PATH on this machine, so fall back to the known install
# rather than failing with a bare "command not found".
$flutter = $null
$onPath = Get-Command flutter.bat -ErrorAction SilentlyContinue
if ($onPath) { $flutter = $onPath.Source }
if (-not $flutter) {
    $guess = 'C:\Users\kuzme\flutter\bin\flutter.bat'
    if (Test-Path $guess) { $flutter = $guess }
}
if (-not $flutter) { throw "flutter.bat not found (not on PATH, not at C:\Users\kuzme\flutter\bin)." }

# Gradle needs JAVA_HOME set explicitly. Only the flutter tool finds Android
# Studio's bundled JBR on its own; gradlew.bat just gives up.
if (-not ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME 'bin\java.exe')))) {
    $jdks = @(
        (Join-Path $env:ProgramFiles 'Android\Android Studio\jbr'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Android Studio\jbr'),
        (Join-Path $env:ProgramFiles 'Android\Android Studio\jre')
    )
    $found = $jdks | Where-Object { Test-Path (Join-Path $_ 'bin\java.exe') } | Select-Object -First 1
    if (-not $found) { throw "No JDK found. Set JAVA_HOME to a JDK (Android Studio ships one in its jbr\ directory)." }
    $env:JAVA_HOME = $found
}
Step "JDK: $env:JAVA_HOME"

# --- Read the build identity -------------------------------------------------
# Both of these are hand-maintained and neither derives from git, so read them
# back and print them: a build that ships the previous stamp is indistinguishable
# from the previous APK on the tester's phone.
$pubspecPath = Join-Path $root 'pubspec.yaml'
$versionLine = Select-String -Path $pubspecPath -Pattern '^version:\s*(\S+)' | Select-Object -First 1
if (-not $versionLine) { throw "No 'version:' line in $pubspecPath." }
if ($versionLine.Matches[0].Groups[1].Value -notmatch '^([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)$') {
    throw "Cannot parse version '$($versionLine.Matches[0].Groups[1].Value)' - expected <name>+<code>, e.g. 0.33.2+101."
}
$versionName = $matches[1]
$versionCode = $matches[2]

# Both live in lib\core\util\app_build.dart now, so the profile screen can show
# them. That screen used to carry its own hardcoded '0.1.0', which had been
# wrong for forty releases because nothing ever compared it to anything - hence
# the version check below, which is the whole reason the constant moved.
$buildDart = Get-Content (Join-Path $root 'lib\core\util\app_build.dart') -Raw
if ($buildDart -notmatch "const\s+String\s+appBuildStamp\s*=\s*'([^']*)'") {
    throw "Could not find appBuildStamp in lib\core\util\app_build.dart."
}
$stamp = $matches[1]
if ($buildDart -notmatch "const\s+String\s+appVersion\s*=\s*'([^']*)'") {
    throw "Could not find appVersion in lib\core\util\app_build.dart."
}
$declaredVersion = $matches[1]
if ($declaredVersion -ne $versionName) {
    throw "appVersion is '$declaredVersion' but pubspec says '$versionName'. " +
          "The profile screen would show the wrong number - bump both."
}
Step "Building cubechat $versionName+$versionCode  ($stamp)"

# A stamp reading like the last one is the single most common way a tester ends
# up testing the wrong APK, so say it out loud rather than failing.
if ($stamp -notmatch '^\d{4}-\d{2}-\d{2}') {
    Warn "_buildStamp does not start with a date - is it stale?"
}

# --- Optional clean ----------------------------------------------------------
if ($Clean) {
    Step 'flutter clean'
    & $flutter clean | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "flutter clean failed ($LASTEXITCODE)." }
}

# --- Resolve dependencies ----------------------------------------------------
if (-not $SkipPubGet) {
    Step 'flutter pub get'
    # `2>&1` on a native executable is a trap in Windows PowerShell: every
    # stderr line comes back wrapped in an ErrorRecord, and under
    # $ErrorActionPreference = 'Stop' that is a *terminating* error. So the
    # Developer Mode warning this block exists to tolerate was killing the
    # build one line before the check that tolerates it. Drop to 'Continue'
    # for the call and flatten the records to plain strings.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $pubLog = & $flutter pub get 2>&1 | ForEach-Object { $_.ToString() }
    } finally {
        $ErrorActionPreference = $prevEap
    }
    # pub get exits non-zero here purely because of the Developer Mode symlink
    # warning, which does not affect the Android build. Only treat it as fatal
    # if dependencies genuinely did not resolve.
    # Note the shape of this test: $pubLog is an array, and `-match` on an array
    # filters it rather than returning a boolean, so `-notmatch` would be true
    # whenever *any* line fails to match - i.e. always.
    if (-not ($pubLog -match 'Got dependencies')) {
        $pubLog | Select-Object -Last 20 | Write-Host
        throw 'flutter pub get did not resolve dependencies.'
    }
    if ($pubLog -match 'requires symlink support') {
        Warn 'Windows Developer Mode is off (pub get cannot create symlinks). Harmless for Android; needed for iOS/desktop plugins.'
    }
}

# --- Repair the generated plugin list ---------------------------------------
# See the note at the top of this file. Single pass, 4 backslashes -> 2: a value
# that legitimately holds one backslash is written `\\` in JSON and is left
# alone, so this is a no-op once the underlying bug is fixed.
$pluginsPath = Join-Path $root '.flutter-plugins-dependencies'
if (-not (Test-Path $pluginsPath)) { throw "$pluginsPath is missing - run without -SkipPubGet." }
$raw = Get-Content $pluginsPath -Raw
$broken = ([regex]::Matches($raw, [regex]::Escape('\\\\'))).Count
if ($broken -gt 0) {
    [System.IO.File]::WriteAllText($pluginsPath, $raw.Replace('\\\\', '\\'))
    Step "Repaired .flutter-plugins-dependencies ($broken double-escaped paths)"
} else {
    Step '.flutter-plugins-dependencies already sane'
}

# Fail early and clearly if a plugin really is missing, rather than letting
# Gradle report it 2 seconds in with a normalised path that looks correct.
#
# Only plugins with `native_build: true` are checked, matching what Gradle's
# native_plugin_loader actually iterates. A Dart-only plugin is listed under
# `plugins.android` but ships no android/ directory at all - path_provider_android
# 2.3.1, for instance, reaches Android through jni_flutter and declares only a
# dartPluginClass. Checking those too reports a fault that isn't there.
$plugins = (Get-Content $pluginsPath -Raw | ConvertFrom-Json).plugins.android
$missing = $plugins |
    Where-Object { $_.native_build } |
    Where-Object { -not (Test-Path (Join-Path $_.path 'android')) }
if ($missing) {
    $missing | ForEach-Object { Warn "missing: $($_.name) -> $($_.path)android" }
    throw 'Some plugin directories are genuinely absent. Try: flutter pub cache repair'
}

# --- Pin the Android version to pubspec --------------------------------------
$localProps = Join-Path $root 'android\local.properties'
$props = [System.Collections.Specialized.OrderedDictionary]::new()
if (Test-Path $localProps) {
    foreach ($line in Get-Content $localProps) {
        if ($line -match '^\s*([^#=]+?)\s*=\s*(.*)$') { $props[$matches[1]] = $matches[2] }
    }
}
if (-not $props.Contains('flutter.sdk')) { throw "android\local.properties has no flutter.sdk - Gradle cannot find the SDK." }
$props['flutter.buildMode'] = 'release'
$props['flutter.versionName'] = $versionName
$props['flutter.versionCode'] = $versionCode
$out = foreach ($k in $props.Keys) { "$k=$($props[$k])" }
[System.IO.File]::WriteAllLines($localProps, $out, (New-Object System.Text.UTF8Encoding($false)))
Step "local.properties pinned to $versionName / $versionCode"

# --- Build -------------------------------------------------------------------
$task = if ($Bundle) { 'bundleRelease' } else { 'assembleRelease' }
Step "gradlew $task (this takes ~8 minutes)"
$sw = [Diagnostics.Stopwatch]::StartNew()
# Kotlin's incremental caches break on this machine specifically: the plugin
# sources live on C: and the project on D:, and the cache keys do not survive
# the crossing. Compiling in-process without them is the workaround — passed
# here rather than written into android/gradle.properties, because that file
# is also read by CI, where the fault does not exist and the cost is a cold
# Kotlin compile on every push.
& (Join-Path $root 'android\gradlew.bat') -p (Join-Path $root 'android') `
    '-Pkotlin.incremental=false' `
    '-Pkotlin.compiler.execution.strategy=in-process' `
    $task --console=plain
if ($LASTEXITCODE -ne 0) { throw "Gradle failed ($LASTEXITCODE)." }
$sw.Stop()

# The APK is relocated by the Flutter Gradle plugin; the bundle is not, so it
# sits where AGP wrote it. Both are under build\app\ only because
# android\build.gradle.kts redirects the build directory out of android\.
$artifact = if ($Bundle) {
    Join-Path $root 'build\app\outputs\bundle\release\app-release.aab'
} else {
    Join-Path $root 'build\app\outputs\flutter-apk\app-release.apk'
}
if (-not (Test-Path $artifact)) { throw "Gradle reported success but $artifact is missing." }

# --- Deliver under a unique name ---------------------------------------------
# Gradle always writes the same path, and the size barely moves between builds,
# so in a file explorer a fresh APK looks exactly like the previous one and gets
# skipped. Give every build a name that says what it is.
$ext = if ($Bundle) { 'aab' } else { 'apk' }
$tag = $stamp -replace '^\d{4}-\d{2}-\d{2}-', ''
$named = Join-Path $root "build\cubechat-$versionName-$versionCode-$tag.$ext"
Copy-Item $artifact $named -Force

# --- Verify the stamp actually shipped ---------------------------------------
# Release Dart is AOT-compiled, so the stamp lives inside libapp.so rather than
# anywhere greppable in the APK itself. Checking it here is what catches a build
# that silently reused an old snapshot.
#
# An APK holds the library at lib/<abi>/; a bundle nests every module under its
# own name, so the same file is at base/lib/<abi>/. Worth following rather than
# skipping the check for bundles: a stale snapshot is exactly as invisible in an
# AAB, and there it would reach Play rather than one tester's phone.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$libPath = if ($Bundle) { 'base/lib/arm64-v8a/libapp.so' } else { 'lib/arm64-v8a/libapp.so' }
$zip = [System.IO.Compression.ZipFile]::OpenRead($named)
try {
    $entry = $zip.Entries | Where-Object { $_.FullName -eq $libPath }
    if (-not $entry) { throw "No $libPath in the $($ext.ToUpper())." }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) 'cubechat-libapp.so'
    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $tmp, $true)
    $bytes = [System.IO.File]::ReadAllBytes($tmp)
    $text = [System.Text.Encoding]::GetEncoding('latin1').GetString($bytes)
    if (-not $text.Contains($stamp)) { throw "Built $($ext.ToUpper()) does not contain the build stamp '$stamp'." }
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
} finally {
    $zip.Dispose()
}

$size = [math]::Round((Get-Item $named).Length / 1MB, 1)
Write-Host ''
Write-Host "BUILD OK  in $([math]::Round($sw.Elapsed.TotalMinutes,1)) min" -ForegroundColor Green
Write-Host "  $named"
Write-Host "  $size MB - cubechat $versionName+$versionCode - stamp verified inside libapp.so"
if ($Bundle) {
    Write-Host '  Upload to Play Console. This cannot be installed on a phone as it is -'
    Write-Host '  use bundletool if you need the exact APKs Play would generate.'
    Write-Host '  Play re-signs with its own key: the SHA-1 that restricts the Maps key must'
    Write-Host '  come from Play Console (App integrity), not from this keystore.'
} else {
    Write-Host '  Install OVER the existing app. Uninstalling wipes the identity and breaks existing chats.'
}
