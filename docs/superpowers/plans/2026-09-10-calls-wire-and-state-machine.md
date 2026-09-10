# Звонки, часть 1: провод и машина состояний — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** положить на провод тип `callSignal` и собрать машину состояний
звонка так, чтобы весь ход разговора — от набора до записи в историю — был
проверяем тестами на машине без телефона и без сервера.

**Architecture:** кодек нового внутреннего типа живёт в
`lib/core/transport/call_signal.dart` рядом с другими отдельными payload-ами
(`channel_poll.dart`, `shared_location.dart`); в `inner_payload.dart` попадает
только строка перечисления. Машина состояний — обычный `ChangeNotifier` в
`lib/features/call/domain/`, без Riverpod, без WebRTC и без нативного кода:
она получает сигналы, отдаёт сигналы через переданный ей колбэк и заводит
таймеры настоящим `Timer`, который тесты крутят через `fake_async`. Транспорт
получает один новый флаг тега, `MessagingService` — одну точку входа и одну
точку выхода.

**Tech Stack:** Dart, Flutter 3.41.x, `flutter_test`, `fake_async` (уже в
`dev_dependencies`).

**Spec:** `docs/superpowers/specs/2026-09-10-calls-design.md`

## Global Constraints

- Байт типа на проводе — `0xE7`. Диапазон `0xE7`–`0xEF` свободен; проверено
  чтением `lib/core/transport/inner_payload.dart`. Перед любым изменением на
  проводе загрузить навык `wire-protocol`.
- Сроки ровно такие и никакие другие: подтверждение «звоню» — 8 с, звонок без
  ответа — 45 с, срок годности приглашения — 60 с.
- Каждый декодер проверяет длины явно и бросает `FormatException` на плохом
  входе. Декодер, доверяющий входу, — это удалённое падение.
- Анализатор строгий: `strict-casts`, `strict-inference`, `strict-raw-types`,
  `prefer_final_locals`, `require_trailing_commas`.
- Комментарии объясняют почему, а не что, и несут измерение или наблюдение,
  которое оправдало решение.
- Работа в `messaging_service.dart` только аддитивная. Подсистемы оттуда не
  выносить.
- Тесты запускать `flutter test --no-pub <файл>`. Полный прогон в конце.
- Файлы с не-ASCII (кириллица, длинные тире) создавать и править только
  инструментами Write/Edit, никогда не через шелл: и Bash, и PowerShell на
  Windows перекодируют такое в обе стороны.
- Ничего из этого плана не требует телефона, сервера или coturn. Если шаг
  такое требует, он попал не в тот план.
- Два похожих имени, и путать их нельзя. `CallEndReason` — это байт на проводе,
  его видит собеседник. `CallEndCause` — внутреннее состояние, из него растёт
  запись в истории, и на провод оно не попадает никогда. Причина, по которой
  их двое: собеседнику не сообщают «я проиграл встречный вызов» и «у меня не
  собралось медиа», а истории это знать надо.

---

### Task 1: кодек `CallSignal`

**Files:**
- Create: `lib/core/transport/call_signal.dart`
- Modify: `lib/core/transport/inner_payload.dart` (одна строка перечисления)
- Test: `test/call_signal_test.dart`

**Interfaces:**
- Consumes: `packInnerPayload`, `unpackInnerPayload`, `InnerPayloadType` из
  `lib/core/transport/inner_payload.dart`.
- Produces:
  - `const int callIdLen = 16;`
  - `const int callSignalVersion = 0x01;`
  - `enum CallSignalKind { invite, ringing, accept, decline, busy, hangup }` с
    полем `int get tag` и `static CallSignalKind? fromByte(int b)`
  - `enum CallEndReason { hungUp, noAnswer, declined, busy, failed }` с полем
    `int get tag` и `static CallEndReason fromByte(int b)`
  - `class CallSignal` с полями `CallSignalKind kind`, `Uint8List callId`,
    `String? sdp`, `int? sentAtMs`, `CallEndReason? reason`; фабриками
    `CallSignal.invite({required Uint8List callId, required String sdp, required int sentAtMs})`,
    `CallSignal.ringing(Uint8List callId)`,
    `CallSignal.accept({required Uint8List callId, required String sdp})`,
    `CallSignal.decline({required Uint8List callId, required CallEndReason reason})`,
    `CallSignal.busy(Uint8List callId)`,
    `CallSignal.hangup({required Uint8List callId, required CallEndReason reason})`;
    методами `Uint8List encode()` и `static CallSignal decode(Uint8List bytes)`
  - `InnerPayloadType.callSignal` со значением `0xE7`

- [ ] **Step 1: Написать падающий тест**

Создать `test/call_signal_test.dart`:

```dart
import 'dart:typed_data';

import 'package:cubechat/core/transport/call_signal.dart';
import 'package:cubechat/core/transport/inner_payload.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Uint8List id(int seed) =>
      Uint8List.fromList(List.generate(callIdLen, (i) => (i + seed) & 0xff));

  group('CallSignal', () {
    test('an invite round-trips its sdp and the moment it was sent', () {
      final signal = CallSignal.invite(
        callId: id(3),
        sdp: 'v=0\r\no=- 1 2 IN IP4 0.0.0.0\r\n',
        sentAtMs: 1789000000123,
      );
      final back = CallSignal.decode(signal.encode());
      expect(back.kind, CallSignalKind.invite);
      expect(back.callId, equals(id(3)));
      expect(back.sdp, 'v=0\r\no=- 1 2 IN IP4 0.0.0.0\r\n');
      expect(back.sentAtMs, 1789000000123);
    });

    test('a timestamp past the 32-bit mark survives the round trip', () {
      // Milliseconds since the epoch need 41 bits. Encoding them with
      // `setUint64` would throw on the web build, and shifting by 32 is wrong
      // there too, so the two halves are cut arithmetically. This is the test
      // that catches somebody "simplifying" that back to a shift.
      final signal = CallSignal.invite(
        callId: id(0),
        sdp: 'x',
        sentAtMs: 0x1_0000_0001,
      );
      expect(CallSignal.decode(signal.encode()).sentAtMs, 0x1_0000_0001);
    });

    test('an accept carries sdp and nothing else', () {
      final back = CallSignal.decode(
        CallSignal.accept(callId: id(1), sdp: 'answer').encode(),
      );
      expect(back.kind, CallSignalKind.accept);
      expect(back.sdp, 'answer');
      expect(back.sentAtMs, isNull);
      expect(back.reason, isNull);
    });

    test('ringing and busy carry an id and an empty body', () {
      for (final signal in [CallSignal.ringing(id(2)), CallSignal.busy(id(2))]) {
        final back = CallSignal.decode(signal.encode());
        expect(back.callId, equals(id(2)));
        expect(back.sdp, isNull);
      }
    });

    test('a hangup round-trips its reason', () {
      final back = CallSignal.decode(
        CallSignal.hangup(callId: id(5), reason: CallEndReason.noAnswer)
            .encode(),
      );
      expect(back.kind, CallSignalKind.hangup);
      expect(back.reason, CallEndReason.noAnswer);
    });

    test('rides through the inner-payload tag', () {
      final wire = packInnerPayload(
        InnerPayloadType.callSignal,
        CallSignal.ringing(id(7)).encode(),
      );
      final unpacked = unpackInnerPayload(wire);
      expect(unpacked.type, InnerPayloadType.callSignal);
      expect(CallSignal.decode(unpacked.body).callId, equals(id(7)));
    });

    test('the tag byte is 0xE7 and nothing else claims it', () {
      expect(InnerPayloadType.callSignal.tag, 0xE7);
      final sameTag = InnerPayloadType.values
          .where((v) => v.tag == 0xE7)
          .toList(growable: false);
      expect(sameTag, hasLength(1));
    });

    test('a truncated buffer is rejected rather than read', () {
      final whole = CallSignal.ringing(id(1)).encode();
      for (var cut = 0; cut < whole.length; cut++) {
        expect(
          () => CallSignal.decode(Uint8List.sublistView(whole, 0, cut)),
          throwsA(isA<FormatException>()),
          reason: 'a buffer cut at $cut must not decode',
        );
      }
    });

    test('a body shorter than its own length field is rejected', () {
      final whole = CallSignal.accept(callId: id(1), sdp: 'answer').encode();
      whole[2 + callIdLen] = 0xff;
      expect(
        () => CallSignal.decode(whole),
        throwsA(isA<FormatException>()),
      );
    });

    test('an unknown version is rejected', () {
      final whole = CallSignal.ringing(id(1)).encode();
      whole[0] = 0x02;
      expect(() => CallSignal.decode(whole), throwsA(isA<FormatException>()));
    });

    test('an unknown kind is rejected', () {
      final whole = CallSignal.ringing(id(1)).encode();
      whole[1] = 0x7f;
      expect(() => CallSignal.decode(whole), throwsA(isA<FormatException>()));
    });

    test('an invite with no sdp is rejected', () {
      final whole = CallSignal.invite(
        callId: id(1),
        sdp: 'x',
        sentAtMs: 1,
      ).encode();
      // Cut the sdp byte off, and shorten the declared length to match, so the
      // only thing wrong is that an invite says nothing.
      final trimmed = Uint8List.sublistView(whole, 0, whole.length - 1);
      trimmed[3 + callIdLen] = 8;
      expect(
        () => CallSignal.decode(Uint8List.fromList(trimmed)),
        throwsA(isA<FormatException>()),
      );
    });

    test('a wrong-length call id is refused on encode', () {
      expect(
        () => CallSignal.ringing(Uint8List(8)).encode(),
        throwsA(isA<FormatException>()),
      );
    });

    test('an unknown reason from a newer build still ends the call', () {
      // Losing the label is survivable; a call that will not hang up is not.
      final whole = CallSignal.hangup(
        callId: id(1),
        reason: CallEndReason.hungUp,
      ).encode();
      whole[whole.length - 1] = 0x7e;
      expect(CallSignal.decode(whole).reason, CallEndReason.hungUp);
    });
  });
}
```

