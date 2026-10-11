import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Lets the phone reach this computer when it signs in with the phone's
/// account. Windows only.
///
/// The sign-in is the one place the computer listens and the phone dials in,
/// and Windows Defender Firewall drops an incoming connection to a program it
/// has no rule for — silently, on a network marked Public, which is what a
/// home Wi-Fi is unless someone changed it. Measured on 2026-10-11: no rule for
/// cubechat.exe at all, Wi-Fi "Public", and the phone's connection simply never
/// answered. The installer runs without administrator rights, so it cannot add
/// the rule; the sign-in screen offers to, behind Windows' own consent prompt.
///
/// The rule is scoped as narrowly as the job allows: inbound TCP, to this
/// program's path only, from the local subnet only.
class WindowsFirewall {
  const WindowsFirewall({String? program}) : _program = program;

  final String? _program;

  static const ruleName = 'CubeChat (sign in from phone)';

  String get program => _program ?? Platform.resolvedExecutable;

  /// Whether an enabled rule lets the phone in, and no rule blocks it.
  ///
  /// A block rule wins over an allow rule — and Windows writes one itself when
  /// someone presses Cancel on its "allow access?" window.
  Future<bool> allowsInbound() async {
    final result = await _powershell(checkScript(program));
    return result.exitCode == 0;
  }

  /// Asks Windows, through its consent prompt, to let the phone in. False if
  /// the person declined or it did not take.
  Future<bool> allow() async {
    final elevated = encodePowerShell(allowScript(program));
    final result = await _powershell(
      'try { \$p = Start-Process powershell -Verb RunAs -Wait -PassThru '
      '-WindowStyle Hidden -ArgumentList '
      "'-NoProfile','-NonInteractive','-EncodedCommand','$elevated'; "
      'exit \$p.ExitCode } catch { exit 1 }',
    );
    return result.exitCode == 0 && await allowsInbound();
  }

  static Future<ProcessResult> _powershell(String script) => Process.run(
        'powershell',
        [
          '-NoProfile',
          '-NonInteractive',
          '-EncodedCommand',
          encodePowerShell(script),
        ],
      );
}

/// A PowerShell string literal: single quotes, with any inside doubled. Paths
/// go in this way so a folder name can never become a command.
String powerShellLiteral(String value) => "'${value.replaceAll("'", "''")}'";

/// What `-EncodedCommand` takes: the script as UTF-16LE in base64. Nothing
/// is quoted on the command line, and a path in Cyrillic survives.
String encodePowerShell(String script) {
  final units = script.codeUnits;
  final bytes = ByteData(units.length * 2);
  for (var i = 0; i < units.length; i++) {
    bytes.setUint16(i * 2, units[i], Endian.little);
  }
  return base64.encode(bytes.buffer.asUint8List());
}

/// Exits 0 when this program has an enabled inbound allow rule and no enabled
/// inbound block rule.
String checkScript(String program) => '''
\$rules = Get-NetFirewallApplicationFilter -Program ${powerShellLiteral(program)} -ErrorAction SilentlyContinue |
  Get-NetFirewallRule -ErrorAction SilentlyContinue |
  Where-Object { \$_.Direction -eq 'Inbound' -and \$_.Enabled -eq 'True' }
if (\$rules | Where-Object { \$_.Action -eq 'Block' }) { exit 2 }
if (\$rules | Where-Object { \$_.Action -eq 'Allow' }) { exit 0 }
exit 1
''';

/// Run elevated: drops this program's inbound rules — including a block
/// Windows wrote after a Cancel, or an allow for Private networks only — and
/// adds the one rule the sign-in needs.
String allowScript(String program) => '''
\$ErrorActionPreference = 'Stop'
\$p = ${powerShellLiteral(program)}
Get-NetFirewallApplicationFilter -Program \$p -ErrorAction SilentlyContinue |
  Get-NetFirewallRule -ErrorAction SilentlyContinue |
  Where-Object { \$_.Direction -eq 'Inbound' } |
  Remove-NetFirewallRule
New-NetFirewallRule -DisplayName ${powerShellLiteral(WindowsFirewall.ruleName)} -Direction Inbound -Action Allow -Program \$p -Protocol TCP -Profile Any -RemoteAddress LocalSubnet | Out-Null
''';
