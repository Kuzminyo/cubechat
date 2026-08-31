#!/usr/bin/env bash
#
# Builds a release APK — or, with --bundle, an AAB for Google Play — on macOS
# or Linux. The macOS half of tool/build_apk.ps1, which stays for Windows.
#
# WHY THIS IS NOT A TRANSLATION OF THE POWERSHELL SCRIPT
#
# Most of that script is a workaround for a fault that does not exist here.
# On Windows every `flutter pub get` writes `.flutter-plugins-dependencies`
# with double-escaped paths — the JSON holding `\\\\` where it should hold
# `\\` — so Gradle's plugin loader looks for a directory that is really there
# and does not find it. A path made of forward slashes has nothing to
# double-escape, so none of that happens on this side.
#
# Measured rather than assumed, 2026-08-31 on macOS 26.6.2 / arm64:
# `flutter pub get` and then `flutter build apk` each rewrote the file with
# plain /Users/... paths and zero occurrences of `\\\\`, and the build ran
# through to a signed 33.4 MB arm64 APK in 895 s with the stamp verified
# inside libapp.so. So three of that script's steps are gone here:
#
#   - repairing the plugin list: nothing to repair
#   - checking every plugin's android/ directory: that check existed to tell
#     the Windows fault apart from a genuinely corrupt pub cache
#   - pinning android/local.properties: that was needed because the script
#     invoked Gradle directly, bypassing the flutter tool. Going through
#     `flutter build` instead, flutter_tools calls updateLocalProperties()
#     itself (gradle.dart:470 → gradle_utils.dart:1118) and writes
#     flutter.versionName and flutter.versionCode straight from pubspec,
#     leaving every other key — GOOGLE_MAPS_API_KEY above all — untouched.
#
# What is kept is the part that was never about Windows: the two checks that
# catch a build which succeeds and is still the wrong artifact.
#
# And one check is new, because this platform has a trap the other did not.
# See the JDK section below.
#
# Usage:
#   tool/build_apk.sh                 universal APK, same as the PS script
#   tool/build_apk.sh --arm64         arm64 only — a third the size, and what
#                                     testers are actually handed
#   tool/build_apk.sh --bundle        AAB for Play
#   tool/build_apk.sh --clean         flutter clean first (minutes slower)
#   tool/build_apk.sh --skip-pub-get  only when pubspec has not moved

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bundle=0
clean=0
skip_pub_get=0
arm64_only=0

while [ $# -gt 0 ]; do
  case "$1" in
    --bundle)       bundle=1 ;;
    --clean)        clean=1 ;;
    --skip-pub-get) skip_pub_get=1 ;;
    --arm64)        arm64_only=1 ;;
    -h|--help)      sed -n '/^# Usage:/,/^$/s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown flag: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

step() { printf '\033[36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m    ! %s\033[0m\n' "$*"; }
die()  { printf '\033[31mFAILED: %s\033[0m\n' "$*" >&2; exit 1; }

# --- Locate the toolchain ----------------------------------------------------
if command -v flutter >/dev/null 2>&1; then
  flutter="$(command -v flutter)"
elif [ -x "$HOME/flutter/bin/flutter" ]; then
  flutter="$HOME/flutter/bin/flutter"
else
  die "flutter not found (not on PATH, not at ~/flutter/bin)."
fi

# --- The JDK trap, which is this platform's version of the plugin-list bug ---
#
# Flutter does not use JAVA_HOME. It prefers the JDK bundled with Android
# Studio, and a current Android Studio bundles JBR 25 — which Gradle 8.14, the
# wrapper this repo pins, refuses outright; it supports at most 24. The build
# then fails somewhere inside Gradle with a message about Gradle, naming
# nothing that would send anybody to the JDK.
#
# Anyone who installs Android Studio on a Mac walks into this. It cost a build
# here on 2026-08-31 before it was recognised. The fix is one command, and it
# persists in ~/.config/flutter/settings:
#
#   flutter config --jdk-dir="$(brew --prefix openjdk@17)/libexec/openjdk.jdk/Contents/Home"
#
# Checked before the build rather than after, because the build is 15 minutes.
settings="${XDG_CONFIG_HOME:-$HOME/.config}/flutter/settings"
jdk_dir=""
if [ -f "$settings" ]; then
  jdk_dir="$(sed -n 's/.*"jdk-dir"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' "$settings" | head -1)"