- [ ] **Step 2: Убедиться, что тест падает**

Run: `flutter test --no-pub test/call_signal_test.dart`
Expected: FAIL — компиляция не проходит, `call_signal.dart` не существует.

- [ ] **Step 3: Написать `lib/core/transport/call_signal.dart`**

```dart
import 'dart:convert';
import 'dart:typed_data';

/// Width of the identifier every frame of one call carries.
///
/// Sixteen random bytes, the same width as the transport `msgId`, so a log
/// line showing one is read the same way as a log line showing the other.
const int callIdLen = 16;

/// Version byte at the head of a [CallSignal] body.
const int callSignalVersion = 0x01;

/// Which step of a call one frame is.
enum CallSignalKind {
  invite(0x01),
  ringing(0x02),
  accept(0x03),
  decline(0x04),
  busy(0x05),
  hangup(0x06);

  const CallSignalKind(this.tag);
  final int tag;

  static CallSignalKind? fromByte(int b) {
    for (final v in CallSignalKind.values) {
      if (v.tag == b) return v;
    }
    return null;
  }
}

/// Why a call stopped, in one byte.
enum CallEndReason {
  hungUp(0x00),
  noAnswer(0x01),
  declined(0x02),
  busy(0x03),
  failed(0x04);

  const CallEndReason(this.tag);
  final int tag;

  /// Unknown reasons fall back rather than throw: a newer build inventing a
  /// reason should still be able to hang up on an older one. Losing the label
  /// costs a wrong word in the history; refusing the frame would leave the
  /// call ringing forever.
  static CallEndReason fromByte(int b) {
    for (final v in CallEndReason.values) {
      if (v.tag == b) return v;
    }
    return CallEndReason.hungUp;
  }
}

/// One frame of call signalling, carried inside the same envelope as text.
///
/// ```
///   [version:1][kind:1][callId:16][len:2][body:len]
/// ```
///
/// `len` is big-endian, matching the padded-text body next door. Bodies:
/// invite `[sentAtMs:8][sdp]`, accept `[sdp]`, decline and hangup
/// `[reason:1]`, ringing and busy empty.
///
/// **There is no payload type for ICE candidates and that is deliberate.**
/// Media is relayed through our own TURN by default, so exactly one candidate
/// exists and it is already inside the SDP. Trickling candidates one at a time
/// over a store-and-forward relay would be the expensive way to send
/// information that fits in the frame already being sent.
class CallSignal {
  const CallSignal._({
    required this.kind,
    required this.callId,
    this.sdp,
    this.sentAtMs,
    this.reason,
  });

  factory CallSignal.invite({
    required Uint8List callId,
    required String sdp,
    required int sentAtMs,
  }) {
    if (sdp.isEmpty) {
      throw const FormatException('an invite must carry an sdp');
    }
    return CallSignal._(
      kind: CallSignalKind.invite,
      callId: callId,
      sdp: sdp,
      sentAtMs: sentAtMs,
    );
  }

  factory CallSignal.ringing(Uint8List callId) =>
      CallSignal._(kind: CallSignalKind.ringing, callId: callId);

  factory CallSignal.accept({
    required Uint8List callId,
    required String sdp,
  }) {
    if (sdp.isEmpty) {
      throw const FormatException('an accept must carry an sdp');
    }
    return CallSignal._(
      kind: CallSignalKind.accept,
      callId: callId,
      sdp: sdp,
    );
  }

  factory CallSignal.decline({
    required Uint8List callId,
    required CallEndReason reason,
  }) =>
      CallSignal._(
        kind: CallSignalKind.decline,
        callId: callId,
        reason: reason,
      );

  factory CallSignal.busy(Uint8List callId) =>
      CallSignal._(kind: CallSignalKind.busy, callId: callId);

  factory CallSignal.hangup({
    required Uint8List callId,
    required CallEndReason reason,
  }) =>
      CallSignal._(
        kind: CallSignalKind.hangup,
        callId: callId,
        reason: reason,
      );

  final CallSignalKind kind;
  final Uint8List callId;
  final String? sdp;
  final int? sentAtMs;
  final CallEndReason? reason;

  static const int _headerLen = 4 + callIdLen;

  Uint8List encode() {
    if (callId.length != callIdLen) {
      throw const FormatException('call id must be 16 bytes');
    }
    final body = _body();
    if (body.length > 0xffff) {
      throw const FormatException('call signal body too long');
    }
    final out = Uint8List(_headerLen + body.length);
    out[0] = callSignalVersion;
    out[1] = kind.tag;
    out.setRange(2, 2 + callIdLen, callId);
    out[2 + callIdLen] = (body.length >> 8) & 0xff;
    out[3 + callIdLen] = body.length & 0xff;
    out.setRange(_headerLen, out.length, body);
    return out;
  }

  Uint8List _body() {
    switch (kind) {
      case CallSignalKind.invite:
        final sdpBytes = utf8.encode(sdp!);
        final out = Uint8List(8 + sdpBytes.length);
        // Split arithmetically, not with `>> 32`. Milliseconds since the epoch
        // need 41 bits; on the web build an int is a double and a shift is
        // 32-bit, so a shift silently loses the top of the number there.
        final view = ByteData.sublistView(out);
        view.setUint32(0, sentAtMs! ~/ 0x100000000);
        view.setUint32(4, sentAtMs! % 0x100000000);
        out.setRange(8, out.length, sdpBytes);
        return out;
      case CallSignalKind.accept:
        return Uint8List.fromList(utf8.encode(sdp!));
      case CallSignalKind.decline:
      case CallSignalKind.hangup:
        return Uint8List.fromList([reason!.tag]);
      case CallSignalKind.ringing:
      case CallSignalKind.busy:
        return Uint8List(0);
    }
  }

  static CallSignal decode(Uint8List bytes) {
    if (bytes.length < _headerLen) {
      throw const FormatException('call signal truncated');
    }
    if (bytes[0] != callSignalVersion) {
      throw FormatException('unknown call signal version ${bytes[0]}');
    }
    final kind = CallSignalKind.fromByte(bytes[1]);
    if (kind == null) {
      throw FormatException(
          'unknown call signal kind 0x${bytes[1].toRadixString(16)}');
    }
    final callId = Uint8List.fromList(bytes.sublist(2, 2 + callIdLen));
    final len = (bytes[2 + callIdLen] << 8) | bytes[3 + callIdLen];
    if (bytes.length < _headerLen + len) {
      throw const FormatException('call signal body truncated');
    }
    final body = Uint8List.sublistView(bytes, _headerLen, _headerLen + len);
    switch (kind) {
      case CallSignalKind.invite:
        if (body.length <= 8) {
          throw const FormatException('an invite must carry an sdp');
        }
        final view = ByteData.sublistView(body);
        final at = view.getUint32(0) * 0x100000000 + view.getUint32(4);
        return CallSignal.invite(
          callId: callId,
          sdp: utf8.decode(body.sublist(8)),
          sentAtMs: at,
        );
      case CallSignalKind.accept:
        if (body.isEmpty) {
          throw const FormatException('an accept must carry an sdp');
        }
        return CallSignal.accept(callId: callId, sdp: utf8.decode(body));
      case CallSignalKind.decline:
        if (body.isEmpty) {
          throw const FormatException('a decline must carry a reason');
        }
        return CallSignal.decline(
          callId: callId,
          reason: CallEndReason.fromByte(body[0]),
        );
      case CallSignalKind.hangup:
        if (body.isEmpty) {
          throw const FormatException('a hangup must carry a reason');
        }
        return CallSignal.hangup(
          callId: callId,
          reason: CallEndReason.fromByte(body[0]),
        );
      case CallSignalKind.ringing:
        return CallSignal.ringing(callId);
      case CallSignalKind.busy:
        return CallSignal.busy(callId);
    }
  }
}
```

- [ ] **Step 4: Добавить строку в перечисление**

В `lib/core/transport/inner_payload.dart`, сразу после записи
`channelDelete(0xE6)` и перед закрывающей `;`, поменять `channelDelete(0xE6);`
на `channelDelete(0xE6),` и дописать:

```dart
  /// One frame of call signalling: an invite, its acknowledgement, an accept,
  /// a decline, a busy or a hangup. See [CallSignal] in `call_signal.dart`.
  ///
  /// 0xE7 was verified free against this enum before it was taken; the range
  /// 0xE7-0xEF is still empty after it. An older build drops an unknown inner
  /// type silently, so the caller does not treat a call as ringing until the
  /// explicit acknowledgement arrives — otherwise calling an old build would
  /// ring forever against a phone that never heard anything.
  callSignal(0xE7);
