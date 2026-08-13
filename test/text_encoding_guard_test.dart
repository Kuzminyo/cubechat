import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Byte sequences that only appear when UTF-8 text has been written back out
/// through the Windows Cyrillic code page — an em dash, an ellipsis or an emoji
/// re-encoded one byte at a time. Each result is itself valid UTF-8, so nothing
/// downstream complains: the app simply shows the wrong characters. A photo
/// label reached a phone as four Cyrillic letters, and the English chat list
/// spelled its search hint with three.
///
/// Named by what they were, and given as bytes rather than as text, so that
/// this file cannot trip its own check.
const _mojibake = <String, List<int>>{
  'em dash or ellipsis': [0xD0, 0xB2, 0xD0, 0x82],
  'emoji': [0xD1, 0x80, 0xD1, 0x9F],
  'middot': [0xD0, 0x92, 0xC2, 0xB7],
};

bool _contains(List<int> haystack, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

void main() {
  test('no source file carries code-page-mangled text', () {
    final offenders = <String>[];
    for (final dir in ['lib', 'test']) {
      for (final entity in Directory(dir).listSync(recursive: true)) {
        if (entity is! File) continue;
        if (!entity.path.endsWith('.dart') && !entity.path.endsWith('.arb')) {
          continue;
        }
        final bytes = entity.readAsBytesSync();
        for (final entry in _mojibake.entries) {
          if (_contains(bytes, entry.value)) {
            offenders.add('${entity.path}: ${entry.key}');
          }
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'Rewrite these files as UTF-8 — the tool that last saved them '
          'converted the text to the system code page:\n${offenders.join('\n')}',
    );
  });
}