fi

if [ -z "$jdk_dir" ]; then
  studio_jbr="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
  if [ -x "$studio_jbr/bin/java" ]; then
    warn "flutter has no jdk-dir set and Android Studio is installed, so it will"
    warn "use the JDK bundled there — see the note above this check."
    jdk_dir="$studio_jbr"
  elif [ -n "${JAVA_HOME:-}" ]; then
    jdk_dir="$JAVA_HOME"
  fi
fi

if [ -n "$jdk_dir" ] && [ -x "$jdk_dir/bin/java" ]; then
  java_version="$("$jdk_dir/bin/java" -version 2>&1 | head -1 | sed -n 's/.*"\([0-9][0-9]*\)[.."].*/\1/p')"
  gradle_version="$(sed -n 's/.*gradle-\([0-9.]*\)-.*/\1/p' \
    "$root/android/gradle/wrapper/gradle-wrapper.properties" | head -1)"
  step "JDK ${java_version:-?} at $jdk_dir  (Gradle $gradle_version)"
  if [ -n "$java_version" ]; then
    # AGP 8.11.1 needs 17 or newer; Gradle 8.14 runs on at most 24.
    if [ "$java_version" -gt 24 ]; then
      die "JDK $java_version is newer than Gradle $gradle_version supports (max 24).
       Point flutter at a 17: flutter config --jdk-dir=\"\$(brew --prefix openjdk@17)/libexec/openjdk.jdk/Contents/Home\""
    fi
    if [ "$java_version" -lt 17 ]; then
      die "JDK $java_version is older than AGP requires (min 17)."
    fi
  fi
else
  warn "could not determine which JDK flutter will use; building anyway."
fi

# --- Read the build identity -------------------------------------------------
# Both of these are hand-maintained and neither derives from git, so read them
# back and print them: a build that ships the previous stamp is
# indistinguishable from the previous APK on the tester's phone.
version_line="$(sed -n 's/^version:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$root/pubspec.yaml" | head -1)"
[ -n "$version_line" ] || die "no 'version:' line in pubspec.yaml."

if [[ ! "$version_line" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)$ ]]; then
  die "cannot parse version '$version_line' — expected <name>+<code>, e.g. 1.0.0+932."
fi
version_name="${BASH_REMATCH[1]}"
version_code="${BASH_REMATCH[2]}"

build_dart="$root/lib/core/util/app_build.dart"
stamp="$(sed -n "s/^const String appBuildStamp = '\(.*\)';$/\1/p" "$build_dart" | head -1)"
declared="$(sed -n "s/^const String appVersion = '\(.*\)';$/\1/p" "$build_dart" | head -1)"
[ -n "$stamp" ]    || die "could not find appBuildStamp in lib/core/util/app_build.dart."
[ -n "$declared" ] || die "could not find appVersion in lib/core/util/app_build.dart."

# This comparison is the whole point of the constant living in app_build.dart.
# The profile screen carried a hardcoded '0.1.0' for forty releases because
# nothing ever compared it to anything.
if [ "$declared" != "$version_name" ]; then
  die "appVersion is '$declared' but pubspec says '$version_name'.
       The profile screen would show the wrong number — bump both."
fi

step "Building cubechat $version_name+$version_code  ($stamp)"

# A stamp reading like the last one is the single most common way a tester ends
# up testing the wrong APK, so say it out loud rather than failing.
case "$stamp" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*) ;;
  *) warn "appBuildStamp does not start with a date — is it stale?" ;;
esac

# --- Build -------------------------------------------------------------------
if [ "$clean" -eq 1 ]; then
  step "flutter clean"
  "$flutter" clean >/dev/null
fi

if [ "$skip_pub_get" -eq 0 ]; then
  step "flutter pub get"
  "$flutter" pub get >/dev/null
fi

args=(build)
if [ "$bundle" -eq 1 ]; then args+=(appbundle); else args+=(apk); fi
args+=(--release)
[ "$arm64_only" -eq 1 ] && args+=(--target-platform android-arm64)