```

- [ ] **Step 5: Прогнать тест**

Run: `flutter test --no-pub test/call_signal_test.dart`
Expected: PASS, все тесты группы.

- [ ] **Step 6: Проверить анализатор так, как это делает CI**

Локальный `flutter analyze | grep` уже один раз соврал в этом репозитории:
собственное выражение находило ноль, а выражение из workflow — четыре
предупреждения. Поэтому вывод всегда сначала в файл, и грепается выражением
самого workflow.

```bash
flutter analyze > analyze.log 2>&1; grep -E '^[[:space:]]*(error|warning)[[:space:]]*[-•]' analyze.log
```

Expected: ни одной строки.

- [ ] **Step 7: Коммит**

```bash
git add lib/core/transport/call_signal.dart lib/core/transport/inner_payload.dart test/call_signal_test.dart
git commit -m "Put call signalling on the wire at 0xE7, with one candidate already inside the sdp"
```

---

### Task 2: правила звонка — срок годности и встречный вызов

**Files:**
- Create: `lib/features/call/domain/call_rules.dart`
- Test: `test/call_rules_test.dart`

**Interfaces:**
- Consumes: `callIdLen` из `lib/core/transport/call_signal.dart`.
- Produces:
  - `abstract final class CallTimings` со статическими полями
    `Duration ringingAck`, `Duration noAnswer`, `Duration inviteFreshness`
  - `bool inviteIsFresh({required int sentAtMs, required DateTime now})`
  - `bool winsGlare({required Uint8List mine, required Uint8List theirs})`

- [ ] **Step 1: Написать падающий тест**

Создать `test/call_rules_test.dart`:

```dart
import 'dart:typed_data';

import 'package:cubechat/features/call/domain/call_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 10, 12, 0, 0);
  int msAgo(Duration d) => now.subtract(d).millisecondsSinceEpoch;

  group('invite freshness', () {
    test('an invite sent a moment ago is fresh', () {
      expect(
        inviteIsFresh(sentAtMs: msAgo(const Duration(seconds: 2)), now: now),
        isTrue,
      );
    });

    test('an invite from an hour ago is not', () {
      // Relays hold events and hand them over on connect, so an invite from an
      // hour ago arrives looking new. A phone that rings an hour after a call
      // that never happened is a ghost, and this is the line that stops it.
      expect(
        inviteIsFresh(sentAtMs: msAgo(const Duration(hours: 1)), now: now),
        isFalse,
      );
    });

    test('the boundary itself is still fresh', () {
      expect(
        inviteIsFresh(sentAtMs: msAgo(CallTimings.inviteFreshness), now: now),
        isTrue,
      );
    });

    test('one millisecond past the boundary is not', () {
      expect(
        inviteIsFresh(
          sentAtMs: msAgo(CallTimings.inviteFreshness) - 1,
          now: now,
        ),
        isFalse,
      );
    });

    test('a clock a little ahead of ours is tolerated, a lot is not', () {
      // Phone clocks disagree. A few seconds of drift must not kill a real
      // call; a timestamp days in the future is not drift, it is nonsense.
      expect(
        inviteIsFresh(
          sentAtMs: now.add(const Duration(seconds: 5)).millisecondsSinceEpoch,
          now: now,
        ),
        isTrue,
      );
      expect(
        inviteIsFresh(
          sentAtMs: now.add(const Duration(days: 1)).millisecondsSinceEpoch,
          now: now,
        ),
        isFalse,
      );
    });
  });

  group('glare', () {
    Uint8List idOf(List<int> head) => Uint8List.fromList(
          [...head, ...List.filled(callIdLen - head.length, 0)],
        );

    test('the smaller id wins, and both sides agree', () {
      final low = idOf([0x01]);
      final high = idOf([0x02]);
      expect(winsGlare(mine: low, theirs: high), isTrue);
      expect(winsGlare(mine: high, theirs: low), isFalse);
    });

    test('the comparison reads past the first byte', () {
      final a = idOf([0x05, 0x01]);
      final b = idOf([0x05, 0x02]);
      expect(winsGlare(mine: a, theirs: b), isTrue);
      expect(winsGlare(mine: b, theirs: a), isFalse);
    });

    test('two identical ids are not a contest either side wins', () {
      // Sixteen random bytes never collide in practice. If they did, both
      // sides deciding "I win" would leave two half-calls, so both lose.
      final same = idOf([0x09]);
      expect(winsGlare(mine: same, theirs: same), isFalse);
    });
  });
}
```

- [ ] **Step 2: Убедиться, что тест падает**

Run: `flutter test --no-pub test/call_rules_test.dart`
Expected: FAIL — `call_rules.dart` не существует.

- [ ] **Step 3: Написать `lib/features/call/domain/call_rules.dart`**

```dart
import 'dart:typed_data';

import '../../../core/transport/call_signal.dart';

/// How long each part of a call is allowed to take.
///
/// Three numbers, and the order between them is the point: an invite outlives
/// the ringing it starts, so a call that is still being answered is never
/// thrown away as stale, while yesterday's invite still is.
abstract final class CallTimings {
  /// How long the caller waits for the callee's acknowledgement before saying
  /// the person is unavailable.
  ///
  /// An older build drops an unknown inner type silently, so silence here is
  /// the only signal that the other end cannot take calls at all. Ringing on
  /// against a phone that heard nothing is the failure this replaces.
  static const Duration ringingAck = Duration(seconds: 8);

  /// How long a call rings before it becomes a missed call.
  static const Duration noAnswer = Duration(seconds: 45);

  /// How old an invite may be and still ring a phone.
  static const Duration inviteFreshness = Duration(seconds: 60);

  /// How far ahead of us a sender's clock may be before the timestamp is
  /// nonsense rather than drift.
  static const Duration clockSkew = Duration(seconds: 30);
}

/// Whether an invite stamped [sentAtMs] should ring a phone at [now].
bool inviteIsFresh({required int sentAtMs, required DateTime now}) {
  final age = now.millisecondsSinceEpoch - sentAtMs;
  if (age < 0) return -age <= CallTimings.clockSkew.inMilliseconds;
  return age <= CallTimings.inviteFreshness.inMilliseconds;
}

/// Whether our own call wins when both sides dialled at once.
///
/// Byte-for-byte, lower wins. Both sides run the same comparison over the same
/// two ids and reach the same answer, so no negotiation is needed and there is
/// no round trip in which the two could disagree.
bool winsGlare({required Uint8List mine, required Uint8List theirs}) {
  for (var i = 0; i < callIdLen; i++) {
    if (mine[i] != theirs[i]) return mine[i] < theirs[i];
  }
  // Identical ids cannot happen with sixteen random bytes, and if they did,
  // both sides claiming victory would leave two half-calls. Both lose instead.
  return false;
}
```

- [ ] **Step 4: Прогнать тест**

Run: `flutter test --no-pub test/call_rules_test.dart`
Expected: PASS.

- [ ] **Step 5: Коммит**

```bash
git add lib/features/call/domain/call_rules.dart test/call_rules_test.dart
git commit -m "Name the three call deadlines, and settle a simultaneous dial without a round trip"
```

---

### Task 3: машина состояний, исходящий звонок

**Files:**
- Create: `lib/features/call/domain/call_state_machine.dart`
- Test: `test/call_state_machine_outgoing_test.dart`

**Interfaces:**
- Consumes: `CallSignal`, `CallSignalKind`, `CallEndReason`, `callIdLen` из
  `lib/core/transport/call_signal.dart`; `CallTimings`, `inviteIsFresh`,
  `winsGlare` из `lib/features/call/domain/call_rules.dart`.
- Produces:
  - `enum CallPhase { idle, dialing, ringing, incoming, connecting, talking, ended }`
  - `enum CallEndCause { hungUp, declined, busy, noAnswer, unavailable, failed, glareLost }`
  - `class CallOutcome` с полями `Uint8List callId`, `bool outgoing`,
    `CallEndCause cause`, `Duration talkedFor`
  - `class CallStateMachine extends ChangeNotifier` с конструктором
    `CallStateMachine({required Future<void> Function(CallSignal signal) send, required void Function(CallOutcome outcome) onOutcome, required DateTime Function() now})`,
    геттерами `CallPhase get phase` и `Uint8List? get callId`, и методами
    `void startOutgoing({required Uint8List callId, required String sdp})`,
    `void handleSignal(CallSignal signal)`, `void accept({required String sdp})`,
    `void decline()`, `void hangUp()`, `void mediaConnected()`,
    `void mediaFailed()`

Входящий путь и встречный звонок доделываются в задаче 4; здесь `handleSignal`
обрабатывает только ответы на наше собственное приглашение.

- [ ] **Step 1: Написать падающий тест**

Создать `test/call_state_machine_outgoing_test.dart`:

```dart
import 'dart:typed_data';

