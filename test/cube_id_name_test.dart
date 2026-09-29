import 'dart:convert';
import 'dart:io';

import 'package:cubechat/features/cube_id/domain/cube_name.dart';
import 'package:flutter_test/flutter_test.dart';

/// Same table as id/test/names.test.js, so the app never offers a name the
/// server refuses, or refuses one the server would take.
void main() {
  final cases = (jsonDecode(
    File('id/test/fixtures/name-cases.json').readAsStringSync(),
  ) as List<dynamic>)
      .cast<Map<String, dynamic>>();

  for (final c in cases) {
    test('name case ${c['input']}', () {
      final name = normalizeCubeName(c['input'] as String);
      expect(name, c['name']);
      expect(cubeNameProblem(name)?.name, c['problem']);
    });
  }
}