step "flutter ${args[*]}"
started=$(date +%s)
"$flutter" "${args[@]}"
elapsed=$(( $(date +%s) - started ))

if [ "$bundle" -eq 1 ]; then
  artifact="$root/build/app/outputs/bundle/release/app-release.aab"
  lib_in_archive="base/lib/arm64-v8a/libapp.so"
  ext="aab"
else
  artifact="$root/build/app/outputs/flutter-apk/app-release.apk"
  lib_in_archive="lib/arm64-v8a/libapp.so"
  ext="apk"
fi
[ -f "$artifact" ] || die "the build reported success but $artifact is missing."

# --- Deliver under a unique name ---------------------------------------------
# Gradle always writes the same path and the size barely moves between builds,
# so in a file browser a fresh APK looks exactly like the previous one and gets
# skipped. Give every build a name that says what it is.
tag="$(printf '%s' "$stamp" | sed 's/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-//')"
named="$root/build/cubechat-$version_name-$version_code-$tag.$ext"
cp -f "$artifact" "$named"

# --- Verify the stamp actually shipped ---------------------------------------
# Release Dart is AOT-compiled, so the stamp lives inside libapp.so rather than
# anywhere greppable in the archive itself. This is what catches a build that
# silently reused an old snapshot — the failure that is otherwise invisible
# until a tester reports behaviour from a build you thought you had replaced.
step "verifying the stamp inside $lib_in_archive"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
unzip -q -o "$named" "$lib_in_archive" -d "$tmp" \
  || die "no $lib_in_archive in the ${ext}."
if ! LC_ALL=C grep -qaF "$stamp" "$tmp/$lib_in_archive"; then
  die "the built $ext does not contain the build stamp '$stamp' — stale snapshot."
fi

# --- Verify who signed it ----------------------------------------------------
# "App not installed" almost always means the signing fingerprint changed, not
# that the APK is bad, and there is no way to tell from the phone. Print the
# signer so the comparison can be made before the APK is handed over.
#
# The debug fallback in android/app/build.gradle.kts keeps a release build
# installable when nothing is configured, and that is the right default — but
# CN=Android Debug is the placeholder every SDK produces, so Play Protect
# blocks it on sight with "never seen an app from this developer". That is not
# a signing failure and cannot be fixed by signing harder, so it is worth a
# hard stop here rather than a discovery on someone's phone.
#
# Skipped for an AAB: Play re-signs it, and the certificate that reaches phones
# is Google's. The SHA-1 that restricts the Maps key has to come from Play
# Console, not from this keystore.
if [ "$bundle" -eq 0 ]; then
  apksigner="$(ls -1 "${ANDROID_HOME:-$HOME/Library/Android/sdk}"/build-tools/*/apksigner 2>/dev/null | sort -V | tail -1 || true)"
  if [ -n "$apksigner" ] && [ -x "$apksigner" ]; then
    signer="$("$apksigner" verify --print-certs "$named" 2>/dev/null | sed -n 's/^Signer #1 certificate DN: //p' | head -1)"
    sha256="$("$apksigner" verify --print-certs "$named" 2>/dev/null | sed -n 's/^Signer #1 certificate SHA-256 digest: //p' | head -1)"
    case "$signer" in
      *"CN=Android Debug"*)
        die "signed with the debug keystore ($signer).
       Play Protect blocks that outright. Check android/key.properties and
       that android/app/cubechat-release.jks is present." ;;
    esac
    step "signer: $signer"
    step "sha256: $sha256"
  else
    warn "apksigner not found under \$ANDROID_HOME — signature not verified."
  fi
fi

# --- Say what happened -------------------------------------------------------
size="$(du -m "$named" | cut -f1)"
printf '\n\033[32mBUILD OK  in %d min %02d s\033[0m\n' $((elapsed / 60)) $((elapsed % 60))
echo "  $named"
echo "  ${size} MB — cubechat $version_name+$version_code — stamp verified inside libapp.so"
if [ "$bundle" -eq 1 ]; then
  echo '  Upload to Play Console. This cannot be installed on a phone as it is —'
  echo '  use bundletool if you need the exact APKs Play would generate.'
else
  echo '  Install OVER the existing app. Uninstalling wipes the identity and breaks existing chats.'
fi