import 'package:cubechat/core/transport/call_signal.dart';
import 'package:cubechat/features/call/domain/call_rules.dart';
import 'package:cubechat/features/call/domain/call_state_machine.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Uint8List id(int seed) =>
      Uint8List.fromList(List.generate(callIdLen, (i) => (i + seed) & 0xff));

  /// A machine plus the two things it says to the outside world.
  ({
    CallStateMachine machine,
    List<CallSignal> sent,
    List<CallOutcome> outcomes,
  }) build(FakeAsync async) {
    final sent = <CallSignal>[];
    final outcomes = <CallOutcome>[];
    final machine = CallStateMachine(
      send: (signal) async => sent.add(signal),
      onOutcome: outcomes.add,
      now: () => DateTime.fromMillisecondsSinceEpoch(
        async.elapsed.inMilliseconds,
        isUtc: true,
      ),
    );
    return (machine: machine, sent: sent, outcomes: outcomes);
  }

  test('dialing sends an invite and is not yet ringing', () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.startOutgoing(callId: id(1), sdp: 'offer');
      async.flushMicrotasks();
      expect(t.machine.phase, CallPhase.dialing);
      expect(t.sent.single.kind, CallSignalKind.invite);
      expect(t.sent.single.sdp, 'offer');
      expect(t.sent.single.callId, equals(id(1)));
      t.machine.dispose();
    });
  });

  test('the ringback starts only when the other end says it is ringing', () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.startOutgoing(callId: id(1), sdp: 'offer');
      async.elapse(const Duration(seconds: 2));
      expect(t.machine.phase, CallPhase.dialing);
      t.machine.handleSignal(CallSignal.ringing(id(1)));
      expect(t.machine.phase, CallPhase.ringing);
      t.machine.dispose();
    });
  });

  test('no acknowledgement means unavailable, not an endless ringback', () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.startOutgoing(callId: id(1), sdp: 'offer');
      async.elapse(CallTimings.ringingAck + const Duration(milliseconds: 1));
      expect(t.machine.phase, CallPhase.ended);
      expect(t.outcomes.single.cause, CallEndCause.unavailable);
      expect(t.outcomes.single.outgoing, isTrue);
      t.machine.dispose();
    });
  });

  test('an accept moves to connecting, and media moves it to talking', () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.startOutgoing(callId: id(1), sdp: 'offer');
      t.machine.handleSignal(CallSignal.ringing(id(1)));
      t.machine.handleSignal(CallSignal.accept(callId: id(1), sdp: 'answer'));
      expect(t.machine.phase, CallPhase.connecting);
      t.machine.mediaConnected();
      expect(t.machine.phase, CallPhase.talking);
      t.machine.dispose();
    });
  });

  test('forty-five seconds of ringing becomes a missed call and hangs up', () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.startOutgoing(callId: id(1), sdp: 'offer');
      t.machine.handleSignal(CallSignal.ringing(id(1)));
      async.elapse(CallTimings.noAnswer + const Duration(milliseconds: 1));
      async.flushMicrotasks();
      expect(t.machine.phase, CallPhase.ended);
      expect(t.outcomes.single.cause, CallEndCause.noAnswer);
      expect(t.sent.last.kind, CallSignalKind.hangup);
      expect(t.sent.last.reason, CallEndReason.noAnswer);
      t.machine.dispose();
    });
  });

  test('a decline ends the call and does not send a hangup back', () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.startOutgoing(callId: id(1), sdp: 'offer');
      t.machine.handleSignal(CallSignal.ringing(id(1)));
      t.machine.handleSignal(
        CallSignal.decline(callId: id(1), reason: CallEndReason.declined),
      );
      async.flushMicrotasks();
      expect(t.machine.phase, CallPhase.ended);
      expect(t.outcomes.single.cause, CallEndCause.declined);
      expect(
        t.sent.where((s) => s.kind == CallSignalKind.hangup),
        isEmpty,
        reason: 'the other end already stopped; telling it to stop is noise',
      );
      t.machine.dispose();
    });
  });

  test('busy is its own outcome', () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.startOutgoing(callId: id(1), sdp: 'offer');
      t.machine.handleSignal(CallSignal.busy(id(1)));
      async.flushMicrotasks();
      expect(t.outcomes.single.cause, CallEndCause.busy);
      t.machine.dispose();
    });
  });

  test('hanging up mid-conversation records how long it lasted', () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.startOutgoing(callId: id(1), sdp: 'offer');
      t.machine.handleSignal(CallSignal.ringing(id(1)));
      t.machine.handleSignal(CallSignal.accept(callId: id(1), sdp: 'answer'));
      t.machine.mediaConnected();
      async.elapse(const Duration(minutes: 2, seconds: 31));
      t.machine.hangUp();
      async.flushMicrotasks();
      expect(t.machine.phase, CallPhase.ended);
      expect(t.outcomes.single.talkedFor,
          const Duration(minutes: 2, seconds: 31));
      expect(t.outcomes.single.cause, CallEndCause.hungUp);
      expect(t.sent.last.kind, CallSignalKind.hangup);
      t.machine.dispose();
    });
  });

  test('a call that never connected lasted no time at all', () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.startOutgoing(callId: id(1), sdp: 'offer');
      t.machine.handleSignal(CallSignal.ringing(id(1)));
      async.elapse(const Duration(seconds: 10));
      t.machine.hangUp();
      async.flushMicrotasks();
      expect(t.outcomes.single.talkedFor, Duration.zero);
      t.machine.dispose();
    });
  });

  test('media failing ends the call rather than hanging in connecting', () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.startOutgoing(callId: id(1), sdp: 'offer');
      t.machine.handleSignal(CallSignal.ringing(id(1)));
      t.machine.handleSignal(CallSignal.accept(callId: id(1), sdp: 'answer'));
      t.machine.mediaFailed();
      async.flushMicrotasks();
      expect(t.machine.phase, CallPhase.ended);
      expect(t.outcomes.single.cause, CallEndCause.failed);
      t.machine.dispose();
    });
  });

  test('a signal for some other call is ignored', () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.startOutgoing(callId: id(1), sdp: 'offer');
      t.machine.handleSignal(CallSignal.ringing(id(9)));
      expect(t.machine.phase, CallPhase.dialing);
      t.machine.dispose();
    });
  });

  test('the same acknowledgement twice does not restart anything', () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.startOutgoing(callId: id(1), sdp: 'offer');
      t.machine.handleSignal(CallSignal.ringing(id(1)));
      async.elapse(const Duration(seconds: 40));
      t.machine.handleSignal(CallSignal.ringing(id(1)));
      async.elapse(const Duration(seconds: 6));
      async.flushMicrotasks();
      expect(t.outcomes.single.cause, CallEndCause.noAnswer,
          reason: 'a repeat delivery must not buy another forty-five seconds');
      t.machine.dispose();
    });
  });

  test('exactly one outcome per call, no matter what arrives after', () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.startOutgoing(callId: id(1), sdp: 'offer');
      t.machine.handleSignal(CallSignal.ringing(id(1)));
      t.machine.hangUp();
      t.machine.handleSignal(
        CallSignal.hangup(callId: id(1), reason: CallEndReason.hungUp),
      );
      t.machine.mediaFailed();
      async.flushMicrotasks();
      expect(t.outcomes, hasLength(1));
      t.machine.dispose();
    });
  });

  test('no timer outlives the machine', () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.startOutgoing(callId: id(1), sdp: 'offer');
      t.machine.dispose();
      async.elapse(const Duration(minutes: 5));
      expect(async.pendingTimers, isEmpty);
    });
  });
}
```

- [ ] **Step 2: Убедиться, что тест падает**

Run: `flutter test --no-pub test/call_state_machine_outgoing_test.dart`
Expected: FAIL — `call_state_machine.dart` не существует.

- [ ] **Step 3: Написать `lib/features/call/domain/call_state_machine.dart`**

```dart
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../../core/transport/call_signal.dart';
import 'call_rules.dart';

/// Where a call is, from the point of view of the person holding the phone.
enum CallPhase { idle, dialing, ringing, incoming, connecting, talking, ended }

/// How a call finished, in the words the history will use.
enum CallEndCause {
  hungUp,
  declined,
  busy,
  noAnswer,
  unavailable,
  failed,
  glareLost,
}

/// What a finished call leaves behind.
@immutable
class CallOutcome {
  const CallOutcome({
    required this.callId,
    required this.outgoing,
    required this.cause,
    required this.talkedFor,
  });

  final Uint8List callId;
  final bool outgoing;
  final CallEndCause cause;

  /// Time actually spent talking, which is zero for everything that never
  /// connected. The ringing is not part of it.
  final Duration talkedFor;
}

/// The whole life of one call, with no media, no platform and no transport in
/// it.
///
/// Everything this needs from the outside arrives through the constructor:
/// [send] puts one frame on the wire, [onOutcome] is called exactly once when
/// the call is over, and [now] is the clock. Keeping the three injected is
/// what lets `fake_async` drive a forty-five second ring in a millisecond,
/// and it is the only reason the hard parts of a call are testable at all on
/// a machine with no phone attached.
class CallStateMachine extends ChangeNotifier {
  CallStateMachine({
    required this.send,
    required this.onOutcome,
    required this.now,
  });

