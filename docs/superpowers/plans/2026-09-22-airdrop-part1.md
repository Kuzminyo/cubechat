# AirDrop, часть 1 — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Передача файлов людям рядом по прямой Bluetooth-сессии: запрос → «Прийняти / Відхилити» → файлы существующим путём `sendFile`, с историей, антиспамом и вкладкой «Поблизу | AirDrop | Файли».

**Architecture:** Два новых подписанных управляющих кадра (`nearbyOffer` 0xE8, `nearbyAnswer` 0xE9) идут только по прямой BLE-сессии. Решения принимает `AirDropController` (Riverpod Notifier) поверх узкого порта `AirDropPort`, за которым стоит `MessagingService`; вся логика (переходы, антиспам, сроки) — чистые функции в `features/airdrop/domain`, проверяемые без телефона. Приём файлов переиспользует манифест и сборку файлов: сервис спрашивает у AirDrop (`NearbyFileSink`), чей это файл, и отдаёт готовый файл ему, а не в чат.

**Tech Stack:** Flutter, Riverpod (`Notifier`), Hive (зашифрованный `settings`), go_router, `flutter_test` + `fake_async`, Kotlin (Android), Swift (iOS).

**Spec:** `docs/superpowers/specs/2026-09-22-airdrop-design.md` — исполнитель читает спецификацию и этот план вместе.

## Global Constraints

- Типы кадров: `nearbyOffer` = `0xE8`, `nearbyAnswer` = `0xE9` (сверено с enum 2026-09-22: занято до `0xE7`).
- `nearbyOffer` v1: `[version:1][transferId:16][flags:1][count:1]` + `count × [mediaId:16][size:8 BE][nameLen:1][name:utf8][mimeLen:1][mime:ascii]`; `count` 1..50; длины ≤ 255; любая ошибка — `FormatException`.
- `nearbyAnswer` v1: `[version:1][transferId:16][kind:1][reason:1]`; kind: `0x01` увидел, `0x02` принял, `0x03` отклонил, `0x04` отменил; reason: `0x00` пользователь, `0x01` нет места, `0x02` только контакты, `0x03` занят, `0x04` не ответил за 60 с.
- Только прямая связь: предложение, ответы и файлы — только по прямой BLE-сессии, без ретрансляции и без релея.
- Сроки: «увидел» ждём 10 с; ответ человека — 60 с; «перервано» у получателя — 60 с без кусков; принятое предложение действует 10 минут; режим «Усі» — 10 минут.
- Антиспам (только незнакомцы): 3 нажатых «Відхилити» подряд → бан 10 мин, каждый следующий вдвое длиннее, потолок 24 ч; обнуление после суток без запросов или когда человек стал контактом; во время бана — молча, без «увидел». Истечение 60 с, «занят» и «нет места» не считаются.
- История — последние 200 передач; ключи Hive начинаются с `airdrop.` в боксе `settings`; бекап и перенос их не берут.
- Полученные файлы — папка приложения `airdrop/`, имена `safeFileName`, совпадения получают номер.
- До 50 файлов за раз. Отдельного лимита AirDrop нет; действует уже существующий потолок одного файла по Bluetooth `MessagingService.maxFileBytesMesh` (128 МиБ). Больше 20 МБ за раз — предупреждение «через Bluetooth це може тривати довго».
- Фото по Bluetooth сжимаются по «Якість фото» (`encodeBytesForMesh` + `mediaQualityProvider`), видео и файлы — как есть.
- Всё видимое — через `AppLocalizations`, ключи в `app_en.arb` и `app_uk.arb` одновременно, затем `flutter gen-l10n`.
- Анимации — `AppearAnimation` / `AppearOnce`; без вечных тикеров; `MediaQuery.disableAnimationsOf` отключает движение.
- Анализатор строгий (`strict-casts`, `strict-inference`, `strict-raw-types`, `prefer_final_locals`, `require_trailing_commas`); CI падает на любом `warning`.
- `MessagingService` — только добавления, без выноса подсистем.
- Правка исходников — только Edit/Write (хук запрещает переписывать файлы через shell; shell ломает кириллицу).
- Тесты запускать: `flutter test --no-pub <файл>` (без Developer Mode обычный запуск падает на symlink).
- Коммиты — предложение о результате, не conventional-commits; в конце строка `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.

## Отклонение от спецификации (решено при планировании)

Спецификация: «индикатор островка едет за пальцем». Горизонтальный жест во всей оболочке принадлежит `BranchContainer`; вложенный `PageView` отнял бы свайп между вкладками приложения. Здесь уже есть принятый механизм — `BranchPager`: свайп сначала листает страницы вкладки, на краю переходит к соседней вкладке (так листаются папки чатов). Индикатор островка доезжает анимацией после свайпа, а не тянется за пальцем. Задача 9 правит строку спецификации.

## Карта файлов

Создаются:

| Файл | Отвечает за |
|---|---|
| `lib/core/transport/nearby_offer.dart` | кодеки `NearbyOffer`/`NearbyAnswer`, `NearbyInbound`, интерфейс `NearbyFileSink` |
| `lib/core/util/free_space.dart` | свободное место на диске через канал `cubechat/storage` |
| `lib/core/widgets/section_switch.dart` | островок-переключатель (вынесен из контактов) |
| `lib/features/airdrop/domain/airdrop_rules.dart` | все сроки и пределы |
| `lib/features/airdrop/domain/airdrop_spam_guard.dart` | антиспам, чистые функции |
| `lib/features/airdrop/domain/airdrop_transfer.dart` | модель передачи и её переходы |
| `lib/features/airdrop/data/airdrop_clock.dart` | «сейчас» для всех сроков, подменяется в тестах |
| `lib/features/airdrop/data/airdrop_storage.dart` | папка `airdrop/`, уникальные имена |
| `lib/features/airdrop/data/airdrop_receive_controller.dart` | «Контакти / Усі 10 хв» |
| `lib/features/airdrop/data/airdrop_history_controller.dart` | история, 200 записей |
| `lib/features/airdrop/data/airdrop_spam_store.dart` | хранение записей антиспама |
| `lib/features/airdrop/data/airdrop_source.dart` | файл, готовый к отправке |
| `lib/features/airdrop/data/airdrop_port.dart` | порт к `MessagingService` |
| `lib/features/airdrop/data/airdrop_controller.dart` | оркестратор |
| `lib/features/airdrop/data/share_inbox.dart` | файлы из системного «Поделиться» (Android) |
| `lib/features/airdrop/presentation/airdrop_text.dart` | «3 фото · 12 МБ» и подобные строки |
| `lib/features/airdrop/presentation/airdrop_navigation.dart` | какая страница «Поблизу» открыта и какую просят |
| `lib/features/airdrop/presentation/airdrop_banner.dart` | запрос поверх любого экрана |
| `lib/features/airdrop/presentation/airdrop_page.dart` | страница AirDrop |
| `lib/features/airdrop/presentation/airdrop_cards.dart` | карточки запроса, прогресса, истории |
| `lib/features/airdrop/presentation/airdrop_send_flow.dart` | выбор файлов и человека, отправка |
| `lib/features/airdrop/presentation/airdrop_people_sheet.dart` | список людей с прямой связью |
| `lib/features/airdrop/presentation/airdrop_share_screen.dart` | экран «Надіслати кому» для «Поделиться» |
| `lib/features/peers/presentation/nearby_screen.dart` | вкладка с островком «Поблизу / AirDrop / Файли» |
| `lib/features/backup/data/backup_filter.dart` | что из `settings` не идёт в бекап |

Меняются: `inner_payload.dart`, `messaging_service.dart`, `file_transfer_controller.dart`, `file_transfer_center_screen.dart`, `branch_pager.dart`, `app_router.dart`, `chats_list_screen.dart`, `contacts_screen.dart`, `peers_screen.dart`, `message_bubble.dart`, `backup_service.dart`, `wipe_service.dart`, `app.dart`, `app_en.arb`, `app_uk.arb`, `MainApplication.kt`, `MainActivity.kt`, `AndroidManifest.xml`, `AppDelegate.swift`, спецификация, `pubspec.yaml`, `app_build.dart`.

---

### Task 1: Кодеки `nearbyOffer` / `nearbyAnswer` и входящий поток

**Files:**
- Create: `lib/core/transport/nearby_offer.dart`
- Modify: `lib/core/transport/inner_payload.dart` (enum, после `callSignal(0xE7)`)
- Modify: `lib/core/transport/messaging_service.dart` (поле-стрим рядом с `_callSignals` ~351; канальный `switch` ~6523; 1:1 `switch` ~7563; `dispose` ~12180)
- Test: `test/nearby_offer_test.dart`

**Interfaces:**
- Produces: `nearbyIdLen = 16`, `nearbyMaxFiles = 50`, `nearbyHex(Uint8List) → String`, `nearbyUnhex(String) → Uint8List`; `NearbyOfferFile{mediaId, size, name, mime}`; `NearbyOffer{transferId, flags, files, totalBytes, encode(), static decode()}`; `NearbyAnswerKind{seen, accepted, declined, cancelled}`; `NearbyDeclineReason{user, noSpace, contactsOnly, busy, timeout}`; `NearbyAnswer{transferId, kind, reason, encode(), static decode()}`; `NearbyInbound{peerHex, direct, offer?, answer?}`; `NearbyFileVerdict{notNearby, keep, refuse}`; `abstract interface class NearbyFileSink { NearbyFileVerdict judge({mediaIdHex, senderHex, direct}); Future<String?> keep({mediaIdHex, senderHex, file, name}); }`; `MessagingService.nearbyInbound → Stream<NearbyInbound>`.

- [ ] **Step 1: Write the failing test**

`test/nearby_offer_test.dart`:

```dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:cubechat/core/transport/inner_payload.dart';
import 'package:cubechat/core/transport/nearby_offer.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _id(int seed) =>
    Uint8List.fromList(List.generate(nearbyIdLen, (i) => (seed + i) & 0xFF));

NearbyOfferFile _file(
  int seed, {
  String name = 'photo.jpg',
  String mime = 'image/jpeg',
  int size = 1234,
}) =>
    NearbyOfferFile(mediaId: _id(seed), size: size, name: name, mime: mime);

NearbyOffer _offer(int count) => NearbyOffer(
      transferId: _id(200),
      files: [for (var i = 0; i < count; i++) _file(i * 17 + 1)],
    );

