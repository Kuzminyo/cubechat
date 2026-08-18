/// Which build of cubechat this is, in the two forms anyone ever needs.
///
/// Both were already in the codebase and neither was reachable from the screen
/// that shows them. The version on the profile screen was a `const '0.1.0'`
/// written on the first day and never touched again — so a phone running
/// 0.40.0 said 0.1.0, and the one place a tester can check what they have was
/// the one place that lied. The stamp lived as a private constant in `main.dart`
/// where only the boot log could see it.
///
/// So: one file, two constants, and a build script that refuses to proceed if
/// [version] and `pubspec.yaml` disagree. That check is the point — the drift
/// this replaces was invisible precisely because nothing compared the two.
library;

/// Matches `version:` in pubspec.yaml, without the build number.
///
/// Bumped by hand alongside pubspec, and `tool/build_apk.ps1` verifies the two
/// agree before it will build.
const String appVersion = '0.47.1';

/// Which build, in words. Bumped for every APK that leaves this machine so a
/// tester can say what they are running without reading a number.
///
/// Verified inside `libapp.so` after every build — see `tool/build_apk.ps1`,
/// which is what catches a build that silently reused an old snapshot.
const String appBuildStamp = '2026-08-18-map-wakes-with-the-app';
