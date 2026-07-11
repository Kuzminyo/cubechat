import 'dart:convert';

import 'package:cubechat/core/transport/nostr/nostr_event.dart';
import 'package:flutter_test/flutter_test.dart';

NostrEvent _sample({int createdAt = 1700000000, String content = 'cc1:AAAA'}) {
  return NostrEvent(
    pubkey: 'aa' * 32,
    createdAt: createdAt,
    kind: 1059,
    tags: [
      ['p', 'bb' * 32],
    ],
    content: content,
  );
}

void main() {
  group('NostrEvent canonical serialization', () {
    test('matches the NIP-01 [0,pubkey,created_at,kind,tags,content] shape', () {
      final s = _sample().serializeForId();
      final expected =
          '[0,"${'aa' * 32}",1700000000,1059,[["p","${'bb' * 32}"]],"cc1:AAAA"]';
      expect(s, expected);
    });

    test('emits no insignificant whitespace', () {
      final s = _sample().serializeForId();
      expect(s.contains(' '), isFalse);
      expect(s.contains('\n'), isFalse);
    });

    test('escapes control characters in content per JSON rules', () {
      final s = _sample(content: 'a"b\nc').serializeForId();
      // Round-trips back to the original list, and the raw string carries the
      // escaped sequences rather than literal quote/newline.
      expect(s.contains(r'\n'), isTrue);
      expect(s.contains(r'\"'), isTrue);
      final decoded = jsonDecode(s) as List;
      expect(decoded.last, 'a"b\nc');
    });
  });

  group('NostrEvent id', () {
    test('computeId is a 64-char lowercase hex string', () async {
      final id = await _sample().computeId();
      expect(id.length, 64);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(id), isTrue);
    });

    test('is deterministic for identical fields', () async {
      expect(await _sample().computeId(), await _sample().computeId());
    });

    test('changes when any signed field changes', () async {
      final base = await _sample().computeId();
      expect(await _sample(createdAt: 1700000001).computeId(), isNot(base));
      expect(await _sample(content: 'cc1:AAAB').computeId(), isNot(base));
    });

    test('withId populates a matching id and hasValidId confirms it', () async {
      final signed = await _sample().withId();
      expect(signed.id, isNotNull);
      expect(await signed.hasValidId(), isTrue);
    });

    test('hasValidId rejects an id that no longer matches the fields', () async {
      final signed = await _sample().withId();
      final tampered = signed.copyWith(content: 'cc1:TAMPERED');
      expect(await tampered.hasValidId(), isFalse);
    });

    test('an event without an id is not valid', () async {
      expect(await _sample().hasValidId(), isFalse);
    });
  });

  group('NostrEvent json', () {
    test('round-trips through toJson/fromJson', () async {
      final original = await _sample().withId();
      final signed = original.copyWith(sig: 'ff' * 64);
      final restored = NostrEvent.fromJson(signed.toJson());
      expect(restored.pubkey, signed.pubkey);
      expect(restored.createdAt, signed.createdAt);
      expect(restored.kind, signed.kind);
      expect(restored.tags, signed.tags);
      expect(restored.content, signed.content);
      expect(restored.id, signed.id);
      expect(restored.sig, signed.sig);
    });

    test('omits id and sig from json until present', () {
      final json = _sample().toJson();
      expect(json.containsKey('id'), isFalse);
      expect(json.containsKey('sig'), isFalse);
    });
  });

  group('NostrEvent tags', () {
    test('firstTagValue finds the recipient p-tag', () {
      expect(_sample().firstTagValue('p'), 'bb' * 32);
      expect(_sample().firstTagValue('e'), isNull);
    });
  });
}