void main() {
  group('tag bytes', () {
    test('nearbyOffer is 0xE8 and nearbyAnswer is 0xE9', () {
      expect(InnerPayloadType.nearbyOffer.tag, 0xE8);
      expect(InnerPayloadType.nearbyAnswer.tag, 0xE9);
      expect(InnerPayloadType.fromByte(0xE8), InnerPayloadType.nearbyOffer);
      expect(InnerPayloadType.fromByte(0xE9), InnerPayloadType.nearbyAnswer);
    });

    // A colliding byte compiles, passes every other test and breaks phones
    // that already have the app — see the wire-protocol skill.
    test('no two inner payload types share a byte', () {
      final tags = InnerPayloadType.values.map((v) => v.tag).toList();
      expect(tags.toSet().length, tags.length);
    });
  });

  group('NearbyOffer', () {
    test('round-trips one file', () {
      final offer = NearbyOffer(
        transferId: _id(9),
        flags: 0,
        files: [_file(1, name: 'відпустка.mp4', mime: 'video/mp4', size: 42)],
      );
      final back = NearbyOffer.decode(offer.encode());
      expect(back.transferId, _id(9));
      expect(back.flags, 0);
      expect(back.files.single.mediaId, _id(1));
      expect(back.files.single.name, 'відпустка.mp4');
      expect(back.files.single.mime, 'video/mp4');
      expect(back.files.single.size, 42);
      expect(back.totalBytes, 42);
    });

    test('round-trips fifty files and a size past 4 GiB', () {
      const big = 5 * 1024 * 1024 * 1024;
      final offer = NearbyOffer(
        transferId: _id(1),
        files: [for (var i = 0; i < 50; i++) _file(i * 3 + 5, size: big + i)],
      );
      final back = NearbyOffer.decode(offer.encode());
      expect(back.files, hasLength(50));
      expect(back.files.last.size, big + 49);
    });

    test('keeps a 255-byte name and cuts a longer one on a character', () {
      final exact = 'a' * 255;
      expect(
        NearbyOffer.decode(
          NearbyOffer(transferId: _id(1), files: [_file(1, name: exact)])
              .encode(),
        ).files.single.name,
        exact,
      );
      final long = 'я' * 200; // 400 bytes of UTF-8
      final back = NearbyOffer.decode(
        NearbyOffer(transferId: _id(1), files: [_file(1, name: long)]).encode(),
      );
      expect(utf8.encode(back.files.single.name).length, lessThanOrEqualTo(255));
      expect(back.files.single.name, 'я' * 127);
    });

    test('refuses to encode no files or more than fifty', () {
      expect(
        () => NearbyOffer(transferId: _id(1), files: const []).encode(),
        throwsArgumentError,
      );
      expect(() => _offer(51).encode(), throwsArgumentError);
    });

    group('decode rejects', () {
      late Uint8List good;
      setUp(() => good = _offer(2).encode());

      test('a truncated body', () {
        expect(
          () => NearbyOffer.decode(good.sublist(0, good.length - 1)),
          throwsFormatException,
        );
      });

      test('a trailing byte', () {
        expect(
          () => NearbyOffer.decode(Uint8List.fromList([...good, 0])),
          throwsFormatException,
        );
      });

      test('another version', () {
        final bad = Uint8List.fromList(good)..[0] = 0x02;
        expect(() => NearbyOffer.decode(bad), throwsFormatException);
      });

      test('zero files and fifty-one files', () {
        const countAt = 1 + nearbyIdLen + 1;
        expect(
          () => NearbyOffer.decode(Uint8List.fromList(good)..[countAt] = 0),
          throwsFormatException,
        );
        expect(
          () => NearbyOffer.decode(Uint8List.fromList(good)..[countAt] = 51),
          throwsFormatException,
        );
      });

      test('a name length running past the end', () {
        const nameLenAt = 1 + nearbyIdLen + 1 + 1 + nearbyIdLen + 8;
        final bad = Uint8List.fromList(good)..[nameLenAt] = 255;
        expect(() => NearbyOffer.decode(bad), throwsFormatException);
      });

      // [0]=ver [1..16]=tid [17]=flags [18]=count [19..34]=mediaId
      // [35..42]=size [43]=nameLen [44]=name [45]=mimeLen [46]=mime
      Uint8List oneFile() => NearbyOffer(
            transferId: _id(3),
            files: [_file(4, name: 'n', mime: 'm')],
          ).encode();

      test('a mime that is not ASCII', () {
        expect(
          () => NearbyOffer.decode(oneFile()..[46] = 0xC3),
          throwsFormatException,
        );
      });

      test('a name that is not UTF-8', () {
        expect(
          () => NearbyOffer.decode(oneFile()..[44] = 0xFF),
          throwsFormatException,
        );
      });

      test('a size beyond what a Dart int holds everywhere', () {
        final bad = oneFile();
        for (var i = 35; i < 39; i++) {
          bad[i] = 0xFF;
        }
        expect(() => NearbyOffer.decode(bad), throwsFormatException);
      });

      test('the same media id twice', () {
        final twice = NearbyOffer(transferId: _id(1), files: [_file(1), _file(1)]);
        expect(() => NearbyOffer.decode(twice.encode()), throwsFormatException);
      });
    });
  });

  group('NearbyAnswer', () {
    test('round-trips every kind and reason', () {
      for (final kind in NearbyAnswerKind.values) {
        for (final reason in NearbyDeclineReason.values) {
          final back = NearbyAnswer.decode(
            NearbyAnswer(transferId: _id(7), kind: kind, reason: reason)
                .encode(),
          );
          expect(back.transferId, _id(7));
          expect(back.kind, kind);
          expect(back.reason, reason);
        }
      }
    });

    test('is exactly 19 bytes', () {
      expect(
        NearbyAnswer(transferId: _id(1), kind: NearbyAnswerKind.seen)
            .encode()
            .length,
        19,
      );
    });

    // A newer build inventing a reason must still be able to say no to this
    // one; losing the label costs a word, refusing the frame costs the answer.
    test('an unknown reason reads as the person declining', () {
      final bytes = NearbyAnswer(
        transferId: _id(1),
        kind: NearbyAnswerKind.declined,
        reason: NearbyDeclineReason.busy,
      ).encode()
        ..[18] = 0x7F;
      expect(NearbyAnswer.decode(bytes).reason, NearbyDeclineReason.user);
    });

    test('rejects a wrong length, another version and an unknown kind', () {
      final good =
          NearbyAnswer(transferId: _id(1), kind: NearbyAnswerKind.accepted)
              .encode();
      expect(
        () => NearbyAnswer.decode(good.sublist(0, 18)),
        throwsFormatException,
      );
      expect(
        () => NearbyAnswer.decode(Uint8List.fromList([...good, 0])),
        throwsFormatException,
      );
      expect(
        () => NearbyAnswer.decode(Uint8List.fromList(good)..[0] = 2),
        throwsFormatException,
      );
      expect(
        () => NearbyAnswer.decode(Uint8List.fromList(good)..[17] = 0x09),
        throwsFormatException,
      );
    });
  });

  test('hex helpers round-trip', () {
    expect(nearbyUnhex(nearbyHex(_id(5))), _id(5));
    expect(() => nearbyUnhex('zz'), throwsFormatException);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test --no-pub test/nearby_offer_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:cubechat/core/transport/nearby_offer.dart'`.

- [ ] **Step 3: Add the enum values**

In `lib/core/transport/inner_payload.dart` replace the `callSignal` entry's closing:

```dart
  /// 0xE7 was verified free against this enum before it was taken; the range
  /// 0xE7-0xEF is still empty after it. An older build drops an unknown inner
  /// type silently, so the caller does not treat a call as ringing until the
  /// explicit acknowledgement arrives — otherwise calling an old build would
  /// ring forever against a phone that never heard anything.
  callSignal(0xE7);
```

with:

```dart
  /// 0xE7 was verified free against this enum before it was taken. An older
  /// build drops an unknown inner type silently, so the caller does not treat
  /// a call as ringing until the explicit acknowledgement arrives — otherwise
  /// calling an old build would ring forever against a phone that never heard
  /// anything.
  callSignal(0xE7),

  /// AirDrop: somebody in arm's reach offers files. See [NearbyOffer] in
  /// `nearby_offer.dart` and docs/superpowers/specs/2026-09-22-airdrop-design.md.
  ///
  /// 0xE8 and 0xE9 were verified free against this enum on 2026-09-22;
  /// 0xEA-0xEF are still empty. An old build drops both silently, which the
  /// sender reads as "no automatic 'seen' within ten seconds" and says so.
  nearbyOffer(0xE8),

  /// AirDrop: seen, accepted, declined (with a reason) or cancelled.
  nearbyAnswer(0xE9);
```

- [ ] **Step 4: Write the codec**

`lib/core/transport/nearby_offer.dart`:

```dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Width of a transfer id and of each file's media id — the width of every
/// other id on the wire, so a log line reads the same.
const int nearbyIdLen = 16;

/// Version byte at the head of both bodies.
const int nearbyVersion = 0x01;

/// Most files one offer may carry.
const int nearbyMaxFiles = 50;

/// A name or a mime is prefixed by one length byte.
const int nearbyMaxFieldBytes = 255;

/// Largest size a Dart int holds exactly on every platform the app builds for
/// (web included), so a size read here means the same number everywhere.
const int _maxSize = 0x1FFFFFFFFFFFFF;

String nearbyHex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List nearbyUnhex(String hex) {
  if (hex.length.isOdd) throw FormatException('odd hex length: $hex');
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final byte = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    if (byte == null) throw FormatException('not hex: $hex');
    out[i] = byte;
  }
  return out;
}

/// One file named in an offer. The sender picks [mediaId] before sending the
/// offer, and the file later travels under exactly that id.
class NearbyOfferFile {
  NearbyOfferFile({
    required this.mediaId,
    required this.size,
    required this.name,
    required this.mime,
  }) {
    if (mediaId.length != nearbyIdLen) {
      throw ArgumentError.value(mediaId.length, 'mediaId', 'not $nearbyIdLen');
    }
    if (size < 0 || size > _maxSize) throw ArgumentError.value(size, 'size');
  }

  final Uint8List mediaId;
  final int size;
  final String name;
  final String mime;
}

/// "I would like to send you these."
///
/// ```
///   [version:1][transferId:16][flags:1][count:1]
///   count × [mediaId:16][size:8 BE][nameLen:1][name:utf8][mimeLen:1][mime:ascii]
/// ```
///
/// [flags] bit 0 is reserved for the Wi-Fi lane (part 2 of the design) and is
/// 0 today. Every length is checked on the way in: a decoder that trusts its
/// input is a crash anybody in Bluetooth range can cause.
class NearbyOffer {
  NearbyOffer({required this.transferId, required this.files, this.flags = 0}) {
    if (transferId.length != nearbyIdLen) {
      throw ArgumentError.value(transferId.length, 'transferId');
    }
  }

  final Uint8List transferId;
  final int flags;
  final List<NearbyOfferFile> files;

  int get totalBytes => files.fold(0, (sum, f) => sum + f.size);

  Uint8List encode() {
    if (files.isEmpty || files.length > nearbyMaxFiles) {
      throw ArgumentError.value(files.length, 'files', '1..$nearbyMaxFiles');
    }
    final out = BytesBuilder(copy: false)
      ..addByte(nearbyVersion)
      ..add(transferId)
      ..addByte(flags & 0xFF)
      ..addByte(files.length);
    for (final f in files) {
      final name = _fitUtf8(f.name, nearbyMaxFieldBytes);
      final mime = ascii.encode(f.mime);
      if (mime.length > nearbyMaxFieldBytes) {
        throw ArgumentError.value(f.mime, 'mime', 'longer than 255 bytes');
      }
      out
        ..add(f.mediaId)
        ..add(_u64(f.size))
        ..addByte(name.length)
        ..add(name)
        ..addByte(mime.length)
        ..add(mime);
    }
    return out.toBytes();
  }

  static NearbyOffer decode(Uint8List body) {
    final r = _Reader(body);
    if (r.byte() != nearbyVersion) {
      throw const FormatException('nearby offer: unknown version');
    }
    final transferId = r.bytes(nearbyIdLen);
    final flags = r.byte();
    final count = r.byte();
    if (count < 1 || count > nearbyMaxFiles) {
      throw FormatException('nearby offer: $count files');
    }
    final files = <NearbyOfferFile>[];
    final ids = <String>{};
    for (var i = 0; i < count; i++) {
      final mediaId = r.bytes(nearbyIdLen);
      final size = r.u64();
      final name = utf8.decode(r.bytes(r.byte()));
      final mime = ascii.decode(r.bytes(r.byte()));
      if (!ids.add(nearbyHex(mediaId))) {
        throw const FormatException('nearby offer: a media id twice');
      }
      files.add(
        NearbyOfferFile(mediaId: mediaId, size: size, name: name, mime: mime),
      );
    }
    if (!r.done) throw const FormatException('nearby offer: trailing bytes');
    return NearbyOffer(transferId: transferId, flags: flags, files: files);
  }
}

enum NearbyAnswerKind {
  seen(0x01),
  accepted(0x02),
  declined(0x03),
  cancelled(0x04);

  const NearbyAnswerKind(this.tag);
  final int tag;

  static NearbyAnswerKind? fromByte(int b) {
    for (final v in values) {
      if (v.tag == b) return v;
    }
    return null;
  }
}

enum NearbyDeclineReason {
  user(0x00),
  noSpace(0x01),
  contactsOnly(0x02),
  busy(0x03),
  timeout(0x04);

  const NearbyDeclineReason(this.tag);
  final int tag;

  /// Unknown reasons read as the person saying no — see [NearbyAnswer].
  static NearbyDeclineReason fromByte(int b) {
    for (final v in values) {
      if (v.tag == b) return v;
    }
    return user;
  }
}

/// `[version:1][transferId:16][kind:1][reason:1]` — nineteen bytes, always.
class NearbyAnswer {
  NearbyAnswer({
    required this.transferId,
    required this.kind,
    this.reason = NearbyDeclineReason.user,
  }) {
    if (transferId.length != nearbyIdLen) {
      throw ArgumentError.value(transferId.length, 'transferId');
    }
  }

  static const int length = 1 + nearbyIdLen + 2;

  final Uint8List transferId;
  final NearbyAnswerKind kind;
  final NearbyDeclineReason reason;

  Uint8List encode() => (BytesBuilder(copy: false)
        ..addByte(nearbyVersion)
        ..add(transferId)
        ..addByte(kind.tag)
        ..addByte(reason.tag))
      .toBytes();

  static NearbyAnswer decode(Uint8List body) {
    if (body.length != length) {
      throw FormatException('nearby answer: ${body.length} bytes');
    }
    if (body[0] != nearbyVersion) {
      throw const FormatException('nearby answer: unknown version');
    }
    final kind = NearbyAnswerKind.fromByte(body[1 + nearbyIdLen]);
    if (kind == null) throw const FormatException('nearby answer: kind');
    return NearbyAnswer(
      transferId: Uint8List.fromList(body.sublist(1, 1 + nearbyIdLen)),
      kind: kind,
      reason: NearbyDeclineReason.fromByte(body[2 + nearbyIdLen]),
    );
  }
}

/// One AirDrop frame as the transport hands it on: who sent it, whether it
/// came straight from their phone, and what it said.
class NearbyInbound {
  const NearbyInbound({
    required this.peerHex,
    required this.direct,
    this.offer,
    this.answer,
  });

  final String peerHex;
  final bool direct;
  final NearbyOffer? offer;
  final NearbyAnswer? answer;
}

/// What the transport should do with a file manifest — asked of AirDrop,
/// because only AirDrop knows which media ids it offered or accepted.
enum NearbyFileVerdict {
  /// Not an AirDrop id: an ordinary file for the chat.
  notNearby,

  /// Part of an accepted offer from this sender over a direct link.
  keep,

  /// An AirDrop id without an accepted offer, from somebody else, or not over
  /// a direct link. Dropped and logged.
  refuse,
}

abstract interface class NearbyFileSink {
  NearbyFileVerdict judge({
    required String mediaIdHex,
    required String senderHex,
    required bool direct,
  });

  /// A kept file has arrived whole and its hash matched. Move it to where
  /// AirDrop keeps files and say where; null when the transfer has ended and
  /// the file is no longer wanted.
  Future<String?> keep({
    required String mediaIdHex,
    required String senderHex,
    required File file,
    required String name,
  });
}

Uint8List _fitUtf8(String s, int max) {
  final whole = utf8.encode(s);
  if (whole.length <= max) return Uint8List.fromList(whole);
  final out = BytesBuilder(copy: false);
  for (final rune in s.runes) {
    final bytes = utf8.encode(String.fromCharCode(rune));
    if (out.length + bytes.length > max) break;
    out.add(bytes);
  }
  return out.toBytes();
}

Uint8List _u64(int v) {
  final b = ByteData(8)
    ..setUint32(0, v ~/ 0x100000000)
    ..setUint32(4, v % 0x100000000);
  return b.buffer.asUint8List();
}

class _Reader {
  _Reader(this._b);

  final Uint8List _b;
  int _at = 0;

  bool get done => _at == _b.length;

  void _need(int n) {
    if (_at + n > _b.length) throw const FormatException('nearby: truncated');
  }

  int byte() {
    _need(1);
    return _b[_at++];
  }

  Uint8List bytes(int n) {
    _need(n);
    final out = Uint8List.fromList(_b.sublist(_at, _at + n));
    _at += n;
    return out;
  }

  int u64() {
    _need(8);
    final d = ByteData.sublistView(_b, _at, _at + 8);
    _at += 8;
    final hi = d.getUint32(0);
    if (hi > 0x1FFFFF) throw const FormatException('nearby: size too large');
    return hi * 0x100000000 + d.getUint32(4);
  }
}
```

- [ ] **Step 5: Hand the frames on from the transport**

`lib/core/transport/messaging_service.dart` — add the import `import 'nearby_offer.dart';` next to `import 'call_signal.dart';`. Beside `_callSignals` (~line 351):

```dart
  final _nearbyInbound = StreamController<NearbyInbound>.broadcast();

  /// AirDrop offers and answers as they arrive — see `features/airdrop`.
  Stream<NearbyInbound> get nearbyInbound => _nearbyInbound.stream;
```

In `dispose`, next to `await _callSignals.close();`:

```dart
    await _nearbyInbound.close();
```

In the channel `switch` (the case list that ends with `case InnerPayloadType.callSignal:` ~line 6523), add two cases to the ignored list, right after `case InnerPayloadType.callSignal:`:

```dart
        case InnerPayloadType.nearbyOffer:
        case InnerPayloadType.nearbyAnswer:
```

and append to the comment block below them:

```dart
          //
          // AirDrop is between two phones in arm's reach; inside a room frame
          // it names nobody who could answer it.
```

In the 1:1 `switch`, after the `case InnerPayloadType.callSignal:` block (~line 7563-7581):

```dart
        case InnerPayloadType.nearbyOffer:
        case InnerPayloadType.nearbyAnswer:
          // AirDrop. Handed on with whether it came straight from the phone
          // that wrote it: the controller refuses anything that crossed a
          // third phone or the internet. This layer only knows the route.
          if (senderPub == null) break;
          try {
            final isOffer = unpacked.type == InnerPayloadType.nearbyOffer;
            _nearbyInbound.add(
              NearbyInbound(
                peerHex: _hexOf(senderPub),
                direct: incomingRoute == MessageRoute.bluetooth,
                offer: isOffer ? NearbyOffer.decode(unpacked.body) : null,
                answer: isOffer ? null : NearbyAnswer.decode(unpacked.body),
              ),
            );
          } on FormatException catch (e) {
            DebugLog.instance.log(
              'AIRDROP',
              'drop ${unpacked.type.name} from $peerId: $e',
            );
          }
```

- [ ] **Step 6: Run the tests and the analyzer**

Run: `flutter test --no-pub test/nearby_offer_test.dart test/call_signal_test.dart`
Expected: PASS.
Run: `flutter analyze --no-pub lib/core/transport` and confirm no `error`/`warning` lines.

- [ ] **Step 7: Commit**

```bash
git add lib/core/transport/nearby_offer.dart lib/core/transport/inner_payload.dart lib/core/transport/messaging_service.dart test/nearby_offer_test.dart
git commit -m "AirDrop can say what it wants to send and hear the answer: two new frames on the wire"
```

---

### Task 2: Задача передачи знает, что она из AirDrop

**Files:**
- Modify: `lib/features/files/data/file_transfer_controller.dart`
- Test: `test/file_transfer_controller_test.dart`

**Interfaces:**
- Produces: `enum FileTransferSource { chat, airdrop }`; `FileTransferTask.source` (default `chat`), `FileTransferTask.peerName` (`String?`); `FileTransferController.storageKey` (public, `'file_transfers_v1'`). An outgoing AirDrop task becomes `failed` after a restart, never `queued`.

- [ ] **Step 1: Write the failing tests**

Append inside `main()` of `test/file_transfer_controller_test.dart` (before the final `}`):

```dart
  test('an AirDrop task keeps its source and sender name across a restart',
      () async {
    final controller = container.read(fileTransferControllerProvider.notifier);
    await controller.loaded;
    controller.register(
      FileTransferTask(
        id: 'air-1',
        chatId: 'bob',
        fileName: 'clip.mp4',
        filePath: 'C:/tmp/clip.mp4',
        mime: 'video/mp4',
        bytesTotal: 10,
        completedUnits: 10,
        totalUnits: 10,
        direction: FileTransferDirection.incoming,
        status: FileTransferStatus.completed,
        createdAt: DateTime(2026, 9, 22),
        updatedAt: DateTime(2026, 9, 22),
        source: FileTransferSource.airdrop,
        peerName: 'Жека',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 450));

    final relaunched = ProviderContainer();
    addTearDown(relaunched.dispose);
    final restored = relaunched.read(fileTransferControllerProvider.notifier);
    await restored.loaded;
    final value = relaunched.read(fileTransferControllerProvider)['air-1'];
    expect(value?.source, FileTransferSource.airdrop);
    expect(value?.peerName, 'Жека');
  });

  // The file queue retries queued outgoing tasks as chat sends. An AirDrop
  // needs the person in reach and their yes, so after a restart it is failed —
  // the AirDrop page offers "retry" — and never quietly re-sent into a chat.
  test('an outgoing AirDrop is failed after a restart, not queued', () async {
    final controller = container.read(fileTransferControllerProvider.notifier);
    await controller.loaded;
    controller.register(
      FileTransferTask(
        id: 'air-2',
        chatId: 'bob',
        fileName: 'a.jpg',
        filePath: 'C:/tmp/a.jpg',
        mime: 'image/jpeg',
        bytesTotal: 10,
        completedUnits: 1,
        totalUnits: 4,
        direction: FileTransferDirection.outgoing,
        status: FileTransferStatus.transferring,
        createdAt: DateTime(2026, 9, 22),
        updatedAt: DateTime(2026, 9, 22),
        source: FileTransferSource.airdrop,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 450));

    final relaunched = ProviderContainer();
    addTearDown(relaunched.dispose);
    await relaunched.read(fileTransferControllerProvider.notifier).loaded;
    expect(
      relaunched.read(fileTransferControllerProvider)['air-2']?.status,
      FileTransferStatus.failed,
    );
  });

  test('a record written before sources existed reads as a chat file',
      () async {
    final controller = container.read(fileTransferControllerProvider.notifier);
    await controller.loaded;
    controller.register(task(status: FileTransferStatus.completed));
    await Future<void>.delayed(const Duration(milliseconds: 450));
    final relaunched = ProviderContainer();
    addTearDown(relaunched.dispose);
    await relaunched.read(fileTransferControllerProvider.notifier).loaded;
    expect(
      relaunched.read(fileTransferControllerProvider)['transfer-1']?.source,
      FileTransferSource.chat,
    );
  });
```

- [ ] **Step 2: Run to verify they fail**

Run: `flutter test --no-pub test/file_transfer_controller_test.dart`
Expected: FAIL — `The named parameter 'source' isn't defined`.

- [ ] **Step 3: Implement**

In `file_transfer_controller.dart`, after `enum FileTransferStatus {…}`:

```dart
/// Where a transfer came from. The transfer centre shows both; only a chat
/// file is ever retried by the file queue.
enum FileTransferSource { chat, airdrop }
```

In `FileTransferTask`: add constructor params `this.source = FileTransferSource.chat,` and `this.peerName,` (after `this.error,`), fields:

```dart
  final FileTransferSource source;

  /// The other person's name when the task was made — AirDrop shows it,
  /// because an AirDrop file has no conversation to be read in.
  final String? peerName;
```

and in `copyWith`'s constructor call add `source: source,` and `peerName: peerName,`.

Rename `static const _key = 'file_transfers_v1';` to `static const storageKey = 'file_transfers_v1';` and replace the three uses of `_key` in the class with `storageKey`.

`_statusAfterRestart` becomes:

```dart
  static FileTransferStatus _statusAfterRestart(FileTransferTask task) {
    if (!task.active) return task.status;
    // An AirDrop needs the person in reach and their yes; the AirDrop page
    // offers a retry. Queued would hand it to the chat file queue.
    if (task.source == FileTransferSource.airdrop) {
      return FileTransferStatus.failed;
    }
    return task.direction == FileTransferDirection.outgoing
        ? FileTransferStatus.queued
        : FileTransferStatus.failed;
  }
```

In `_encode` add:

```dart
        if (task.source != FileTransferSource.chat) 'source': task.source.name,
        if (task.peerName != null) 'peerName': task.peerName,
```

In `_decode` add to the constructor call:

```dart
        source: FileTransferSource.values.asNameMap()[value['source']] ??
            FileTransferSource.chat,
        peerName: value['peerName'] as String?,
```

- [ ] **Step 4: Run to verify they pass**

Run: `flutter test --no-pub test/file_transfer_controller_test.dart`
Expected: PASS (10 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/features/files/data/file_transfer_controller.dart test/file_transfer_controller_test.dart
git commit -m "A transfer remembers whether it came from AirDrop, and an AirDrop is never retried as a chat file"
```

---

### Task 3: Сроки и антиспам

**Files:**
- Create: `lib/features/airdrop/domain/airdrop_rules.dart`
- Create: `lib/features/airdrop/domain/airdrop_spam_guard.dart`
- Test: `test/airdrop_spam_guard_test.dart`

**Interfaces:**
- Produces: `AirDropRules` constants (`seenWithin`, `answerWithin`, `stallAfter`, `acceptedFor`, `everyoneFor`, `historyCap`, `declinesBeforeBan`, `firstBan`, `maxBan`, `forgetAfter`, `longOverBluetoothBytes`); `SpamRecord{declines, bans, bannedUntil, lastRequestAt, copyWith, toJson, static fromJson}`; `AirDropSpamGuard.isBanned(SpamRecord?, DateTime)`, `.onRequest(SpamRecord?, DateTime) → SpamRecord`, `.onDecline(SpamRecord, DateTime) → SpamRecord`, `.onAccept(SpamRecord) → SpamRecord`, `.banLength(int bansSoFar) → Duration`.

- [ ] **Step 1: Write the failing test**

`test/airdrop_spam_guard_test.dart`:

```dart
import 'package:cubechat/features/airdrop/domain/airdrop_rules.dart';
import 'package:cubechat/features/airdrop/domain/airdrop_spam_guard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 9, 22, 12);

  SpamRecord declineTimes(SpamRecord start, int n, DateTime at) {
    var r = start;
    for (var i = 0; i < n; i++) {
      r = AirDropSpamGuard.onDecline(AirDropSpamGuard.onRequest(r, at), at);
    }
    return r;
  }

  test('three declines in a row ban for ten minutes', () {
    final first = AirDropSpamGuard.onRequest(null, t0);
    final two = declineTimes(first, 2, t0);
    expect(AirDropSpamGuard.isBanned(two, t0), isFalse);
    final three = declineTimes(first, 3, t0);
    expect(AirDropSpamGuard.isBanned(three, t0), isTrue);
    expect(three.bannedUntil, t0.add(const Duration(minutes: 10)));
    expect(
      AirDropSpamGuard.isBanned(three, t0.add(const Duration(minutes: 10))),
      isFalse,
    );
  });

  test('each ban is twice the last, up to a day', () {
    expect(AirDropSpamGuard.banLength(0), const Duration(minutes: 10));
    expect(AirDropSpamGuard.banLength(1), const Duration(minutes: 20));
    expect(AirDropSpamGuard.banLength(2), const Duration(minutes: 40));
    expect(AirDropSpamGuard.banLength(3), const Duration(minutes: 80));
    expect(AirDropSpamGuard.banLength(8), AirDropRules.maxBan);
    expect(AirDropSpamGuard.banLength(40), AirDropRules.maxBan);
  });

  test('the second round of three bans for twenty minutes', () {
    final firstBan = declineTimes(AirDropSpamGuard.onRequest(null, t0), 3, t0);
    final after = firstBan.bannedUntil!;
    final secondBan = declineTimes(firstBan, 3, after);
    expect(secondBan.bannedUntil, after.add(const Duration(minutes: 20)));
  });

  test('an accept starts the count of declines again', () {
    final two = declineTimes(AirDropSpamGuard.onRequest(null, t0), 2, t0);
    final accepted = AirDropSpamGuard.onAccept(two);
    expect(accepted.declines, 0);
    expect(
      AirDropSpamGuard.isBanned(declineTimes(accepted, 2, t0), t0),
      isFalse,
    );
  });

  test('a day without requests forgets everything', () {
    final banned = declineTimes(AirDropSpamGuard.onRequest(null, t0), 3, t0);
    final later = t0.add(const Duration(hours: 25));
    final fresh = AirDropSpamGuard.onRequest(banned, later);
    expect(fresh.bans, 0);
    expect(fresh.declines, 0);
    expect(fresh.bannedUntil, isNull);
  });

  test('knocking during a ban keeps the record alive', () {
    final banned = declineTimes(AirDropSpamGuard.onRequest(null, t0), 3, t0);
    final during = t0.add(const Duration(minutes: 5));
    final knocked = AirDropSpamGuard.onRequest(banned, during);
    expect(knocked.lastRequestAt, during);
    expect(AirDropSpamGuard.isBanned(knocked, during), isTrue);
  });

  test('a record survives JSON', () {
    final banned = declineTimes(AirDropSpamGuard.onRequest(null, t0), 3, t0);
    final back = SpamRecord.fromJson(banned.toJson())!;
    expect(back.bans, banned.bans);
    expect(back.bannedUntil, banned.bannedUntil);
    expect(back.lastRequestAt, banned.lastRequestAt);
    expect(SpamRecord.fromJson(const {'bans': 'x'}), isNull);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test --no-pub test/airdrop_spam_guard_test.dart`
Expected: FAIL — missing files.

- [ ] **Step 3: Implement the rules**

`lib/features/airdrop/domain/airdrop_rules.dart`:

```dart
/// Every wait and limit AirDrop has, in one place — the design in
/// docs/superpowers/specs/2026-09-22-airdrop-design.md sets each of them.
abstract final class AirDropRules {
  /// An offer that draws no automatic "seen" in this long probably went to an
  /// old build, which drops the frame without a word.
  static const Duration seenWithin = Duration(seconds: 10);

  /// A request nobody answers is declined for them after this.
  static const Duration answerWithin = Duration(seconds: 60);

  /// An accepted transfer that receives nothing for this long is interrupted.
  static const Duration stallAfter = Duration(seconds: 60);

  /// How long an accepted offer stays accepted, so a retry after a dropped
  /// link goes through without asking again.
  static const Duration acceptedFor = Duration(minutes: 10);

  /// "Everyone" switches itself back to contacts after this.
  static const Duration everyoneFor = Duration(minutes: 10);

  static const int historyCap = 200;

  static const int declinesBeforeBan = 3;
  static const Duration firstBan = Duration(minutes: 10);
  static const Duration maxBan = Duration(hours: 24);

  /// A stranger's record is forgotten after a day without requests.
  static const Duration forgetAfter = Duration(hours: 24);

  /// Past this much in one go the sender is warned Bluetooth will be slow:
  /// at the ~40 KB/s a phone link really carries, twenty megabytes is minutes.
  static const int longOverBluetoothBytes = 20 * 1024 * 1024;
}
```

- [ ] **Step 4: Implement the guard**

`lib/features/airdrop/domain/airdrop_spam_guard.dart`:

```dart
import 'package:flutter/foundation.dart';

import 'airdrop_rules.dart';

/// What one stranger has done lately. Contacts never get a record.
@immutable
class SpamRecord {
  const SpamRecord({
    required this.lastRequestAt,
    this.declines = 0,
    this.bans = 0,
    this.bannedUntil,
  });

  /// Declines pressed in a row since the last ban or accept.
  final int declines;

  /// Bans served so far — each next one is twice as long.
  final int bans;
  final DateTime? bannedUntil;
  final DateTime lastRequestAt;

  SpamRecord copyWith({
    int? declines,
    int? bans,
    DateTime? bannedUntil,
    DateTime? lastRequestAt,
  }) =>
      SpamRecord(
        declines: declines ?? this.declines,
        bans: bans ?? this.bans,
        bannedUntil: bannedUntil ?? this.bannedUntil,
        lastRequestAt: lastRequestAt ?? this.lastRequestAt,
      );

  Map<String, Object?> toJson() => {
        'declines': declines,
        'bans': bans,
        if (bannedUntil != null) 'until': bannedUntil!.millisecondsSinceEpoch,
        'last': lastRequestAt.millisecondsSinceEpoch,
      };

  static SpamRecord? fromJson(Map<dynamic, dynamic> json) {
    final declines = json['declines'];
    final bans = json['bans'];
    final last = json['last'];
    final until = json['until'];
    if (declines is! int || bans is! int || last is! int) return null;
    if (until != null && until is! int) return null;
    return SpamRecord(
      declines: declines,
      bans: bans,
      bannedUntil: until is int
          ? DateTime.fromMillisecondsSinceEpoch(until)
          : null,
      lastRequestAt: DateTime.fromMillisecondsSinceEpoch(last),
    );
  }
}

/// The anti-spam rule for strangers, as arithmetic.
///
/// Only a decline the person *pressed* counts: an offer left to expire, or
/// refused because of space or because another one from the same person is
/// already waiting, says nothing about the sender.
abstract final class AirDropSpamGuard {
  static bool isBanned(SpamRecord? r, DateTime now) {
    final until = r?.bannedUntil;
    return until != null && now.isBefore(until);
  }

  /// A request arrived — whether or not it will be shown.
  static SpamRecord onRequest(SpamRecord? r, DateTime now) {
    if (r == null) return SpamRecord(lastRequestAt: now);
    final quiet = now.difference(r.lastRequestAt) >= AirDropRules.forgetAfter;
    if (quiet && !isBanned(r, now)) return SpamRecord(lastRequestAt: now);
    return r.copyWith(lastRequestAt: now);
  }

  static SpamRecord onDecline(SpamRecord r, DateTime now) {
    final declines = r.declines + 1;
    if (declines < AirDropRules.declinesBeforeBan) {
      return r.copyWith(declines: declines);
    }
    return SpamRecord(
      bans: r.bans + 1,
      bannedUntil: now.add(banLength(r.bans)),
      lastRequestAt: r.lastRequestAt,
    );
  }

  static SpamRecord onAccept(SpamRecord r) => r.copyWith(declines: 0);

  static Duration banLength(int bansSoFar) {
    var length = AirDropRules.firstBan;
    for (var i = 0; i < bansSoFar; i++) {
      length *= 2;
      if (length >= AirDropRules.maxBan) return AirDropRules.maxBan;
    }
    return length;
  }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `flutter test --no-pub test/airdrop_spam_guard_test.dart`
Expected: PASS (7 tests).

- [ ] **Step 6: Commit**

```bash
git add lib/features/airdrop/domain test/airdrop_spam_guard_test.dart
git commit -m "Three declines from a stranger put them away for ten minutes, twice as long each time"
```

---

### Task 4: Модель передачи и её переходы

**Files:**
- Create: `lib/features/airdrop/domain/airdrop_transfer.dart`
- Test: `test/airdrop_transfer_test.dart`

**Interfaces:**
- Consumes: `NearbyAnswer`, `NearbyAnswerKind`, `NearbyDeclineReason` (Task 1); `AirDropRules` (Task 3).
- Produces: `enum AirDropDirection { incoming, outgoing }`; `enum AirDropPhase { offered, unheard, waiting, transferring, interrupted, done, partial, declined, cancelled, failed }` with `bool get isFinal`; `AirDropFile{mediaIdHex, name, size, mime, path, done, copyWith}`; `AirDropTransfer{id, peerHex, peerName, direction, files, phase, createdAt, reason, acceptedAt, lastProgressAt, totalBytes, doneCount, allDone, isIncomingRequest, acceptedStill(now), copyWith}`; `AirDropTransitions.onAnswer / onSeenTimeout / onOfferExpired / accept / decline / onAnswerTimeout / onFileDone / onProgress / onStall / interrupt / retry / stop / expire`.

- [ ] **Step 1: Write the failing test**

`test/airdrop_transfer_test.dart`:

```dart
import 'dart:typed_data';

import 'package:cubechat/core/transport/nearby_offer.dart';
import 'package:cubechat/features/airdrop/domain/airdrop_transfer.dart';
import 'package:flutter_test/flutter_test.dart';

final _t0 = DateTime(2026, 9, 22, 12);
final _tid = Uint8List(nearbyIdLen);

AirDropTransfer _transfer({
  AirDropDirection direction = AirDropDirection.outgoing,
  AirDropPhase phase = AirDropPhase.offered,
  int files = 2,
  DateTime? acceptedAt,
}) =>
    AirDropTransfer(
      id: nearbyHex(_tid),
      peerHex: 'bb' * 32,
      peerName: 'Жека',
      direction: direction,
      files: [
        for (var i = 0; i < files; i++)
          AirDropFile(
            mediaIdHex: 'f$i',
            name: 'p$i.jpg',
            size: 100,
            mime: 'image/jpeg',
          ),
      ],
      phase: phase,
      createdAt: _t0,
      acceptedAt: acceptedAt,
      lastProgressAt: acceptedAt,
    );

NearbyAnswer _answer(
  NearbyAnswerKind kind, [
  NearbyDeclineReason reason = NearbyDeclineReason.user,
]) =>
    NearbyAnswer(transferId: _tid, kind: kind, reason: reason);

void main() {
  group('outgoing', () {
    test('seen, then accepted', () {
      final seen = AirDropTransitions.onAnswer(
        _transfer(),
        _answer(NearbyAnswerKind.seen),
        _t0,
      );
      expect(seen.phase, AirDropPhase.waiting);
      final accepted = AirDropTransitions.onAnswer(
        seen,
        _answer(NearbyAnswerKind.accepted),
        _t0,
      );
      expect(accepted.phase, AirDropPhase.transferring);
      expect(accepted.acceptedAt, _t0);
    });

    test('no seen in time says unheard, and a late seen still counts', () {
      final unheard = AirDropTransitions.onSeenTimeout(_transfer());
      expect(unheard.phase, AirDropPhase.unheard);
      expect(
        AirDropTransitions.onSeenTimeout(
          _transfer(phase: AirDropPhase.waiting),
        ).phase,
        AirDropPhase.waiting,
      );
      expect(
        AirDropTransitions.onAnswer(
          unheard,
          _answer(NearbyAnswerKind.seen),
          _t0,
        ).phase,
        AirDropPhase.waiting,
      );
    });

    test('a decline carries its reason', () {
      final declined = AirDropTransitions.onAnswer(
        _transfer(phase: AirDropPhase.waiting),
        _answer(NearbyAnswerKind.declined, NearbyDeclineReason.noSpace),
        _t0,
      );
      expect(declined.phase, AirDropPhase.declined);
      expect(declined.reason, NearbyDeclineReason.noSpace);
    });

    test('nothing moves a finished transfer', () {
      final done = _transfer(phase: AirDropPhase.done);
      for (final kind in NearbyAnswerKind.values) {
        expect(
          AirDropTransitions.onAnswer(done, _answer(kind), _t0).phase,
          AirDropPhase.done,
        );
      }
    });

    test('an offer nobody answers fails', () {
      for (final phase in [
        AirDropPhase.offered,
        AirDropPhase.unheard,
        AirDropPhase.waiting,
      ]) {
        expect(
          AirDropTransitions.onOfferExpired(_transfer(phase: phase)).phase,
          AirDropPhase.failed,
        );
      }
      expect(
        AirDropTransitions.onOfferExpired(
          _transfer(phase: AirDropPhase.transferring, acceptedAt: _t0),
        ).phase,
        AirDropPhase.transferring,
      );
    });

    test('a retry inside ten minutes resumes; after, it does not', () {
      final broken = AirDropTransitions.interrupt(
        _transfer(phase: AirDropPhase.transferring, acceptedAt: _t0),
      );
      expect(broken.phase, AirDropPhase.interrupted);
      expect(
        AirDropTransitions.retry(broken, _t0.add(const Duration(minutes: 9)))
            .phase,
        AirDropPhase.transferring,
      );
      expect(
        AirDropTransitions.retry(broken, _t0.add(const Duration(minutes: 10)))
            .phase,
        AirDropPhase.interrupted,
      );
    });
  });

  group('incoming', () {
    AirDropTransfer request() => _transfer(
          direction: AirDropDirection.incoming,
          phase: AirDropPhase.waiting,
        );

    test('accept, decline and the sixty-second timeout act on a request only',
        () {
      expect(request().isIncomingRequest, isTrue);
      expect(
        AirDropTransitions.accept(request(), _t0).phase,
        AirDropPhase.transferring,
      );
      final declined =
          AirDropTransitions.decline(request(), NearbyDeclineReason.user);
      expect(declined.phase, AirDropPhase.declined);
      final expired = AirDropTransitions.onAnswerTimeout(request());
      expect(expired.phase, AirDropPhase.declined);
      expect(expired.reason, NearbyDeclineReason.timeout);
      final moving = AirDropTransitions.accept(request(), _t0);
      expect(AirDropTransitions.onAnswerTimeout(moving), same(moving));
    });

    test('files arrive one by one and the last one finishes it', () {
      var t = AirDropTransitions.accept(request(), _t0);
      t = AirDropTransitions.onFileDone(t, 'f0', '/a/p0.jpg', _t0);
      expect(t.doneCount, 1);
      expect(t.files.first.path, '/a/p0.jpg');
      expect(t.phase, AirDropPhase.transferring);
      t = AirDropTransitions.onFileDone(t, 'f1', '/a/p1.jpg', _t0);
      expect(t.phase, AirDropPhase.done);
    });

    test('a file for a request not yet accepted changes nothing', () {
      expect(
        AirDropTransitions.onFileDone(request(), 'f0', '/a', _t0).doneCount,
        0,
      );
    });

    test('sixty seconds without a piece interrupts, a file resumes it', () {
      final moving = AirDropTransitions.accept(request(), _t0);
      expect(
        AirDropTransitions.onStall(
          moving,
          _t0.add(const Duration(seconds: 59)),
        ).phase,
        AirDropPhase.transferring,
      );
      final stalled = AirDropTransitions.onStall(
        moving,
        _t0.add(const Duration(seconds: 60)),
      );
      expect(stalled.phase, AirDropPhase.interrupted);
      final resumed = AirDropTransitions.onFileDone(
        stalled,
        'f0',
        '/a/p0.jpg',
        _t0.add(const Duration(minutes: 2)),
      );
      expect(resumed.phase, AirDropPhase.transferring);
    });

    test('an interrupted transfer ends when its acceptance runs out', () {
      final stalled = AirDropTransitions.interrupt(
        AirDropTransitions.accept(request(), _t0),
      );
      final later = _t0.add(const Duration(minutes: 10));
      expect(
        AirDropTransitions.expire(stalled, later).phase,
        AirDropPhase.failed,
      );
      final one = AirDropTransitions.onFileDone(stalled, 'f0', '/a', _t0);
      expect(
        AirDropTransitions.expire(AirDropTransitions.interrupt(one), later)
            .phase,
        AirDropPhase.partial,
      );
    });
  });

  test('stopping keeps what already arrived', () {
    final moving = AirDropTransitions.accept(
      _transfer(direction: AirDropDirection.incoming, phase: AirDropPhase.waiting),
      _t0,
    );
    expect(AirDropTransitions.stop(moving).phase, AirDropPhase.cancelled);
    final one = AirDropTransitions.onFileDone(moving, 'f0', '/a', _t0);
    expect(AirDropTransitions.stop(one).phase, AirDropPhase.partial);
    expect(
      AirDropTransitions.stop(_transfer(phase: AirDropPhase.done)).phase,
      AirDropPhase.done,
    );
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test --no-pub test/airdrop_transfer_test.dart`
Expected: FAIL — missing file.

- [ ] **Step 3: Implement**

`lib/features/airdrop/domain/airdrop_transfer.dart`:

```dart
import 'package:flutter/foundation.dart';

import '../../../core/transport/nearby_offer.dart';
import 'airdrop_rules.dart';

enum AirDropDirection { incoming, outgoing }

enum AirDropPhase {
  /// Outgoing: offer sent, not even the automatic "seen" back yet.
  offered,

  /// Outgoing: no "seen" within [AirDropRules.seenWithin] — probably an old
  /// build. Still live: a late seen or answer moves it on.
  unheard,

  /// Outgoing: seen, the person is deciding. Incoming: the card on screen.
  waiting,

  /// Accepted; files moving or about to.
  transferring,

  /// The link dropped mid-transfer. Live while the acceptance lasts.
  interrupted,

  done,

  /// Stopped or run out after some files got through.
  partial,
  declined,
  cancelled,

  /// Never got anywhere: the offer could not leave, nobody answered, or an
  /// interruption outlived its acceptance.
  failed;

  bool get isFinal =>
      this == done ||
      this == partial ||
      this == declined ||
      this == cancelled ||
      this == failed;
}

@immutable
class AirDropFile {
  const AirDropFile({
    required this.mediaIdHex,
    required this.name,
    required this.size,
    required this.mime,
    this.path,
    this.done = false,
  });

  final String mediaIdHex;
  final String name;
  final int size;
  final String mime;

  /// Outgoing: the file being read. Incoming: where it was kept, once done.
  final String? path;
  final bool done;

  AirDropFile copyWith({String? path, bool? done}) => AirDropFile(
        mediaIdHex: mediaIdHex,
        name: name,
        size: size,
        mime: mime,
        path: path ?? this.path,
        done: done ?? this.done,
      );
}

@immutable
class AirDropTransfer {
  const AirDropTransfer({
    required this.id,
    required this.peerHex,
    required this.peerName,
    required this.direction,
    required this.files,
    required this.phase,
    required this.createdAt,
    this.reason,
    this.acceptedAt,
    this.lastProgressAt,
  });

  /// The transfer id, hex.
  final String id;
  final String peerHex;
  final String peerName;
  final AirDropDirection direction;
  final List<AirDropFile> files;
  final AirDropPhase phase;
  final DateTime createdAt;
  final NearbyDeclineReason? reason;
  final DateTime? acceptedAt;
  final DateTime? lastProgressAt;

  int get totalBytes => files.fold(0, (sum, f) => sum + f.size);
  int get doneCount => files.where((f) => f.done).length;
  bool get allDone => files.every((f) => f.done);
  bool get isIncomingRequest =>
      direction == AirDropDirection.incoming && phase == AirDropPhase.waiting;

  bool acceptedStill(DateTime now) {
    final at = acceptedAt;
    return at != null && now.difference(at) < AirDropRules.acceptedFor;
  }

  AirDropTransfer copyWith({
    AirDropPhase? phase,
    List<AirDropFile>? files,
    NearbyDeclineReason? reason,
    DateTime? acceptedAt,
    DateTime? lastProgressAt,
  }) =>
      AirDropTransfer(
        id: id,
        peerHex: peerHex,
        peerName: peerName,
        direction: direction,
        files: files ?? this.files,
        phase: phase ?? this.phase,
        createdAt: createdAt,
        reason: reason ?? this.reason,
        acceptedAt: acceptedAt ?? this.acceptedAt,
        lastProgressAt: lastProgressAt ?? this.lastProgressAt,
      );
}

/// Every way a transfer moves, as functions of what it was and what happened.
/// Anything that does not apply returns the transfer unchanged — the same
/// instance, so a caller can tell "nothing happened" with `identical`.
abstract final class AirDropTransitions {
  static const _beforeAnswer = {
    AirDropPhase.offered,
    AirDropPhase.unheard,
    AirDropPhase.waiting,
  };

  static AirDropTransfer onAnswer(
    AirDropTransfer t,
    NearbyAnswer a,
    DateTime now,
  ) {
    if (t.phase.isFinal) return t;
    switch (a.kind) {
      case NearbyAnswerKind.seen:
        return t.phase == AirDropPhase.offered ||
                t.phase == AirDropPhase.unheard
            ? t.copyWith(phase: AirDropPhase.waiting)
            : t;
      case NearbyAnswerKind.accepted:
        return t.direction == AirDropDirection.outgoing &&
                _beforeAnswer.contains(t.phase)
            ? t.copyWith(
                phase: AirDropPhase.transferring,
                acceptedAt: now,
                lastProgressAt: now,
              )
            : t;
      case NearbyAnswerKind.declined:
        return _beforeAnswer.contains(t.phase)
            ? t.copyWith(phase: AirDropPhase.declined, reason: a.reason)
            : t;
      case NearbyAnswerKind.cancelled:
        return stop(t);
    }
  }

  static AirDropTransfer onSeenTimeout(AirDropTransfer t) =>
      t.phase == AirDropPhase.offered
          ? t.copyWith(phase: AirDropPhase.unheard)
          : t;

  /// Our offer went unanswered for longer than the other side would wait.
  static AirDropTransfer onOfferExpired(AirDropTransfer t) =>
      t.direction == AirDropDirection.outgoing &&
              _beforeAnswer.contains(t.phase)
          ? t.copyWith(phase: AirDropPhase.failed)
          : t;

  static AirDropTransfer accept(AirDropTransfer t, DateTime now) =>
      t.isIncomingRequest
          ? t.copyWith(
              phase: AirDropPhase.transferring,
              acceptedAt: now,
              lastProgressAt: now,
            )
          : t;

  static AirDropTransfer decline(
    AirDropTransfer t,
    NearbyDeclineReason reason,
  ) =>
      t.isIncomingRequest
          ? t.copyWith(phase: AirDropPhase.declined, reason: reason)
          : t;

  static AirDropTransfer onAnswerTimeout(AirDropTransfer t) =>
      decline(t, NearbyDeclineReason.timeout);

  static AirDropTransfer onFileDone(
    AirDropTransfer t,
    String mediaIdHex,
    String path,
    DateTime now,
  ) {
    if (t.phase != AirDropPhase.transferring &&
        t.phase != AirDropPhase.interrupted) {
      return t;
    }
    final next = t.copyWith(
      files: [
        for (final f in t.files)
          f.mediaIdHex == mediaIdHex ? f.copyWith(done: true, path: path) : f,
      ],
      phase: AirDropPhase.transferring,
      lastProgressAt: now,
    );
    return next.allDone ? next.copyWith(phase: AirDropPhase.done) : next;
  }

  static AirDropTransfer onProgress(AirDropTransfer t, DateTime now) =>
      t.phase == AirDropPhase.transferring
          ? t.copyWith(lastProgressAt: now)
          : t;

  static AirDropTransfer onStall(AirDropTransfer t, DateTime now) {
    final last = t.lastProgressAt ?? t.acceptedAt;
    if (t.phase != AirDropPhase.transferring || last == null) return t;
    return now.difference(last) >= AirDropRules.stallAfter
        ? t.copyWith(phase: AirDropPhase.interrupted)
        : t;
  }

  /// The link went while a file was moving, or the offer could not leave.
  static AirDropTransfer interrupt(AirDropTransfer t) {
    if (t.phase == AirDropPhase.transferring) {
      return t.copyWith(phase: AirDropPhase.interrupted);
    }
    return _beforeAnswer.contains(t.phase)
        ? t.copyWith(phase: AirDropPhase.failed)
        : t;
  }

  static AirDropTransfer retry(AirDropTransfer t, DateTime now) =>
      t.phase == AirDropPhase.interrupted &&
              t.direction == AirDropDirection.outgoing &&
              t.acceptedStill(now)
          ? t.copyWith(phase: AirDropPhase.transferring, lastProgressAt: now)
          : t;

  /// Stopped by either side. Files already through stay.
  static AirDropTransfer stop(AirDropTransfer t) => t.phase.isFinal
      ? t
      : t.copyWith(
          phase: t.doneCount > 0 ? AirDropPhase.partial : AirDropPhase.cancelled,
        );

  static AirDropTransfer expire(AirDropTransfer t, DateTime now) =>
      t.phase == AirDropPhase.interrupted && !t.acceptedStill(now)
          ? t.copyWith(
              phase:
                  t.doneCount > 0 ? AirDropPhase.partial : AirDropPhase.failed,
            )
          : t;
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `flutter test --no-pub test/airdrop_transfer_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/features/airdrop/domain/airdrop_transfer.dart test/airdrop_transfer_test.dart
git commit -m "Every step an AirDrop can take, written down where a test can check it"
```

---

### Task 5: Хранение — папка, режим приёма, история, записи антиспама

**Files:**
- Create: `lib/features/airdrop/data/airdrop_clock.dart`
- Create: `lib/features/airdrop/data/airdrop_storage.dart`
- Create: `lib/features/airdrop/data/airdrop_receive_controller.dart`
- Create: `lib/features/airdrop/data/airdrop_history_controller.dart`
- Create: `lib/features/airdrop/data/airdrop_spam_store.dart`
- Test: `test/airdrop_storage_test.dart`

**Interfaces:**
- Consumes: `AirDropRules`, `SpamRecord` (Task 3); `AirDropTransfer`, `AirDropPhase`, `AirDropDirection` (Task 4); `safeFileName` (`inner_payload.dart`); `hiveCipherProvider`, `HiveBoxes.settings`.
- Produces: `airdropClockProvider` (`Provider<DateTime Function()>`); `airdropDirectory()`, `airdropDirectoryProvider` (`Provider<Future<Directory> Function()>`), `uniqueFileIn(Directory, String) → Future<File>`, `deleteAirdropDirectory()`; `AirDropReceive{everyoneUntil, everyoneAt(now)}`, `airdropReceiveProvider` with `openToEveryone()`, `contactsOnly()`, `reset()`; `AirDropOutcome{received, sent, declined, cancelled, failed, partial}`, `AirDropHistoryFile`, `AirDropHistoryEntry`, `AirDropHistoryEntry.of(AirDropTransfer, DateTime)`, `airdropHistoryProvider` with `add`, `markDeleted(path)`, `clear()`, overridable `save`; `airdropSpamProvider` (`Map<String, SpamRecord>`) with `recordFor`, `put`, `remove`, `clear()`, overridable `save`.

- [ ] **Step 1: Write the failing tests**

`test/airdrop_storage_test.dart`:

```dart
import 'dart:io';

import 'package:cubechat/core/storage/hive_cipher.dart';
import 'package:cubechat/core/storage/hive_init.dart';
import 'package:cubechat/features/airdrop/data/airdrop_clock.dart';
import 'package:cubechat/features/airdrop/data/airdrop_history_controller.dart';
import 'package:cubechat/features/airdrop/data/airdrop_receive_controller.dart';
import 'package:cubechat/features/airdrop/data/airdrop_spam_store.dart';
import 'package:cubechat/features/airdrop/data/airdrop_storage.dart';
import 'package:cubechat/features/airdrop/domain/airdrop_spam_guard.dart';
import 'package:cubechat/features/airdrop/domain/airdrop_transfer.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

AirDropHistoryEntry _entry(int i, {String? path}) => AirDropHistoryEntry(
      id: 'id$i',
      peerHex: 'bb' * 32,
      peerName: 'Жека',
      direction: AirDropDirection.incoming,
      at: DateTime(2026, 9, 22).add(Duration(minutes: i)),
      outcome: AirDropOutcome.received,
      files: [
        AirDropHistoryFile(
          name: 'p$i.jpg',
          size: 10,
          mime: 'image/jpeg',
          path: path,
        ),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ProviderContainer container;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_airdrop_');
    Hive.init(tempDir.path);
    container = ProviderContainer();
  });

  tearDown(() async {
    await settleBackgroundStorage();
    container.dispose();
    await Hive.close();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows can briefly retain a Hive file handle after close.
    }
  });

  group('uniqueFileIn', () {
    test('numbers a name that is taken, keeping the extension', () async {
      final a = await uniqueFileIn(tempDir, 'a.jpg');
      expect(a.path, endsWith('${Platform.pathSeparator}a.jpg'));
      await a.writeAsString('x');
      final b = await uniqueFileIn(tempDir, 'a.jpg');
      expect(b.path, endsWith('${Platform.pathSeparator}a (1).jpg'));
      await b.writeAsString('x');
      expect(
        (await uniqueFileIn(tempDir, 'a.jpg')).path,
        endsWith('${Platform.pathSeparator}a (2).jpg'),
      );
    });

    test('a name without an extension, and one that tries to climb out',
        () async {
      await File('${tempDir.path}${Platform.pathSeparator}notes')
          .writeAsString('x');
      expect(
        (await uniqueFileIn(tempDir, 'notes')).path,
        endsWith('${Platform.pathSeparator}notes (1)'),
      );
      final climbed = await uniqueFileIn(tempDir, '../x');
      expect(climbed.parent.path, tempDir.path);
    });
  });

  group('history', () {
    test('keeps the newest two hundred, newest first, across a restart',
        () async {
      final history = container.read(airdropHistoryProvider.notifier);
      await history.loaded;
      for (var i = 0; i < 201; i++) {
        history.add(_entry(i));
      }
      expect(container.read(airdropHistoryProvider), hasLength(200));
      expect(container.read(airdropHistoryProvider).first.id, 'id200');
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final relaunched = ProviderContainer();
      addTearDown(relaunched.dispose);
      await relaunched.read(airdropHistoryProvider.notifier).loaded;
      final restored = relaunched.read(airdropHistoryProvider);
      expect(restored, hasLength(200));
      expect(restored.first.id, 'id200');
      expect(restored.first.files.single.name, 'p200.jpg');
    });

    test('a deleted file stays in the history, marked', () async {
      final history = container.read(airdropHistoryProvider.notifier);
      await history.loaded;
      history
        ..add(_entry(1, path: '/x/p1.jpg'))
        ..add(_entry(2, path: '/x/p2.jpg'))
        ..markDeleted('/x/p1.jpg');
      final entries = container.read(airdropHistoryProvider);
      expect(entries.firstWhere((e) => e.id == 'id1').files.single.deleted,
          isTrue);
      expect(entries.firstWhere((e) => e.id == 'id2').files.single.deleted,
          isFalse);
    });

    test('clear empties it', () async {
      final history = container.read(airdropHistoryProvider.notifier);
      await history.loaded;
      history.add(_entry(1));
      await history.clear();
      expect(container.read(airdropHistoryProvider), isEmpty);
    });
  });

  test('spam records survive a restart', () async {
    final spam = container.read(airdropSpamProvider.notifier);
    await spam.loaded;
    spam.put(
      'cc' * 32,
      SpamRecord(lastRequestAt: DateTime(2026, 9, 22), bans: 2),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final relaunched = ProviderContainer();
    addTearDown(relaunched.dispose);
    await relaunched.read(airdropSpamProvider.notifier).loaded;
    expect(
      relaunched.read(airdropSpamProvider.notifier).recordFor('cc' * 32)?.bans,
      2,
    );
  });

  group('receive mode', () {
    test('everyone lasts ten minutes and survives a restart', () async {
      final now = DateTime.now();
      final pinned = ProviderContainer(
        overrides: [airdropClockProvider.overrideWithValue(() => now)],
      );
      addTearDown(pinned.dispose);
      final receive = pinned.read(airdropReceiveProvider.notifier);
      await receive.loaded;
      await receive.openToEveryone();
      final until = pinned.read(airdropReceiveProvider).everyoneUntil;
      expect(until, now.add(const Duration(minutes: 10)));
      expect(pinned.read(airdropReceiveProvider).everyoneAt(now), isTrue);

      final relaunched = ProviderContainer(
        overrides: [airdropClockProvider.overrideWithValue(() => now)],
      );
      addTearDown(relaunched.dispose);
      await relaunched.read(airdropReceiveProvider.notifier).loaded;
      expect(relaunched.read(airdropReceiveProvider).everyoneUntil, until);

      await receive.contactsOnly();
      expect(pinned.read(airdropReceiveProvider).everyoneUntil, isNull);
    });

    test('switches itself back to contacts when the time is up', () async {
      final box =
          await hiveCipherProvider.openEncryptedBox<dynamic>(HiveBoxes.settings);
      await box.put(
        AirDropReceiveController.storageKey,
        DateTime.now()
            .add(const Duration(milliseconds: 300))
            .millisecondsSinceEpoch,
      );
      final receive = container.read(airdropReceiveProvider.notifier);
      await receive.loaded;
      expect(
        container.read(airdropReceiveProvider).everyoneAt(DateTime.now()),
        isTrue,
      );
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(container.read(airdropReceiveProvider).everyoneUntil, isNull);
    });

    test('a window that ended while the app was closed is not restored',
        () async {
      final box =
          await hiveCipherProvider.openEncryptedBox<dynamic>(HiveBoxes.settings);
      await box.put(
        AirDropReceiveController.storageKey,
        DateTime.now()
            .subtract(const Duration(minutes: 1))
            .millisecondsSinceEpoch,
      );
      await container.read(airdropReceiveProvider.notifier).loaded;
      expect(container.read(airdropReceiveProvider).everyoneUntil, isNull);
    });
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test --no-pub test/airdrop_storage_test.dart`
Expected: FAIL — missing files.

- [ ] **Step 3: The clock and the folder**

`lib/features/airdrop/data/airdrop_clock.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// "Now", for everything in AirDrop that counts minutes — injectable so tests
/// can stand at a moment of their choosing.
final airdropClockProvider =
    Provider<DateTime Function()>((ref) => DateTime.now);
```

`lib/features/airdrop/data/airdrop_storage.dart`:

```dart
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/transport/inner_payload.dart' show safeFileName;

String _airdropPath(Directory docs) =>
    '${docs.path}${Platform.pathSeparator}airdrop';

/// Where received AirDrop files live: the app's own documents, in a folder of
/// their own. Backup and phone transfer take the `cubechat-*` folders only, so
/// these never leave the phone — as the design says.
Future<Directory> airdropDirectory() async {
  final dir = Directory(_airdropPath(await getApplicationDocumentsDirectory()));
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

/// Injected so tests keep their files in a temporary directory.
final airdropDirectoryProvider =
    Provider<Future<Directory> Function()>((ref) => airdropDirectory);

/// A free place for [rawName] in [dir]: the sanitised name, or the same with
/// " (1)", " (2)"… before the extension.
Future<File> uniqueFileIn(Directory dir, String rawName) async {
  final safe = safeFileName(rawName);
  final dot = safe.lastIndexOf('.');
  final stem = dot > 0 ? safe.substring(0, dot) : safe;
  final ext = dot > 0 ? safe.substring(dot) : '';
  final sep = Platform.pathSeparator;
  var candidate = File('${dir.path}$sep$safe');
  for (var n = 1; await candidate.exists(); n++) {
    candidate = File('${dir.path}$sep$stem ($n)$ext');
  }
  return candidate;
}

/// Emergency wipe: the whole folder, best effort.
Future<void> deleteAirdropDirectory() async {
  try {
    final dir = Directory(_airdropPath(await getApplicationDocumentsDirectory()));
    if (await dir.exists()) await dir.delete(recursive: true);
  } catch (_) {
    // A wipe that cannot find the folder has nothing to wipe.
  }
}
```

- [ ] **Step 4: The receive mode**

`lib/features/airdrop/data/airdrop_receive_controller.dart`:

```dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';
import '../domain/airdrop_rules.dart';
import 'airdrop_clock.dart';

/// "Receive from: Contacts / Everyone for 10 min".
@immutable
class AirDropReceive {
  const AirDropReceive({this.everyoneUntil});

  /// Null means contacts only.
  final DateTime? everyoneUntil;

  bool everyoneAt(DateTime now) {
    final until = everyoneUntil;
    return until != null && now.isBefore(until);
  }
}

/// While "everyone" is on, this phone is also visible to strangers — the XX
/// handshake is answered even with "Discoverable nearby" off in the profile
/// (see `MessagingService._discoverableNow`). It switches itself off, so
/// nobody is left visible by forgetting.
class AirDropReceiveController extends Notifier<AirDropReceive> {
  static const storageKey = 'airdrop.everyoneUntil';

  Box<dynamic>? _box;
  Future<void>? _loading;
  Timer? _expiry;

  Future<void> get loaded => _loading ?? Future<void>.value();

  DateTime get _now => ref.read(airdropClockProvider)();

  @override
  AirDropReceive build() {
    ref.onDispose(() => _expiry?.cancel());
    unawaited(_loading = _load());
    return const AirDropReceive();
  }

  Future<void> _load() async {
    try {
      _box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      final raw = _box?.get(storageKey);
      if (raw is! int) return;
      final until = DateTime.fromMillisecondsSinceEpoch(raw);
      if (!until.isAfter(_now)) {
        await _box?.delete(storageKey);
        return;
      }
      state = AirDropReceive(everyoneUntil: until);
      _arm(until);
    } catch (e) {
      debugPrint('AirDropReceiveController load failed: $e');
    }
  }

  Future<void> openToEveryone() async {
    final until = _now.add(AirDropRules.everyoneFor);
    state = AirDropReceive(everyoneUntil: until);
    _arm(until);
    await loaded;
    await _box?.put(storageKey, until.millisecondsSinceEpoch);
  }

  Future<void> contactsOnly() async {
    _expiry?.cancel();
    _expiry = null;
    state = const AirDropReceive();
    await loaded;
    await _box?.delete(storageKey);
  }

  Future<void> reset() => contactsOnly();

  void _arm(DateTime until) {
    _expiry?.cancel();
    final left = until.difference(_now);
    _expiry = Timer(
      left.isNegative ? Duration.zero : left,
      () => unawaited(contactsOnly()),
    );
  }
}

final airdropReceiveProvider =
    NotifierProvider<AirDropReceiveController, AirDropReceive>(
  AirDropReceiveController.new,
);
```

The expiry test writes a real `DateTime.now()` 300 ms ahead and uses the real clock, so the timer fires in real time.

- [ ] **Step 5: The history**

`lib/features/airdrop/data/airdrop_history_controller.dart`:

```dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';
import '../../../core/transport/nearby_offer.dart';
import '../domain/airdrop_rules.dart';
import '../domain/airdrop_transfer.dart';

enum AirDropOutcome { received, sent, declined, cancelled, failed, partial }

@immutable
class AirDropHistoryFile {
  const AirDropHistoryFile({
    required this.name,
    required this.size,
    required this.mime,
    this.path,
    this.deleted = false,
  });

  final String name;
  final int size;
  final String mime;

  /// Where a received file was kept. Null for a sent one: no copy is kept.
  final String? path;
  final bool deleted;

  AirDropHistoryFile deletedCopy() => AirDropHistoryFile(
        name: name,
        size: size,
        mime: mime,
        path: path,
        deleted: true,
      );

  Map<String, Object?> toJson() => {
        'name': name,
        'size': size,
        'mime': mime,
        if (path != null) 'path': path,
        if (deleted) 'deleted': true,
      };

  static AirDropHistoryFile? fromJson(Map<dynamic, dynamic> json) {
    final name = json['name'];
    final size = json['size'];
    final mime = json['mime'];
    if (name is! String || size is! int || mime is! String) return null;
    return AirDropHistoryFile(
      name: name,
      size: size,
      mime: mime,
      path: json['path'] as String?,
      deleted: json['deleted'] == true,
    );
  }
}

@immutable
class AirDropHistoryEntry {
  const AirDropHistoryEntry({
    required this.id,
    required this.peerHex,
    required this.peerName,
    required this.direction,
    required this.at,
    required this.outcome,
    required this.files,
    this.reason,
  });

  /// A finished transfer as a history line. Sent files keep no path.
  factory AirDropHistoryEntry.of(AirDropTransfer t, DateTime at) {
    final incoming = t.direction == AirDropDirection.incoming;
    return AirDropHistoryEntry(
      id: t.id,
      peerHex: t.peerHex,
      peerName: t.peerName,
      direction: t.direction,
      at: at,
      reason: t.phase == AirDropPhase.declined ? t.reason : null,
      outcome: switch (t.phase) {
        AirDropPhase.done =>
          incoming ? AirDropOutcome.received : AirDropOutcome.sent,
        AirDropPhase.partial => AirDropOutcome.partial,
        AirDropPhase.declined => AirDropOutcome.declined,
        AirDropPhase.cancelled => AirDropOutcome.cancelled,
        _ => AirDropOutcome.failed,
      },
      files: [
        for (final f in t.files)
          AirDropHistoryFile(
            name: f.name,
            size: f.size,
            mime: f.mime,
            path: incoming && f.done ? f.path : null,
          ),
      ],
    );
  }

  final String id;
  final String peerHex;
  final String peerName;
  final AirDropDirection direction;
  final DateTime at;
  final AirDropOutcome outcome;
  final NearbyDeclineReason? reason;
  final List<AirDropHistoryFile> files;

  AirDropHistoryEntry withFiles(List<AirDropHistoryFile> files) =>
      AirDropHistoryEntry(
        id: id,
        peerHex: peerHex,
        peerName: peerName,
        direction: direction,
        at: at,
        outcome: outcome,
        reason: reason,
        files: files,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'peer': peerHex,
        'name': peerName,
        'dir': direction.name,
        'at': at.millisecondsSinceEpoch,
        'outcome': outcome.name,
        if (reason != null) 'reason': reason!.name,
        'files': [for (final f in files) f.toJson()],
      };

  static AirDropHistoryEntry? fromJson(Map<dynamic, dynamic> json) {
    final id = json['id'];
    final peer = json['peer'];
    final name = json['name'];
    final at = json['at'];
    final direction = AirDropDirection.values.asNameMap()[json['dir']];
    final outcome = AirDropOutcome.values.asNameMap()[json['outcome']];
    final rawFiles = json['files'];
    if (id is! String ||
        peer is! String ||
        name is! String ||
        at is! int ||
        direction == null ||
        outcome == null ||
        rawFiles is! List) {
      return null;
    }
    return AirDropHistoryEntry(
      id: id,
      peerHex: peer,
      peerName: name,
      direction: direction,
      at: DateTime.fromMillisecondsSinceEpoch(at),
      outcome: outcome,
      reason: NearbyDeclineReason.values.asNameMap()[json['reason']],
      files: [
        for (final f in rawFiles)
          if (f is Map) AirDropHistoryFile.fromJson(f),
      ].whereType<AirDropHistoryFile>().toList(),
    );
  }
}

/// AirDrop's history both ways, newest first, the last two hundred.
///
/// In the encrypted settings box under a key the backup skips — see
/// `backup_filter.dart`. "Clear history" clears this list only; received
/// files stay where they are.
class AirDropHistoryController extends Notifier<List<AirDropHistoryEntry>> {
  static const storageKey = 'airdrop.history.v1';

  Box<dynamic>? _box;
  Future<void>? _loading;

  Future<void> get loaded => _loading ?? Future<void>.value();

  @override
  List<AirDropHistoryEntry> build() {
    unawaited(_loading = _load());
    return const [];
  }

  Future<void> _load() async {
    try {
      _box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      final raw = _box?.get(storageKey);
      if (raw is! List) return;
      final restored = [
        for (final row in raw)
          if (row is Map) AirDropHistoryEntry.fromJson(row),
      ].whereType<AirDropHistoryEntry>();
      state = [...state, ...restored].take(AirDropRules.historyCap).toList();
    } catch (e) {
      debugPrint('AirDropHistoryController load failed: $e');
    }
  }

  void add(AirDropHistoryEntry entry) {
    state = [entry, ...state.where((e) => e.id != entry.id)]
        .take(AirDropRules.historyCap)
        .toList();
    unawaited(save(state));
  }

  void markDeleted(String path) {
    state = [
      for (final e in state)
        e.files.any((f) => f.path == path)
            ? e.withFiles([
                for (final f in e.files) f.path == path ? f.deletedCopy() : f,
              ])
            : e,
    ];
    unawaited(save(state));
  }

  Future<void> clear() async {
    state = const [];
    await save(state);
  }

  /// Overridden in tests that keep history in memory.
  @protected
  Future<void> save(List<AirDropHistoryEntry> entries) async {
    if (_box == null) await loaded;
    await _box?.put(storageKey, [for (final e in entries) e.toJson()]);
  }
}

final airdropHistoryProvider =
    NotifierProvider<AirDropHistoryController, List<AirDropHistoryEntry>>(
  AirDropHistoryController.new,
);
```

- [ ] **Step 6: The spam records**

`lib/features/airdrop/data/airdrop_spam_store.dart`:

```dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';
import '../domain/airdrop_spam_guard.dart';

/// One [SpamRecord] per stranger, kept across restarts so closing the app is
/// not a way out of a ban.
class AirDropSpamStore extends Notifier<Map<String, SpamRecord>> {
  static const storageKey = 'airdrop.spam.v1';

  Box<dynamic>? _box;
  Future<void>? _loading;

  Future<void> get loaded => _loading ?? Future<void>.value();

  @override
  Map<String, SpamRecord> build() {
    unawaited(_loading = _load());
    return const {};
  }

  Future<void> _load() async {
    try {
      _box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      final raw = _box?.get(storageKey);
      if (raw is! Map) return;
      final restored = <String, SpamRecord>{};
      raw.forEach((key, value) {
        if (key is! String || value is! Map) return;
        final record = SpamRecord.fromJson(value);
        if (record != null) restored[key] = record;
      });
      state = {...restored, ...state};
    } catch (e) {
      debugPrint('AirDropSpamStore load failed: $e');
    }
  }

  SpamRecord? recordFor(String peerHex) => state[peerHex];

  void put(String peerHex, SpamRecord record) {
    state = {...state, peerHex: record};
    unawaited(save(state));
  }

  void remove(String peerHex) {
    if (!state.containsKey(peerHex)) return;
    state = {...state}..remove(peerHex);
    unawaited(save(state));
  }

  Future<void> clear() async {
    state = const {};
    await save(state);
  }

  @protected
  Future<void> save(Map<String, SpamRecord> records) async {
    if (_box == null) await loaded;
    await _box?.put(storageKey, {
      for (final e in records.entries) e.key: e.value.toJson(),
    });
  }
}

final airdropSpamProvider =
    NotifierProvider<AirDropSpamStore, Map<String, SpamRecord>>(
  AirDropSpamStore.new,
);
```

- [ ] **Step 7: Run to verify it passes**

Run: `flutter test --no-pub test/airdrop_storage_test.dart`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add lib/features/airdrop/data test/airdrop_storage_test.dart
git commit -m "AirDrop keeps its files, its history, its bans and its ten-minute window on the phone"
```

---

### Task 6: Свободное место

**Files:**
- Create: `lib/core/util/free_space.dart`
- Modify: `android/app/src/main/kotlin/com/cubechat/cubechat/MainApplication.kt` (`registerCustomChannels`)
- Modify: `ios/Runner/AppDelegate.swift` (after the `cubechat/secure_window` channel)
- Test: `test/free_space_test.dart`

**Interfaces:**
- Produces: `FreeSpace.bytes() → Future<int?>`; `freeSpaceProvider` (`Provider<Future<int?> Function()>`). Null means "the platform would not say" — the caller then does not refuse for space.

- [ ] **Step 1: Write the failing test**

`test/free_space_test.dart`:

```dart
import 'package:cubechat/core/util/free_space.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('cubechat/storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('reads the number the platform gives', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'freeBytes');
      return 123456;
    });
    expect(await FreeSpace.bytes(), 123456);
  });

  // Web, desktop and a build whose native half is missing all land here.
  // Unknown must never read as "no space", or every offer would be refused.
  test('says nothing when nobody answers', () async {
    expect(await FreeSpace.bytes(), isNull);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test --no-pub test/free_space_test.dart`
Expected: FAIL — missing file.

- [ ] **Step 3: Implement the Dart side**

`lib/core/util/free_space.dart`:

```dart
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Free bytes on the volume the app keeps its files on.
///
/// AirDrop asks before it shows a request: a transfer that would fill the
/// phone is declined up front with "not enough space" rather than failing
/// half way. Null when the platform does not say — and unknown is not "full".
abstract final class FreeSpace {
  static const MethodChannel _channel = MethodChannel('cubechat/storage');

  static Future<int?> bytes() async {
    try {
      return await _channel.invokeMethod<int>('freeBytes');
    } catch (_) {
      return null;
    }
  }
}

final freeSpaceProvider =
    Provider<Future<int?> Function()>((ref) => FreeSpace.bytes);
```

- [ ] **Step 4: Android**

In `MainApplication.kt` add `import android.os.StatFs` to the imports, and inside `registerCustomChannels(engine: FlutterEngine)`, after `SelfUpdater.register(applicationContext, messenger)`:

```kotlin
        // Free space where the app keeps files — AirDrop declines an offer that
        // would not fit rather than failing half way through it.
        MethodChannel(messenger, "cubechat/storage").setMethodCallHandler { call, result ->
            when (call.method) {
                "freeBytes" -> result.success(StatFs(filesDir.absolutePath).availableBytes)
                else -> result.notImplemented()
            }
        }
```

(`messenger` is the local already used by the neighbouring channels in that function.)

- [ ] **Step 5: iOS**

In `AppDelegate.swift`, inside `didInitializeImplicitFlutterEngine`, directly after the `cubechat/secure_window` channel block:

```swift
      // Free space where the app keeps files — AirDrop declines an offer that
      // would not fit. "Important usage" is the figure iOS will actually make
      // room for, not the raw free count.
      FlutterMethodChannel(
        name: "cubechat/storage",
        binaryMessenger: messenger
      ).setMethodCallHandler { call, result in
        guard call.method == "freeBytes" else {
          result(FlutterMethodNotImplemented)
          return
        }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? home.resourceValues(
          forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        if let bytes = values?.volumeAvailableCapacityForImportantUsage {
          result(Int(bytes))
        } else {
          result(nil)
        }
      }
```

- [ ] **Step 6: Run to verify it passes**

Run: `flutter test --no-pub test/free_space_test.dart`
Expected: PASS. The Kotlin compiles in Task 13's APK build; the Swift in the iOS CI job.

- [ ] **Step 7: Commit**

```bash
git add lib/core/util/free_space.dart test/free_space_test.dart android/app/src/main/kotlin/com/cubechat/cubechat/MainApplication.kt ios/Runner/AppDelegate.swift
git commit -m "The app can ask how much room is left before it agrees to take files"
```

---

### Task 7: Транспорт — только прямая связь, отправка файла AirDrop, приём по вердикту

Всё в `MessagingService` — только добавления и необязательные параметры с прежним поведением по умолчанию.

**Files:**
- Modify: `lib/core/transport/messaging_service.dart`
- Test: `test/airdrop_transport_test.dart`

**Interfaces:**
- Consumes: `NearbyOffer`, `NearbyAnswer`, `NearbyFileSink`, `NearbyFileVerdict`, `InnerPayloadType.nearbyOffer/nearbyAnswer` (Task 1); `FileTransferSource`, `FileTransferTask.source/peerName` (Task 2); `airdropReceiveProvider` (Task 5).
- Produces: `bool hasDirectLinkTo(String peerHex)`; `Iterable<String> directPeerHexes()`; `Future<bool> sendNearbyFrame(String peerHex, {NearbyOffer? offer, NearbyAnswer? answer})`; `NearbyFileSink? nearbyFileSink`; `sendFile(..., bool directOnly = false, FileTransferSource source = FileTransferSource.chat, String? peerName)`; `debugIngestManifest(..., bool direct = false)`.

- [ ] **Step 1: Write the failing test**

`test/airdrop_transport_test.dart`:

```dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cubechat/core/transport/inner_payload.dart';
import 'package:cubechat/core/transport/messaging_service.dart';
import 'package:cubechat/core/transport/nearby_offer.dart';
import 'package:cubechat/features/chat/data/messages_controller.dart';
import 'package:cubechat/features/files/data/file_transfer_controller.dart';
import 'package:cubechat/features/profile/data/relay_settings_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

class _Offline extends RelaySettingsController {
  @override
  RelaySettings build() =>
      const RelaySettings(enabled: false, urls: RelaySettings.defaultUrls);

  @override
  Future<void> get loaded => Future<void>.value();
}

class _Sink implements NearbyFileSink {
  _Sink(this.verdict);

  final NearbyFileVerdict verdict;
  final asked = <({String mediaIdHex, String senderHex, bool direct})>[];

  @override
  NearbyFileVerdict judge({
    required String mediaIdHex,
    required String senderHex,
    required bool direct,
  }) {
    asked.add((mediaIdHex: mediaIdHex, senderHex: senderHex, direct: direct));
    return verdict;
  }

  @override
  Future<String?> keep({
    required String mediaIdHex,
    required String senderHex,
    required File file,
    required String name,
  }) async =>
      null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  final sender = Uint8List.fromList(List<int>.filled(32, 0xab));
  final senderHex = 'ab' * 32;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_airdrop_tx_');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await settleBackgroundStorage();
    try {
      await Hive.close();
    } on FileSystemException {
      // The service closes its own boxes on dispose, unawaited.
    }
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows holds a just-closed box briefly.
    }
  });

  Future<(ProviderContainer, MessagingService)> start() async {
    final container = ProviderContainer(
      overrides: [
        relaySettingsProvider.overrideWith(_Offline.new),
        messagingServiceProvider.overrideWith((ref) {
          final service = MessagingService(ref);
          ref.onDispose(() => unawaited(service.dispose()));
          return service;
        }),
      ],
    );
    addTearDown(container.dispose);
    await container.read(messagesControllerProvider.notifier).loaded;
    return (container, container.read(messagingServiceProvider));
  }

  (Uint8List, String) fileManifest(int seed) {
    final id = Uint8List.fromList(List<int>.generate(16, (i) => seed + i));
    final manifest = MediaManifest(
      mediaId: id,
      kind: MediaKind.file,
      total: 3,
      mime: 'video/mp4',
      name: 'clip.mp4',
      sha256: Uint8List(32),
    );
    return (manifest.encode(), nearbyHex(id));
  }

  test('with nobody linked there is no direct peer to send to', () async {
    final (_, service) = await start();
    expect(service.hasDirectLinkTo(senderHex), isFalse);
    expect(service.directPeerHexes(), isEmpty);
    expect(
      await service.sendNearbyFrame(
        senderHex,
        answer: NearbyAnswer(
          transferId: Uint8List(nearbyIdLen),
          kind: NearbyAnswerKind.seen,
        ),
      ),
      isFalse,
    );
  });

  test('a file AirDrop refuses is dropped before anything is kept', () async {
    final (container, service) = await start();
    final sink = _Sink(NearbyFileVerdict.refuse);
    service.nearbyFileSink = sink;
    final (bytes, key) = fileManifest(1);
    await service.debugIngestManifest(
      bytes,
      senderPub: sender,
      sentAt: DateTime.now(),
      direct: true,
    );
    expect(sink.asked.single.mediaIdHex, key);
    expect(sink.asked.single.senderHex, senderHex);
    expect(sink.asked.single.direct, isTrue);
    expect(service.debugHasManifest(key), isFalse);
    expect(container.read(fileTransferControllerProvider)[key], isNull);
  });

  test('a file AirDrop keeps is tracked as an AirDrop transfer', () async {
    final (container, service) = await start();
    service.nearbyFileSink = _Sink(NearbyFileVerdict.keep);
    final (bytes, key) = fileManifest(2);
    await service.debugIngestManifest(
      bytes,
      senderPub: sender,
      sentAt: DateTime.now(),
      direct: true,
    );
    expect(service.debugHasManifest(key), isTrue);
    final task = container.read(fileTransferControllerProvider)[key];
    expect(task?.source, FileTransferSource.airdrop);
    expect(task?.direction, FileTransferDirection.incoming);
  });

  test('anything else is an ordinary chat file, as before', () async {
    final (container, service) = await start();
    service.nearbyFileSink = _Sink(NearbyFileVerdict.notNearby);
    final (bytes, key) = fileManifest(3);
    await service.debugIngestManifest(
      bytes,
      senderPub: sender,
      sentAt: DateTime.now(),
    );
    expect(
      container.read(fileTransferControllerProvider)[key]?.source,
      FileTransferSource.chat,
    );
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test --no-pub test/airdrop_transport_test.dart`
Expected: FAIL — `The method 'hasDirectLinkTo' isn't defined`.

- [ ] **Step 3: One builder for a sealed control frame**

In `_deliverControlToPeer`, replace everything from `final identity = await _ref.read(identityProvider.future);` down to and including

```dart
    final frameBytes =
        Frame(type: FrameType.transport, payload: env.encode()).encode();
```

with:

```dart
    final frameBytes = await _sealedControlFrame(
      peerPub: peerPub,
      type: type,
      innerBody: innerBody,
    );
```

and add, directly above `_deliverControlToPeer`:

```dart
  /// One signed, sealed control frame for [peerPub] — the bytes
  /// [_deliverControlToPeer] sends, built in one place so AirDrop's
  /// direct-only path ([sendNearbyFrame]) sends exactly what a receipt would.
  Future<Uint8List> _sealedControlFrame({
    required Uint8List peerPub,
    required InnerPayloadType type,
    required Uint8List innerBody,
  }) async {
    final identity = await _ref.read(identityProvider.future);
    final myHash = await _myPubkeyHash();
    final peerHash = await _peerPubkeyHash(peerPub);
    final msgId = TransportEnvelope.newMsgId(initialTtl: _meshTtl);
    final ctx = SignedPayload.contextBytes(
      originPubkeyHash: myHash,
      destPubkeyHash: peerHash,
      msgId: msgId,
    );
    final inner = packInnerPayload(type, innerBody);
    final signed = await SignedPayload.wrap(
      inner: inner,
      context: ctx,
      signKeyPair: identity.asSignKeyPair(),
      senderEdPub: identity.signPublicKey,
    );
    final body =
        _tagBody(_cipherSealedBox, await SealedBox.seal(signed, peerPub));
    final env = TransportEnvelope(
      originPubkeyHash: myHash,
      destPubkeyHash: peerHash,
      msgId: msgId,
      ttl: _meshTtl,
      body: body,
    );
    _dedup.acceptEnvelope(env);
    return Frame(type: FrameType.transport, payload: env.encode()).encode();
  }
```

- [ ] **Step 4: Direct links, and sending on nothing else**

Directly after `hasSessionWithPubkey` (~line 12096), add:

```dart
  /// Whether [session] rides a Bluetooth link to that very phone — ours as
  /// central, or theirs connected to our peripheral — rather than a mesh route
  /// or the relay.
  bool _isDirectSession(ChatSession session) {
    final client = _clients[session.peerId];
    if (client != null && client.isConnected) return true;
    return _ref
        .read(peripheralControllerProvider)
        .connectedCentralIds
        .contains(session.peerId);
  }

  ChatSession? _directSessionTo(String peerHex) {
    for (final session in _ref.read(chatSessionManagerProvider).values) {
      if (session.remotePubkeyHex == peerHex &&
          session.isEstablished &&
          _isDirectSession(session)) {
        return session;
      }
    }
    return null;
  }

  /// AirDrop's question: is this person in Bluetooth reach, with a session up?
  bool hasDirectLinkTo(String peerHex) => _directSessionTo(peerHex) != null;

  /// Everybody [hasDirectLinkTo] says yes to, each once.
  Iterable<String> directPeerHexes() {
    final out = <String>{};
    for (final session in _ref.read(chatSessionManagerProvider).values) {
      final hex = session.remotePubkeyHex;
      if (hex == null || !session.isEstablished) continue;
      if (_isDirectSession(session)) out.add(hex);
    }
    return out;
  }

  /// Write [frameBytes] to [peerHex] over the direct link and nothing else:
  /// no mesh fan-out, no relay. False when there is no such link or it
  /// refused the write.
  ///
  /// A frame notified from our peripheral reaches every central subscribed to
  /// it, and those may pass it on — but it arrives at the person it is for in
  /// one hop first, and the receiver's duplicate check drops the copies.
  Future<bool> _writeDirectOnly(String peerHex, Uint8List frameBytes) async {
    final session = _directSessionTo(peerHex);
    if (session == null) return false;
    final client = _clients[session.peerId];
    try {
      if (client != null && client.isConnected) {
        return await _writeFrameToClient(client, frameBytes);
      }
      return await _notifyFrameToPeripheral(frameBytes);
    } catch (e) {
      DebugLog.instance.log('AIRDROP', 'direct write failed: $e');
      return false;
    }
  }

  /// One AirDrop frame to [peerHex], over the direct link only. Exactly one of
  /// [offer] and [answer].
  Future<bool> sendNearbyFrame(
    String peerHex, {
    NearbyOffer? offer,
    NearbyAnswer? answer,
  }) async {
    assert((offer == null) != (answer == null), 'one of offer and answer');
    if (_disposed || !hasDirectLinkTo(peerHex)) return false;
    final peerPub = _resolvePeerPub(peerHex);
    if (peerPub == null) return false;
    final frame = await _sealedControlFrame(
      peerPub: peerPub,
      type: offer != null
          ? InnerPayloadType.nearbyOffer
          : InnerPayloadType.nearbyAnswer,
      innerBody: offer?.encode() ?? answer!.encode(),
    );
    return _writeDirectOnly(peerHex, frame);
  }
```

- [ ] **Step 5: Media frames learn "direct only"**

`_deliverMediaFrame`: add the parameter `bool directOnly = false,` after `bool wakesPeer = false,` and make the first statement of its body:

```dart
    // AirDrop: the person in reach, or nobody. See [_writeDirectOnly].
    if (directOnly) return _writeDirectOnly(canonicalId, frameBytes);
```

`_deliverMediaFrameRetrying`: add `bool directOnly = false,` after `bool wakesPeer = false,` and pass `directOnly: directOnly,` in its call to `_deliverMediaFrame`.

`_sendSignedManifest`: add `bool directOnly = false,` after `required bool relayOnly,` and pass `directOnly: directOnly,` in its call to `_deliverMediaFrameRetrying` (next to `relayOnly: relayOnly,`).

- [ ] **Step 6: `sendFile` for AirDrop**

Signature — after `bool appendLocally = true,` add:

```dart
    /// AirDrop: the direct Bluetooth link to [chatId] or an error — never the
    /// mesh, never the relay, never the queue.
    bool directOnly = false,
    FileTransferSource source = FileTransferSource.chat,

    /// Shown beside an AirDrop transfer, which has no chat to be read in.
    String? peerName,
```

Replace:

```dart
    final relayOnly =
        (!_hasAnyLink || !meshCarries) && _relayClient?.isConnected == true;
```

with:

```dart
    if (directOnly && !hasDirectLinkTo(canonicalId)) {
      throw const MediaRouteUnavailable();
    }
    final relayOnly = !directOnly &&
        (!_hasAnyLink || !meshCarries) &&
        _relayClient?.isConnected == true;
```

In the `transfers.register(FileTransferTask(...))` call add after `updatedAt: msg.sentAt,`:

```dart
        source: source,
        peerName: peerName,
```

Replace `if (!_hasMediaRoute(canonicalId)) {` (the queue branch right after `register`) with `if (!directOnly && !_hasMediaRoute(canonicalId)) {`.

Replace:

```dart
    final sending = PeerActivity.sendingFor(mime);
    _beginSendingMedia(canonicalId, sending);
```

with:

```dart
    final sending = PeerActivity.sendingFor(mime);
    // "Sending a video…" belongs to a conversation. An AirDrop has none, and
    // the indicator would light up in a chat the file is not going to.
    final announces = source == FileTransferSource.chat;
    if (announces) _beginSendingMedia(canonicalId, sending);
```

and in the `finally` of that `try`, replace `_endSendingMedia(canonicalId, sending);` with `if (announces) _endSendingMedia(canonicalId, sending);`.

In the `_sendSignedManifest(` call inside `sendFile` add `directOnly: directOnly,` after `relayOnly: relayOnly,`; in the chunk loop's `_deliverMediaFrameRetrying(` call add `directOnly: directOnly,` after `relayOnly: relayOnly,`.

- [ ] **Step 7: Never retry an AirDrop as a chat file**

In `retryFileTransfer`, after `if (task == null) return;`:

```dart
    // An AirDrop needs the person in reach and their yes; its retry lives on
    // the AirDrop page. Resent from here it would land in a chat.
    if (task.source == FileTransferSource.airdrop) return;
```

In `_drainFileQueue`'s `.where(` add the condition `task.source == FileTransferSource.chat &&` as the first line of the predicate.

- [ ] **Step 8: Incoming files ask AirDrop first**

Add the field next to `nearbyInbound`:

```dart
  /// Set by the AirDrop controller for as long as it lives. Asked about every
  /// incoming file manifest, and handed every AirDrop file once it is whole.
  NearbyFileSink? nearbyFileSink;
```

`_ingestMediaManifest`: add the parameter `bool direct = false,` after `required DateTime sentAt,`. Directly after `final key = _hexOf(manifest.mediaId);` insert:

```dart
    // AirDrop's ids are AirDrop's to judge: one of its accepted offers, over
    // a direct link, from the person who made the offer — or refused.
    final senderHex = senderPub == null ? null : _hexOf(senderPub);
    final nearby = manifest.kind == MediaKind.file && senderHex != null
        ? nearbyFileSink?.judge(
              mediaIdHex: key,
              senderHex: senderHex,
              direct: direct,
            ) ??
            NearbyFileVerdict.notNearby
        : NearbyFileVerdict.notNearby;
    if (nearby == NearbyFileVerdict.refuse) {
      DebugLog.instance.log(
        'AIRDROP',
        'drop manifest $key from $peerId — no accepted offer over a direct '
            'link from this sender',
      );
      return;
    }
```

In the `register(FileTransferTask(...))` inside that function add after `updatedAt: now,`:

```dart
              source: nearby == NearbyFileVerdict.keep
                  ? FileTransferSource.airdrop
                  : FileTransferSource.chat,
              peerName: senderHex == null
                  ? null
                  : _ref
                      .read(knownPeersControllerProvider)[senderHex]
                      ?.displayName,
```

At the 1:1 dispatch (`case InnerPayloadType.mediaManifest:` ~line 7481) add `direct: incomingRoute == MessageRoute.bluetooth,` after `sentAt: stamp,`.

`debugIngestManifest`: add `bool direct = false,` after `required DateTime sentAt,` and pass `direct: direct,` through.

`_emitFile`: after the sha256 mismatch `if (...) { ...; return; }` block and before `final safe = safeFileName(...)`, insert:

```dart
      final idHex = _hexOf(manifest.mediaId);
      final transfers = _ref.read(fileTransferControllerProvider.notifier);
      if (_ref.read(fileTransferControllerProvider)[idHex]?.source ==
          FileTransferSource.airdrop) {
        // Not the chat's: AirDrop moves it into its own folder, or says the
        // transfer is over and it is not wanted any more.
        final senderHex = senderPub == null ? null : _hexOf(senderPub);
        final sink = nearbyFileSink;
        final kept = sink == null || senderHex == null
            ? null
            : await sink.keep(
                mediaIdHex: idHex,
                senderHex: senderHex,
                file: assembled.file,
                name: safeFileName(manifest.name ?? 'file'),
              );
        if (kept == null) {
          if (await assembled.file.exists()) await assembled.file.delete();
          transfers.setStatus(idHex, FileTransferStatus.canceled);
          DebugLog.instance
              .log('AIRDROP', 'file $idHex came after its transfer ended');
          return;
        }
        transfers.complete(idHex, filePath: kept, bytesTotal: assembled.bytes);
        DebugLog.instance
            .log('AIRDROP', 'file $idHex kept (${assembled.bytes}B)');
        return;
      }
```

Add the imports `import '../../features/airdrop/data/airdrop_receive_controller.dart';` among the feature imports (for Step 9).

- [ ] **Step 9: "Everyone for ten minutes" answers strangers**

Add to the class:

```dart
  /// Whether a stranger's XX handshake is answered and the announcement is
  /// public: the profile's "Discoverable nearby", or AirDrop's "Everyone"
  /// window — which exists to be found by people not yet in your contacts.
  bool get _discoverableNow =>
      _ref.read(discoverySettingsProvider).discoverable ||
      _ref.read(airdropReceiveProvider).everyoneAt(DateTime.now());
```

Replace both reads `_ref.read(discoverySettingsProvider).discoverable` (in `case FrameType.noiseHandshake1:` ~line 6806 and in the announcement ~line 11437) with `_discoverableNow`.

- [ ] **Step 10: Run the tests and the analyzer**

Run: `flutter test --no-pub test/airdrop_transport_test.dart test/held_media_test.dart test/forward_and_cancel_test.dart test/replay_window_test.dart`
Expected: PASS.
Run: `flutter analyze --no-pub lib/core/transport` — no `error`/`warning`.

- [ ] **Step 11: Commit**

```bash
git add lib/core/transport/messaging_service.dart test/airdrop_transport_test.dart
git commit -m "The transport can send to the phone in reach and nowhere else, and asks AirDrop about every file"
```

---

### Task 8: Строки, порт и контроллер AirDrop

**Files:**
- Modify: `lib/l10n/app_en.arb`, `lib/l10n/app_uk.arb`, then regenerate `lib/l10n/app_localizations*.dart`
- Create: `lib/features/airdrop/presentation/airdrop_text.dart`
- Create: `lib/features/airdrop/data/airdrop_source.dart`
- Create: `lib/features/airdrop/data/airdrop_port.dart`
- Create: `lib/features/airdrop/data/airdrop_controller.dart`
- Test: `test/airdrop_controller_test.dart`

**Interfaces:**
- Consumes: everything from Tasks 1-7.
- Produces: `AirDropSource{file, name, size, mime, static fromFile(File, {String? name})}`; `AirDropPort` (`inbound`, `hasDirectLinkTo`, `send`, `sendFile`, `cancelFile`, `set sink`), `airdropPortProvider`; `AirDropState{transfers, requests, active, byId}`; `airdropControllerProvider` with `offer({peerHex, peerName, files}) → Future<AirDropTransfer?>`, `accept(id)`, `decline(id)`, `cancel(id)`, `retry(id)`, `clearAll()`, and `NearbyFileSink` (`judge`, `keep`); `airdropContactsProvider` (`Set<String>`), `airdropPeerNameProvider` (`String Function(String)`), `airdropNotifyProvider` (`void Function(AirDropTransfer)`); `airdropWhat(AppLocalizations, List<AirDropFile>)`, `airdropRequestBody(AppLocalizations, AirDropTransfer)`; l10n keys listed in Step 1.

- [ ] **Step 1: Add the strings**

Append to `lib/l10n/app_en.arb`, before the final `}` (add a comma after the current last entry `"@heldMediaDownload": {…}`):

```json
  "airdropTab": "AirDrop",
  "nearbyTabFiles": "Files",
  "airdropReceiveHint": "Who can send you files",
  "airdropReceiveContacts": "Contacts",
  "airdropReceiveEveryone": "Everyone 10 min",
  "airdropEveryoneLeft": "Everyone · {time}",
  "@airdropEveryoneLeft": {
    "placeholders": {
      "time": {"type": "String"}
    }
  },
  "airdropSendFiles": "Send files",
  "airdropRequestBody": "wants to send {what} · {size}",
  "@airdropRequestBody": {
    "placeholders": {
      "what": {"type": "String"},
      "size": {"type": "String"}
    }
  },
  "airdropWhatPhotos": "{count, plural, =1{1 photo} other{{count} photos}}",
  "@airdropWhatPhotos": {
    "placeholders": {
      "count": {"type": "int"}
    }
  },
  "airdropWhatVideos": "{count, plural, =1{1 video} other{{count} videos}}",
  "@airdropWhatVideos": {
    "placeholders": {
      "count": {"type": "int"}
    }
  },
  "airdropWhatFiles": "{count, plural, =1{1 file} other{{count} files}}",
  "@airdropWhatFiles": {
    "placeholders": {
      "count": {"type": "int"}
    }
  },
  "airdropAccept": "Accept",
  "airdropDecline": "Decline",
  "airdropWaiting": "Waiting for an answer…",
  "airdropAccepted": "Accepted",
  "airdropUnheard": "Not received — maybe an old version of CubeChat",
  "airdropSending": "Sending",
  "airdropReceiving": "Receiving",
  "airdropInterrupted": "Interrupted",
  "airdropRetry": "Retry",
  "airdropOutcomeSent": "Sent",
  "airdropOutcomeReceived": "Received",
  "airdropOutcomeDeclined": "Declined",
  "airdropOutcomeCancelled": "Cancelled",
  "airdropOutcomePartial": "Partly",
  "airdropReasonNoSpace": "not enough space",
  "airdropReasonContactsOnly": "contacts only",
  "airdropReasonBusy": "busy",
  "airdropReasonTimeout": "no answer",
  "airdropFileDeleted": "deleted",
  "airdropHistory": "History",
  "airdropClearHistory": "Clear history",
  "airdropEmpty": "Files you send or receive nearby will be here",
  "airdropPickPerson": "Send to",
  "airdropNobody": "Nobody is connected nearby. Open Nearby and tap a person first.",
  "airdropNoDirect": "No Bluetooth connection with this person",
  "airdropSlowWarning": "This can take a long time over Bluetooth",
  "airdropTooLarge": "{name} is larger than {limit} MB",
  "@airdropTooLarge": {
    "placeholders": {
      "name": {"type": "String"},
      "limit": {"type": "int"}
    }
  },
  "airdropFromLabel": "AirDrop · {name}",
  "@airdropFromLabel": {
    "placeholders": {
      "name": {"type": "String"}
    }
  },
  "airdropWrite": "Message",
  "airdropAction": "AirDrop"
```

Append to `lib/l10n/app_uk.arb` the same keys (its own formatting: four-space indent, the `@` entries mirror the English placeholders):

```json
    "airdropTab":  "AirDrop",
    "nearbyTabFiles":  "Файли",
    "airdropReceiveHint":  "Хто може надсилати вам файли",
    "airdropReceiveContacts":  "Контакти",
    "airdropReceiveEveryone":  "Усі 10 хв",
    "airdropEveryoneLeft":  "Усі · {time}",
    "@airdropEveryoneLeft":  {
                                 "placeholders":  {
                                                      "time":  {"type":  "String"}
                                                  }
                             },
    "airdropSendFiles":  "Надіслати файли",
    "airdropRequestBody":  "хоче надіслати {what} · {size}",
    "@airdropRequestBody":  {
                                "placeholders":  {
                                                     "what":  {"type":  "String"},
                                                     "size":  {"type":  "String"}
                                                 }
                            },
    "airdropWhatPhotos":  "{count, plural, =1{1 фото} other{{count} фото}}",
    "@airdropWhatPhotos":  {
                               "placeholders":  {
                                                    "count":  {"type":  "int"}
                                                }
                           },
    "airdropWhatVideos":  "{count, plural, =1{1 відео} other{{count} відео}}",
    "@airdropWhatVideos":  {
                               "placeholders":  {
                                                    "count":  {"type":  "int"}
                                                }
                           },
    "airdropWhatFiles":  "{count, plural, =1{1 файл} few{{count} файли} many{{count} файлів} other{{count} файлу}}",
    "@airdropWhatFiles":  {
                              "placeholders":  {
                                                   "count":  {"type":  "int"}
                                               }
                          },
    "airdropAccept":  "Прийняти",
    "airdropDecline":  "Відхилити",
    "airdropWaiting":  "Очікуємо відповіді…",
    "airdropAccepted":  "Прийнято",
    "airdropUnheard":  "Не отримав — можливо, стара версія CubeChat",
    "airdropSending":  "Надсилаємо",
    "airdropReceiving":  "Отримуємо",
    "airdropInterrupted":  "Перервано",
    "airdropRetry":  "Повторити",
    "airdropOutcomeSent":  "Надіслано",
    "airdropOutcomeReceived":  "Отримано",
    "airdropOutcomeDeclined":  "Відхилено",
    "airdropOutcomeCancelled":  "Скасовано",
    "airdropOutcomePartial":  "Частково",
    "airdropReasonNoSpace":  "не вистачає місця",
    "airdropReasonContactsOnly":  "лише від контактів",
    "airdropReasonBusy":  "зайнято",
    "airdropReasonTimeout":  "немає відповіді",
    "airdropFileDeleted":  "видалено",
    "airdropHistory":  "Історія",
    "airdropClearHistory":  "Очистити історію",
    "airdropEmpty":  "Тут будуть файли, які ви надсилаєте й отримуєте поруч",
    "airdropPickPerson":  "Надіслати кому",
    "airdropNobody":  "Поруч ніхто не підключений. Спершу відкрийте «Поблизу» і торкніться людини.",
    "airdropNoDirect":  "Немає зв’язку Bluetooth з цією людиною",
    "airdropSlowWarning":  "Через Bluetooth це може тривати довго",
    "airdropTooLarge":  "{name} більший за {limit} МБ",
    "@airdropTooLarge":  {
                             "placeholders":  {
                                                  "name":  {"type":  "String"},
                                                  "limit":  {"type":  "int"}
                                              }
                         },
    "airdropFromLabel":  "AirDrop · {name}",
    "@airdropFromLabel":  {
                              "placeholders":  {
                                                   "name":  {"type":  "String"}
                                               }
                          },
    "airdropWrite":  "Написати",
    "airdropAction":  "AirDrop"
```

Both files are edited with Edit only (the shell re-encodes Cyrillic through CP1251). Run `flutter gen-l10n` and confirm it prints no untranslated-message warning.

- [ ] **Step 2: Text helpers**

`lib/features/airdrop/presentation/airdrop_text.dart`:

```dart
import '../../../l10n/app_localizations.dart';
import '../../chat/presentation/widgets/file_bubble.dart' show formatBytes;
import '../domain/airdrop_transfer.dart';

/// "3 photos", "2 videos", "5 files" from the files' types — the first two
/// only when every file is one, as the spec's "Жека хоче надіслати 3 фото ·
/// 12 МБ". Takes types rather than files so a history line can use it too.
String airdropWhat(AppLocalizations t, List<String> mimes) {
  final n = mimes.length;
  if (mimes.every((m) => m.startsWith('image/'))) return t.airdropWhatPhotos(n);
  if (mimes.every((m) => m.startsWith('video/'))) return t.airdropWhatVideos(n);
  return t.airdropWhatFiles(n);
}

String airdropRequestBody(AppLocalizations t, AirDropTransfer transfer) =>
    t.airdropRequestBody(
      airdropWhat(t, [for (final f in transfer.files) f.mime]),
      formatBytes(transfer.totalBytes),
    );
```

- [ ] **Step 3: The source and the port**

`lib/features/airdrop/data/airdrop_source.dart`:

```dart
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../../core/transport/inner_payload.dart' show safeFileName;
import '../../../core/utils/file_mime.dart';

/// A file on this phone, ready to be offered.
@immutable
class AirDropSource {
  const AirDropSource({
    required this.file,
    required this.name,
    required this.size,
    required this.mime,
  });

  final File file;
  final String name;
  final int size;
  final String mime;

  static Future<AirDropSource> fromFile(File file, {String? name}) async {
    final shown = safeFileName(name ?? file.uri.pathSegments.last);
    return AirDropSource(
      file: file,
      name: shown,
      size: await file.length(),
      mime: fileMimeType(shown),
    );
  }
}
```

`lib/features/airdrop/data/airdrop_port.dart`:

```dart
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/transport/messaging_service.dart';
import '../../../core/transport/nearby_offer.dart';
import '../../../core/util/debug_log.dart';
import '../../files/data/file_transfer_controller.dart';
import '../domain/airdrop_transfer.dart';

/// Everything AirDrop needs from the transport, and nothing more — so the
/// controller can be driven in a test with no Bluetooth and no Hive.
abstract interface class AirDropPort {
  Stream<NearbyInbound> get inbound;

  bool hasDirectLinkTo(String peerHex);

  Future<bool> send(String peerHex, {NearbyOffer? offer, NearbyAnswer? answer});

  /// One file of an accepted offer, under its offered id. True when every
  /// chunk went.
  Future<bool> sendFile(
    String peerHex, {
    required File file,
    required AirDropFile meta,
    required String peerName,
  });

  void cancelFile(String mediaIdHex);

  set sink(NearbyFileSink? value);
}

class MessagingAirDropPort implements AirDropPort {
  MessagingAirDropPort(this._ref);

  final Ref _ref;

  MessagingService get _messaging => _ref.read(messagingServiceProvider);

  @override
  Stream<NearbyInbound> get inbound => _messaging.nearbyInbound;

  @override
  bool hasDirectLinkTo(String peerHex) => _messaging.hasDirectLinkTo(peerHex);

  @override
  Future<bool> send(
    String peerHex, {
    NearbyOffer? offer,
    NearbyAnswer? answer,
  }) =>
      _messaging.sendNearbyFrame(peerHex, offer: offer, answer: answer);

  @override
  Future<bool> sendFile(
    String peerHex, {
    required File file,
    required AirDropFile meta,
    required String peerName,
  }) async {
    try {
      await _messaging.sendFile(
        peerHex,
        file: file,
        fileName: meta.name,
        mime: meta.mime,
        reuseMediaId: nearbyUnhex(meta.mediaIdHex),
        appendLocally: false,
        directOnly: true,
        source: FileTransferSource.airdrop,
        peerName: peerName,
      );
    } catch (e) {
      DebugLog.instance.log('AIRDROP', 'sending "${meta.name}" failed: $e');
      return false;
    }
    return _ref.read(fileTransferControllerProvider)[meta.mediaIdHex]?.status ==
        FileTransferStatus.completed;
  }

  @override
  void cancelFile(String mediaIdHex) =>
      _ref.read(fileTransferControllerProvider.notifier).cancel(mediaIdHex);

  @override
  set sink(NearbyFileSink? value) => _messaging.nearbyFileSink = value;
}

final airdropPortProvider = Provider<AirDropPort>(MessagingAirDropPort.new);
```

- [ ] **Step 4: Write the failing controller test**

`test/airdrop_controller_test.dart`:

```dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cubechat/core/transport/nearby_offer.dart';
import 'package:cubechat/core/util/free_space.dart';
import 'package:cubechat/features/airdrop/data/airdrop_clock.dart';
import 'package:cubechat/features/airdrop/data/airdrop_controller.dart';
import 'package:cubechat/features/airdrop/data/airdrop_history_controller.dart';
import 'package:cubechat/features/airdrop/data/airdrop_port.dart';
import 'package:cubechat/features/airdrop/data/airdrop_receive_controller.dart';
import 'package:cubechat/features/airdrop/data/airdrop_source.dart';
import 'package:cubechat/features/airdrop/data/airdrop_spam_store.dart';
import 'package:cubechat/features/airdrop/data/airdrop_storage.dart';
import 'package:cubechat/features/airdrop/domain/airdrop_spam_guard.dart';
import 'package:cubechat/features/airdrop/domain/airdrop_transfer.dart';
import 'package:cubechat/features/files/data/file_transfer_controller.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _bob = 'b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0';
const _eve = 'e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0';

Uint8List _id(int seed) => Uint8List.fromList(
      List.generate(nearbyIdLen, (i) => (seed * 37 + i * 3) & 0xFF),
    );

NearbyOffer _offer(int seed, {int files = 2, int size = 10}) => NearbyOffer(
      transferId: _id(seed),
      files: [
        for (var i = 0; i < files; i++)
          NearbyOfferFile(
            mediaId: _id(seed * 10 + i + 1),
            size: size,
            name: 'f$i.jpg',
            mime: 'image/jpeg',
          ),
      ],
    );

class _Port implements AirDropPort {
  // Created inside the fake zone by each test, sync so a delivery is handled
  // before the next line runs.
  final inboundCtl = StreamController<NearbyInbound>.broadcast(sync: true);
  final direct = <String>{};
  final sent = <({String to, NearbyOffer? offer, NearbyAnswer? answer})>[];
  final filesSent = <String>[];
  final cancelled = <String>[];
  final failing = <String>{};
  NearbyFileSink? currentSink;

  void deliver(
    String from, {
    NearbyOffer? offer,
    NearbyAnswer? answer,
    bool isDirect = true,
  }) =>
      inboundCtl.add(
        NearbyInbound(
          peerHex: from,
          direct: isDirect,
          offer: offer,
          answer: answer,
        ),
      );

  void answer(String from, Uint8List transferId, NearbyAnswerKind kind,
          [NearbyDeclineReason reason = NearbyDeclineReason.user]) =>
      deliver(
        from,
        answer: NearbyAnswer(
          transferId: transferId,
          kind: kind,
          reason: reason,
        ),
      );

  List<NearbyAnswer> answersTo(String hex) => [
        for (final s in sent)
          if (s.to == hex && s.answer != null) s.answer!,
      ];

  @override
  Stream<NearbyInbound> get inbound => inboundCtl.stream;

  @override
  bool hasDirectLinkTo(String peerHex) => direct.contains(peerHex);

  @override
  Future<bool> send(
    String peerHex, {
    NearbyOffer? offer,
    NearbyAnswer? answer,
  }) async {
    if (!direct.contains(peerHex)) return false;
    sent.add((to: peerHex, offer: offer, answer: answer));
    return true;
  }

  @override
  Future<bool> sendFile(
    String peerHex, {
    required File file,
    required AirDropFile meta,
    required String peerName,
  }) async {
    filesSent.add(meta.mediaIdHex);
    return !failing.contains(meta.mediaIdHex);
  }

  @override
  void cancelFile(String mediaIdHex) => cancelled.add(mediaIdHex);

  @override
  set sink(NearbyFileSink? value) => currentSink = value;
}

class _MemHistory extends AirDropHistoryController {
  @override
  List<AirDropHistoryEntry> build() => const [];

  @override
  Future<void> save(List<AirDropHistoryEntry> entries) async {}
}

class _MemSpam extends AirDropSpamStore {
  @override
  Map<String, SpamRecord> build() => const {};

  @override
  Future<void> save(Map<String, SpamRecord> records) async {}
}

class _Receive extends AirDropReceiveController {
  _Receive(this.everyone);

  final bool everyone;

  @override
  AirDropReceive build() =>
      AirDropReceive(everyoneUntil: everyone ? DateTime(2100) : null);
}

class _MemTransfers extends FileTransferController {
  @override
  Map<String, FileTransferTask> build() => const {};
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('cubechat_airdrop_ctl_');
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  /// [async] drives the clock in the fake-zone tests: `DateTime.now()` does
  /// not move under `fakeAsync`, and bans, stalls and acceptances are all
  /// measured against it.
  ProviderContainer make(
    _Port port, {
    FakeAsync? async,
    bool everyone = false,
    Set<String> contacts = const {_bob},
    int? free,
  }) =>
      ProviderContainer(
        overrides: [
          if (async != null)
            airdropClockProvider.overrideWithValue(
              () => DateTime(2026, 9, 22, 12).add(async.elapsed),
            ),
          airdropPortProvider.overrideWithValue(port),
          airdropHistoryProvider.overrideWith(_MemHistory.new),
          airdropSpamProvider.overrideWith(_MemSpam.new),
          airdropReceiveProvider.overrideWith(() => _Receive(everyone)),
          airdropContactsProvider.overrideWithValue(contacts),
          airdropPeerNameProvider.overrideWithValue((_) => 'Жека'),
          airdropNotifyProvider.overrideWithValue((_) {}),
          freeSpaceProvider.overrideWithValue(() async => free),
          airdropDirectoryProvider.overrideWithValue(() async => dir),
          fileTransferControllerProvider.overrideWith(_MemTransfers.new),
        ],
      );

  AirDropSource src(String name) => AirDropSource(
        file: File('${dir.path}${Platform.pathSeparator}$name'),
        name: name,
        size: 10,
        mime: 'image/jpeg',
      );

  group('sending', () {
    test('seen, accepted, every file goes, and the history says sent', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_bob);
        final c = make(port, async: async);
        final ctl = c.read(airdropControllerProvider.notifier);
        unawaited(
          ctl.offer(peerHex: _bob, peerName: 'Боб', files: [src('a.jpg'), src('b.jpg')]),
        );
        async.flushMicrotasks();
        final offer = port.sent.single.offer!;
        expect(offer.files.map((f) => f.name), ['a.jpg', 'b.jpg']);

        port.answer(_bob, offer.transferId, NearbyAnswerKind.seen);
        async.flushMicrotasks();
        expect(
          c.read(airdropControllerProvider).transfers.single.phase,
          AirDropPhase.waiting,
        );

        port.answer(_bob, offer.transferId, NearbyAnswerKind.accepted);
        async.flushMicrotasks();
        expect(port.filesSent, [
          for (final f in offer.files) nearbyHex(f.mediaId),
        ]);
        expect(c.read(airdropControllerProvider).transfers, isEmpty);
        expect(
          c.read(airdropHistoryProvider).single.outcome,
          AirDropOutcome.sent,
        );
        c.dispose();
      });
    });

    test('no seen in ten seconds says unheard; nothing at all fails it', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_bob);
        final c = make(port, async: async);
        unawaited(
          c.read(airdropControllerProvider.notifier).offer(
            peerHex: _bob,
            peerName: 'Боб',
            files: [src('a.jpg')],
          ),
        );
        async.elapse(const Duration(seconds: 10));
        expect(
          c.read(airdropControllerProvider).transfers.single.phase,
          AirDropPhase.unheard,
        );
        async.elapse(const Duration(seconds: 60));
        expect(c.read(airdropControllerProvider).transfers, isEmpty);
        expect(
          c.read(airdropHistoryProvider).single.outcome,
          AirDropOutcome.failed,
        );
        c.dispose();
      });
    });

    test('a decline comes back with its reason', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_bob);
        final c = make(port, async: async);
        unawaited(
          c.read(airdropControllerProvider.notifier).offer(
            peerHex: _bob,
            peerName: 'Боб',
            files: [src('a.jpg')],
          ),
        );
        async.flushMicrotasks();
        port.answer(
          _bob,
          port.sent.single.offer!.transferId,
          NearbyAnswerKind.declined,
          NearbyDeclineReason.noSpace,
        );
        async.flushMicrotasks();
        final entry = c.read(airdropHistoryProvider).single;
        expect(entry.outcome, AirDropOutcome.declined);
        expect(entry.reason, NearbyDeclineReason.noSpace);
        c.dispose();
      });
    });

    test('a broken link interrupts; a retry sends only what did not go', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_bob);
        final c = make(port, async: async);
        final ctl = c.read(airdropControllerProvider.notifier);
        unawaited(
          ctl.offer(peerHex: _bob, peerName: 'Боб', files: [src('a.jpg'), src('b.jpg')]),
        );
        async.flushMicrotasks();
        final offer = port.sent.single.offer!;
        final second = nearbyHex(offer.files[1].mediaId);
        port.failing.add(second);
        port.answer(_bob, offer.transferId, NearbyAnswerKind.accepted);
        async.flushMicrotasks();
        final t = c.read(airdropControllerProvider).transfers.single;
        expect(t.phase, AirDropPhase.interrupted);
        expect(t.doneCount, 1);

        port.failing.clear();
        unawaited(ctl.retry(t.id));
        async.flushMicrotasks();
        expect(port.filesSent.last, second);
        expect(port.filesSent, hasLength(3));
        expect(port.sent.where((s) => s.offer != null), hasLength(1));
        expect(
          c.read(airdropHistoryProvider).single.outcome,
          AirDropOutcome.sent,
        );
        c.dispose();
      });
    });

    test('without a direct link nothing is offered', () {
      fakeAsync((async) {
        final port = _Port();
        final c = make(port, async: async);
        AirDropTransfer? result;
        unawaited(
          c
              .read(airdropControllerProvider.notifier)
              .offer(peerHex: _bob, peerName: 'Боб', files: [src('a.jpg')])
              .then((v) => result = v),
        );
        async.flushMicrotasks();
        expect(result, isNull);
        expect(port.sent, isEmpty);
        c.dispose();
      });
    });
  });

  group('receiving', () {
    test('a contact: seen at once, the card, then accepted', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_bob);
        final c = make(port, async: async);
        c.read(airdropControllerProvider);
        port.deliver(_bob, offer: _offer(1));
        async.flushMicrotasks();
        expect(port.answersTo(_bob).single.kind, NearbyAnswerKind.seen);
        final request = c.read(airdropControllerProvider).requests.single;
        expect(request.peerName, 'Жека');

        unawaited(c.read(airdropControllerProvider.notifier).accept(request.id));
        async.flushMicrotasks();
        expect(port.answersTo(_bob).last.kind, NearbyAnswerKind.accepted);
        final sink = port.currentSink!;
        final fileHex = request.files.first.mediaIdHex;
        expect(
          sink.judge(mediaIdHex: fileHex, senderHex: _bob, direct: true),
          NearbyFileVerdict.keep,
        );
        expect(
          sink.judge(mediaIdHex: fileHex, senderHex: _eve, direct: true),
          NearbyFileVerdict.refuse,
        );
        expect(
          sink.judge(mediaIdHex: fileHex, senderHex: _bob, direct: false),
          NearbyFileVerdict.refuse,
        );
        expect(
          sink.judge(mediaIdHex: 'ff' * 16, senderHex: _bob, direct: true),
          NearbyFileVerdict.notNearby,
        );
        c.dispose();
      });
    });

    test('a file for a request nobody accepted yet is refused', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_bob);
        final c = make(port, async: async);
        c.read(airdropControllerProvider);
        port.deliver(_bob, offer: _offer(2));
        async.flushMicrotasks();
        final fileHex =
            c.read(airdropControllerProvider).requests.single.files.first.mediaIdHex;
        expect(
          port.currentSink!
              .judge(mediaIdHex: fileHex, senderHex: _bob, direct: true),
          NearbyFileVerdict.refuse,
        );
        c.dispose();
      });
    });

    test('an offer that did not come straight from the phone is ignored', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_bob);
        final c = make(port, async: async);
        c.read(airdropControllerProvider);
        port.deliver(_bob, offer: _offer(3), isDirect: false);
        async.flushMicrotasks();
        expect(port.sent, isEmpty);
        expect(c.read(airdropControllerProvider).transfers, isEmpty);
        c.dispose();
      });
    });

    test('a stranger in contacts-only mode is told so', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_eve);
        final c = make(port, async: async);
        c.read(airdropControllerProvider);
        port.deliver(_eve, offer: _offer(4));
        async.flushMicrotasks();
        final answers = port.answersTo(_eve);
        expect(answers.first.kind, NearbyAnswerKind.seen);
        expect(answers.last.kind, NearbyAnswerKind.declined);
        expect(answers.last.reason, NearbyDeclineReason.contactsOnly);
        expect(c.read(airdropControllerProvider).requests, isEmpty);
        c.dispose();
      });
    });

    test('a stranger while "everyone" is on gets the card', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_eve);
        final c = make(port, async: async, everyone: true);
        c.read(airdropControllerProvider);
        port.deliver(_eve, offer: _offer(5));
        async.flushMicrotasks();
        expect(c.read(airdropControllerProvider).requests, hasLength(1));
        c.dispose();
      });
    });

    test('a second offer while the first waits is busy', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_bob);
        final c = make(port, async: async);
        c.read(airdropControllerProvider);
        port
          ..deliver(_bob, offer: _offer(6))
          ..deliver(_bob, offer: _offer(7));
        async.flushMicrotasks();
        expect(c.read(airdropControllerProvider).requests, hasLength(1));
        expect(port.answersTo(_bob).last.reason, NearbyDeclineReason.busy);
        c.dispose();
      });
    });

    test('an offer bigger than the free space is declined for it', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_bob);
        final c = make(port, async: async, free: 15);
        c.read(airdropControllerProvider);
        port.deliver(_bob, offer: _offer(8));
        async.flushMicrotasks();
        expect(port.answersTo(_bob).last.reason, NearbyDeclineReason.noSpace);
        expect(c.read(airdropControllerProvider).requests, isEmpty);
        c.dispose();
      });
    });

    test('sixty seconds without an answer declines for the person', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_eve);
        final c = make(port, async: async, everyone: true);
        c.read(airdropControllerProvider);
        port.deliver(_eve, offer: _offer(9));
        async.elapse(const Duration(seconds: 60));
        expect(port.answersTo(_eve).last.reason, NearbyDeclineReason.timeout);
        expect(c.read(airdropControllerProvider).requests, isEmpty);
        // An offer left to expire says nothing about the sender.
        expect(
          c.read(airdropSpamProvider.notifier).recordFor(_eve)?.declines,
          0,
        );
        c.dispose();
      });
    });

    test('three declines of a stranger: silence for ten minutes', () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_eve);
        final c = make(port, async: async, everyone: true);
        final ctl = c.read(airdropControllerProvider.notifier);
        for (var i = 0; i < 3; i++) {
          port.deliver(_eve, offer: _offer(20 + i));
          async.flushMicrotasks();
          final id = c.read(airdropControllerProvider).requests.single.id;
          unawaited(ctl.decline(id));
          async.flushMicrotasks();
        }
        final before = port.sent.length;
        port.deliver(_eve, offer: _offer(30));
        async.flushMicrotasks();
        expect(port.sent.length, before, reason: 'not even a seen');
        expect(c.read(airdropControllerProvider).requests, isEmpty);

        async.elapse(const Duration(minutes: 10));
        port.deliver(_eve, offer: _offer(31));
        async.flushMicrotasks();
        expect(c.read(airdropControllerProvider).requests, hasLength(1));
        c.dispose();
      });
    });

    test('sixty seconds without a piece interrupts and drops the unfinished',
        () {
      fakeAsync((async) {
        final port = _Port()..direct.add(_bob);
        final c = make(port, async: async);
        c.read(airdropControllerProvider);
        port.deliver(_bob, offer: _offer(40));
        async.flushMicrotasks();
        final request = c.read(airdropControllerProvider).requests.single;
        unawaited(c.read(airdropControllerProvider.notifier).accept(request.id));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 65));
        final t = c.read(airdropControllerProvider).transfers.single;
        expect(t.phase, AirDropPhase.interrupted);
        expect(port.cancelled, [for (final f in request.files) f.mediaIdHex]);
        // Still accepted: a retry from the sender goes straight in.
        expect(
          port.currentSink!.judge(
            mediaIdHex: request.files.first.mediaIdHex,
            senderHex: _bob,
            direct: true,
          ),
          NearbyFileVerdict.keep,
        );
        async.elapse(const Duration(minutes: 10));
        expect(c.read(airdropControllerProvider).transfers, isEmpty);
        expect(
          c.read(airdropHistoryProvider).single.outcome,
          AirDropOutcome.failed,
        );
        c.dispose();
      });
    });
  });

  // Real time: keep() moves files on disk, and file I/O does not complete
  // inside a fake zone.
  group('keeping files', () {
    Future<(ProviderContainer, _Port, AirDropTransfer)> accepted() async {
      final port = _Port()..direct.add(_bob);
      final c = make(port);
      addTearDown(c.dispose);
      c.read(airdropControllerProvider);
      port.deliver(_bob, offer: _offer(50));
      await Future<void>.delayed(Duration.zero);
      final request = c.read(airdropControllerProvider).requests.single;
      await c.read(airdropControllerProvider.notifier).accept(request.id);
      return (c, port, request);
    }

    Future<File> arrived(String name) async {
      final f = File('${dir.path}${Platform.pathSeparator}tmp-$name');
      await f.writeAsString(name);
      return f;
    }

    test('both files land in the AirDrop folder and the history says received',
        () async {
      final (c, port, request) = await accepted();
      final sink = port.currentSink!;
      for (final f in request.files) {
        final path = await sink.keep(
          mediaIdHex: f.mediaIdHex,
          senderHex: _bob,
          file: await arrived(f.name),
          name: f.name,
        );
        expect(path, endsWith('${Platform.pathSeparator}${f.name}'));
        expect(File(path!).existsSync(), isTrue);
      }
      expect(c.read(airdropControllerProvider).transfers, isEmpty);
      final entry = c.read(airdropHistoryProvider).single;
      expect(entry.outcome, AirDropOutcome.received);
      expect(entry.files.every((f) => f.path != null), isTrue);
    });

    test('taken back half way: what came stays, the rest is not wanted',
        () async {
      final (c, port, request) = await accepted();
      final sink = port.currentSink!;
      await sink.keep(
        mediaIdHex: request.files.first.mediaIdHex,
        senderHex: _bob,
        file: await arrived('first'),
        name: 'first',
      );
      port.answer(_bob, nearbyUnhex(request.id), NearbyAnswerKind.cancelled);
      await Future<void>.delayed(Duration.zero);
      expect(c.read(airdropControllerProvider).transfers, isEmpty);
      expect(
        c.read(airdropHistoryProvider).single.outcome,
        AirDropOutcome.partial,
      );
      expect(
        await sink.keep(
          mediaIdHex: request.files.last.mediaIdHex,
          senderHex: _bob,
          file: await arrived('second'),
          name: 'second',
        ),
        isNull,
      );
      expect(
        sink.judge(
          mediaIdHex: request.files.last.mediaIdHex,
          senderHex: _bob,
          direct: true,
        ),
        NearbyFileVerdict.refuse,
      );
    });
  });
}
```

- [ ] **Step 5: Run to verify it fails**

Run: `flutter test --no-pub test/airdrop_controller_test.dart`
Expected: FAIL — `airdrop_controller.dart` missing.

- [ ] **Step 6: Implement the controller**

`lib/features/airdrop/data/airdrop_controller.dart`:

```dart
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/locale/locale_controller.dart';
import '../../../core/notifications/notification_service.dart';
import '../../../core/transport/nearby_offer.dart';
import '../../../core/util/app_lifecycle.dart';
import '../../../core/util/debug_log.dart';
import '../../../core/util/free_space.dart';
import '../../../l10n/app_localizations.dart';
import '../../contacts/presentation/contacts_screen.dart'
    show contactChatsProvider;
import '../../files/data/file_transfer_controller.dart';
import '../../peers/data/known_peers_controller.dart';
import '../domain/airdrop_rules.dart';
import '../domain/airdrop_spam_guard.dart';
import '../domain/airdrop_transfer.dart';
import '../presentation/airdrop_text.dart';
import 'airdrop_clock.dart';
import 'airdrop_history_controller.dart';
import 'airdrop_port.dart';
import 'airdrop_receive_controller.dart';
import 'airdrop_source.dart';
import 'airdrop_spam_store.dart';
import 'airdrop_storage.dart';

/// Who counts as a contact for "Contacts only": the people on the Contacts
/// tab, by the same rule that tab uses.
final airdropContactsProvider = Provider<Set<String>>(
  (ref) => {for (final c in ref.watch(contactChatsProvider)) c.peerId},
);

/// A person's name as this phone knows it.
final airdropPeerNameProvider = Provider<String Function(String)>((ref) {
  final peers = ref.watch(knownPeersControllerProvider);
  return (hex) {
    final name = peers[hex]?.displayName;
    return name == null || name.trim().isEmpty ? 'CubeChat' : name;
  };
});

/// A request while the app is not on screen: a system banner, or it would
/// expire unseen in its sixty seconds.
final airdropNotifyProvider =
    Provider<void Function(AirDropTransfer)>((ref) => (request) {
          if (AppLifecycle.instance.isForeground) return;
          final t = lookupAppLocalizations(ref.read(localeControllerProvider));
          unawaited(
            NotificationService.instance.showMessage(
              threadKey: 'airdrop',
              title: request.peerName,
              body: airdropRequestBody(t, request),
              senderId: request.peerHex,
            ),
          );
        });

@immutable
class AirDropState {
  const AirDropState({this.transfers = const []});

  /// Live transfers, newest first. A finished one moves to the history.
  final List<AirDropTransfer> transfers;

  List<AirDropTransfer> get requests =>
      [for (final t in transfers) if (t.isIncomingRequest) t];

  List<AirDropTransfer> get active =>
      [for (final t in transfers) if (!t.isIncomingRequest) t];

  AirDropTransfer? byId(String id) {
    for (final t in transfers) {
      if (t.id == id) return t;
    }
    return null;
  }
}

/// AirDrop's decisions: offers both ways, answers, the anti-spam rule, the
/// timers, and which incoming files are AirDrop's. The rules themselves are
/// the pure functions in `domain/`; this wires them to the transport.
class AirDropController extends Notifier<AirDropState>
    implements NearbyFileSink {
  final Map<String, List<Timer>> _timers = {};

  /// Outgoing: media id → the file on this phone it is read from.
  final Map<String, File> _sources = {};

  /// Media ids of incoming transfers that ended, refused until the time given
  /// — so a file sent after a decline or a cancel cannot slip into a chat.
  final Map<String, DateTime> _retired = {};

  /// Incoming progress, kept out of the state so a dozen chunks a second do
  /// not rebuild every widget watching AirDrop.
  final Map<String, int> _unitsSeen = {};
  final Map<String, DateTime> _lastProgress = {};

  /// Senders whose offer is being looked at right now — see [_onOffer].
  final Set<String> _evaluating = {};

  StreamSubscription<NearbyInbound>? _inbound;
  Timer? _ticker;
  final _random = Random.secure();

  AirDropPort get _port => ref.read(airdropPortProvider);
  DateTime get _now => ref.read(airdropClockProvider)();

  @override
  AirDropState build() {
    final port = ref.read(airdropPortProvider);
    _inbound = port.inbound.listen((m) => unawaited(_onInbound(m)));
    port.sink = this;
    ref.listen(fileTransferControllerProvider, (_, tasks) => _noteProgress(tasks));
    ref.onDispose(() {
      unawaited(_inbound?.cancel());
      port.sink = null;
      _cancelAllTimers();
    });
    return const AirDropState();
  }

  // ---------------------------------------------------------------- sending

  /// Offer [files] to [peerHex]. Null when there is no direct link, or the
  /// offer could not be written to it.
  Future<AirDropTransfer?> offer({
    required String peerHex,
    required String peerName,
    required List<AirDropSource> files,
  }) async {
    if (files.isEmpty || files.length > nearbyMaxFiles) {
      throw ArgumentError.value(files.length, 'files', '1..$nearbyMaxFiles');
    }
    if (!_port.hasDirectLinkTo(peerHex)) return null;
    final transferId = _newId();
    final metas = <AirDropFile>[];
    for (final f in files) {
      final hex = nearbyHex(_newId());
      _sources[hex] = f.file;
      metas.add(
        AirDropFile(
          mediaIdHex: hex,
          name: f.name,
          size: f.size,
          mime: f.mime,
          path: f.file.path,
        ),
      );
    }
    final transfer = AirDropTransfer(
      id: nearbyHex(transferId),
      peerHex: peerHex,
      peerName: peerName,
      direction: AirDropDirection.outgoing,
      files: metas,
      phase: AirDropPhase.offered,
      createdAt: _now,
    );
    _put(transfer);
    final sent = await _port.send(
      peerHex,
      offer: NearbyOffer(
        transferId: transferId,
        files: [
          for (final m in metas)
            NearbyOfferFile(
              mediaId: nearbyUnhex(m.mediaIdHex),
              size: m.size,
              name: m.name,
              mime: m.mime,
            ),
        ],
      ),
    );
    if (!sent) {
      _update(transfer.id, AirDropTransitions.interrupt);
      return null;
    }
    _after(
      transfer.id,
      AirDropRules.seenWithin,
      () => _update(transfer.id, AirDropTransitions.onSeenTimeout),
    );
    _after(
      transfer.id,
      AirDropRules.seenWithin + AirDropRules.answerWithin,
      () => _update(transfer.id, AirDropTransitions.onOfferExpired),
    );
    return transfer;
  }

  /// "Повторити". Inside the acceptance the rest simply goes; after it, the
  /// rest is offered again as a new request.
  Future<void> retry(String id) async {
    final t = state.byId(id);
    if (t == null ||
        t.direction != AirDropDirection.outgoing ||
        t.phase != AirDropPhase.interrupted) {
      return;
    }
    final resumed = AirDropTransitions.retry(t, _now);
    if (!identical(resumed, t)) {
      _put(resumed);
      unawaited(_pump(id));
      return;
    }
    final left = <AirDropSource>[
      for (final f in t.files)
        if (!f.done)
          if (_sources[f.mediaIdHex] case final file?)
            AirDropSource(file: file, name: f.name, size: f.size, mime: f.mime),
    ];
    _finish(AirDropTransitions.expire(t, _now));
    if (left.isNotEmpty) {
      await offer(peerHex: t.peerHex, peerName: t.peerName, files: left);
    }
  }

  /// Sends the files of an accepted offer one after another.
  Future<void> _pump(String id) async {
    while (true) {
      final t = state.byId(id);
      if (t == null || t.phase != AirDropPhase.transferring) return;
      AirDropFile? next;
      for (final f in t.files) {
        if (!f.done) {
          next = f;
          break;
        }
      }
      if (next == null) {
        _finish(t.copyWith(phase: AirDropPhase.done));
        return;
      }
      final current = next;
      final source = _sources[current.mediaIdHex];
      if (source == null) {
        _put(AirDropTransitions.interrupt(t));
        return;
      }
      final ok = await _port.sendFile(
        t.peerHex,
        file: source,
        meta: current,
        peerName: t.peerName,
      );
      final after = state.byId(id);
      if (after == null || after.phase != AirDropPhase.transferring) return;
      if (!ok) {
        _put(AirDropTransitions.interrupt(after));
        return;
      }
      _update(
        id,
        (x) => AirDropTransitions.onFileDone(
          x,
          current.mediaIdHex,
          source.path,
          _now,
        ),
      );
    }
  }

  // -------------------------------------------------------------- receiving

  Future<void> _onInbound(NearbyInbound m) async {
    if (!m.direct) {
      DebugLog.instance.log(
        'AIRDROP',
        'drop ${m.offer != null ? 'offer' : 'answer'} from '
            '${_short(m.peerHex)} — not over a direct link',
      );
      return;
    }
    final offer = m.offer;
    if (offer != null) return _onOffer(m.peerHex, offer);
    final answer = m.answer;
    if (answer != null) _onAnswer(m.peerHex, answer);
  }

  Future<void> _onOffer(String peerHex, NearbyOffer offer) async {
    final id = nearbyHex(offer.transferId);
    if (state.byId(id) != null) return;
    final contact = ref.read(airdropContactsProvider).contains(peerHex);
    final spam = ref.read(airdropSpamProvider.notifier);
    if (contact) {
      spam.remove(peerHex);
    } else {
      final record = AirDropSpamGuard.onRequest(spam.recordFor(peerHex), _now);
      spam.put(peerHex, record);
      if (AirDropSpamGuard.isBanned(record, _now)) {
        DebugLog.instance.log(
          'AIRDROP',
          'ignored an offer from ${_short(peerHex)} — declined too often',
        );
        return;
      }
    }
    // Decided before the first await: a second offer from the same phone that
    // arrives while this one is being looked at must see it and be "busy".
    NearbyDeclineReason? refusal;
    if (!contact && !ref.read(airdropReceiveProvider).everyoneAt(_now)) {
      refusal = NearbyDeclineReason.contactsOnly;
    } else if (_evaluating.contains(peerHex) ||
        state.transfers.any(
          (t) =>
              t.peerHex == peerHex &&
              t.direction == AirDropDirection.incoming &&
              !t.phase.isFinal,
        )) {
      refusal = NearbyDeclineReason.busy;
    }
    final reserved = refusal == null;
    if (reserved) _evaluating.add(peerHex);
    try {
      await _port.send(
        peerHex,
        answer: NearbyAnswer(
          transferId: offer.transferId,
          kind: NearbyAnswerKind.seen,
        ),
      );
      final request = AirDropTransfer(
        id: id,
        peerHex: peerHex,
        peerName: ref.read(airdropPeerNameProvider)(peerHex),
        direction: AirDropDirection.incoming,
        phase: AirDropPhase.waiting,
        createdAt: _now,
        files: [
          for (final f in offer.files)
            AirDropFile(
              mediaIdHex: nearbyHex(f.mediaId),
              name: f.name,
              size: f.size,
              mime: f.mime,
            ),
        ],
      );
      if (refusal == null) {
        final free = await ref.read(freeSpaceProvider)();
        if (free != null && free < request.totalBytes) {
          refusal = NearbyDeclineReason.noSpace;
        }
      }
      if (refusal != null) {
        _finish(AirDropTransitions.decline(request, refusal));
        await _port.send(
          peerHex,
          answer: NearbyAnswer(
            transferId: offer.transferId,
            kind: NearbyAnswerKind.declined,
            reason: refusal,
          ),
        );
        return;
      }
      _put(request);
      ref.read(airdropNotifyProvider)(request);
      _after(id, AirDropRules.answerWithin, () => unawaited(_expire(id)));
    } finally {
      if (reserved) _evaluating.remove(peerHex);
    }
  }

  void _onAnswer(String peerHex, NearbyAnswer a) {
    final t = state.byId(nearbyHex(a.transferId));
    if (t == null || t.peerHex != peerHex) return;
    if (t.direction == AirDropDirection.incoming) {
      // All a sender can say to a transfer coming our way is "take it back".
      if (a.kind == NearbyAnswerKind.cancelled) _stop(t, tell: false);
      return;
    }
    final next = AirDropTransitions.onAnswer(t, a, _now);
    if (identical(next, t)) return;
    if (next.phase.isFinal) {
      _cancelRunning(t);
      _finish(next);
      return;
    }
    _put(next);
    if (next.phase == AirDropPhase.transferring &&
        t.phase != AirDropPhase.transferring) {
      unawaited(_pump(next.id));
    }
  }

  Future<void> accept(String id) async {
    final t = state.byId(id);
    if (t == null || !t.isIncomingRequest) return;
    if (!ref.read(airdropContactsProvider).contains(t.peerHex)) {
      final spam = ref.read(airdropSpamProvider.notifier);
      final record = spam.recordFor(t.peerHex);
      if (record != null) spam.put(t.peerHex, AirDropSpamGuard.onAccept(record));
    }
    _cancelTimers(id);
    // In the state before the answer leaves: the manifests race right behind
    // it, and each one is judged against this.
    _put(AirDropTransitions.accept(t, _now));
    await _port.send(
      t.peerHex,
      answer: NearbyAnswer(
        transferId: nearbyUnhex(id),
        kind: NearbyAnswerKind.accepted,
      ),
    );
  }

  Future<void> decline(String id) async {
    final t = state.byId(id);
    if (t == null || !t.isIncomingRequest) return;
    if (!ref.read(airdropContactsProvider).contains(t.peerHex)) {
      final spam = ref.read(airdropSpamProvider.notifier);
      spam.put(
        t.peerHex,
        AirDropSpamGuard.onDecline(
          spam.recordFor(t.peerHex) ?? SpamRecord(lastRequestAt: _now),
          _now,
        ),
      );
    }
    _finish(AirDropTransitions.decline(t, NearbyDeclineReason.user));
    await _port.send(
      t.peerHex,
      answer: NearbyAnswer(
        transferId: nearbyUnhex(id),
        kind: NearbyAnswerKind.declined,
      ),
    );
  }

  Future<void> _expire(String id) async {
    final t = state.byId(id);
    if (t == null || !t.isIncomingRequest) return;
    _finish(AirDropTransitions.onAnswerTimeout(t));
    await _port.send(
      t.peerHex,
      answer: NearbyAnswer(
        transferId: nearbyUnhex(id),
        kind: NearbyAnswerKind.declined,
        reason: NearbyDeclineReason.timeout,
      ),
    );
  }

  /// The cross on any transfer, from either side. On a request it is a
  /// decline, and counts as one.
  Future<void> cancel(String id) async {
    final t = state.byId(id);
    if (t == null) return;
    if (t.isIncomingRequest) return decline(id);
    _stop(t, tell: true);
  }

  void _stop(AirDropTransfer t, {required bool tell}) {
    _cancelRunning(t);
    _finish(AirDropTransitions.stop(t));
    if (!tell) return;
    unawaited(
      _port.send(
        t.peerHex,
        answer: NearbyAnswer(
          transferId: nearbyUnhex(t.id),
          kind: NearbyAnswerKind.cancelled,
        ),
      ),
    );
  }

  // ------------------------------------------------------------ files in

  AirDropTransfer? _incomingHolding(String mediaIdHex) {
    for (final t in state.transfers) {
      if (t.direction == AirDropDirection.incoming &&
          t.files.any((f) => f.mediaIdHex == mediaIdHex)) {
        return t;
      }
    }
    return null;
  }

  bool _takesFiles(AirDropTransfer t) =>
      t.phase == AirDropPhase.transferring ||
      (t.phase == AirDropPhase.interrupted && t.acceptedStill(_now));

  @override
  NearbyFileVerdict judge({
    required String mediaIdHex,
    required String senderHex,
    required bool direct,
  }) {
    final owner = _incomingHolding(mediaIdHex);
    if (owner == null) {
      final until = _retired[mediaIdHex];
      return until != null && _now.isBefore(until)
          ? NearbyFileVerdict.refuse
          : NearbyFileVerdict.notNearby;
    }
    return _takesFiles(owner) && direct && owner.peerHex == senderHex
        ? NearbyFileVerdict.keep
        : NearbyFileVerdict.refuse;
  }

  @override
  Future<String?> keep({
    required String mediaIdHex,
    required String senderHex,
    required File file,
    required String name,
  }) async {
    final owner = _incomingHolding(mediaIdHex);
    if (owner == null || owner.peerHex != senderHex || !_takesFiles(owner)) {
      return null;
    }
    // The name from the offer — what the person agreed to receive.
    final offered = owner.files.firstWhere((f) => f.mediaIdHex == mediaIdHex);
    final dir = await ref.read(airdropDirectoryProvider)();
    final target = await uniqueFileIn(dir, offered.name);
    try {
      await file.rename(target.path);
    } on FileSystemException {
      await file.copy(target.path);
      await file.delete();
    }
    _lastProgress[owner.id] = _now;
    _update(
      owner.id,
      (t) => AirDropTransitions.onFileDone(t, mediaIdHex, target.path, _now),
    );
    return target.path;
  }

  void _noteProgress(Map<String, FileTransferTask> tasks) {
    for (final t in state.transfers) {
      if (t.direction != AirDropDirection.incoming ||
          t.phase != AirDropPhase.transferring) {
        continue;
      }
      for (final f in t.files) {
        final units = tasks[f.mediaIdHex]?.completedUnits;
        if (units == null || units == _unitsSeen[f.mediaIdHex]) continue;
        _unitsSeen[f.mediaIdHex] = units;
        _lastProgress[t.id] = _now;
      }
    }
  }

  void _tick() {
    final now = _now;
    for (final t in [...state.transfers]) {
      if (t.direction == AirDropDirection.incoming &&
          t.phase == AirDropPhase.transferring) {
        final seen = _lastProgress[t.id];
        final probe = seen == null ? t : t.copyWith(lastProgressAt: seen);
        final next = AirDropTransitions.onStall(probe, now);
        if (!identical(next, probe)) {
          // Whatever was half way through is dropped; the acceptance stays,
          // so the sender's retry is taken without asking again.
          _cancelRunning(t);
          _put(next);
          DebugLog.instance
              .log('AIRDROP', 'incoming ${_short(t.id)} interrupted');
        }
      } else if (t.phase == AirDropPhase.interrupted) {
        _update(t.id, (x) => AirDropTransitions.expire(x, now));
      }
    }
    if (!state.transfers.any(_needsTicker)) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  // ------------------------------------------------------------- plumbing

  /// Emergency wipe: forget everything in flight.
  void clearAll() {
    _cancelAllTimers();
    _sources.clear();
    _retired.clear();
    _unitsSeen.clear();
    _lastProgress.clear();
    _evaluating.clear();
    state = const AirDropState();
  }

  static bool _needsTicker(AirDropTransfer t) =>
      t.phase == AirDropPhase.transferring ||
      t.phase == AirDropPhase.interrupted;

  void _put(AirDropTransfer t) {
    final list = state.transfers;
    final at = list.indexWhere((x) => x.id == t.id);
    state = AirDropState(
      transfers: at < 0 ? [t, ...list] : ([...list]..[at] = t),
    );
    if (_needsTicker(t)) {
      _ticker ??= Timer.periodic(const Duration(seconds: 5), (_) => _tick());
    }
  }

  void _update(String id, AirDropTransfer Function(AirDropTransfer) step) {
    final t = state.byId(id);
    if (t == null) return;
    final next = step(t);
    if (identical(next, t)) return;
    if (next.phase.isFinal) {
      _finish(next);
    } else {
      _put(next);
    }
  }

  void _finish(AirDropTransfer t) {
    _cancelTimers(t.id);
    _lastProgress.remove(t.id);
    state = AirDropState(
      transfers: [for (final x in state.transfers) if (x.id != t.id) x],
    );
    if (t.direction == AirDropDirection.outgoing) {
      for (final f in t.files) {
        _sources.remove(f.mediaIdHex);
      }
    } else {
      final until = _now.add(AirDropRules.acceptedFor);
      for (final f in t.files) {
        _retired[f.mediaIdHex] = until;
        _unitsSeen.remove(f.mediaIdHex);
      }
    }
    ref.read(airdropHistoryProvider.notifier).add(AirDropHistoryEntry.of(t, _now));
    DebugLog.instance.log(
      'AIRDROP',
      '${t.direction.name} ${_short(t.id)} ended: ${t.phase.name}'
          '${t.reason == null ? '' : ' (${t.reason!.name})'}',
    );
  }

  /// Stop whatever file of [t] is still moving.
  void _cancelRunning(AirDropTransfer t) {
    for (final f in t.files) {
      if (!f.done) _port.cancelFile(f.mediaIdHex);
    }
  }

  void _after(String id, Duration wait, void Function() then) {
    (_timers[id] ??= <Timer>[]).add(Timer(wait, then));
  }

  void _cancelTimers(String id) {
    for (final timer in _timers.remove(id) ?? const <Timer>[]) {
      timer.cancel();
    }
  }

  void _cancelAllTimers() {
    for (final list in _timers.values) {
      for (final timer in list) {
        timer.cancel();
      }
    }
    _timers.clear();
    _ticker?.cancel();
    _ticker = null;
  }

  Uint8List _newId() => Uint8List.fromList(
        List<int>.generate(nearbyIdLen, (_) => _random.nextInt(256)),
      );

  static String _short(String hex) =>
      hex.length > 8 ? hex.substring(0, 8) : hex;
}

final airdropControllerProvider =
    NotifierProvider<AirDropController, AirDropState>(AirDropController.new);
```

Note on the stall test: `_cancelRunning` on a transfer with no file done cancels both ids, which is what the test expects.

- [ ] **Step 7: Run to verify it passes**

Run: `flutter test --no-pub test/airdrop_controller_test.dart`
Expected: PASS. If a fake-zone test hangs, check that `_Port`'s `StreamController` is `sync: true` and built inside `fakeAsync` (it is: each test constructs `_Port()` there).

- [ ] **Step 8: Keep it alive for the life of the app**

`lib/app.dart`, next to `ref.watch(mapPresenceControllerProvider);`:

```dart
    // Built at startup so an offer is answered whatever tab is open.
    // Listened, not watched: its state changes with every transfer, and the
    // whole app has no business rebuilding for that.
    ref.listen(airdropControllerProvider, (_, __) {});
```

with the import `import 'features/airdrop/data/airdrop_controller.dart';`.

- [ ] **Step 9: Analyze and commit**

Run: `flutter analyze --no-pub lib/features/airdrop lib/app.dart` — no `error`/`warning`.

```bash
git add lib/l10n lib/features/airdrop lib/app.dart test/airdrop_controller_test.dart
git commit -m "AirDrop answers offers, sends accepted files one by one and keeps what arrives in its own folder"
```

---

### Task 9: Островок-переключатель — общий, и страницы вкладки для свайпа

**Files:**
- Create: `lib/core/widgets/section_switch.dart`
- Modify: `lib/features/contacts/presentation/contacts_screen.dart` (delete `_SectionSwitch`, use `SectionSwitch`)
- Modify: `lib/core/routing/branch_pager.dart`, `lib/core/routing/app_router.dart:211-236`, `lib/features/chats/presentation/chats_list_screen.dart:667`
- Modify: `docs/superpowers/specs/2026-09-22-airdrop-design.md` (the swipe sentence)
- Test: `test/section_switch_test.dart`, `test/branch_pager_test.dart`

**Interfaces:**
- Produces: `SectionSwitch({labels, selected, onSelect})`; `branchPagersProvider` (`StateProvider<Map<int, BranchPager>>`), `registerBranchPager(StateController<Map<int, BranchPager>>, BranchPager)`, `kNearbyBranch = 2`. `branchPagerProvider` is removed.

- [ ] **Step 1: Write the failing tests**

`test/section_switch_test.dart`:

```dart
import 'package:cubechat/core/widgets/section_switch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a tap picks a part, and the picked one says it is selected',
      (tester) async {
    var picked = -1;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SectionSwitch(
              labels: const ['Nearby', 'AirDrop', 'Files'],
              selected: 1,
              onSelect: (i) => picked = i,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Files'));
    expect(picked, 2);
    final handle = tester.ensureSemantics();
    expect(
      tester.getSemantics(find.text('AirDrop')),
      containsSemantics(isSelected: true, isButton: true),
    );
    expect(
      tester.getSemantics(find.text('Files')),
      containsSemantics(isSelected: false),
    );
    handle.dispose();
  });
}
```

`test/branch_pager_test.dart`:

```dart
import 'package:cubechat/core/routing/branch_pager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // One slot used to hold the only pager, the chats list's. A second branch
  // with pages would have overwritten it, and the folders would have stopped
  // taking the swipe until the chats list happened to rebuild.
  test('each branch keeps its own pager', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final slot = c.read(branchPagersProvider.notifier);
    registerBranchPager(
      slot,
      BranchPager(branch: kChatsBranch, index: 0, count: 4, step: (_) {}),
    );
    registerBranchPager(
      slot,
      BranchPager(branch: kNearbyBranch, index: 1, count: 3, step: (_) {}),
    );
    registerBranchPager(
      slot,
      BranchPager(branch: kNearbyBranch, index: 2, count: 3, step: (_) {}),
    );
    final pagers = c.read(branchPagersProvider);
    expect(pagers[kChatsBranch]?.count, 4);
    expect(pagers[kNearbyBranch]?.index, 2);
    expect(pagers[kNearbyBranch]!.canStep(1), isFalse);
    expect(pagers[kNearbyBranch]!.canStep(-1), isTrue);
  });
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `flutter test --no-pub test/section_switch_test.dart test/branch_pager_test.dart`
Expected: FAIL — missing `section_switch.dart`, `branchPagersProvider`.

- [ ] **Step 3: Move the switch**

Create `lib/core/widgets/section_switch.dart` with the body of `_SectionSwitch` from `contacts_screen.dart` (lines 373-455), renamed and made public:

```dart
import 'package:flutter/material.dart';

import '../theme/colors.dart';
import 'floating_glass.dart';

/// Two or three halves of one screen, picked from a glass island — Contacts |
/// Calls, and Nearby | AirDrop | Files. The highlight slides to the picked
/// part; "reduce motion" makes it jump.
class SectionSwitch extends StatelessWidget {
  const SectionSwitch({
    super.key,
    required this.labels,
    required this.selected,
    required this.onSelect,
  });

  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 220);
    return FloatingGlass(
      blur: false,
      borderRadius: 14,
      padding: const EdgeInsets.all(4),
      child: LayoutBuilder(
        builder: (context, constraints) => Stack(
          children: [
            AnimatedPositionedDirectional(
              duration: duration,
              curve: Curves.easeOutCubic,
              start: constraints.maxWidth * selected / labels.length,
              width: constraints.maxWidth / labels.length,
              top: 0,
              bottom: 0,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: AppColors.brandPrimary.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: AppColors.brandPrimary.withValues(alpha: 0.55),
                  ),
                ),
              ),
            ),
            Row(
              children: [
                for (var i = 0; i < labels.length; i++)
                  Expanded(
                    child: Semantics(
                      selected: i == selected,
                      button: true,
                      child: InkWell(
                        onTap: () => onSelect(i),
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          constraints: const BoxConstraints(minHeight: 44),
                          padding: const EdgeInsets.symmetric(vertical: 9),
                          alignment: Alignment.center,
                          child: AnimatedDefaultTextStyle(
                            duration: duration,
                            curve: Curves.easeOutCubic,
                            style: TextStyle(
                              color: i == selected
                                  ? AppColors.textOnGlass
                                  : AppColors.textOnGlassDim,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                            child: Text(
                              labels[i],
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
```

In `contacts_screen.dart`: delete the `_SectionSwitch` class and its doc comment, replace `_SectionSwitch(` with `SectionSwitch(`, add `import '../../../core/widgets/section_switch.dart';`.

- [ ] **Step 4: One pager per branch**

In `lib/core/routing/branch_pager.dart` replace the `branchPagerProvider` declaration and its doc comment with:

```dart
/// The pagers branches have published, by branch.
///
/// A single slot until Nearby grew pages of its own (Nearby | AirDrop | Files):
/// with one slot the second registration overwrote the chats list's, and its
/// folders stopped taking the swipe until the list happened to rebuild. Every
/// branch stays mounted for the life of the shell, so a registration is never
/// taken down; the strip asks only the one for the tab that is showing.
final branchPagersProvider =
    StateProvider<Map<int, BranchPager>>((ref) => const {});

/// Publish [pager] for its branch, replacing that branch's previous one.
void registerBranchPager(
  StateController<Map<int, BranchPager>> slot,
  BranchPager pager,
) {
  slot.state = {...slot.state, pager.branch: pager};
}
```

and after `const int kChatsBranch = 0;`:

```dart
/// The Nearby branch, as declared in `app_router.dart` (chats, contacts,
/// peers, map, profile).
const int kNearbyBranch = 2;
```

In `app_router.dart` replace the body of `pager()`:

```dart
            BranchPager? pager() =>
                ref.read(branchPagersProvider)[navigationShell.currentIndex];
```

(and shorten the comment above it: the map is keyed by branch, so "only when the branch that published it is the one showing" is now the lookup itself.)

In `chats_list_screen.dart` replace

```dart
      ref.read(branchPagerProvider.notifier).state = BranchPager(
```

with

```dart
      registerBranchPager(ref.read(branchPagersProvider.notifier), BranchPager(
```

and close the call with `));` instead of `);`.

- [ ] **Step 5: Say how the swipe really works**

In the spec, replace

```
Переключение нажатием или горизонтальным
свайпом, индикатор островка едет за пальцем.
```

with

```
Переключение нажатием или горизонтальным
свайпом. Свайп принадлежит ленте вкладок (`BranchContainer`), поэтому
страницы листаются так же, как папки чатов (`BranchPager`): свайп сначала
листает «Поблизу → AirDrop → Файли», на краю — соседнюю вкладку, а индикатор
островка доезжает анимацией после свайпа, не тянется за пальцем. Вложенный
`PageView` отнял бы у пользователя свайп между вкладками.
```

- [ ] **Step 6: Run the tests**

Run: `flutter test --no-pub test/section_switch_test.dart test/branch_pager_test.dart`
Expected: PASS. Then `flutter analyze --no-pub lib/core lib/features/contacts lib/features/chats` — no `error`/`warning`.

- [ ] **Step 7: Commit**

```bash
git add lib/core/widgets/section_switch.dart lib/core/routing lib/features/contacts/presentation/contacts_screen.dart lib/features/chats/presentation/chats_list_screen.dart docs/superpowers/specs/2026-09-22-airdrop-design.md test/section_switch_test.dart test/branch_pager_test.dart
git commit -m "Any tab can have pages the swipe turns before it changes tab, and the island that picks them is shared"
```

---

### Task 10: Страница AirDrop, карточки, выбор человека и отправка

**Files:**
- Create: `lib/features/airdrop/presentation/airdrop_navigation.dart`
- Create: `lib/features/airdrop/presentation/airdrop_people_sheet.dart`
- Create: `lib/features/airdrop/presentation/airdrop_cards.dart`
- Create: `lib/features/airdrop/presentation/airdrop_send_flow.dart`
- Create: `lib/features/airdrop/presentation/airdrop_page.dart`
- Test: `test/airdrop_page_test.dart`

**Interfaces:**
- Consumes: Tasks 5, 8, 9.
- Produces: `kAirDropPage = 1`, `nearbyPageRequestProvider` (`StateProvider<int?>`), `airdropPageOnScreenProvider` (`StateProvider<bool>`); `AirDropPeer(hex, name)`, `airdropDirectPeersProvider`, `showAirDropPeopleSheet(context) → Future<AirDropPeer?>`, `AirDropPeopleList({onPick})`; `AirDropRequestCard`, `AirDropProgressCard`, `AirDropHistoryRow`, `airdropReasonLabel`, `airdropOutcomeLabel`, `airdropPhaseLabel`; `startAirDropSend(context, ref, {AirDropPeer? to, List<AirDropSource>? files})`, `pickAirDropFiles(context, ref)`; `AirDropPage`.

- [ ] **Step 1: Write the failing widget tests**

`test/airdrop_page_test.dart`:

```dart
import 'package:cubechat/core/transport/nearby_offer.dart';
import 'package:cubechat/features/airdrop/data/airdrop_controller.dart';
import 'package:cubechat/features/airdrop/data/airdrop_history_controller.dart';
import 'package:cubechat/features/airdrop/data/airdrop_receive_controller.dart';
import 'package:cubechat/features/airdrop/domain/airdrop_transfer.dart';
import 'package:cubechat/features/airdrop/presentation/airdrop_page.dart';
import 'package:cubechat/features/airdrop/presentation/airdrop_people_sheet.dart';
import 'package:cubechat/features/files/data/file_transfer_controller.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAirDrop extends AirDropController {
  _FakeAirDrop(this.initial);

  final AirDropState initial;
  final accepted = <String>[];
  final declined = <String>[];
  final cancelled = <String>[];

  @override
  AirDropState build() => initial;

  @override
  Future<void> accept(String id) async => accepted.add(id);

  @override
  Future<void> decline(String id) async => declined.add(id);

  @override
  Future<void> cancel(String id) async => cancelled.add(id);
}

class _MemHistory extends AirDropHistoryController {
  _MemHistory(this.entries);

  final List<AirDropHistoryEntry> entries;

  @override
  List<AirDropHistoryEntry> build() => entries;

  @override
  Future<void> save(List<AirDropHistoryEntry> entries) async {}
}

class _Receive extends AirDropReceiveController {
  var opened = 0;

  @override
  AirDropReceive build() => const AirDropReceive();

  @override
  Future<void> openToEveryone() async => opened++;
}

class _MemTransfers extends FileTransferController {
  @override
  Map<String, FileTransferTask> build() => const {};
}

AirDropTransfer _transfer({
  required AirDropDirection direction,
  required AirDropPhase phase,
}) =>
    AirDropTransfer(
      id: 'aa' * 16,
      peerHex: 'bb' * 32,
      peerName: 'Жека',
      direction: direction,
      phase: phase,
      createdAt: DateTime(2026, 9, 22),
      files: const [
        AirDropFile(mediaIdHex: 'f0', name: 'a.jpg', size: 10, mime: 'image/jpeg'),
        AirDropFile(mediaIdHex: 'f1', name: 'b.jpg', size: 10, mime: 'image/jpeg'),
      ],
    );

Widget _app(Widget home, List<Override> overrides) => ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('uk'),
        home: Scaffold(body: home),
      ),
    );

void main() {
  late _Receive receive;

  List<Override> overrides(
    _FakeAirDrop airdrop, [
    List<AirDropHistoryEntry> history = const [],
  ]) =>
      [
        airdropControllerProvider.overrideWith(() => airdrop),
        airdropHistoryProvider.overrideWith(() => _MemHistory(history)),
        airdropReceiveProvider.overrideWith(() => receive),
        fileTransferControllerProvider.overrideWith(_MemTransfers.new),
      ];

  setUp(() => receive = _Receive());

  testWidgets('a request says who, what and how much, and both buttons work',
      (tester) async {
    final request = _transfer(
      direction: AirDropDirection.incoming,
      phase: AirDropPhase.waiting,
    );
    final airdrop = _FakeAirDrop(AirDropState(transfers: [request]));
    await tester.pumpWidget(_app(const AirDropPage(), overrides(airdrop)));
    await tester.pumpAndSettle();

    expect(find.textContaining('хоче надіслати 2 фото · 20 B'), findsOneWidget);
    await tester.tap(find.text('Прийняти'));
    await tester.tap(find.text('Відхилити'));
    expect(airdrop.accepted, [request.id]);
    expect(airdrop.declined, [request.id]);
  });

  testWidgets('an offer nobody saw says it may be an old version',
      (tester) async {
    final sending = _transfer(
      direction: AirDropDirection.outgoing,
      phase: AirDropPhase.unheard,
    );
    final airdrop = _FakeAirDrop(AirDropState(transfers: [sending]));
    await tester.pumpWidget(_app(const AirDropPage(), overrides(airdrop)));
    await tester.pumpAndSettle();

    expect(
      find.text('Не отримав — можливо, стара версія CubeChat'),
      findsOneWidget,
    );
    await tester.tap(find.byIcon(Icons.close_rounded));
    expect(airdrop.cancelled, [sending.id]);
  });

  testWidgets('the history says what happened and why', (tester) async {
    final airdrop = _FakeAirDrop(const AirDropState());
    final entry = AirDropHistoryEntry(
      id: 'h1',
      peerHex: 'bb' * 32,
      peerName: 'Жека',
      direction: AirDropDirection.outgoing,
      at: DateTime(2026, 9, 22, 14, 5),
      outcome: AirDropOutcome.declined,
      reason: NearbyDeclineReason.busy,
      files: const [
        AirDropHistoryFile(name: 'a.jpg', size: 10, mime: 'image/jpeg'),
      ],
    );
    await tester.pumpWidget(
      _app(const AirDropPage(), overrides(airdrop, [entry])),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Відхилено · зайнято'), findsOneWidget);
  });

  testWidgets('nothing yet: the empty line, and "everyone" opens the window',
      (tester) async {
    final airdrop = _FakeAirDrop(const AirDropState());
    await tester.pumpWidget(_app(const AirDropPage(), overrides(airdrop)));
    await tester.pumpAndSettle();
    expect(
      find.text('Тут будуть файли, які ви надсилаєте й отримуєте поруч'),
      findsOneWidget,
    );
    await tester.tap(find.text('Усі 10 хв'));
    expect(receive.opened, 1);
  });

  testWidgets('the people list offers only who is linked, and a tap picks',
      (tester) async {
    AirDropPeer? picked;
    await tester.pumpWidget(
      _app(
        AirDropPeopleList(onPick: (p) => picked = p),
        [
          airdropDirectPeersProvider.overrideWithValue(
            [AirDropPeer('cc' * 32, 'Оля'), AirDropPeer('dd' * 32, 'Петро')],
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Петро'));
    expect(picked?.hex, 'dd' * 32);
  });

  testWidgets('with nobody linked the list says how to link', (tester) async {
    await tester.pumpWidget(
      _app(
        AirDropPeopleList(onPick: (_) {}),
        [airdropDirectPeersProvider.overrideWithValue(const [])],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Поруч ніхто не підключений'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test --no-pub test/airdrop_page_test.dart`
Expected: FAIL — missing presentation files.

- [ ] **Step 3: Navigation bits**

`lib/features/airdrop/presentation/airdrop_navigation.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The AirDrop page's place on the Nearby tab (Nearby | AirDrop | Files).
const int kAirDropPage = 1;

/// A request to bring one of the Nearby pages to the front — set by the send
/// flow and the incoming banner, taken and cleared by the Nearby screen.
final nearbyPageRequestProvider = StateProvider<int?>((ref) => null);

/// Whether the AirDrop page is what the person is looking at, so the incoming
/// banner does not cover the very card it would repeat.
final airdropPageOnScreenProvider = StateProvider<bool>((ref) => false);
```

- [ ] **Step 4: The people list**

`lib/features/airdrop/presentation/airdrop_people_sheet.dart`:

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/transport/chat_session_manager.dart';
import '../../../core/transport/messaging_service.dart';
import '../../../core/widgets/floating_glass.dart';
import '../../../core/widgets/glass_sheet.dart';
import '../../../core/widgets/identity_avatar.dart';
import '../../../l10n/app_localizations.dart';
import '../../peers/data/peripheral_controller.dart';
import '../data/airdrop_controller.dart' show airdropPeerNameProvider;

@immutable
class AirDropPeer {
  const AirDropPeer(this.hex, this.name);

  final String hex;
  final String name;
}

/// Everyone with a Bluetooth session to this phone right now — the only
/// people AirDrop can reach. Recomputed when sessions or peripheral links
/// change.
final airdropDirectPeersProvider = Provider<List<AirDropPeer>>((ref) {
  ref.watch(chatSessionManagerProvider);
  ref.watch(peripheralControllerProvider);
  final names = ref.watch(airdropPeerNameProvider);
  return [
    for (final hex in ref.watch(messagingServiceProvider).directPeerHexes())
      AirDropPeer(hex, names(hex)),
  ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
});

Future<AirDropPeer?> showAirDropPeopleSheet(BuildContext context) =>
    showGlassSheet<AirDropPeer>(
      context: context,
      useRootNavigator: true,
      builder: (sheet) => AirDropPeopleList(
        onPick: (peer) => Navigator.of(sheet).pop(peer),
      ),
    );

class AirDropPeopleList extends ConsumerWidget {
  const AirDropPeopleList({super.key, required this.onPick});

  final ValueChanged<AirDropPeer> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final peers = ref.watch(airdropDirectPeersProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            t.airdropPickPerson,
            style: AppTypography.heading(size: 18, color: AppColors.textOnGlass),
          ),
          const SizedBox(height: 12),
          if (peers.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                t.airdropNobody,
                style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 13),
              ),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 420),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final peer in peers)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: FloatingGlass(
                        blur: false,
                        borderRadius: 16,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        onTap: () => onPick(peer),
                        child: Row(
                          children: [
                            IdentityAvatar(
                              seed: peer.hex,
                              label: peer.name,
                              size: 40,
                              online: true,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                peer.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: AppColors.textOnGlass,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Icon(
                              Icons.bluetooth_connected_rounded,
                              color: AppColors.brandPrimary,
                              size: 18,
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 5: The cards**

`lib/features/airdrop/presentation/airdrop_cards.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';

import '../../../core/theme/colors.dart';
import '../../../core/transport/nearby_offer.dart';
import '../../../core/util/media_storage.dart';
import '../../../core/utils/file_mime.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../core/widgets/identity_avatar.dart';
import '../../../core/widgets/pill_button.dart';
import '../../../l10n/app_localizations.dart';
import '../../chat/presentation/widgets/file_bubble.dart' show formatBytes;
import '../../files/data/file_transfer_controller.dart';
import '../data/airdrop_history_controller.dart';
import '../domain/airdrop_transfer.dart';
import 'airdrop_text.dart';

String? airdropReasonLabel(AppLocalizations t, NearbyDeclineReason? reason) =>
    switch (reason) {
      null || NearbyDeclineReason.user => null,
      NearbyDeclineReason.noSpace => t.airdropReasonNoSpace,
      NearbyDeclineReason.contactsOnly => t.airdropReasonContactsOnly,
      NearbyDeclineReason.busy => t.airdropReasonBusy,
      NearbyDeclineReason.timeout => t.airdropReasonTimeout,
    };

String airdropOutcomeLabel(AppLocalizations t, AirDropHistoryEntry e) {
  final base = switch (e.outcome) {
    AirDropOutcome.received => t.airdropOutcomeReceived,
    AirDropOutcome.sent => t.airdropOutcomeSent,
    AirDropOutcome.declined => t.airdropOutcomeDeclined,
    AirDropOutcome.cancelled => t.airdropOutcomeCancelled,
    AirDropOutcome.failed => t.airdropInterrupted,
    AirDropOutcome.partial => t.airdropOutcomePartial,
  };
  final why = airdropReasonLabel(t, e.reason);
  return why == null ? base : '$base · $why';
}

/// The sender's own words for where things are: "waiting", "accepted ·
/// sending", "not received — maybe an old version".
String airdropPhaseLabel(AppLocalizations t, AirDropTransfer x) =>
    switch (x.phase) {
      AirDropPhase.offered || AirDropPhase.waiting => t.airdropWaiting,
      AirDropPhase.unheard => t.airdropUnheard,
      AirDropPhase.transferring => x.direction == AirDropDirection.outgoing
          ? '${t.airdropAccepted} · ${t.airdropSending}'
          : t.airdropReceiving,
      AirDropPhase.interrupted => t.airdropInterrupted,
      _ => '',
    };

TextStyle _dim(double size) =>
    TextStyle(color: AppColors.textOnGlassDim, fontSize: size);

class AirDropRequestCard extends StatelessWidget {
  const AirDropRequestCard({
    super.key,
    required this.transfer,
    required this.onAccept,
    required this.onDecline,
    this.onTap,
  });

  final AirDropTransfer transfer;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final names = transfer.files.take(3).map((f) => f.name).join(', ');
    final more = transfer.files.length > 3 ? ' …' : '';
    return GlassCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IdentityAvatar(
                seed: transfer.peerHex,
                label: transfer.peerName,
                size: 40,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: transfer.peerName,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      TextSpan(text: ' ${airdropRequestBody(t, transfer)}'),
                    ],
                  ),
                  style: TextStyle(color: AppColors.textOnGlass, fontSize: 14),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '$names$more',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: _dim(12),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: PillButton(
                  label: t.airdropDecline,
                  icon: Icons.close_rounded,
                  onTap: onDecline,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: PillButton(
                  label: t.airdropAccept,
                  icon: Icons.check_rounded,
                  active: true,
                  onTap: onAccept,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class AirDropProgressCard extends StatelessWidget {
  const AirDropProgressCard({
    super.key,
    required this.transfer,
    required this.onCancel,
    this.onRetry,
  });

  final AirDropTransfer transfer;
  final VoidCallback onCancel;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IdentityAvatar(
                seed: transfer.peerHex,
                label: transfer.peerName,
                size: 36,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      transfer.peerName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textOnGlass,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      airdropPhaseLabel(t, transfer),
                      maxLines: 2,
                      style: _dim(12),
                    ),
                  ],
                ),
              ),
              if (onRetry != null)
                TextButton(onPressed: onRetry, child: Text(t.airdropRetry)),
              IconButton(
                tooltip: t.cancel,
                onPressed: onCancel,
                icon: const Icon(Icons.close_rounded, size: 20),
                color: AppColors.textOnGlass,
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (final f in transfer.files) _FileProgress(file: f),
        ],
      ),
    );
  }
}

/// One file's bar. Reads the transfer queue by the file's id, rebuilt once
/// per whole percent, and eased between steps like the photo send ring.
class _FileProgress extends ConsumerWidget {
  const _FileProgress({required this.file});

  final AirDropFile file;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final percent = ref.watch(
      fileTransferControllerProvider.select(
        (tasks) => ((tasks[file.mediaIdHex]?.progress ?? 0) * 100).floor(),
      ),
    );
    final value = file.done ? 1.0 : percent / 100;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  file.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: AppColors.textOnGlass, fontSize: 13),
                ),
              ),
              Text(formatBytes(file.size), style: _dim(11)),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: value),
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 260),
              curve: Curves.easeOut,
              builder: (context, v, _) => LinearProgressIndicator(
                value: v,
                minHeight: 4,
                backgroundColor: AppColors.glass(0.08),
                valueColor: AlwaysStoppedAnimation(AppColors.brandPrimary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AirDropHistoryRow extends StatelessWidget {
  const AirDropHistoryRow({super.key, required this.entry});

  final AirDropHistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final incoming = entry.direction == AirDropDirection.incoming;
    final total = entry.files.fold<int>(0, (sum, f) => sum + f.size);
    AirDropHistoryFile? opener;
    if (incoming) {
      for (final f in entry.files) {
        if (!f.deleted && MediaPaths.existsOrNull(f.path)) {
          opener = f;
          break;
        }
      }
    }
    final file = opener;
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      onTap: file == null
          ? null
          : () => OpenFilex.open(file.path!, type: fileMimeType(file.name)),
      child: Row(
        children: [
          Icon(
            incoming ? Icons.south_west_rounded : Icons.north_east_rounded,
            color: AppColors.brandPrimary,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.peerName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textOnGlass,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${airdropOutcomeLabel(t, entry)} · '
                  '${airdropWhat(t, [for (final f in entry.files) f.mime])} · '
                  '${formatBytes(total)}',
                  style: _dim(12),
                ),
                if (entry.files.any((f) => f.deleted))
                  Text(
                    t.airdropFileDeleted,
                    style: TextStyle(
                      color: AppColors.textOnGlassFaint,
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
          ),
          Text(
            _when(entry.at),
            style: TextStyle(color: AppColors.textOnGlassFaint, fontSize: 11),
          ),
        ],
      ),
    );
  }

  static String _when(DateTime at) {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final time = '${two(at.hour)}:${two(at.minute)}';
    final today =
        at.year == now.year && at.month == now.month && at.day == now.day;
    return today ? time : '${at.day}.${two(at.month)} $time';
  }
}
```

- [ ] **Step 6: The send flow**

`lib/features/airdrop/presentation/airdrop_send_flow.dart`:

```dart
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../../core/transport/inner_payload.dart' show safeFileName;
import '../../../core/transport/messaging_service.dart';
import '../../../core/transport/nearby_offer.dart';
import '../../../core/util/image_encode.dart';
import '../../../core/widgets/glass_sheet.dart';
import '../../../core/widgets/glass_toast.dart';
import '../../../l10n/app_localizations.dart';
import '../../chat/presentation/widgets/media_picker_sheet.dart';
import '../../profile/data/media_quality_controller.dart';
import '../data/airdrop_controller.dart';
import '../data/airdrop_source.dart';
import '../domain/airdrop_rules.dart';
import 'airdrop_navigation.dart';
import 'airdrop_people_sheet.dart';

/// Everything between "send files" and the offer leaving: what, to whom,
/// the checks, and the AirDrop page brought to the front to show it.
/// [to] and [files] are filled in by entry points that already know them.
Future<void> startAirDropSend(
  BuildContext context,
  WidgetRef ref, {
  AirDropPeer? to,
  List<AirDropSource>? files,
}) async {
  final t = AppLocalizations.of(context);
  final chosen = files ?? await pickAirDropFiles(context, ref);
  if (chosen == null || chosen.isEmpty || !context.mounted) return;
  final peer = to ?? await showAirDropPeopleSheet(context);
  if (peer == null || !context.mounted) return;

  const cap = MessagingService.maxFileBytesMesh;
  for (final f in chosen) {
    if (f.size > cap) {
      showGlassToast(
        context,
        t.airdropTooLarge(f.name, cap ~/ (1024 * 1024)),
        tone: ToastTone.danger,
      );
      return;
    }
  }
  final capped = chosen.take(nearbyMaxFiles).toList();
  final total = capped.fold<int>(0, (sum, f) => sum + f.size);
  if (total > AirDropRules.longOverBluetoothBytes) {
    showGlassToast(
      context,
      t.airdropSlowWarning,
      icon: Icons.bluetooth_rounded,
      duration: const Duration(seconds: 3),
    );
  }
  final sent = await ref.read(airdropControllerProvider.notifier).offer(
        peerHex: peer.hex,
        peerName: peer.name,
        files: capped,
      );
  if (!context.mounted) return;
  if (sent == null) {
    showGlassToast(context, t.airdropNoDirect, tone: ToastTone.danger);
    return;
  }
  ref.read(nearbyPageRequestProvider.notifier).state = kAirDropPage;
}

/// Photos and videos from the gallery grid, or documents from the system
/// picker — the same sheet the chat attaches with.
Future<List<AirDropSource>?> pickAirDropFiles(
  BuildContext context,
  WidgetRef ref,
) async {
  final result = await showGlassSheet<MediaPickerResult>(
    context: context,
    useRootNavigator: true,
    builder: (_) => const MediaPickerSheet(allowCaption: false),
  );
  if (result is MediaPickerFile) {
    final picked = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (picked == null) return null;
    return [
      for (final f in picked.files)
        if (f.path != null)
          await AirDropSource.fromFile(File(f.path!), name: f.name),
    ];
  }
  if (result is! MediaPickerAssets) return null;
  final quality = await ref.read(mediaQualityProvider.notifier).resolved();
  final out = <AirDropSource>[];
  for (final asset in result.assets.take(nearbyMaxFiles)) {
    final origin = await asset.originFile;
    if (origin == null) continue;
    final title = await asset.titleAsync;
    out.add(
      asset.type == AssetType.image
          ? await _photoForBluetooth(origin, title, quality)
          : await AirDropSource.fromFile(origin, name: title),
    );
  }
  return out;
}

/// Part one moves files over Bluetooth only, so a photo is squeezed the way
/// the chat squeezes one, by "Photo quality". Part two (Wi-Fi) sends
/// originals. A photo the encoder cannot read goes as it is.
Future<AirDropSource> _photoForBluetooth(
  File origin,
  String title,
  MediaQuality quality,
) async {
  final wire = await encodeBytesForMesh(
    await origin.readAsBytes(),
    quality: quality,
  );
  if (wire == null) return AirDropSource.fromFile(origin, name: title);
  final sep = Platform.pathSeparator;
  final dir = Directory('${(await getTemporaryDirectory()).path}${sep}airdrop-out');
  if (!await dir.exists()) await dir.create(recursive: true);
  final dot = title.lastIndexOf('.');
  final stem = safeFileName(dot > 0 ? title.substring(0, dot) : title);
  final out =
      File('${dir.path}$sep${DateTime.now().microsecondsSinceEpoch}-$stem.jpg');
  await out.writeAsBytes(wire, flush: true);
  return AirDropSource(
    file: out,
    name: '$stem.jpg',
    size: wire.length,
    mime: 'image/jpeg',
  );
}
```

- [ ] **Step 7: The page**

`lib/features/airdrop/presentation/airdrop_page.dart`:

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/widgets/appear_animation.dart';
import '../../../core/widgets/floating_glass.dart';
import '../../../core/widgets/section_switch.dart';
import '../../../l10n/app_localizations.dart';
import '../data/airdrop_clock.dart';
import '../data/airdrop_controller.dart';
import '../data/airdrop_history_controller.dart';
import '../data/airdrop_receive_controller.dart';
import '../domain/airdrop_transfer.dart';
import 'airdrop_cards.dart';
import 'airdrop_send_flow.dart';

/// The middle page of Nearby: who may send, what is asking, what is moving,
/// and what has been.
class AirDropPage extends ConsumerWidget {
  const AirDropPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final state = ref.watch(airdropControllerProvider);
    final history = ref.watch(airdropHistoryProvider);
    final controller = ref.read(airdropControllerProvider.notifier);
    final reduced = MediaQuery.disableAnimationsOf(context);
    final now = DateTime.now();

    return AppearOnce(
      builder: (context, animate) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 140),
        children: [
          Row(
            children: [
              Icon(
                Icons.wifi_tethering_rounded,
                color: AppColors.brandPrimary,
                size: 30,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(t.airdropTab, style: AppTypography.display()),
              ),
            ],
          ),
          const SizedBox(height: 14),
          AppearAnimation(
            enabled: animate && !reduced,
            child: const _ReceiveSwitch(),
          ),
          const SizedBox(height: 12),
          AppearAnimation(
            enabled: animate && !reduced,
            delay: AppearAnimation.stagger(1),
            child: FloatingGlass(
              blur: false,
              borderRadius: 18,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              onTap: () => unawaited(startAirDropSend(context, ref)),
              child: Row(
                children: [
                  Icon(Icons.upload_rounded, color: AppColors.brandPrimary),
                  const SizedBox(width: 12),
                  Text(
                    t.airdropSendFiles,
                    style: TextStyle(
                      color: AppColors.textOnGlass,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          // A request drops in from above; once accepted, the same slot turns
          // into the progress card instead of one card leaving and another
          // arriving.
          for (final x in state.transfers)
            Padding(
              key: ValueKey('airdrop-${x.id}'),
              padding: const EdgeInsets.only(bottom: 10),
              child: AppearAnimation(
                enabled: !reduced,
                beginOffset: const Offset(0, -0.25),
                child: AnimatedSwitcher(
                  duration: reduced
                      ? Duration.zero
                      : const Duration(milliseconds: 260),
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SizeTransition(
                      sizeFactor: animation,
                      axisAlignment: -1,
                      child: child,
                    ),
                  ),
                  child: x.isIncomingRequest
                      ? AirDropRequestCard(
                          key: const ValueKey('request'),
                          transfer: x,
                          onAccept: () => unawaited(controller.accept(x.id)),
                          onDecline: () => unawaited(controller.decline(x.id)),
                        )
                      : AirDropProgressCard(
                          key: const ValueKey('progress'),
                          transfer: x,
                          onCancel: () => unawaited(controller.cancel(x.id)),
                          onRetry: x.phase == AirDropPhase.interrupted &&
                                  x.direction == AirDropDirection.outgoing
                              ? () => unawaited(controller.retry(x.id))
                              : null,
                        ),
                ),
              ),
            ),
          if (state.transfers.isEmpty && history.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 40),
              child: Text(
                t.airdropEmpty,
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 13),
              ),
            ),
          if (history.isNotEmpty)
            Row(
              children: [
                Expanded(
                  child: Text(
                    t.airdropHistory.toUpperCase(),
                    style: TextStyle(
                      color: AppColors.textOnGlassFaint,
                      fontSize: 11,
                      letterSpacing: 1.1,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => unawaited(
                    ref.read(airdropHistoryProvider.notifier).clear(),
                  ),
                  child: Text(t.airdropClearHistory),
                ),
              ],
            ),
          for (var i = 0; i < history.length; i++)
            Padding(
              key: ValueKey('history-${history[i].id}'),
              padding: const EdgeInsets.only(bottom: 8),
              // The page arriving staggers its rows; after that only a line
              // that has just been written slides in — a transfer finishing
              // is the one thing worth the motion.
              child: AppearAnimation(
                enabled: !reduced &&
                    (animate ||
                        now.difference(history[i].at) <
                            const Duration(seconds: 2)),
                delay: animate
                    ? AppearAnimation.stagger(i + 2)
                    : Duration.zero,
                child: AirDropHistoryRow(entry: history[i]),
              ),
            ),
        ],
      ),
    );
  }
}

/// "Receive from: Contacts / Everyone 10 min", with the minutes left counting
/// down while the window is open and on screen — the only ticking thing here,
/// and only then.
class _ReceiveSwitch extends ConsumerStatefulWidget {
  const _ReceiveSwitch();

  @override
  ConsumerState<_ReceiveSwitch> createState() => _ReceiveSwitchState();
}

class _ReceiveSwitchState extends ConsumerState<_ReceiveSwitch> {
  Timer? _second;

  @override
  void dispose() {
    _second?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final receive = ref.watch(airdropReceiveProvider);
    final now = ref.read(airdropClockProvider)();
    final everyone = receive.everyoneAt(now);
    if (everyone && TickerMode.valuesOf(context).enabled) {
      _second ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _second?.cancel();
      _second = null;
    }
    final left = everyone ? receive.everyoneUntil!.difference(now) : Duration.zero;
    final everyoneLabel = everyone
        ? t.airdropEveryoneLeft(
            '${left.inMinutes}:${(left.inSeconds % 60).toString().padLeft(2, '0')}',
          )
        : t.airdropReceiveEveryone;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t.airdropReceiveHint,
          style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 12),
        ),
        const SizedBox(height: 6),
        SectionSwitch(
          labels: [t.airdropReceiveContacts, everyoneLabel],
          selected: everyone ? 1 : 0,
          onSelect: (i) {
            final c = ref.read(airdropReceiveProvider.notifier);
            unawaited(i == 1 ? c.openToEveryone() : c.contactsOnly());
          },
        ),
      ],
    );
  }
}
```

- [ ] **Step 8: Run to verify it passes**

Run: `flutter test --no-pub test/airdrop_page_test.dart`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add lib/features/airdrop/presentation test/airdrop_page_test.dart
git commit -m "The AirDrop page: who may send, requests to answer, transfers in flight and what happened before"
```

---

### Task 11: Вкладка «Поблизу | AirDrop | Файли», меню человека, страница файлов

**Files:**
- Create: `lib/features/peers/presentation/nearby_screen.dart`
- Modify: `lib/features/files/presentation/file_transfer_center_screen.dart`
- Modify: `lib/features/peers/presentation/peers_screen.dart` (`_PeerCard`, `_buildBody`, new `_showPeerMenu`)
- Modify: `lib/core/routing/app_router.dart` (`/peers` builder)
- Test: `test/nearby_screen_test.dart`, `test/file_transfer_list_test.dart`

**Interfaces:**
- Consumes: `SectionSwitch`, `registerBranchPager`, `kNearbyBranch` (Task 9); `AirDropPage`, `startAirDropSend`, `AirDropPeer`, `kAirDropPage`, `nearbyPageRequestProvider`, `airdropPageOnScreenProvider` (Task 10); `FileTransferSource`, `peerName` (Task 2); `airdropHistoryProvider.markDeleted` (Task 5); `AirDropSource.fromFile` (Task 8).
- Produces: `NearbyScreen({List<Widget>? pages})`; `FileTransferList({bottomPadding})`.

- [ ] **Step 1: Write the failing tests**

`test/nearby_screen_test.dart`:

```dart
import 'package:cubechat/core/routing/branch_pager.dart';
import 'package:cubechat/features/airdrop/presentation/airdrop_navigation.dart';
import 'package:cubechat/features/peers/presentation/nearby_screen.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The real pages start the Bluetooth scanner and read Hive; the shell is
  // what is under test, so it gets three labels instead.
  Future<ProviderContainer> pump(WidgetTester tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('uk'),
          home: Scaffold(
            body: NearbyScreen(
              pages: [Text('page 0'), Text('page 1'), Text('page 2')],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('the island shows the three parts and switches between them',
      (tester) async {
    final c = await pump(tester);
    expect(find.text('Поблизу'), findsOneWidget);
    expect(find.text('AirDrop'), findsOneWidget);
    expect(find.text('Файли'), findsOneWidget);
    expect(find.text('page 0').hitTestable(), findsOneWidget);

    await tester.tap(find.text('AirDrop'));
    await tester.pumpAndSettle();
    expect(find.text('page 1').hitTestable(), findsOneWidget);
    expect(find.text('page 0').hitTestable(), findsNothing);
    expect(c.read(branchPagersProvider)[kNearbyBranch]?.index, 1);
    expect(c.read(airdropPageOnScreenProvider), isTrue);
  });

  testWidgets('the tab swipe steps through the pages before the next tab',
      (tester) async {
    final c = await pump(tester);
    final pager = c.read(branchPagersProvider)[kNearbyBranch]!;
    expect(pager.count, 3);
    expect(pager.canStep(-1), isFalse, reason: 'left of Nearby is a tab');
    pager.step(1);
    await tester.pumpAndSettle();
    pager.step(1);
    await tester.pumpAndSettle();
    expect(find.text('page 2').hitTestable(), findsOneWidget);
    expect(c.read(branchPagersProvider)[kNearbyBranch]!.canStep(1), isFalse);
  });

  testWidgets('a request from elsewhere brings AirDrop to the front',
      (tester) async {
    final c = await pump(tester);
    c.read(nearbyPageRequestProvider.notifier).state = kAirDropPage;
    await tester.pumpAndSettle();
    expect(find.text('page 1').hitTestable(), findsOneWidget);
    expect(c.read(nearbyPageRequestProvider), isNull);
  });
}
```

`test/file_transfer_list_test.dart`:

```dart
import 'dart:io';

import 'package:cubechat/features/files/data/file_transfer_controller.dart';
import 'package:cubechat/features/files/presentation/file_transfer_center_screen.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Tasks extends FileTransferController {
  _Tasks(this.tasks);

  final Map<String, FileTransferTask> tasks;

  @override
  Map<String, FileTransferTask> build() => tasks;
}

FileTransferTask _task(
  String id, {
  required FileTransferDirection direction,
  required FileTransferStatus status,
  String path = '',
}) =>
    FileTransferTask(
      id: id,
      chatId: 'bb' * 32,
      fileName: '$id.jpg',
      filePath: path,
      mime: 'image/jpeg',
      bytesTotal: 10,
      completedUnits: 1,
      totalUnits: 1,
      direction: direction,
      status: status,
      createdAt: DateTime(2026, 9, 22),
      updatedAt: DateTime(2026, 9, 22),
      source: FileTransferSource.airdrop,
      peerName: 'Жека',
    );

void main() {
  testWidgets('an AirDrop file says so, and is never offered a chat retry',
      (tester) async {
    final dir = Directory.systemTemp.createTempSync('cubechat_files_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final kept = File('${dir.path}${Platform.pathSeparator}in.jpg')
      ..writeAsStringSync('x');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          fileTransferControllerProvider.overrideWith(
            () => _Tasks({
              'in': _task(
                'in',
                direction: FileTransferDirection.incoming,
                status: FileTransferStatus.completed,
                path: kept.path,
              ),
              'out': _task(
                'out',
                direction: FileTransferDirection.outgoing,
                status: FileTransferStatus.failed,
              ),
            }),
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('uk'),
          home: Scaffold(body: FileTransferList()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('AirDrop · Жека'), findsNWidgets(2));
    expect(find.byIcon(Icons.refresh_rounded), findsNothing);

    await tester.longPress(find.text('in.jpg'));
    await tester.pumpAndSettle();
    expect(find.text('AirDrop'), findsOneWidget);
    expect(find.text('Видалити'), findsOneWidget);
  });
}
```

(`Видалити` is the existing `chatDeleteAction` in `app_uk.arb`.)

- [ ] **Step 2: Run to verify they fail**

Run: `flutter test --no-pub test/nearby_screen_test.dart test/file_transfer_list_test.dart`
Expected: FAIL — missing `nearby_screen.dart`, `FileTransferList`.

- [ ] **Step 3: The transfer list as a widget of its own**

In `file_transfer_center_screen.dart`, `FileTransferCenterScreen.build` keeps its `Scaffold` and `AppBar` (the clear action reads `history` from the provider itself) and its body becomes `const FileTransferList()`. Move the list into:

```dart
/// The transfer centre's list — every file this app moved, both ways, AirDrop
/// included. Its own widget so the Nearby tab's Files page shows the very same
/// list the Profile opens.
class FileTransferList extends ConsumerWidget {
  const FileTransferList({super.key, this.bottomPadding = 40});

  /// 40 as a screen of its own; 140 inside a tab, above the floating bar.
  final double bottomPadding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final transfers = ref.watch(fileTransferControllerProvider).values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final active = transfers.where((task) => task.active).toList();
    final history = transfers.where((task) => !task.active).toList();
    if (transfers.isEmpty) return _EmptyState(label: t.fileTransfersEmpty);
    return ListView(
      padding: EdgeInsets.fromLTRB(16, 8, 16, bottomPadding),
      children: [
        if (active.isNotEmpty) ...[
          _SectionLabel(t.fileTransfersActive),
          for (final task in active) ...[
            _TransferCard(task: task),
            const SizedBox(height: 10),
          ],
        ],
        if (history.isNotEmpty) ...[
          _SectionLabel(t.fileTransfersHistory),
          for (final task in history) ...[
            _TransferCard(task: task),
            const SizedBox(height: 10),
          ],
        ],
      ],
    );
  }
}
```

In `FileTransferCenterScreen.build`, compute `history` for the clear button as
`final history = ref.watch(fileTransferControllerProvider).values.where((task) => !task.active);`
and use `history.isNotEmpty`.

In `_TransferCard.build`, under the status line (`'${_statusLabel(...)} · ${_formatBytes(...)}'`) add:

```dart
                    if (task.source == FileTransferSource.airdrop)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          t.airdropFromLabel(task.peerName ?? '—'),
                          style: TextStyle(
                            color: AppColors.brandPrimary,
                            fontSize: 11.5,
                          ),
                        ),
                      ),
```

Wrap the returned `GlassCard` in:

```dart
    return GestureDetector(
      onLongPressStart: (details) =>
          unawaited(_menu(context, ref, details.globalPosition)),
      child: GlassCard(/* unchanged */),
    );
```

and add to `_TransferCard`:

```dart
  /// Hold a finished file: send it on by AirDrop, or — for one AirDrop
  /// brought in — delete it from the phone. Its history line stays, marked.
  Future<void> _menu(BuildContext context, WidgetRef ref, Offset at) async {
    final t = AppLocalizations.of(context);
    final path = task.filePath;
    if (task.status != FileTransferStatus.completed ||
        !MediaPaths.existsOrNull(path)) {
      return;
    }
    final deletable = task.source == FileTransferSource.airdrop &&
        task.direction == FileTransferDirection.incoming;
    final action = await showContextPopup<String>(
      context: context,
      globalPosition: at,
      items: [
        PopupMenuItem<String>(
          value: 'airdrop',
          height: 44,
          child: Text(
            t.airdropAction,
            style: TextStyle(color: AppColors.textOnGlass, fontSize: 14),
          ),
        ),
        if (deletable)
          PopupMenuItem<String>(
            value: 'delete',
            height: 44,
            child: Text(
              t.chatDeleteAction,
              style: const TextStyle(color: AppColors.danger, fontSize: 14),
            ),
          ),
      ],
    );
    if (action == null || !context.mounted) return;
    if (action == 'airdrop') {
      final source = await AirDropSource.fromFile(File(path), name: task.fileName);
      if (!context.mounted) return;
      await startAirDropSend(context, ref, files: [source]);
      return;
    }
    try {
      await File(path).delete();
    } on FileSystemException {
      // Already gone is the outcome that was asked for.
    }
    MediaPaths.forget(path);
    ref.read(airdropHistoryProvider.notifier).markDeleted(path);
    await ref.read(fileTransferControllerProvider.notifier).remove(task.id);
  }
```

In `_actions`, make the `queued`/`failed` case start with:

```dart
        // An AirDrop is retried from the AirDrop page, with the person there
        // to say yes; this button would resend it into a chat.
        if (task.source == FileTransferSource.airdrop) return const [];
```

New imports for the file: `dart:async`, `dart:io`, `../../../core/util/media_storage.dart`, `../../../core/widgets/context_popup.dart`, `../../airdrop/data/airdrop_history_controller.dart`, `../../airdrop/data/airdrop_source.dart`, `../../airdrop/presentation/airdrop_send_flow.dart`.

- [ ] **Step 4: The Nearby screen**

`lib/features/peers/presentation/nearby_screen.dart`:

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/routing/branch_pager.dart';
import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/widgets/section_switch.dart';
import '../../../l10n/app_localizations.dart';
import '../../airdrop/presentation/airdrop_navigation.dart';
import '../../airdrop/presentation/airdrop_page.dart';
import '../../files/data/file_transfer_controller.dart';
import '../../files/presentation/file_transfer_center_screen.dart';
import 'peers_screen.dart';

/// The Nearby tab: people in Bluetooth range, AirDrop, and every file the app
/// has moved — one island to pick between them, and the tab swipe turning the
/// pages before it changes tab (see [BranchPager]).
///
/// All three stay mounted: the first holds the scanner, and remounting it is a
/// radio restart. The hidden two have their tickers off.
class NearbyScreen extends ConsumerStatefulWidget {
  const NearbyScreen({super.key, @visibleForTesting this.pages});

  /// Stand-ins for the three pages, in a test that is about the shell.
  final List<Widget>? pages;

  static const int pageCount = 3;

  @override
  ConsumerState<NearbyScreen> createState() => _NearbyScreenState();
}

class _NearbyScreenState extends ConsumerState<NearbyScreen>
    with SingleTickerProviderStateMixin {
  int _page = 0;
  double _from = 1;
  late final AnimationController _slide = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    value: 1,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final asked = ref.read(nearbyPageRequestProvider);
      if (asked != null) {
        _take(asked);
      } else {
        _publish();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The tab leaving the screen, or a route covering it, turns tickers off —
    // which is also exactly when the AirDrop page stops being seen.
    WidgetsBinding.instance.addPostFrameCallback((_) => _publish());
  }

  @override
  void dispose() {
    _slide.dispose();
    super.dispose();
  }

  void _publish() {
    if (!mounted) return;
    registerBranchPager(
      ref.read(branchPagersProvider.notifier),
      BranchPager(
        branch: kNearbyBranch,
        index: _page,
        count: NearbyScreen.pageCount,
        step: (delta) => _select(_page + delta),
      ),
    );
    ref.read(airdropPageOnScreenProvider.notifier).state =
        _page == kAirDropPage && _visible;
  }

  /// Whether this tab is on screen, as of the last build — tickers are off
  /// for a tab the strip has moved away from and for a route covered by
  /// another. Read in build, where depending on [TickerMode] is allowed.
  bool _visible = true;

  void _take(int page) {
    ref.read(nearbyPageRequestProvider.notifier).state = null;
    _select(page);
    _publish();
  }

  void _select(int page) {
    if (page == _page || page < 0 || page >= NearbyScreen.pageCount) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _from = page > _page ? 1 : -1;
      _page = page;
    });
    if (MediaQuery.disableAnimationsOf(context)) {
      _slide.value = 1;
    } else {
      unawaited(_slide.forward(from: 0));
    }
    _publish();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    ref.listen<int?>(nearbyPageRequestProvider, (_, next) {
      if (next != null) _take(next);
    });
    final pages = widget.pages ??
        const [PeersScreen(), AirDropPage(), _FilesPage()];
    final visible = TickerMode.valuesOf(context).enabled;
    _visible = visible;
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: SectionSwitch(
              labels: [t.peersTitle, t.airdropTab, t.nearbyTabFiles],
              selected: _page,
              onSelect: _select,
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                for (var i = 0; i < pages.length; i++)
                  Offstage(
                    offstage: i != _page,
                    child: TickerMode(
                      enabled: visible && i == _page,
                      child: _PageSlide(
                        animation: i == _page ? _slide : kAlwaysCompleteAnimation,
                        from: _from,
                        child: pages[i],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The incoming page eases in from the side it came from — the same motion
/// the Contacts | Calls switch uses.
class _PageSlide extends StatelessWidget {
  const _PageSlide({
    required this.animation,
    required this.from,
    required this.child,
  });

  final Animation<double> animation;
  final double from;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final travel = MediaQuery.sizeOf(context).width * 0.22;
    final reduced = MediaQuery.disableAnimationsOf(context);
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, inner) {
        final t = reduced ? 1.0 : Curves.easeOutCubic.transform(animation.value);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset((1 - t) * from * travel, 0),
            child: inner,
          ),
        );
      },
    );
  }
}

class _FilesPage extends ConsumerWidget {
  const _FilesPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final finished = ref.watch(
      fileTransferControllerProvider
          .select((tasks) => tasks.values.any((task) => !task.active)),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(t.nearbyTabFiles, style: AppTypography.display()),
              ),
              if (finished)
                IconButton(
                  tooltip: t.fileTransfersClear,
                  onPressed: () => unawaited(
                    ref.read(fileTransferControllerProvider.notifier).clearFinished(),
                  ),
                  icon: const Icon(Icons.cleaning_services_rounded),
                  color: AppColors.textOnGlass,
                ),
            ],
          ),
        ),
        const Expanded(child: FileTransferList(bottomPadding: 140)),
      ],
    );
  }
}
```

In `app_router.dart` replace `builder: (context, state) => const PeersScreen(),` with `builder: (context, state) => const NearbyScreen(),` and import `../../features/peers/presentation/nearby_screen.dart` (drop the `peers_screen.dart` import if nothing else uses it).

- [ ] **Step 5: "Написати" and "Надіслати файли" on a person**

In `peers_screen.dart`: give `_PeerCard` a field `final void Function(Offset at)? onLongPressAt;` (constructor `this.onLongPressAt`), and wrap its `GlassCard` in

```dart
    return GestureDetector(
      onLongPressStart: onLongPressAt == null
          ? null
          : (details) => onLongPressAt!(details.globalPosition),
      child: GlassCard(/* unchanged */),
    );
```

In `_buildBody`, pass to `_PeerCard`:

```dart
                    onLongPressAt: (at) => unawaited(
                      _showPeerMenu(context, ref, state.peers[i], at, t),
                    ),
```

and add below `_connectAndOpen`:

```dart
/// Hold a person: write to them, or send files — the second only while a
/// Bluetooth session with them is up, because AirDrop goes nowhere else.
Future<void> _showPeerMenu(
  BuildContext context,
  WidgetRef ref,
  DiscoveredPeer peer,
  Offset at,
  AppLocalizations t,
) async {
  final label =
      peer.advertisedName.isNotEmpty ? peer.advertisedName : t.bleUnknownPeer;
  final hex = peer.resolvedPubkeyHex;
  final direct =
      hex != null && ref.read(messagingServiceProvider).hasDirectLinkTo(hex);
  final action = await showContextPopup<String>(
    context: context,
    globalPosition: at,
    items: [
      PopupMenuItem<String>(
        value: 'write',
        height: 44,
        child: Text(
          t.airdropWrite,
          style: TextStyle(color: AppColors.textOnGlass, fontSize: 14),
        ),
      ),
      PopupMenuItem<String>(
        value: 'files',
        enabled: direct,
        height: 44,
        child: Text(
          t.airdropSendFiles,
          style: TextStyle(
            color: direct ? AppColors.textOnGlass : AppColors.textOnGlassFaint,
            fontSize: 14,
          ),
        ),
      ),
    ],
  );
  if (action == null || !context.mounted) return;
  if (action == 'write') {
    await _connectAndOpen(context, ref, peer, t);
  } else if (hex != null) {
    await startAirDropSend(context, ref, to: AirDropPeer(hex, label));
  }
}
```

with the imports `../../../core/widgets/context_popup.dart`, `../../airdrop/presentation/airdrop_people_sheet.dart`, `../../airdrop/presentation/airdrop_send_flow.dart`.

- [ ] **Step 6: Run to verify they pass**

Run: `flutter test --no-pub test/nearby_screen_test.dart test/file_transfer_list_test.dart test/layer_budget_test.dart`
Expected: PASS. If `layer_budget_test.dart` counts the peers screen and fails because Nearby now draws one more glass pane (the island), read that test's comment: the budget is there to catch an accident, and one `FloatingGlass` with `blur: false` adds no backdrop pass — if it does fail, find out what the new pass is before raising the number.

- [ ] **Step 7: Commit**

```bash
git add lib/features/peers lib/features/files/presentation/file_transfer_center_screen.dart lib/core/routing/app_router.dart test/nearby_screen_test.dart test/file_transfer_list_test.dart
git commit -m "Nearby gets its island: people, AirDrop and every file the app moved, and a person can be sent files"
```

---

### Task 12: Входы — из чата, баннер запроса поверх всего, «Поделиться» на Android

**Files:**
- Create: `lib/features/airdrop/presentation/airdrop_banner.dart`
- Create: `lib/features/airdrop/data/share_inbox.dart`
- Create: `lib/features/airdrop/presentation/airdrop_share_screen.dart`
- Modify: `lib/features/chat/presentation/widgets/message_bubble.dart` (spotlight list ~846, dispatch ~992, new getter + method)
- Modify: `lib/app.dart` (builder, `initState`)
- Modify: `lib/core/routing/app_router.dart` (route `/airdrop/share`)
- Modify: `android/app/src/main/AndroidManifest.xml`, `android/app/src/main/kotlin/com/cubechat/cubechat/MainActivity.kt`
- Test: `test/airdrop_banner_test.dart`, `test/share_inbox_test.dart`

**Interfaces:**
- Consumes: Tasks 8, 10.
- Produces: `AirDropRequestBanner({onOpen})`; `SharedFile{path, name, mime}`, `parseSharedFiles(Object?)`, `ShareInbox.take()`, `ShareInbox.listen(onFiles)`; `AirDropShareScreen({files})`; route `/airdrop/share` (extra: `List<SharedFile>`).

- [ ] **Step 1: Write the failing tests**

`test/share_inbox_test.dart`:

```dart
import 'package:cubechat/features/airdrop/data/share_inbox.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('takes well-formed rows and cleans the names', () {
    final files = parseSharedFiles([
      {'path': '/c/a.jpg', 'name': '../a.jpg', 'mime': 'image/jpeg'},
      {'path': '/c/b.pdf', 'name': 'b.pdf'},
      {'path': 7, 'name': 'bad'},
      'nonsense',
    ]);
    expect(files, hasLength(2));
    expect(files.first.name, '_a.jpg');
    expect(files.first.mime, 'image/jpeg');
    expect(files.last.mime, 'application/octet-stream');
  });

  test('anything that is not a list is nothing', () {
    expect(parseSharedFiles(null), isEmpty);
    expect(parseSharedFiles({'path': '/x'}), isEmpty);
  });
}
```

`test/airdrop_banner_test.dart`:

```dart
import 'package:cubechat/features/airdrop/data/airdrop_controller.dart';
import 'package:cubechat/features/airdrop/domain/airdrop_transfer.dart';
import 'package:cubechat/features/airdrop/presentation/airdrop_banner.dart';
import 'package:cubechat/features/airdrop/presentation/airdrop_navigation.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAirDrop extends AirDropController {
  _FakeAirDrop(this.initial);

  final AirDropState initial;
  final accepted = <String>[];

  @override
  AirDropState build() => initial;

  @override
  Future<void> accept(String id) async => accepted.add(id);
}

final _request = AirDropTransfer(
  id: 'aa' * 16,
  peerHex: 'bb' * 32,
  peerName: 'Жека',
  direction: AirDropDirection.incoming,
  phase: AirDropPhase.waiting,
  createdAt: DateTime(2026, 9, 22),
  files: const [
    AirDropFile(mediaIdHex: 'f0', name: 'a.jpg', size: 10, mime: 'image/jpeg'),
  ],
);

void main() {
  Future<_FakeAirDrop> pump(
    WidgetTester tester, {
    bool onAirDropPage = false,
    VoidCallback? onOpen,
  }) async {
    final airdrop = _FakeAirDrop(AirDropState(transfers: [_request]));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          airdropControllerProvider.overrideWith(() => airdrop),
          airdropPageOnScreenProvider.overrideWith((ref) => onAirDropPage),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('uk'),
          home: Scaffold(
            body: AirDropRequestBanner(onOpen: onOpen ?? () {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return airdrop;
  }

  testWidgets('a request shows over whatever is open and can be accepted',
      (tester) async {
    final airdrop = await pump(tester);
    expect(find.textContaining('Жека', findRichText: true), findsOneWidget);
    await tester.tap(find.text('Прийняти'));
    expect(airdrop.accepted, [_request.id]);
  });

  testWidgets('not over the AirDrop page, which already shows it',
      (tester) async {
    await pump(tester, onAirDropPage: true);
    expect(find.text('Прийняти'), findsNothing);
  });
}
```

(The name sits inside a `Text.rich` with the body text, hence `textContaining` and `findRichText: true`.)

- [ ] **Step 2: Run to verify they fail**

Run: `flutter test --no-pub test/share_inbox_test.dart test/airdrop_banner_test.dart`
Expected: FAIL — missing files.

- [ ] **Step 3: The banner**

`lib/features/airdrop/presentation/airdrop_banner.dart`:

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/airdrop_controller.dart';
import 'airdrop_cards.dart';
import 'airdrop_navigation.dart';

/// A request drops in from the top over whatever is open — a chat, the map,
/// a profile — because it expires in a minute and nobody sits on the AirDrop
/// page waiting. Not over that page, which shows the same card itself.
class AirDropRequestBanner extends ConsumerWidget {
  const AirDropRequestBanner({super.key, required this.onOpen});

  /// Tap on the card: open the AirDrop page.
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final requests = ref.watch(airdropControllerProvider.select((s) => s.requests));
    final hidden = ref.watch(airdropPageOnScreenProvider);
    final request = hidden || requests.isEmpty ? null : requests.first;
    final controller = ref.read(airdropControllerProvider.notifier);
    final reduced = MediaQuery.disableAnimationsOf(context);
    return AnimatedSwitcher(
      duration: reduced ? Duration.zero : const Duration(milliseconds: 280),
      transitionBuilder: (child, animation) => SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, -1.2),
          end: Offset.zero,
        ).animate(
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
        ),
        child: FadeTransition(opacity: animation, child: child),
      ),
      child: request == null
          ? const SizedBox.shrink(key: ValueKey('no-request'))
          : Material(
              key: ValueKey(request.id),
              type: MaterialType.transparency,
              child: AirDropRequestCard(
                transfer: request,
                onTap: onOpen,
                onAccept: () => unawaited(controller.accept(request.id)),
                onDecline: () => unawaited(controller.decline(request.id)),
              ),
            ),
    );
  }
}
```

In `lib/app.dart`, replace `child: child ?? const SizedBox.shrink(),` inside `CallHost(...)` with:

```dart
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        child ?? const SizedBox.shrink(),
                        Positioned(
                          top: MediaQuery.paddingOf(context).top + 8,
                          left: 12,
                          right: 12,
                          child: AirDropRequestBanner(onOpen: _openAirDrop),
                        ),
                      ],
                    ),
```

and add to the state class:

```dart
  void _openAirDrop() {
    ref.read(nearbyPageRequestProvider.notifier).state = kAirDropPage;
    _router.go('/peers');
  }
```

with imports `features/airdrop/presentation/airdrop_banner.dart` and `features/airdrop/presentation/airdrop_navigation.dart`.

- [ ] **Step 4: AirDrop from a chat bubble**

In `message_bubble.dart`, after the `'download'` `SpotlightAction` (~line 851):

```dart
        // A photo, a video or a file on this phone, to somebody in arm's
        // reach. Not a view-once picture and not a chat that forbids copying:
        // AirDrop is exactly "take it elsewhere".
        if (_airdropPath != null)
          SpotlightAction(
            id: 'airdrop',
            icon: Icons.wifi_tethering_rounded,
            label: t.airdropAction,
          ),
```

in the dispatch chain, after `} else if (picked == 'download') { await _download();`:

```dart
    } else if (picked == 'airdrop') {
      await _airdrop();
```

and next to `_downloadablePath`:

```dart
  String? get _airdropPath {
    final m = widget.message;
    if (m.viewOnce || _copyingRestricted || m.isSticker) return null;
    final path = switch (m.kind) {
      MessageKind.image => m.imagePath,
      MessageKind.file => m.filePath,
      _ => null,
    };
    return MediaPaths.existsOrNull(path) ? path : null;
  }

  Future<void> _airdrop() async {
    final path = _airdropPath;
    if (path == null) return;
    final source = await AirDropSource.fromFile(
      File(path),
      name: widget.message.fileName,
    );
    if (!mounted) return;
    await startAirDropSend(context, ref, files: [source]);
  }
```

with imports `../../../airdrop/data/airdrop_source.dart` and `../../../airdrop/presentation/airdrop_send_flow.dart` (and `dart:io` if not already imported).

- [ ] **Step 5: The Dart side of "Share"**

`lib/features/airdrop/data/share_inbox.dart`:

```dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../core/transport/inner_payload.dart' show safeFileName;

/// A file another app handed to CubeChat through the system share sheet,
/// already copied into our cache by the platform side.
@immutable
class SharedFile {
  const SharedFile({required this.path, required this.name, required this.mime});

  final String path;
  final String name;
  final String mime;
}

/// Rows as the platform sends them. The name came from another app and is
/// treated as such; a malformed row is dropped rather than trusted.
List<SharedFile> parseSharedFiles(Object? raw) {
  if (raw is! List) return const [];
  final out = <SharedFile>[];
  for (final row in raw) {
    if (row is! Map) continue;
    final path = row['path'];
    final name = row['name'];
    final mime = row['mime'];
    if (path is! String || name is! String) continue;
    out.add(
      SharedFile(
        path: path,
        name: safeFileName(name),
        mime: mime is String ? mime : 'application/octet-stream',
      ),
    );
  }
  return out;
}

/// Android's "Share → CubeChat". See `MainActivity.shareFromIntent`.
abstract final class ShareInbox {
  static const MethodChannel _channel = MethodChannel('cubechat/share');

  static Future<List<SharedFile>> take() async {
    try {
      return parseSharedFiles(await _channel.invokeMethod<Object?>('takeShared'));
    } catch (_) {
      return const [];
    }
  }

  /// [onFiles] for what is already waiting (a cold start from the share
  /// sheet), and again for every share while the app runs.
  static void listen(void Function(List<SharedFile>) onFiles) {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'shared') return;
      final files = await take();
      if (files.isNotEmpty) onFiles(files);
    });
    unawaited(
      take().then((files) {
        if (files.isNotEmpty) onFiles(files);
      }),
    );
  }
}
```

`lib/features/airdrop/presentation/airdrop_share_screen.dart`:

```dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/transport/nearby_offer.dart';
import '../../../l10n/app_localizations.dart';
import '../data/airdrop_source.dart';
import '../data/share_inbox.dart';
import 'airdrop_people_sheet.dart';
import 'airdrop_send_flow.dart';
import 'airdrop_text.dart';

/// "Share → CubeChat": the files are known, only the person is not.
class AirDropShareScreen extends ConsumerWidget {
  const AirDropShareScreen({super.key, required this.files});

  final List<SharedFile> files;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text(
          t.airdropTab,
          style: AppTypography.heading(size: 18, color: AppColors.textOnGlass),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          Text(
            airdropWhat(t, [for (final f in files) f.mime]),
            style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 13),
          ),
          const SizedBox(height: 8),
          AirDropPeopleList(onPick: (peer) => unawaited(_send(context, ref, peer))),
        ],
      ),
    );
  }

  Future<void> _send(BuildContext context, WidgetRef ref, AirDropPeer peer) async {
    final sources = [
      for (final f in files.take(nearbyMaxFiles))
        await AirDropSource.fromFile(File(f.path), name: f.name),
    ];
    if (!context.mounted) return;
    await startAirDropSend(context, ref, to: peer, files: sources);
    if (!context.mounted) return;
    context.go('/peers');
  }
}
```

In `app_router.dart`, next to `/transfers`:

```dart
      GoRoute(
        path: '/airdrop/share',
        parentNavigatorKey: _rootNavKey,
        pageBuilder: (context, state) => fadeSlidePage(
          child: AuroraBackground(
            child: AirDropShareScreen(
              files: state.extra is List<SharedFile>
                  ? state.extra! as List<SharedFile>
                  : const [],
            ),
          ),
          state: state,
        ),
      ),
```

In `lib/app.dart` `initState`, after the notification hooks:

```dart
    // "Share → CubeChat" from another app hands files to AirDrop.
    if (PlatformInfo.isAndroid) {
      ShareInbox.listen(
        (files) => _router.push('/airdrop/share', extra: files),
      );
    }
```

(import `features/airdrop/data/share_inbox.dart`).

- [ ] **Step 6: The Android side of "Share"**

`AndroidManifest.xml`, inside the `.MainActivity` `<activity>`, after the MAIN/LAUNCHER `<intent-filter>`:

```xml
            <!-- "Share → CubeChat" from any app: the files go to AirDrop. -->
            <intent-filter>
                <action android:name="android.intent.action.SEND" />
                <category android:name="android.intent.category.DEFAULT" />
                <data android:mimeType="*/*" />
            </intent-filter>
            <intent-filter>
                <action android:name="android.intent.action.SEND_MULTIPLE" />
                <category android:name="android.intent.category.DEFAULT" />
                <data android:mimeType="*/*" />
            </intent-filter>
```

`MainActivity.kt` — imports `android.net.Uri`, `android.provider.OpenableColumns`, `androidx.core.content.IntentCompat`; companion constant `const val SHARE_CHANNEL = "cubechat/share"`; fields:

```kotlin
    /** Files from the share sheet, copied into our cache, until Dart takes them. */
    private var pendingShare: List<Map<String, String>>? = null
    private var shareChannel: MethodChannel? = null
```

in `configureFlutterEngine`, after the secure channel:

```kotlin
        shareChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SHARE_CHANNEL,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "takeShared" -> {
                        result.success(pendingShare)
                        pendingShare = null
                    }
                    else -> result.notImplemented()
                }
            }
        }
```

call `shareFromIntent(intent)` after `answerFromIntent(intent)` in both `onCreate` and `onNewIntent`, and add:

```kotlin
    /**
     * "Share → CubeChat". The content URIs are only readable while the grant
     * lasts, so each file is copied into our own cache first — off the main
     * thread, since a video is hundreds of megabytes — and then Dart is told.
     * At most fifty, AirDrop's own limit.
     */
    private fun shareFromIntent(intent: Intent?) {
        val uris: List<Uri> = when (intent?.action) {
            Intent.ACTION_SEND -> listOfNotNull(
                IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java),
            )
            Intent.ACTION_SEND_MULTIPLE ->
                IntentCompat.getParcelableArrayListExtra(
                    intent,
                    Intent.EXTRA_STREAM,
                    Uri::class.java,
                ) ?: emptyList()
            else -> return
        }
        // Spent, so a recreate does not share the same files again.
        intent.action = null
        if (uris.isEmpty()) return
        Thread {
            val copied = uris.take(50).mapNotNull { copyShared(it) }
            runOnUiThread {
                pendingShare = copied
                shareChannel?.invokeMethod("shared", null)
            }
        }.start()
    }

    private fun copyShared(uri: Uri): Map<String, String>? = try {
        var name = "file"
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { cursor -> if (cursor.moveToFirst()) name = cursor.getString(0) ?: name }
        val mime = contentResolver.getType(uri) ?: "application/octet-stream"
        val dir = File(cacheDir, "shared").apply { mkdirs() }
        val out = File(dir, "${System.nanoTime()}-${name.replace('/', '_').replace('\\', '_')}")
        val input = contentResolver.openInputStream(uri) ?: throw java.io.IOException("no stream")
        input.use { source -> out.outputStream().use { source.copyTo(it) } }
        mapOf("path" to out.absolutePath, "name" to name, "mime" to mime)
    } catch (_: Exception) {
        null
    }
```

- [ ] **Step 7: Run to verify they pass**

Run: `flutter test --no-pub test/share_inbox_test.dart test/airdrop_banner_test.dart`
Expected: PASS. Then `flutter analyze --no-pub lib` — no `error`/`warning`.

- [ ] **Step 8: Commit**

```bash
git add lib/features/airdrop lib/features/chat/presentation/widgets/message_bubble.dart lib/app.dart lib/core/routing/app_router.dart android/app/src/main/AndroidManifest.xml android/app/src/main/kotlin/com/cubechat/cubechat/MainActivity.kt test/share_inbox_test.dart test/airdrop_banner_test.dart
git commit -m "AirDrop from a chat bubble and from Android's share sheet, and a request shows over whatever is open"
```

---

### Task 13: Бекап без AirDrop, экстренная очистка, документы, сборка

**Files:**
- Create: `lib/features/backup/data/backup_filter.dart`
- Modify: `lib/features/backup/data/backup_service.dart` (`_snapshot`, ~line 63)
- Modify: `lib/core/identity/wipe_service.dart` (after `fileTransferControllerProvider…clearAll()`)
- Modify: `.claude/skills/wire-protocol/SKILL.md` (the `InnerPayloadType` row)
- Modify: `pubspec.yaml`, `lib/core/util/app_build.dart`
- Test: `test/backup_filter_test.dart`

**Interfaces:**
- Consumes: `FileTransferController.storageKey`, `FileTransferSource` (Task 2); AirDrop controllers (Tasks 5, 8); `deleteAirdropDirectory` (Task 5).
- Produces: `backupKeeps(String box, Object? key) → bool`, `backupValue(String box, Object? key, Object? value) → Object?`.

- [ ] **Step 1: Write the failing test**

`test/backup_filter_test.dart`:

```dart
import 'package:cubechat/core/storage/hive_init.dart';
import 'package:cubechat/features/backup/data/backup_filter.dart';
import 'package:cubechat/features/files/data/file_transfer_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test("AirDrop's own keys stay on the phone; everything else goes", () {
    expect(backupKeeps(HiveBoxes.settings, 'airdrop.history.v1'), isFalse);
    expect(backupKeeps(HiveBoxes.settings, 'airdrop.spam.v1'), isFalse);
    expect(backupKeeps(HiveBoxes.settings, 'airdrop.everyoneUntil'), isFalse);
    expect(backupKeeps(HiveBoxes.settings, 'discovery.discoverable'), isTrue);
    expect(backupKeeps(HiveBoxes.messages, 'airdrop.whatever'), isTrue);
  });

  test('the transfer list travels without its AirDrop rows', () {
    final rows = [
      {'id': 'a', 'source': 'airdrop'},
      {'id': 'b'},
      {'id': 'c', 'source': 'chat'},
    ];
    final kept = backupValue(
      HiveBoxes.settings,
      FileTransferController.storageKey,
      rows,
    )! as List;
    expect([for (final r in kept) (r as Map)['id']], ['b', 'c']);
    expect(backupValue(HiveBoxes.settings, 'other', rows), same(rows));
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test --no-pub test/backup_filter_test.dart`
Expected: FAIL — missing file.

- [ ] **Step 3: Implement the filter and use it**

`lib/features/backup/data/backup_filter.dart`:

```dart
import '../../../core/storage/hive_init.dart';
import '../../files/data/file_transfer_controller.dart';

/// Whether a stored value goes into a backup or a phone transfer.
///
/// AirDrop's history, its "everyone" window and its bans stay on this phone —
/// the design says so, and the files the history points at live in
/// `airdrop/`, which neither the backup nor the transfer takes.
bool backupKeeps(String box, Object? key) => !(box == HiveBoxes.settings &&
    key is String &&
    key.startsWith('airdrop.'));

/// The value as a backup carries it: the transfer list without its AirDrop
/// rows, whose files are not carried either.
Object? backupValue(String box, Object? key, Object? value) {
  if (box != HiveBoxes.settings ||
      key != FileTransferController.storageKey ||
      value is! List) {
    return value;
  }
  return [
    for (final row in value)
      if (!(row is Map && row['source'] == FileTransferSource.airdrop.name)) row,
  ];
}
```

In `backup_service.dart` `_snapshot`, replace

```dart
      boxes[name] = [
        for (final key in keys) [_encodeValue(key), _encodeValue(box.get(key))],
      ];
```

with

```dart
      boxes[name] = [
        for (final key in keys)
          if (backupKeeps(name, key))
            [
              _encodeValue(key),
              _encodeValue(backupValue(name, key, box.get(key))),
            ],
      ];
```

and import `backup_filter.dart`.

- [ ] **Step 4: Emergency wipe**

In `wipe_service.dart`, after `await ref.read(fileTransferControllerProvider.notifier).clearAll();`:

```dart
  // AirDrop: what is in flight, its history, its "everyone" window, its bans,
  // and the files it received.
  ref.read(airdropControllerProvider.notifier).clearAll();
  await ref.read(airdropHistoryProvider.notifier).clear();
  await ref.read(airdropSpamProvider.notifier).clear();
  await ref.read(airdropReceiveProvider.notifier).reset();
  await deleteAirdropDirectory();
```

with imports for the four AirDrop data files.

- [ ] **Step 5: The wire-protocol skill**

Replace the `InnerPayloadType` row's "Taken" cell with:

```
36 types on 2026-09-22. The round values 0x10–0xD0 are the originals; everything since has been packed into 0xE0–0xE9 and 0xF0–0xFC, newest `nearbyOffer` 0xE8 and `nearbyAnswer` 0xE9 (AirDrop). **Print what is free — never pick from this row**
```

- [ ] **Step 6: Legal documents**

Nothing new leaves the phone: offers, answers and files go over a direct Bluetooth link only, never to a server or a relay. Read `docs/legal/` for any sentence that lists *what the app sends over Bluetooth* or *what the backup contains*; if one lists them exhaustively, add AirDrop to it (offers and files, only to a person the user picks, only over a direct link; not in backups). If none does, leave the folder alone and say so in the commit message.

- [ ] **Step 7: The whole suite and the analyzer**

Run: `flutter gen-l10n` (no warnings), `flutter analyze --no-pub` and grep for both `error -`/`warning -` and `error •`/`warning •` — none. Run `flutter test --no-pub --exclude-tags golden` — all pass. Run `flutter test --no-pub --tags golden` too; a golden that moved because Contacts now uses the shared `SectionSwitch` has to be diffed numerically, not by eye, before it is re-recorded.

- [ ] **Step 8: Version and build**

Bump `pubspec.yaml` `version:` build number by one and `appBuildStamp` in `lib/core/util/app_build.dart` to `'2026-09-22-airdrop-over-bluetooth'` (or the day's date). Build the universal APK only (load the `release-build` skill first):

```bash
powershell -ExecutionPolicy Bypass -File tool/build_apk.ps1 -SkipPubGet
```

Expected: `BUILD OK … stamp verified inside libapp.so`.

- [ ] **Step 9: Commit**

```bash
git add lib/features/backup lib/core/identity/wipe_service.dart .claude/skills/wire-protocol/SKILL.md pubspec.yaml lib/core/util/app_build.dart test/backup_filter_test.dart
git commit -m "Build NNNN - AirDrop to people nearby over Bluetooth"
```

(`NNNN` is the new build number.)

- [ ] **Step 10: What only two phones can prove**

Hand the owner these checks, in Russian, as exact taps — nothing here can be proven without two phones:

1. Два телефона рядом, оба на новой сборке. На первом: «Поблизу» → зажать человека → «Надіслати файли» → 3 фото. На втором появляется запрос сверху (в любом разделе) → «Прийняти». Файлы в «Поблизу → Файли» с пометкой «AirDrop · имя».
2. Второй телефон на старой сборке → на первом через 10 секунд «Не отримав — можливо, стара версія CubeChat».
3. Незнакомец (не в контактах), режим «Контакти» → у него «Відхилено · лише від контактів». Режим «Усі 10 хв» → запрос приходит; три раза «Відхилити» → четвёртый запрос не показывается 10 минут.
4. Видео на 50 МБ → «Через Bluetooth це може тривати довго»; во время передачи выключить Bluetooth на отправителе → «Перервано · Повторити»; включить, «Повторити» → уходят только недошедшие файлы.
5. Галерея Android → «Поделиться» → CubeChat → выбрать человека.
6. Прислать лог сразу после каждой проверки (журнал держит 200 строк).

---

### Task 14: «Поделиться» на iPhone (Share Extension) — только на Mac

Эта задача требует Xcode и не выполняется на Windows-машине, где собирается APK. Её делают последней, отдельно, и проверяют через CI (`ios.yml`) и TestFlight.

**Files:**
- Create (Xcode): target `CubeChatShare` (Share Extension), `ios/CubeChatShare/ShareViewController.swift`, `ios/CubeChatShare/Info.plist`, entitlements for both targets
- Modify: `ios/Runner/AppDelegate.swift` (`cubechat/share` channel), `ios/Runner/Runner.entitlements`
- Modify: `lib/app.dart` (`ShareInbox.listen` on iOS too)

**Interfaces:**
- Consumes: `ShareInbox`, `parseSharedFiles` (Task 12) — the same channel and the same rows `{path, name, mime}`.

- [ ] **Step 1: Check the sideload risk first.** An App Group id must match between the app and the extension. Sideloadly rewrites the bundle id by appending the team id (see the release-build skill), so a group named for `app.cubechat` may not match what a sideloaded build carries. Read the `[BUILD]` boot line of a sideloaded build; if the bundle id is rewritten, this feature works on TestFlight/App Store builds only, and that goes in the commit message.

- [ ] **Step 2: Create the target in Xcode.** File → New → Target → Share Extension, name `CubeChatShare`, bundle id `app.cubechat.share`. Add the App Group `group.app.cubechat` to both `Runner` and `CubeChatShare` (Signing & Capabilities → App Groups). In the extension's `Info.plist`, `NSExtensionActivationRule` as a dictionary: `NSExtensionActivationSupportsFileWithMaxCount` 50, `NSExtensionActivationSupportsImageWithMaxCount` 50, `NSExtensionActivationSupportsMovieWithMaxCount` 50.

- [ ] **Step 3: The extension copies and says what it copied.** It cannot open the app (Apple offers no API for that from a share extension), so it copies the files into the group container, writes a manifest, and tells the person to open CubeChat.

`ios/CubeChatShare/ShareViewController.swift`:

```swift
import UIKit
import UniformTypeIdentifiers

/// "Share → CubeChat" on iPhone. Copies what was shared into the app group's
/// `shared/` folder and lists it in `shared.json`; CubeChat picks the list up
/// the next time it comes forward and asks who to AirDrop it to.
final class ShareViewController: UIViewController {
  private let group = "group.app.cubechat"

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    Task { await collect() }
  }

  private func collect() async {
    guard
      let root = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: group
      )
    else { return finish() }
    let dir = root.appendingPathComponent("shared", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var rows: [[String: String]] = []
    let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
    for provider in items.flatMap({ $0.attachments ?? [] }).prefix(50) {
      guard let type = provider.registeredTypeIdentifiers.first,
            let url = try? await provider.loadFileRepresentation(forTypeIdentifier: type)
      else { continue }
      let name = url.lastPathComponent
      let out = dir.appendingPathComponent("\(UUID().uuidString)-\(name)")
      guard (try? FileManager.default.copyItem(at: url, to: out)) != nil else { continue }
      let mime = UTType(type)?.preferredMIMEType ?? "application/octet-stream"
      rows.append(["path": out.path, "name": name, "mime": mime])
    }
    if let data = try? JSONSerialization.data(withJSONObject: rows) {
      try? data.write(to: root.appendingPathComponent("shared.json"))
    }
    await MainActor.run { self.tellToOpen() }
  }

  private func tellToOpen() {
    let alert = UIAlertController(
      title: "CubeChat",
      message: "Відкрийте CubeChat, щоб вибрати, кому надіслати.",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in self.finish() })
    present(alert, animated: true)
  }

  private func finish() {
    extensionContext?.completeRequest(returningItems: nil)
  }
}
```

`NSItemProvider.loadFileRepresentation(forTypeIdentifier:)` as `async` exists from iOS 16 (the deployment target must be at least that; check `ios/Podfile` and raise the extension's own target only if needed). The extension's alert text is the one string here not in the arb files — an extension cannot read Flutter's localizations.

- [ ] **Step 4: The app reads the list.** In `AppDelegate.swift`, next to the other channels:

```swift
      // "Share → CubeChat": what the share extension left in the app group.
      FlutterMethodChannel(
        name: "cubechat/share",
        binaryMessenger: messenger
      ).setMethodCallHandler { call, result in
        guard call.method == "takeShared" else {
          result(FlutterMethodNotImplemented)
          return
        }
        guard
          let root = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.app.cubechat"
          )
        else {
          result(nil)
          return
        }
        let list = root.appendingPathComponent("shared.json")
        guard let data = try? Data(contentsOf: list),
              let rows = try? JSONSerialization.jsonObject(with: data)
        else {
          result(nil)
          return
        }
        try? FileManager.default.removeItem(at: list)
        result(rows)
      }
```

Dart asks only on start and on resume, so in `lib/app.dart` make the `ShareInbox.listen` condition `PlatformInfo.isMobile`, and in `didChangeAppLifecycleState` on `resumed` add (iOS only):

```dart
      if (PlatformInfo.isIOS) {
        unawaited(ShareInbox.take().then((files) {
          if (files.isNotEmpty) _router.push('/airdrop/share', extra: files);
        }));
      }
```

- [ ] **Step 5: Verify and commit.** Push only with the owner's explicit yes; CI builds the IPA. On a TestFlight build: Photos → Share → CubeChat → the alert → open CubeChat → «Надіслати кому».

```bash
git add ios lib/app.dart
git commit -m "Share to CubeChat from an iPhone: the files wait in the app group until the app asks who to send them to"
```

---

## Отклонения от спецификации, принятые в плане

1. **Свайп и островок** — индикатор доезжает после свайпа, а не тянется за пальцем (см. начало плана; Task 9 правит спецификацию).
2. **Запрос поверх всего приложения** — спецификация показывает карточку запроса только на странице AirDrop. Запрос живёт 60 секунд, а на этой странице никто не сидит, поэтому та же карточка выезжает сверху над любым экраном (Task 12), а при свёрнутом приложении приходит системное уведомление (Task 8, `airdropNotifyProvider`).
3. **«Призупинено — відкрийте CubeChat» на iPhone** — отдельной карточки нет. Если фоновый Bluetooth остановит передачу, получатель через 60 секунд увидит «Перервано», а отправитель — «Перервано · Повторити», и повтор пройдёт без нового согласия 10 минут. Это то же состояние, названное словами, которые уже есть.
4. **Размер** — у AirDrop нет своего предела, но действует существующий потолок одного файла по Bluetooth, 128 МиБ (`maxFileBytesMesh`); файл больше отказывается до отправки предложения (Task 10).

## Self-review (сделано при написании)

- Покрытие спецификации: экраны (Tasks 9-11), входы (11, 12, 14), качество фото (10), анимации (10, 11), протокол и шаги 1-5 (1, 7, 8), только прямая связь (7, 8), незнакомцы и видимость (7, 8), старые версии (8), хранение, история, удаление, очистка, бекап (5, 11, 13), ошибки: обрыв, отмена, место, одно предложение, лимиты, антиспам, свёрнутое приложение (8, 10, отклонение 3), тесты раздела 5 (1, 3, 4, 5, 8, 10-13).
- Имена сверены между задачами: `AirDropTransitions.*`, `AirDropPhase`, `airdropControllerProvider` (`offer/accept/decline/cancel/retry/clearAll`), `NearbyFileSink.judge/keep`, `FileTransferSource`, `FileTransferController.storageKey`, `registerBranchPager`, `kNearbyBranch`, `kAirDropPage`, `nearbyPageRequestProvider`, `airdropPageOnScreenProvider`, `airdropWhat(t, List<String> mimes)`.