  final Future<void> Function(CallSignal signal) send;
  final void Function(CallOutcome outcome) onOutcome;
  final DateTime Function() now;

  CallPhase _phase = CallPhase.idle;
  Uint8List? _callId;
  bool _outgoing = false;
  DateTime? _talkingSince;
  Timer? _deadline;

  CallPhase get phase => _phase;
  Uint8List? get callId => _callId;

  /// Whether [signal] belongs to the call this machine is running.
  bool _isOurs(CallSignal signal) {
    final mine = _callId;
    if (mine == null) return false;
    for (var i = 0; i < callIdLen; i++) {
      if (mine[i] != signal.callId[i]) return false;
    }
    return true;
  }

  void startOutgoing({required Uint8List callId, required String sdp}) {
    if (_phase != CallPhase.idle) return;
    _callId = callId;
    _outgoing = true;
    _move(CallPhase.dialing);
    unawaited(send(CallSignal.invite(
      callId: callId,
      sdp: sdp,
      sentAtMs: now().millisecondsSinceEpoch,
    )));
    // The acknowledgement, not the invite, is what turns a dial into a ring.
    _arm(CallTimings.ringingAck, () => _end(CallEndCause.unavailable));
  }

  void handleSignal(CallSignal signal) {
    if (!_isOurs(signal)) return;
    switch (signal.kind) {
      case CallSignalKind.ringing:
        if (_phase != CallPhase.dialing) return;
        _move(CallPhase.ringing);
        _arm(CallTimings.noAnswer, () {
          _sendHangup(CallEndReason.noAnswer);
          _end(CallEndCause.noAnswer);
        });
      case CallSignalKind.accept:
        if (_phase != CallPhase.ringing) return;
        _disarm();
        _move(CallPhase.connecting);
      case CallSignalKind.decline:
        // The other end has already stopped. Telling it to stop is noise.
        _end(CallEndCause.declined);
      case CallSignalKind.busy:
        _end(CallEndCause.busy);
      case CallSignalKind.hangup:
        _end(CallEndCause.hungUp);
      case CallSignalKind.invite:
        // Incoming calls arrive in the next task; an invite for a call we are
        // already running is a repeat delivery and changes nothing.
        return;
    }
  }

  void accept({required String sdp}) {
    if (_phase != CallPhase.incoming) return;
    _disarm();
    unawaited(send(CallSignal.accept(callId: _callId!, sdp: sdp)));
    _move(CallPhase.connecting);
  }

  void decline() {
    if (_phase != CallPhase.incoming) return;
    unawaited(send(CallSignal.decline(
      callId: _callId!,
      reason: CallEndReason.declined,
    )));
    _end(CallEndCause.declined);
  }

  void hangUp() {
    if (_phase == CallPhase.idle || _phase == CallPhase.ended) return;
    _sendHangup(CallEndReason.hungUp);
    _end(CallEndCause.hungUp);
  }

  void mediaConnected() {
    if (_phase != CallPhase.connecting) return;
    _talkingSince = now();
    _move(CallPhase.talking);
  }

  void mediaFailed() {
    if (_phase == CallPhase.idle || _phase == CallPhase.ended) return;
    _sendHangup(CallEndReason.failed);
    _end(CallEndCause.failed);
  }

  void _sendHangup(CallEndReason reason) {
    final id = _callId;
    if (id == null) return;
    unawaited(send(CallSignal.hangup(callId: id, reason: reason)));
  }

  void _move(CallPhase next) {
    _phase = next;
    notifyListeners();
  }

  void _arm(Duration after, void Function() fire) {
    _disarm();
    _deadline = Timer(after, fire);
  }

  void _disarm() {
    _deadline?.cancel();
    _deadline = null;
  }

  /// Exactly one outcome per call, whatever arrives afterwards.
  ///
  /// Late frames are normal rather than exceptional: a hangup crossing our own
  /// hangup in flight is one round trip, and a media failure reported after
  /// the user already hung up is one frame. Both used to be able to write a
  /// second line into the history for the same call.
  void _end(CallEndCause cause) {
    if (_phase == CallPhase.ended || _phase == CallPhase.idle) return;
    _disarm();
    final since = _talkingSince;
    final outcome = CallOutcome(
      callId: _callId!,
      outgoing: _outgoing,
      cause: cause,
      talkedFor: since == null ? Duration.zero : now().difference(since),
    );
    _move(CallPhase.ended);
    onOutcome(outcome);
  }

  @override
  void dispose() {
    _disarm();
    super.dispose();
  }
}
```

- [ ] **Step 4: Прогнать тест**

Run: `flutter test --no-pub test/call_state_machine_outgoing_test.dart`
Expected: PASS.

- [ ] **Step 5: Коммит**

```bash
git add lib/features/call/domain/call_state_machine.dart test/call_state_machine_outgoing_test.dart
git commit -m "Run an outgoing call as a clock and six states, with no media in it"
```

---

### Task 4: входящий звонок и встречный вызов

**Files:**
- Modify: `lib/features/call/domain/call_state_machine.dart`
- Test: `test/call_state_machine_incoming_test.dart`

**Interfaces:**
- Consumes: всё из задачи 3.
- Produces: у `CallStateMachine` появляется метод
  `void handleInvite(CallSignal invite)`, а ветка `CallSignalKind.invite` в
  `handleSignal` начинает вести к нему. Публичная поверхность больше не
  меняется.

- [ ] **Step 1: Написать падающий тест**

Создать `test/call_state_machine_incoming_test.dart`:

```dart
import 'dart:typed_data';

