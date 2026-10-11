import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cubechat/features/backup/data/windows_firewall.dart';
import 'package:flutter_test/flutter_test.dart';

/// The firewall rule the computer asks for before a phone can sign it in.
void main() {
  String decode(String encoded) {
    final bytes = ByteData.sublistView(base64.decode(encoded));
    return String.fromCharCodes([
      for (var i = 0; i < bytes.lengthInBytes; i += 2)
        bytes.getUint16(i, Endian.little),
    ]);
  }

  test('a path is a literal, never a command', () {
    expect(powerShellLiteral(r'C:\Program Files\CubeChat\cubechat.exe'),
        r"'C:\Program Files\CubeChat\cubechat.exe'");
    expect(powerShellLiteral(r"D:\it's\x.exe"), r"'D:\it''s\x.exe'");
    final script = allowScript(r"C:\a'; Remove-Item C:\ -Recurse; '\b.exe");
    expect(script, contains(r"'C:\a''; Remove-Item C:\ -Recurse; ''\b.exe'"));
  });

  test('the encoded script survives a Cyrillic path', () {
    const path = r'D:\Програми\CubeChat\cubechat.exe';
    final script = checkScript(path);
    expect(decode(encodePowerShell(script)), script);
    expect(script, contains(path));
  });

  test('the rule is inbound TCP for this program from the local subnet', () {
    final script = allowScript(r'C:\x\cubechat.exe');
    expect(script, contains('-Direction Inbound'));
    expect(script, contains('-Action Allow'));
    expect(script, contains('-Protocol TCP'));
    expect(script, contains('-RemoteAddress LocalSubnet'));
    expect(script, contains('-Program \$p'));
  });

  test(
    'a program with no rule is reported as not let in',
    () async {
      const firewall = WindowsFirewall(
        program: r'C:\nowhere\cubechat-firewall-test.exe',
      );
      expect(await firewall.allowsInbound(), isFalse);
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
