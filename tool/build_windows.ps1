<#
.SYNOPSIS
    Builds CubeChat for Windows: a portable ZIP and, when Inno Setup 6 is
    installed, an installer.

.DESCRIPTION
    The same two checks build_apk.ps1 makes, for the same reasons: appVersion
    in lib\core\util\app_build.dart must match pubspec, and the build stamp
    must be found inside the AOT snapshot that shipped (data\app.so), which is
    what catches a build that silently reused an old one.

    flutter is on PATH only in Git Bash on this machine (via ~/.bashrc), so
    the build goes through `bash -ic`. Unlike the APK, `flutter build windows`
    is not broken here and is used as it is.

.OUTPUTS
    build\CubeChat-<version>-<code>-windows.zip
    build\windows\installer\CubeChat-<version>-<code>-setup.exe  (with Inno Setup)
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$sw = [Diagnostics.Stopwatch]::StartNew()
function Step($text) { Write-Host "==> $text" -ForegroundColor Cyan }

# --- Version and stamp -------------------------------------------------------
$versionLine = Select-String -Path (Join-Path $root 'pubspec.yaml') -Pattern '^version:\s*(\S+)' |
    Select-Object -First 1
if (-not $versionLine) { throw "No 'version:' line in pubspec.yaml." }
if ($versionLine.Matches[0].Groups[1].Value -notmatch '^([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)$') {
    throw "Cannot parse version '$($versionLine.Matches[0].Groups[1].Value)'."
}
$versionName = $matches[1]
$versionCode = $matches[2]
$buildDart = Get-Content (Join-Path $root 'lib\core\util\app_build.dart') -Raw
if ($buildDart -notmatch "const\s+String\s+appBuildStamp\s*=\s*'([^']*)'") {
    throw 'Could not find appBuildStamp in app_build.dart.'
}
$stamp = $matches[1]
if ($buildDart -notmatch "const\s+String\s+appVersion\s*=\s*'([^']*)'") {
    throw 'Could not find appVersion in app_build.dart.'
}
if ($matches[1] -ne $versionName) {
    throw "appVersion is '$($matches[1])' but pubspec says '$versionName' - bump both."
}
Step "Building CubeChat for Windows $versionName+$versionCode  ($stamp)"

# --- Build -------------------------------------------------------------------
$bashRoot = (& bash -c "cygpath -u '$root'").Trim()
& bash -ic "cd '$bashRoot' && flutter build windows --release"
if ($LASTEXITCODE -ne 0) { throw "flutter build windows failed ($LASTEXITCODE)." }

$release = Join-Path $root 'build\windows\x64\runner\Release'
foreach ($needed in @('cubechat.exe', 'libopus_x64.dll', 'data\app.so')) {
    if (-not (Test-Path (Join-Path $release $needed))) { throw "Missing $needed in $release." }
}

# --- Verify the stamp shipped ------------------------------------------------
$bytes = [IO.File]::ReadAllBytes((Join-Path $release 'data\app.so'))
$text = [Text.Encoding]::GetEncoding('latin1').GetString($bytes)
if (-not $text.Contains($stamp)) { throw "data\app.so does not contain the build stamp '$stamp'." }

# --- Portable ZIP ------------------------------------------------------------
$zip = Join-Path $root "build\CubeChat-$versionName-$versionCode-windows.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $release '*') -DestinationPath $zip
Step "ZIP: $zip ($([math]::Round((Get-Item $zip).Length / 1MB, 1)) MB)"

# --- Installer, when Inno Setup is here --------------------------------------
$iscc = @(
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($iscc) {
    & $iscc "/DAppVersion=$versionName" "/DAppBuild=$versionCode" (Join-Path $root 'windows\installer\cubechat.iss') | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed ($LASTEXITCODE)." }
    Step "Installer: build\windows\installer\CubeChat-$versionName-$versionCode-setup.exe"
} else {
    Write-Host '    Inno Setup 6 not found - ZIP only. https://jrsoftware.org/isinfo.php' -ForegroundColor Yellow
}

Write-Host ''
Write-Host "BUILD OK  in $([math]::Round($sw.Elapsed.TotalMinutes, 1)) min - stamp verified inside data\app.so" -ForegroundColor Green