import 'package:cubechat/core/transport/call_signal.dart';
import 'package:cubechat/features/call/domain/call_rules.dart';
import 'package:cubechat/features/call/domain/call_state_machine.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Uint8List id(int seed) =>
      Uint8List.fromList(List.generate(callIdLen, (i) => (i + seed) & 0xff));

  ({
    CallStateMachine machine,
    List<CallSignal> sent,
    List<CallOutcome> outcomes,
    DateTime Function() clock,
  }) build(FakeAsync async) {
    final sent = <CallSignal>[];
    final outcomes = <CallOutcome>[];
    // Start the clock well away from zero so an invite can be stamped in the
    // past without the arithmetic going negative.
    DateTime clock() => DateTime.utc(2026, 9, 10, 12).add(async.elapsed);
    final machine = CallStateMachine(
      send: (signal) async => sent.add(signal),
      onOutcome: outcomes.add,
      now: clock,
    );
    return (machine: machine, sent: sent, outcomes: outcomes, clock: clock);
  }

  CallSignal inviteAt(Uint8List callId, DateTime at) => CallSignal.invite(
        callId: callId,
        sdp: 'offer',
        sentAtMs: at.millisecondsSinceEpoch,
      );

  test('a fresh invite rings and acknowledges immediately', () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.handleInvite(inviteAt(id(1), t.clock()));
      async.flushMicrotasks();
      expect(t.machine.phase, CallPhase.incoming);
      expect(t.sent.single.kind, CallSignalKind.ringing);
      expect(t.sent.single.callId, equals(id(1)));
      t.machine.dispose();
    });
  });

  test('an invite from an hour ago rings nothing and answers nothing', () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.handleInvite(
        inviteAt(id(1), t.clock().subtract(const Duration(hours: 1))),
      );
      async.flushMicrotasks();
      expect(t.machine.phase, CallPhase.idle);
      expect(t.sent, isEmpty,
          reason: 'answering a stale invite would ring the caller back for a '
              'call they gave up on an hour ago');
      expect(t.outcomes, isEmpty);
      t.machine.dispose();
    });
  });

  test('the same invite delivered twice rings once', () {
    fakeAsync((async) {
      final t = build(async);
      final invite = inviteAt(id(1), t.clock());
      t.machine.handleInvite(invite);
      t.machine.handleInvite(invite);
      async.flushMicrotasks();
      expect(t.sent, hasLength(1));
      t.machine.dispose();
    });
  });

  test('an invite arriving mid-conversation answers busy and changes nothing',
      () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.handleInvite(inviteAt(id(1), t.clock()));
      t.machine.accept(sdp: 'answer');
      t.machine.mediaConnected();
      t.machine.handleInvite(inviteAt(id(2), t.clock()));
      async.flushMicrotasks();
      expect(t.machine.phase, CallPhase.talking);
      expect(t.machine.callId, equals(id(1)));
      final busy = t.sent.where((s) => s.kind == CallSignalKind.busy);
      expect(busy.single.callId, equals(id(2)));
      t.machine.dispose();
    });
  });

  test('accepting sends the answer and connects', () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.handleInvite(inviteAt(id(1), t.clock()));
      t.machine.accept(sdp: 'answer');
      async.flushMicrotasks();
      expect(t.machine.phase, CallPhase.connecting);
      expect(t.sent.last.kind, CallSignalKind.accept);
      expect(t.sent.last.sdp, 'answer');
      t.machine.mediaConnected();
      expect(t.machine.phase, CallPhase.talking);
      t.machine.dispose();
    });
  });

  test('declining tells the caller and records a declined call', () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.handleInvite(inviteAt(id(1), t.clock()));
      t.machine.decline();
      async.flushMicrotasks();
      expect(t.sent.last.kind, CallSignalKind.decline);
      expect(t.machine.phase, CallPhase.ended);
      expect(t.outcomes.single.cause, CallEndCause.declined);
      expect(t.outcomes.single.outgoing, isFalse);
      t.machine.dispose();
    });
  });

  test('an unanswered incoming call becomes a missed call on its own', () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.handleInvite(inviteAt(id(1), t.clock()));
      async.elapse(CallTimings.noAnswer + const Duration(milliseconds: 1));
      async.flushMicrotasks();
      expect(t.machine.phase, CallPhase.ended);
      expect(t.outcomes.single.cause, CallEndCause.noAnswer);
      expect(t.outcomes.single.outgoing, isFalse);
      t.machine.dispose();
    });
  });

  test('the caller hanging up stops the ringing', () {
    fakeAsync((async) {
      final t = build(async);
      t.machine.handleInvite(inviteAt(id(1), t.clock()));
      t.machine.handleSignal(
        CallSignal.hangup(callId: id(1), reason: CallEndReason.hungUp),
      );
      async.flushMicrotasks();
      expect(t.machine.phase, CallPhase.ended);
      expect(t.outcomes.single.cause, CallEndCause.hungUp);
      t.machine.dispose();
    });
  });

  group('both dialled at once', () {
    test('the smaller id wins and its own call carries on', () {
      fakeAsync((async) {
        final t = build(async);
        t.machine.startOutgoing(callId: id(1), sdp: 'offer');
        t.machine.handleInvite(inviteAt(id(2), t.clock()));
        async.flushMicrotasks();
        expect(t.machine.phase, CallPhase.dialing);
        expect(t.machine.callId, equals(id(1)));
        expect(t.outcomes, isEmpty);
        final busy = t.sent.where((s) => s.kind == CallSignalKind.busy);
        expect(busy.single.callId, equals(id(2)),
            reason: 'the loser is told, or it rings until it times out');
        t.machine.dispose();
      });
    });

    test('the larger id gives way and takes the incoming call', () {
      fakeAsync((async) {
        final t = build(async);
        t.machine.startOutgoing(callId: id(9), sdp: 'offer');
        t.machine.handleInvite(inviteAt(id(1), t.clock()));
        async.flushMicrotasks();
        expect(t.machine.phase, CallPhase.incoming);
        expect(t.machine.callId, equals(id(1)));
        expect(t.outcomes.single.cause, CallEndCause.glareLost);
        expect(t.outcomes.single.outgoing, isTrue);
        expect(t.sent.last.kind, CallSignalKind.ringing);
        t.machine.dispose();
      });
    });

    test('a stale invite never wins a contest it should not be in', () {
      fakeAsync((async) {
        final t = build(async);
        t.machine.startOutgoing(callId: id(9), sdp: 'offer');
        t.machine.handleInvite(
          inviteAt(id(1), t.clock().subtract(const Duration(hours: 1))),
        );
        async.flushMicrotasks();
        expect(t.machine.phase, CallPhase.dialing);
        expect(t.machine.callId, equals(id(9)));
        t.machine.dispose();
      });
    });
  });
}
```

- [ ] **Step 2: Убедиться, что тест падает**

Run: `flutter test --no-pub test/call_state_machine_incoming_test.dart`
Expected: FAIL — метода `handleInvite` нет.

- [ ] **Step 3: Заменить ветку `invite` и добавить `handleInvite`**

В `call_state_machine.dart` заменить ветку

```dart
      case CallSignalKind.invite:
        // Incoming calls arrive in the next task; an invite for a call we are
        // already running is a repeat delivery and changes nothing.
        return;
```

на

```dart
      case CallSignalKind.invite:
        // A repeat delivery of the invite we are already running.
        return;
```

и добавить перед `void accept(...)`:

```dart
  /// An invite that is not for the call we are already running.
  ///
  /// Kept separate from [handleSignal] because it is the only path that may
  /// legitimately replace the current call, and mixing "answer this frame"
  /// with "abandon what you were doing" in one switch is how a state machine
  /// grows a hole.
  void handleInvite(CallSignal invite) {
    if (_isOurs(invite)) return;
    // Relays hold events and hand them over on connect, so an invite from an
    // hour ago arrives looking new. Answering one rings the caller back for a
    // call they gave up on, which is worse than dropping it.
    if (!inviteIsFresh(sentAtMs: invite.sentAtMs!, now: now())) return;

    if (_phase == CallPhase.dialing || _phase == CallPhase.ringing) {
      // Both dialled at once. Both sides run the same comparison over the same
      // two ids, so neither has to ask the other what happened.
      if (winsGlare(mine: _callId!, theirs: invite.callId)) {
        unawaited(send(CallSignal.busy(invite.callId)));
        return;
      }
      _end(CallEndCause.glareLost);
    } else if (_phase != CallPhase.idle && _phase != CallPhase.ended) {
      unawaited(send(CallSignal.busy(invite.callId)));
      return;
    }

    _callId = invite.callId;
    _outgoing = false;
    _talkingSince = null;
    _move(CallPhase.incoming);
    // Acknowledged before anything else: without this the caller cannot tell
    // a phone that is ringing from a build that never understood the frame.
    unawaited(send(CallSignal.ringing(invite.callId)));
    _arm(CallTimings.noAnswer, () => _end(CallEndCause.noAnswer));
  }
```

- [ ] **Step 4: Разрешить перезапуск после `ended`**

`_end` возвращается рано при `_phase == CallPhase.ended`, а `handleInvite`
вызывает `_end` для проигранного встречного звонка и сразу после этого ставит
новую фазу. Это уже работает, потому что `_end` вызывается из фазы `dialing`.
Отдельно проверить, что `startOutgoing` после завершённого звонка снова
работает: заменить в `startOutgoing`

```dart
    if (_phase != CallPhase.idle) return;
```

на

```dart
    if (_phase != CallPhase.idle && _phase != CallPhase.ended) return;
    _talkingSince = null;
```

- [ ] **Step 5: Прогнать оба теста машины**

Run: `flutter test --no-pub test/call_state_machine_outgoing_test.dart test/call_state_machine_incoming_test.dart`
Expected: PASS, обе группы.

- [ ] **Step 6: Коммит**

```bash
git add lib/features/call/domain/call_state_machine.dart test/call_state_machine_incoming_test.dart
git commit -m "Answer an incoming call, drop a stale one, and settle a simultaneous dial"
```

---

### Task 5: транспорт и `MessagingService`

**Files:**
- Modify: `lib/core/transport/nostr/nostr_transport.dart` (тег и флаг у
  `sendFrame`, рядом с `kWakeTag` на строке 54 и с телом `sendFrame` на
  строке 243)
- Modify: `lib/core/transport/messaging_service.dart` (отправка и разбор)
- Test: `test/call_transport_tags_test.dart`

**Interfaces:**
- Consumes: `CallSignal`, `CallSignalKind` из задачи 1; существующие
  `kRecipientTag` (`'p'`), `kWakeTag` (`'w'`), `NostrTransport.sendFrame`.
- Produces:
  - `const String kCallTag = 'c';` в `nostr_transport.dart`
  - у `NostrTransport.sendFrame` появляется именованный параметр
    `bool wakesCall = false`
  - `bool callWakesPeer(CallSignalKind kind)` и
    `bool callIsVoipWake(CallSignalKind kind)` в
    `lib/features/call/domain/call_rules.dart`

- [ ] **Step 1: Написать падающий тест**

Создать `test/call_transport_tags_test.dart`:

```dart
import 'package:cubechat/core/transport/call_signal.dart';
import 'package:cubechat/features/call/domain/call_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('which call frames ring a doorbell', () {
    test('only an invite takes the voip path', () {
      // iOS kills an app that takes a voip push and does not report a new
      // incoming call. A hangup has no call to report, so a voip push for one
      // would be fatal; and it does not need one, because by then the app is
      // already awake and holding a relay subscription.
      expect(callIsVoipWake(CallSignalKind.invite), isTrue);
      for (final kind in CallSignalKind.values
          .where((k) => k != CallSignalKind.invite)) {
        expect(callIsVoipWake(kind), isFalse, reason: '$kind must not');
      }
    });

    test('an invite, a hangup and a decline wake the phone; the rest do not',
        () {
      expect(callWakesPeer(CallSignalKind.invite), isTrue);
      expect(callWakesPeer(CallSignalKind.hangup), isTrue,
          reason: 'a phone that missed the hangup keeps ringing');
      expect(callWakesPeer(CallSignalKind.decline), isTrue);
      expect(callWakesPeer(CallSignalKind.ringing), isFalse);
      expect(callWakesPeer(CallSignalKind.accept), isFalse);
      expect(callWakesPeer(CallSignalKind.busy), isFalse);
    });

    test('everything that takes the voip path also wakes the phone', () {
      for (final kind in CallSignalKind.values) {
        if (callIsVoipWake(kind)) {
          expect(callWakesPeer(kind), isTrue,
              reason: '$kind asks for a voip push without asking to be woken');
        }
      }
    });
  });
}
```

- [ ] **Step 2: Убедиться, что тест падает**

Run: `flutter test --no-pub test/call_transport_tags_test.dart`
Expected: FAIL — функций нет.

- [ ] **Step 3: Дописать две функции в `call_rules.dart`**

В конец `lib/features/call/domain/call_rules.dart`:

```dart
/// Whether this frame should wake a sleeping phone at all.
///
/// A ringing acknowledgement and an accept travel to somebody who is by
/// definition awake — they are in a call screen. A hangup and a decline do
/// not: the phone at the other end may be ringing in a pocket, and a phone
/// that missed the hangup goes on ringing after the caller gave up.
bool callWakesPeer(CallSignalKind kind) => switch (kind) {
      CallSignalKind.invite ||
      CallSignalKind.hangup ||
      CallSignalKind.decline =>
        true,
      CallSignalKind.ringing ||
      CallSignalKind.accept ||
      CallSignalKind.busy =>
        false,
    };

/// Whether this frame should be delivered as a VoIP push rather than an
/// ordinary silent wake.
///
/// **Only the invite, and this is not a detail.** iOS terminates an app that
/// accepts a VoIP push without immediately reporting a new incoming call. A
/// hangup has no call to report, so a VoIP push carrying one would kill the
/// app; and it needs none, because the app is awake by then — it reported the
/// incoming call moments earlier and still holds its relay subscription.
bool callIsVoipWake(CallSignalKind kind) => kind == CallSignalKind.invite;
```

и добавить в начало файла импорт:

```dart
import '../../../core/transport/call_signal.dart';
```

(он уже там ради `callIdLen`; убедиться, что импорт один).

- [ ] **Step 4: Прогнать тест**

Run: `flutter test --no-pub test/call_transport_tags_test.dart`
Expected: PASS.

- [ ] **Step 5: Добавить тег в транспорт**

В `lib/core/transport/nostr/nostr_transport.dart` рядом с объявлением
`kWakeTag`:

```dart
/// Marks an event as a call invite, so the push service sends it down the VoIP
/// path instead of the ordinary silent wake.
///
/// A flag, exactly like [kWakeTag]: the recipient still travels in
/// [kRecipientTag], and the push service reads it from there as it always did.
///
/// The cost is named rather than hidden. Beside `p`, this flag tells our relays
/// — and anyone else reading the same relays — that the npub in `p` is being
/// called, where before they could only tell that it had mail. It does not
/// reveal who is calling: the sender is behind an ephemeral key, and the
/// contents are inside the envelope.
const String kCallTag = 'c';
```

и в `sendFrame` добавить параметр и тег:

```dart
  Future<PublishReceipt> sendFrame({
    required String recipientNpubHex,
    required Uint8List frameBytes,
    bool wakesPeer = false,
    bool wakesCall = false,
    RelayLane lane = RelayLane.conversation,
  }) async {
    final event = NostrEvent(
      pubkey: _signer.npubHex,
      createdAt: _clock().millisecondsSinceEpoch ~/ 1000,
      kind: kCubechatFrameKind,
      tags: [
        [kRecipientTag, recipientNpubHex],
        if (wakesPeer) [kWakeTag, '1'],
        if (wakesCall) [kCallTag, '1'],
      ],
```

- [ ] **Step 6: Прокинуть флаг через `MessagingService`**

В `lib/core/transport/messaging_service.dart` у `_sendOverNostr` (строка 706 —
объявление, 738 — передача в транспорт) добавить `bool wakesCall = false`
рядом с существующим `wakesPeer` и передать его в `sendFrame`. Ничего другого
в этом методе не менять.

Существующий путь отправки маленького подписанного payload одному человеку —
`Future<int> _sendControlToPeer({required String canonicalId, required Uint8List peerPub, required InnerPayloadType type, required Uint8List innerBody, bool relayOnly = false})`;
им ходят `receipt` (строка 2703) и `reaction` (строка 2931). Он не принимает
`wakesPeer`, поэтому добавить оба флага туда и передать дальше в
`_sendOverNostr`, сохранив значения по умолчанию `false`:

```dart
  Future<int> _sendControlToPeer({
    required String canonicalId,
    required Uint8List peerPub,
    required InnerPayloadType type,
    required Uint8List innerBody,
    bool relayOnly = false,
    bool wakesPeer = false,
    bool wakesCall = false,
  }) async {
```

Значения по умолчанию оставить ложными намеренно: всё, что ходит этим путём
сегодня, — машинерия, за которую человека не будят, и добавление флага не
должно менять поведение ни одного существующего вызова.

Затем добавить публичный метод, рядом с прочими отправками:

```dart
  /// Put one frame of call signalling on the wire.
  ///
  /// Rides the same envelope as text, so the sdp inside is encrypted under the
  /// session already established with this peer, and the DTLS fingerprint it
  /// carries is protected by that same envelope. Nothing new is introduced
  /// here cryptographically, which is the point.
  Future<void> sendCallSignal({
    required String canonicalId,
    required Uint8List peerPub,
    required CallSignal signal,
  }) async {
    await _sendControlToPeer(
      canonicalId: canonicalId,
      peerPub: peerPub,
      type: InnerPayloadType.callSignal,
      innerBody: signal.encode(),
      wakesPeer: callWakesPeer(signal.kind),
      wakesCall: callIsVoipWake(signal.kind),
    );
  }
```

`_sendControlToPeer` уже вызывает `packInnerPayload` сам, поэтому здесь
передаётся голое тело сигнала, а не завёрнутое.

- [ ] **Step 7: Разобрать входящий тип**

Найти в `messaging_service.dart` место, где `unpackInnerPayload` разводит типы
по веткам, и добавить ветку:

```dart
      case InnerPayloadType.callSignal:
        // Decoded here and handed on; the machine that decides what it means
        // lives in features/call and knows nothing about transport.
        try {
          _callSignals.add((chatId: chatId, signal: CallSignal.decode(body)));
        } on FormatException catch (e) {
          debugPrint('[CALL] undecodable call signal from $chatId: $e');
        }
```

и объявить рядом с прочими потоками сервиса:

```dart
  final _callSignals =
      StreamController<({String chatId, CallSignal signal})>.broadcast();

  /// Call signalling as it arrives, for whoever is running a call.
  Stream<({String chatId, CallSignal signal})> get callSignals =>
      _callSignals.stream;
```

и закрыть его там же, где сервис закрывает остальные свои контроллеры.

- [ ] **Step 8: Прогнать транспортные тесты и анализатор**

Run: `flutter test --no-pub test/call_transport_tags_test.dart test/nostr_transport_test.dart test/relay_lanes_test.dart`
Expected: PASS.

```bash
flutter analyze > analyze.log 2>&1; grep -E '^[[:space:]]*(error|warning)[[:space:]]*[-•]' analyze.log
```

Expected: ни одной строки.

- [ ] **Step 9: Коммит**

```bash
git add lib/core/transport/nostr/nostr_transport.dart lib/core/transport/messaging_service.dart lib/features/call/domain/call_rules.dart test/call_transport_tags_test.dart
git commit -m "Give a call invite its own flag, so a hangup never arrives as a voip push"
```

---

### Task 6: запись о звонке в истории

**Files:**
- Create: `lib/features/call/domain/call_record.dart`
- Modify: `lib/features/chat/domain/message_preview.dart` (ветка `_textPreview`,
  около строки 106)
- Modify: `lib/l10n/app_en.arb`, `lib/l10n/app_uk.arb`
- Test: `test/call_record_test.dart`
- Test: `test/message_preview_test.dart` (дописать группу в конец)

**Interfaces:**
- Consumes: `CallOutcome`, `CallEndCause` из задачи 3.
- Produces:
  - `const String callMarker = 'cubechat:call:v1:';`
  - `String encodeCallRecord(CallOutcome outcome)`
  - `class CallRecord` с полями `bool outgoing`, `bool answered`,
    `Duration talkedFor`
  - `CallRecord? tryParseCallRecord(String text)`
  - ключи l10n `previewCallOutgoing`, `previewCallIncoming`,
    `previewCallMissed`

- [ ] **Step 1: Написать падающий тест**

Создать `test/call_record_test.dart`:

```dart
import 'dart:typed_data';

import 'package:cubechat/features/call/domain/call_record.dart';
import 'package:cubechat/features/call/domain/call_state_machine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final callId = Uint8List(16);

  CallOutcome outcome({
    required bool outgoing,
    required CallEndCause cause,
    Duration talkedFor = Duration.zero,
  }) =>
      CallOutcome(
        callId: callId,
        outgoing: outgoing,
        cause: cause,
        talkedFor: talkedFor,
      );

  test('an answered call round-trips its direction and its length', () {
    final text = encodeCallRecord(outcome(
      outgoing: true,
      cause: CallEndCause.hungUp,
      talkedFor: const Duration(minutes: 2, seconds: 31),
    ));
    final back = tryParseCallRecord(text)!;
    expect(back.outgoing, isTrue);
    expect(back.answered, isTrue);
    expect(back.talkedFor, const Duration(minutes: 2, seconds: 31));
  });

  test('everything that never connected is an unanswered call', () {
    for (final cause in [
      CallEndCause.noAnswer,
      CallEndCause.declined,
      CallEndCause.busy,
      CallEndCause.unavailable,
      CallEndCause.failed,
    ]) {
      final back = tryParseCallRecord(
        encodeCallRecord(outcome(outgoing: false, cause: cause)),
      )!;
      expect(back.answered, isFalse, reason: '$cause is not an answered call');
      expect(back.talkedFor, Duration.zero);
    }
  });

  test('a call lost to a simultaneous dial leaves no record at all', () {
    // Both people are about to be in the very call that replaced it. Two lines
    // for one conversation is the confusing outcome, not the tidy one.
    expect(
      encodeCallRecord(outcome(outgoing: true, cause: CallEndCause.glareLost)),
      isEmpty,
    );
  });

  test('ordinary text is not mistaken for a record', () {
    expect(tryParseCallRecord('позвони мне'), isNull);
    expect(tryParseCallRecord('cubechat:loc:v1:abc'), isNull);
    expect(tryParseCallRecord(''), isNull);
  });

  test('a corrupt record is refused rather than half-read', () {
    expect(tryParseCallRecord('${callMarker}not-base64!!'), isNull);
    expect(tryParseCallRecord(callMarker), isNull);
  });
}
```

- [ ] **Step 2: Убедиться, что тест падает**

Run: `flutter test --no-pub test/call_record_test.dart`
Expected: FAIL — `call_record.dart` не существует.

- [ ] **Step 3: Написать `lib/features/call/domain/call_record.dart`**

```dart
import 'dart:convert';

import 'call_state_machine.dart';

/// The scheme a call record wears in a chat.
///
/// A record is written **locally by each side** and never travels: both ends
/// already know how the call ended and how long it lasted, so putting it on
/// the wire would be sending somebody a fact they already have. That is also
/// why no `InnerPayloadType` was spent on it, and why an older build can never
/// receive one it does not understand.
const String callMarker = 'cubechat:call:v1:';

/// What a chat row says about a call that has finished.
class CallRecord {
  const CallRecord({
    required this.outgoing,
    required this.answered,
    required this.talkedFor,
  });

  final bool outgoing;
  final bool answered;
  final Duration talkedFor;
}

/// The stored text for [outcome], or an empty string when the call should
/// leave no trace.
String encodeCallRecord(CallOutcome outcome) {
  // A call given up because both people dialled at once is immediately
  // replaced by the call that won. Recording both leaves two lines for one
  // conversation, which reads as a bug to the person scrolling.
  if (outcome.cause == CallEndCause.glareLost) return '';
  final answered = outcome.cause == CallEndCause.hungUp &&
      outcome.talkedFor > Duration.zero;
  final payload = <String, Object>{
    'o': outcome.outgoing,
    'a': answered,
    's': answered ? outcome.talkedFor.inSeconds : 0,
  };
  return '$callMarker${base64Url.encode(utf8.encode(jsonEncode(payload)))}';
}

/// Reads back what [encodeCallRecord] wrote, or null for anything else.
CallRecord? tryParseCallRecord(String text) {
  final trimmed = text.trim();
  if (!trimmed.startsWith(callMarker)) return null;
  try {
    final raw = utf8.decode(
      base64Url.decode(trimmed.substring(callMarker.length)),
    );
    final map = jsonDecode(raw);
    if (map is! Map<String, dynamic>) return null;
    final answered = map['a'] == true;
    return CallRecord(
      outgoing: map['o'] == true,
      answered: answered,
      talkedFor: Duration(seconds: answered ? (map['s'] as int? ?? 0) : 0),
    );
  } catch (_) {
    // A record we cannot read is not a call worth guessing at.
    return null;
  }
}
```

- [ ] **Step 4: Прогнать тест**

Run: `flutter test --no-pub test/call_record_test.dart`
Expected: PASS.

- [ ] **Step 5: Добавить строки локализации**

В `lib/l10n/app_en.arb`, рядом с `"previewLocation"`:

```json
  "previewCallOutgoing": "Outgoing call",
  "previewCallIncoming": "Incoming call",
  "previewCallMissed": "Missed call",
```

В `lib/l10n/app_uk.arb` — те же ключи со значениями `"Вихідний дзвінок"`,
`"Вхідний дзвінок"`, `"Пропущений дзвінок"`. Оба файла править инструментом
Write/Edit, не шеллом: кириллица через шелл на этой машине перекодируется.

Затем:

```bash
flutter gen-l10n
```

- [ ] **Step 6: Научить превью**

В `lib/features/chat/domain/message_preview.dart`, в `_textPreview`, добавить
перед строкой `if (SharedLocation.tryParse(...)`:

```dart
  final call = tryParseCallRecord(trimmed);
  if (call != null) {
    if (!call.answered) return '📞 ${t.previewCallMissed}';
    return call.outgoing
        ? '📞 ${t.previewCallOutgoing}'
        : '📞 ${t.previewCallIncoming}';
  }
```

и импорт `package:cubechat/features/call/domain/call_record.dart` рядом с
прочими импортами файла.

- [ ] **Step 7: Дописать тест превью**

Дописать в конец `test/message_preview_test.dart` — там уже есть и хелпер
`_m(...)`, и `final t = lookupAppLocalizations(const Locale('en'))`:

```dart
  group('a finished call in a chat row', () {
    Message call(CallOutcome outcome) => _m(
          kind: MessageKind.text,
          text: encodeCallRecord(outcome),
        );

    CallOutcome outcome({
      required bool outgoing,
      required CallEndCause cause,
      Duration talkedFor = Duration.zero,
    }) =>
        CallOutcome(
          callId: Uint8List(16),
          outgoing: outgoing,
          cause: cause,
          talkedFor: talkedFor,
        );

    test('an answered outgoing call is named, not shown as base64', () {
      final preview = messagePreview(
        call(outcome(
          outgoing: true,
          cause: CallEndCause.hungUp,
          talkedFor: const Duration(minutes: 2, seconds: 31),
        )),
        t,
      );
      expect(preview, '📞 Outgoing call');
      expect(preview, isNot(contains('cubechat:')));
    });

    test('an answered incoming call says so', () {
      expect(
        messagePreview(
          call(outcome(
            outgoing: false,
            cause: CallEndCause.hungUp,
            talkedFor: const Duration(seconds: 12),
          )),
          t,
        ),
        '📞 Incoming call',
      );
    });

    test('a call nobody picked up is a missed call in either direction', () {
      for (final outgoing in [true, false]) {
        expect(
          messagePreview(
            call(outcome(outgoing: outgoing, cause: CallEndCause.noAnswer)),
            t,
          ),
          '📞 Missed call',
        );
      }
    });

    test('somebody typing the scheme by hand is still unsupported, not a call',
        () {
      expect(
        messagePreview(_m(kind: MessageKind.text, text: 'cubechat:call:v1:zz'), t),
        t.previewUnsupported,
      );
    });
  });
```

Дописать в шапку `test/message_preview_test.dart` импорты:

```dart
import 'dart:typed_data';

import 'package:cubechat/features/call/domain/call_record.dart';
import 'package:cubechat/features/call/domain/call_state_machine.dart';
```

Run: `flutter test --no-pub test/message_preview_test.dart`
Expected: PASS.

- [ ] **Step 8: Прогнать всё**

Run: `flutter test --no-pub`
Expected: PASS; число тестов больше, чем было до этого плана, и ни одного
падения.

```bash
flutter analyze > analyze.log 2>&1; grep -E '^[[:space:]]*(error|warning)[[:space:]]*[-•]' analyze.log
```

Expected: ни одной строки.

- [ ] **Step 9: Коммит**

```bash
git add lib/features/call/domain/call_record.dart lib/features/chat/domain/message_preview.dart lib/l10n test/call_record_test.dart test/message_preview_test.dart
git commit -m "Write a finished call into the chat locally, and keep base64 out of the row"
```

---

## Что этот план намеренно не делает

- Не поднимает WebRTC, не открывает микрофон и не звонит. `mediaConnected` и
  `mediaFailed` — это входы, которые в этом плане дёргает только тест.
- Не трогает пуш-сервер. Флаг `c` уже уходит на реле, но сервер его пока не
  читает, и это ничего не ломает: тег, на который никто не смотрит, — просто
  тег.
- Не рисует экран звонка и не заводит Riverpod-контроллер.
- Не ставит coturn и не выдаёт доступ к нему.

Каждое из четырёх — предмет отдельного плана, и каждый из них опирается на
имена, зафиксированные здесь.

## Порядок остальных планов

1. **Инфраструктура.** coturn на дроплете, выдача короткоживущего доступа
   отдельным запросом к пуш-серверу, чтение флага `c` и VoIP-путь на сервере,
   отдельный счётчик побудок для звонков. Проверяется тестами сервера и
   запросами к нему, без телефона.
2. **Медиа и экран.** `flutter_webrtc`, Riverpod-контроллер поверх машины
   состояний, экран звонка, отказ вместо тихого перехода на прямое соединение
   при недоступном TURN. Здесь же запись исхода в чат.
3. **Нативный звонок.** CallKit и PushKit на iOS, служба переднего плана и
   полноэкранное намерение на Android. Проверяется только на двух живых
   телефонах.
