# AirDrop part 2 — Wi‑Fi lane and the bump gesture — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Files of an accepted AirDrop offer travel over the local network when both phones share one, and two phones brought together on the open AirDrop page send the staged files or swap contact cards, with a NameDrop-style glow.

**Architecture:** Bluetooth keeps doing discovery, offer and answer. An accepting receiver opens a one-shot TCP server and returns its address, port and a fresh 32-byte key inside the already encrypted `nearbyAnswer` (version 2). The sender connects and streams files as ChaCha20‑Poly1305 records sealed with that key, falling back to the Bluetooth path of part 1. The bump gesture is a pure `ProximityTracker` over RSSI from a faster scan that only runs while the AirDrop page is on screen, plus a mutual `nearbyBump` (0xEA) handshake over the direct session.

**Tech Stack:** Flutter, Riverpod `Notifier`s, `dart:io` sockets, `cryptography` (ChaCha20‑Poly1305) in `Isolate.run`, `flutter_blue_plus` scan, Hive encrypted settings box, `CustomPainter`.

**Spec:** `docs/superpowers/specs/2026-09-23-airdrop-wifi-and-bump-design.md` (and part 1: `docs/superpowers/specs/2026-09-22-airdrop-design.md`).

## Global Constraints

- Load the `wire-protocol` skill before Tasks 1 and 8; load `glass-ui` before Tasks 7, 12, 13; load `flutter-testing` before running tests.
- Edit source files with Edit/Write only — never through the shell (a hook blocks it; shells also mangle Cyrillic).
- Analyzer is strict (`strict-casts`, `strict-inference`, `strict-raw-types`, `prefer_final_locals`, `require_trailing_commas`). `flutter analyze` must show no new errors or warnings (grep both `error -`/`warning -` and `•` forms).
- Every user-visible string goes to both `lib/l10n/app_en.arb` and `lib/l10n/app_uk.arb`, then `flutter gen-l10n`, and the regenerated `app_localizations*.dart` is committed.
- `MessagingService` changes are additive only.
- Comments explain why; commit subjects are a sentence about the effect (no `feat:` prefixes), ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Exact values from the spec: Wi‑Fi connect timeout **5 s**; receiver port idle close **2 min**; key **32 bytes**, per transfer, never persisted; record payload **64 KiB**; `bumpRssi` **−40 dBm**; lead over the runner-up **15 dB**; median window **1 s**; mutual bump window **2 s**; per-person cooldown **5 s**; bumped offer auto-accepted within **10 s**; glow starts at **−60 dBm**; wave **~600 ms**; `nearbyBump` card **≤ 2048 bytes**.
- Tag bytes: `nearbyOffer` 0xE8, `nearbyAnswer` 0xE9 (taken); `nearbyBump` takes **0xEA** — re-verify against `lib/core/transport/inner_payload.dart` before using it.
- Run single tests with `flutter test test/<file>.dart`. The stale golden `contact_profile_capture` fails on its own and is not a regression.

## File map

| File | Status | Responsibility |
|---|---|---|
| `lib/core/transport/nearby_offer.dart` | modify | `nearbyFlagWifi`, `NearbyWifiEndpoint`, answer v2, `NearbyBump`, `NearbyInbound.bump` |
| `lib/core/transport/inner_payload.dart` | modify | `nearbyBump(0xEA)` |
| `lib/core/transport/messaging_service.dart` | modify (additive) | dispatch bump, `sendNearbyFrame(bump:)`, discoverable while AirDrop page open |
| `lib/features/airdrop/data/wifi_lane_codec.dart` | create | record framing + batched sealing in an isolate |
| `lib/features/airdrop/data/wifi_lane.dart` | create | `WifiLaneReceiver`, `WifiLaneSender`, `AirDropWifi` interface + `pickLanAddress` |
| `lib/features/airdrop/data/airdrop_lane_controller.dart` | create | "Channel: Auto / Bluetooth / Wi‑Fi" setting |
| `lib/features/airdrop/domain/airdrop_transfer.dart` | modify | `wifi`, `wifiUnreachable` fields |
| `lib/features/airdrop/data/airdrop_controller.dart` | modify | lane choice, receiver/sender lifecycle, fallback, bump auto-accept |
| `lib/features/airdrop/data/airdrop_port.dart` | modify | `send(bump:)` |
| `lib/features/airdrop/domain/proximity_tracker.dart` | create | RSSI medians → "who is touching" |
| `lib/features/airdrop/data/bump_ledger.dart` | create | who we bumped and when (shared by two controllers) |
| `lib/features/airdrop/data/bump_controller.dart` | create | mutual bump, staged files, events |
| `lib/features/airdrop/data/airdrop_staged.dart` | create | files chosen ahead of a bump |
| `lib/core/ble/ble_scanner.dart`, `ble_constants.dart` | modify | proximity scan mode |
| `lib/features/peers/data/peer_discovery_controller.dart` | modify | toggle proximity mode from the page |
| `lib/features/airdrop/presentation/airdrop_page.dart`, `airdrop_cards.dart` | modify | lane switch, staged card, lane icon |
| `lib/features/airdrop/presentation/bump_glow.dart` | create | glow + wave painter, contact card overlay |
| `ios/Runner/Info.plist`, `docs/legal/*` | modify | local-network wording |

---

## Part A — Wi‑Fi lane

### Task 1: Answer version 2 carries a Wi‑Fi endpoint

**Files:**
- Modify: `lib/core/transport/nearby_offer.dart`
- Test: `test/nearby_offer_test.dart` (exists — add a group)

**Interfaces:**
- Produces: `const int nearbyFlagWifi = 0x01;` `const int nearbyAnswerVersionWifi = 0x02;` `class NearbyWifiEndpoint { NearbyWifiEndpoint({required String address, required int port, required Uint8List key}); final String address; final int port; final Uint8List key; static const int keyLen = 32; }` and `NearbyAnswer({..., NearbyWifiEndpoint? wifi})` with `final NearbyWifiEndpoint? wifi;`.

- [ ] **Step 1: Write the failing tests** — append to `test/nearby_offer_test.dart`:

```dart
  group('answer v2 (Wi-Fi endpoint)', () {
    Uint8List key() => Uint8List.fromList(List.generate(32, (i) => i + 1));
    Uint8List tid() => Uint8List.fromList(List.generate(16, (i) => 200 - i));

    test('an answer without an endpoint is still nineteen bytes, version 1',
        () {
      final bytes = NearbyAnswer(
        transferId: tid(),
        kind: NearbyAnswerKind.accepted,
      ).encode();
      expect(bytes.length, NearbyAnswer.length);
      expect(bytes[0], nearbyVersion);
    });

    test('an endpoint round-trips', () {
      final a = NearbyAnswer(
        transferId: tid(),
        kind: NearbyAnswerKind.accepted,
        wifi: NearbyWifiEndpoint(
          address: '192.168.1.23',
          port: 40123,
          key: key(),
        ),
      );
      final bytes = a.encode();
      expect(bytes[0], nearbyAnswerVersionWifi);
      final back = NearbyAnswer.decode(bytes);
      expect(back.kind, NearbyAnswerKind.accepted);
      expect(back.wifi!.address, '192.168.1.23');
      expect(back.wifi!.port, 40123);
      expect(back.wifi!.key, key());
    });

    test('IPv6 round-trips', () {
      final back = NearbyAnswer.decode(
        NearbyAnswer(
          transferId: tid(),
          kind: NearbyAnswerKind.accepted,
          wifi: NearbyWifiEndpoint(address: 'fe80::1', port: 1, key: key()),
        ).encode(),
      );
      expect(back.wifi!.address, 'fe80::1');
    });

    test('only an acceptance may carry an endpoint', () {
      expect(
        () => NearbyAnswer(
          transferId: tid(),
          kind: NearbyAnswerKind.declined,
          wifi: NearbyWifiEndpoint(address: '10.0.0.2', port: 5, key: key()),
        ),
        throwsArgumentError,
      );
    });

    test('bad endpoints are refused on construction', () {
      expect(
        () => NearbyWifiEndpoint(address: 'not-an-ip', port: 5, key: key()),
        throwsArgumentError,
      );
      expect(
        () => NearbyWifiEndpoint(address: '10.0.0.2', port: 0, key: key()),
        throwsArgumentError,
      );
      expect(
        () => NearbyWifiEndpoint(
          address: '10.0.0.2',
          port: 5,
          key: Uint8List(31),
        ),
        throwsArgumentError,
      );
    });

    test('tampered v2 bytes throw FormatException', () {
      final good = NearbyAnswer(
        transferId: tid(),
        kind: NearbyAnswerKind.accepted,
        wifi: NearbyWifiEndpoint(address: '10.0.0.2', port: 5, key: key()),
      ).encode();
      // truncated
      expect(
        () => NearbyAnswer.decode(Uint8List.sublistView(good, 0, 30)),
        throwsFormatException,
      );
      // trailing byte
      expect(
        () => NearbyAnswer.decode(Uint8List.fromList([...good, 0])),
        throwsFormatException,
      );
      // address length pointing past the end
      final longAddr = Uint8List.fromList(good)..[19] = 200;
      expect(() => NearbyAnswer.decode(longAddr), throwsFormatException);
      // a v2 answer that is not an acceptance
      final notAccepted = Uint8List.fromList(good)
        ..[17] = NearbyAnswerKind.declined.tag;
      expect(() => NearbyAnswer.decode(notAccepted), throwsFormatException);
      // v1 with the wrong length is still refused
      final v1 = Uint8List.fromList(good)..[0] = nearbyVersion;
      expect(() => NearbyAnswer.decode(v1), throwsFormatException);
    });
  });
```

- [ ] **Step 2: Run to verify failure**

Run: `flutter test test/nearby_offer_test.dart`
Expected: compile error — `NearbyWifiEndpoint` / `nearbyAnswerVersionWifi` undefined.

- [ ] **Step 3: Implement** in `lib/core/transport/nearby_offer.dart`.

Replace the `[flags] bit 0 is reserved…` sentence in the `NearbyOffer` doc with: `[flags] bit 0 ([nearbyFlagWifi]) says the sender can take the files over the local network; an older build leaves it 0 and never reads it.` Add near the top constants:

```dart
/// Offer flag: "I can send these over the local network" (part 2).
const int nearbyFlagWifi = 0x01;

/// Answer version that carries a [NearbyWifiEndpoint]. Only ever sent in
/// reply to an offer with [nearbyFlagWifi], which a part-1 build never sets —
/// so no phone that cannot read it is ever sent one.
const int nearbyAnswerVersionWifi = 0x02;

/// Longest textual IP address: a full IPv6 with an embedded IPv4.
const int _maxAddressBytes = 45;

/// Where the receiver is listening, and the key the stream is sealed with.
class NearbyWifiEndpoint {
  NearbyWifiEndpoint({
    required this.address,
    required this.port,
    required this.key,
  }) {
    if (address.length > _maxAddressBytes ||
        InternetAddress.tryParse(address) == null) {
      throw ArgumentError.value(address, 'address');
    }
    if (port < 1 || port > 0xFFFF) throw ArgumentError.value(port, 'port');
    if (key.length != keyLen) throw ArgumentError.value(key.length, 'key');
  }

  static const int keyLen = 32;

  final String address;
  final int port;
  final Uint8List key;
}
```

Change `NearbyAnswer`:

```dart
/// Version 1: `[version:1][transferId:16][kind:1][reason:1]` — nineteen bytes.
///
/// Version 2, an acceptance with a Wi-Fi endpoint:
/// `… [addrLen:1][addr:ascii][port:2 BE][key:32]`.
class NearbyAnswer {
  NearbyAnswer({
    required this.transferId,
    required this.kind,
    this.reason = NearbyDeclineReason.user,
    this.wifi,
  }) {
    if (transferId.length != nearbyIdLen) {
      throw ArgumentError.value(transferId.length, 'transferId');
    }
    if (wifi != null && kind != NearbyAnswerKind.accepted) {
      throw ArgumentError.value(kind, 'kind', 'only an acceptance has wifi');
    }
  }

  static const int length = 1 + nearbyIdLen + 2;

  final Uint8List transferId;
  final NearbyAnswerKind kind;
  final NearbyDeclineReason reason;
  final NearbyWifiEndpoint? wifi;

  Uint8List encode() {
    final w = wifi;
    final out = BytesBuilder(copy: false)
      ..addByte(w == null ? nearbyVersion : nearbyAnswerVersionWifi)
      ..add(transferId)
      ..addByte(kind.tag)
      ..addByte(reason.tag);
    if (w != null) {
      final addr = ascii.encode(w.address);
      out
        ..addByte(addr.length)
        ..add(addr)
        ..addByte(w.port >> 8)
        ..addByte(w.port & 0xFF)
        ..add(w.key);
    }
    return out.toBytes();
  }

  static NearbyAnswer decode(Uint8List body) {
    if (body.isEmpty) throw const FormatException('nearby answer: empty');
    final version = body[0];
    if (version == nearbyVersion) {
      if (body.length != length) {
        throw FormatException('nearby answer: ${body.length} bytes');
      }
    } else if (version != nearbyAnswerVersionWifi) {
      throw const FormatException('nearby answer: unknown version');
    }
    final r = _Reader(body)..byte();
    final transferId = r.bytes(nearbyIdLen);
    final kind = NearbyAnswerKind.fromByte(r.byte());
    if (kind == null) throw const FormatException('nearby answer: kind');
    final reason = NearbyDeclineReason.fromByte(r.byte());
    NearbyWifiEndpoint? wifi;
    if (version == nearbyAnswerVersionWifi) {
      if (kind != NearbyAnswerKind.accepted) {
        throw const FormatException('nearby answer: wifi on a non-acceptance');
      }
      final addrLen = r.byte();
      if (addrLen == 0 || addrLen > _maxAddressBytes) {
        throw FormatException('nearby answer: address of $addrLen bytes');
      }
      final address = ascii.decode(r.bytes(addrLen), allowInvalid: false);
      final port = (r.byte() << 8) | r.byte();
      final key = r.bytes(NearbyWifiEndpoint.keyLen);
      if (!r.done) throw const FormatException('nearby answer: trailing bytes');
      try {
        wifi = NearbyWifiEndpoint(address: address, port: port, key: key);
      } on ArgumentError catch (e) {
        throw FormatException('nearby answer: $e');
      }
    }
    return NearbyAnswer(
      transferId: transferId,
      kind: kind,
      reason: reason,
      wifi: wifi,
    );
  }
}
```

`ascii.decode` throws `FormatException` on non-ASCII already, which is what we want.

- [ ] **Step 4: Run** `flutter test test/nearby_offer_test.dart test/airdrop_controller_test.dart test/airdrop_transport_test.dart` — Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/transport/nearby_offer.dart test/nearby_offer_test.dart
git commit -m "An AirDrop acceptance can say where on the local network to send the files

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: The Wi‑Fi stream's records, sealed in batches off the UI isolate

**Files:**
- Create: `lib/features/airdrop/data/wifi_lane_codec.dart`
- Test: `test/wifi_lane_codec_test.dart`

**Interfaces:**
- Produces:
  - `enum WifiRecordKind { hello(0x01), fileStart(0x02), data(0x03), fileEnd(0x04), fileKept(0x05), fileRefused(0x06) }` with `final int tag;`
  - `class WifiRecord { const WifiRecord(this.kind, this.body); final WifiRecordKind kind; final Uint8List body; }`
  - `enum WifiDirection { toReceiver(0x00), toSender(0x01) }` — first nonce byte, so each direction has its own nonce space under one key.
  - `class WifiLaneCipher { WifiLaneCipher(Uint8List key, WifiDirection direction); Future<List<Uint8List>> seal(List<WifiRecord> records); Future<List<WifiRecord>> open(List<Uint8List> sealed); }` — each sealed item is `ciphertext‖tag` for one record; counters advance per record and are never reused.
  - `class WifiRecordFramer { void add(Uint8List bytes); List<Uint8List> take(); }` — splits `[len:4 BE][sealed]`; throws `FormatException` when `len > WifiLaneCodec.maxSealed`.
  - `abstract final class WifiLaneCodec { static const int dataBytes = 64 * 1024; static const int maxSealed = 1 + dataBytes + 16 + 64; static Uint8List frame(Uint8List sealed); }`

- [ ] **Step 1: Write the failing tests** — `test/wifi_lane_codec_test.dart`:

```dart
import 'dart:typed_data';

import 'package:cubechat/features/airdrop/data/wifi_lane_codec.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _key([int seed = 1]) =>
    Uint8List.fromList(List.generate(32, (i) => (i * 7 + seed) & 0xFF));

WifiRecord _data(int n, int fill) =>
    WifiRecord(WifiRecordKind.data, Uint8List(n)..fillRange(0, n, fill));

void main() {
  test('records round-trip in order, big ones through the isolate', () async {
    final tx = WifiLaneCipher(_key(), WifiDirection.toReceiver);
    final rx = WifiLaneCipher(_key(), WifiDirection.toReceiver);
    final records = [
      WifiRecord(WifiRecordKind.hello, Uint8List.fromList([1, 2, 3])),
      _data(WifiLaneCodec.dataBytes, 0xAB),
      _data(10, 0xCD),
      const WifiRecord(WifiRecordKind.fileEnd, Uint8List.fromList([])),
    ];
    final opened = await rx.open(await tx.seal(records));
    expect([for (final r in opened) r.kind], [for (final r in records) r.kind]);
    expect(opened[1].body, records[1].body);
    expect(opened[2].body, records[2].body);
  });

  test('a flipped byte is refused', () async {
    final tx = WifiLaneCipher(_key(), WifiDirection.toReceiver);
    final rx = WifiLaneCipher(_key(), WifiDirection.toReceiver);
    final sealed = await tx.seal([_data(100, 1)]);
    sealed[0][5] ^= 0x01;
    expect(rx.open(sealed), throwsA(isA<FormatException>()));
  });

  test('a record replayed out of order is refused', () async {
    final tx = WifiLaneCipher(_key(), WifiDirection.toReceiver);
    final rx = WifiLaneCipher(_key(), WifiDirection.toReceiver);
    final sealed = await tx.seal([_data(10, 1), _data(10, 2)]);
    expect(rx.open([sealed[1]]), throwsA(isA<FormatException>()));
  });

  test('the other direction cannot open it, nor a wrong key', () async {
    final sealed =
        await WifiLaneCipher(_key(), WifiDirection.toReceiver).seal([
      _data(10, 1),
    ]);
    expect(
      WifiLaneCipher(_key(), WifiDirection.toSender).open(sealed),
      throwsA(isA<FormatException>()),
    );
    expect(
      WifiLaneCipher(_key(2), WifiDirection.toReceiver).open(sealed),
      throwsA(isA<FormatException>()),
    );
  });

  test('the framer splits a byte stream cut anywhere', () {
    final a = Uint8List.fromList(List.generate(70, (i) => i));
    // A real sealed record is never shorter than its 16-byte tag plus the
    // kind byte, and the framer refuses one that is.
    final b = Uint8List.fromList(List.generate(20, (i) => 9));
    final stream = [...WifiLaneCodec.frame(a), ...WifiLaneCodec.frame(b)];
    final framer = WifiRecordFramer();
    final got = <Uint8List>[];
    for (var i = 0; i < stream.length; i += 5) {
      framer.add(
        Uint8List.fromList(
          stream.sublist(i, i + 5 > stream.length ? stream.length : i + 5),
        ),
      );
      got.addAll(framer.take());
    }
    expect(got, [a, b]);
  });

  test('the framer refuses an absurd length', () {
    final framer = WifiRecordFramer()
      ..add(Uint8List.fromList([0x7F, 0xFF, 0xFF, 0xFF, 0]));
    expect(framer.take, throwsFormatException);
  });
}
```

- [ ] **Step 2: Run** `flutter test test/wifi_lane_codec_test.dart` — Expected: FAIL, file missing.

- [ ] **Step 3: Implement** `lib/features/airdrop/data/wifi_lane_codec.dart`:

```dart
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// What one record on the Wi-Fi stream says. The first plaintext byte.
enum WifiRecordKind {
  /// Sender → receiver, first record: the transfer id, proving the key.
  hello(0x01),

  /// `[mediaId:16][size:8 BE]`.
  fileStart(0x02),

  /// Up to [WifiLaneCodec.dataBytes] of the current file.
  data(0x03),

  /// The current file is complete.
  fileEnd(0x04),

  /// Receiver → sender: `[mediaId:16]` was kept where AirDrop keeps files.
  fileKept(0x05),

  /// Receiver → sender: `[mediaId:16]` was not wanted (size wrong, transfer
  /// over). The sender stops.
  fileRefused(0x06);

  const WifiRecordKind(this.tag);
  final int tag;

  static WifiRecordKind? fromByte(int b) {
    for (final v in values) {
      if (v.tag == b) return v;
    }
    return null;
  }
}

class WifiRecord {
  const WifiRecord(this.kind, this.body);
  final WifiRecordKind kind;
  final Uint8List body;
}

/// First nonce byte. One key serves both directions of one transfer; this
/// byte keeps their counters from ever producing the same nonce.
enum WifiDirection {
  toReceiver(0x00),
  toSender(0x01);

  const WifiDirection(this.tag);
  final int tag;
}

abstract final class WifiLaneCodec {
  /// 64 KiB of file per record: a 1 MiB read is sixteen records sealed in one
  /// isolate hop, and the 17-byte overhead is 0.03%.
  static const int dataBytes = 64 * 1024;

  /// Largest sealed record the reader will buffer: kind byte, data, tag, and
  /// slack for the largest control body. Anything longer is an attack or a
  /// bug, and the connection is dropped.
  static const int maxSealed = 1 + dataBytes + 16 + 64;

  static Uint8List frame(Uint8List sealed) {
    final out = Uint8List(4 + sealed.length);
    ByteData.sublistView(out).setUint32(0, sealed.length);
    out.setRange(4, out.length, sealed);
    return out;
  }
}

/// ChaCha20-Poly1305 over one direction of the stream. The nonce is
/// `[direction:1][0:3][counter:8 BE]`: counting records means a replayed,
/// dropped or reordered record fails to open rather than being taken.
///
/// Batches at or over [_offloadBytes] are sealed in [Isolate.run] — the same
/// reasoning and threshold as `MediaFsCipher.offloadBytes`, measured in 1106:
/// crypto on the UI isolate was the heat and the lag of sending a video.
class WifiLaneCipher {
  WifiLaneCipher(Uint8List key, this._direction)
      : _key = Uint8List.fromList(key);

  final Uint8List _key;
  final WifiDirection _direction;
  int _counter = 0;

  static const int _offloadBytes = 16 * 1024;

  Future<List<Uint8List>> seal(List<WifiRecord> records) async {
    final plains = [
      for (final r in records)
        (Uint8List(1 + r.body.length)
          ..[0] = r.kind.tag
          ..setRange(1, 1 + r.body.length, r.body)),
    ];
    final start = _counter;
    _counter += plains.length;
    final size = plains.fold<int>(0, (s, p) => s + p.length);
    final key = _key;
    final dir = _direction.tag;
    return size >= _offloadBytes
        ? Isolate.run(() => _sealAll(key, dir, start, plains))
        : _sealAll(key, dir, start, plains);
  }

  Future<List<WifiRecord>> open(List<Uint8List> sealed) async {
    final start = _counter;
    _counter += sealed.length;
    final size = sealed.fold<int>(0, (s, p) => s + p.length);
    final key = _key;
    final dir = _direction.tag;
    final plains = size >= _offloadBytes
        ? await Isolate.run(() => _openAll(key, dir, start, sealed))
        : await _openAll(key, dir, start, sealed);
    return [
      for (final p in plains)
        WifiRecord(
          WifiRecordKind.fromByte(p[0]) ??
              (throw FormatException('wifi lane: record kind ${p[0]}')),
          Uint8List.sublistView(p, 1),
        ),
    ];
  }

  static List<int> _nonce(int dir, int counter) {
    final n = Uint8List(12)..[0] = dir;
    ByteData.sublistView(n).setUint64(4, counter);
    return n;
  }

  static Future<List<Uint8List>> _sealAll(
    Uint8List key,
    int dir,
    int start,
    List<Uint8List> plains,
  ) async {
    final aead = Chacha20.poly1305Aead();
    final secret = SecretKey(key);
    final out = <Uint8List>[];
    for (var i = 0; i < plains.length; i++) {
      final box = await aead.encrypt(
        plains[i],
        secretKey: secret,
        nonce: _nonce(dir, start + i),
      );
      out.add(
        Uint8List.fromList([...box.cipherText, ...box.mac.bytes]),
      );
    }
    return out;
  }

  static Future<List<Uint8List>> _openAll(
    Uint8List key,
    int dir,
    int start,
    List<Uint8List> sealed,
  ) async {
    final aead = Chacha20.poly1305Aead();
    final secret = SecretKey(key);
    final out = <Uint8List>[];
    for (var i = 0; i < sealed.length; i++) {
      final s = sealed[i];
      if (s.length < 17) throw const FormatException('wifi lane: short record');
      try {
        final plain = await aead.decrypt(
          SecretBox(
            s.sublist(0, s.length - 16),
            nonce: _nonce(dir, start + i),
            mac: Mac(s.sublist(s.length - 16)),
          ),
          secretKey: secret,
        );
        out.add(Uint8List.fromList(plain));
      } on SecretBoxAuthenticationError {
        throw const FormatException('wifi lane: record failed to open');
      }
    }
    return out;
  }
}

/// Cuts a TCP byte stream into sealed records.
class WifiRecordFramer {
  final BytesBuilder _buf = BytesBuilder(copy: false);
  Uint8List _pending = Uint8List(0);

  void add(Uint8List bytes) => _buf.add(bytes);

  List<Uint8List> take() {
    if (_buf.isNotEmpty) {
      _pending = Uint8List.fromList([..._pending, ..._buf.takeBytes()]);
    }
    final out = <Uint8List>[];
    var at = 0;
    while (_pending.length - at >= 4) {
      final len = ByteData.sublistView(_pending, at, at + 4).getUint32(0);
      if (len > WifiLaneCodec.maxSealed || len < 17) {
        throw FormatException('wifi lane: record of $len bytes');
      }
      if (_pending.length - at - 4 < len) break;
      out.add(Uint8List.fromList(_pending.sublist(at + 4, at + 4 + len)));
      at += 4 + len;
    }
    _pending = Uint8List.fromList(_pending.sublist(at));
    return out;
  }
}
```

- [ ] **Step 4: Run** `flutter test test/wifi_lane_codec_test.dart` — Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/features/airdrop/data/wifi_lane_codec.dart test/wifi_lane_codec_test.dart
git commit -m "The AirDrop Wi-Fi stream seals its records in batches, off the UI isolate

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: A receiver that takes one proven connection, and a sender that feeds it

**Files:**
- Create: `lib/features/airdrop/data/wifi_lane.dart`
- Test: `test/wifi_lane_test.dart`

**Interfaces:**
- Consumes: Task 2's `WifiLaneCipher`, `WifiRecord`, `WifiRecordKind`, `WifiRecordFramer`, `WifiLaneCodec`, `WifiDirection`; Task 1's `NearbyWifiEndpoint`, `nearbyHex`, `nearbyUnhex`.
- Produces:

```dart
typedef WifiProgress = void Function(String mediaIdHex, int done, int total);

/// Asked when a file is whole on disk. True when AirDrop kept it.
typedef WifiKeep = Future<bool> Function(String mediaIdHex, File file);

class WifiLaneReceiver {
  static Future<WifiLaneReceiver> start({
    required InternetAddress address,
    required Uint8List key,
    required Uint8List transferId,
    required Map<String, int> expected,      // mediaIdHex → size from the offer
    required Directory tempDir,
    required WifiProgress onProgress,
    required WifiKeep onFile,
    void Function()? onConnected,
    Duration idle = const Duration(minutes: 2),
  });
  int get port;
  Future<void> get done;   // completes when every expected file was kept, or on close
  Future<void> close();
}

class WifiLaneSender {
  static Future<WifiLaneSender?> connect({
    required NearbyWifiEndpoint endpoint,
    required Uint8List transferId,
    Duration timeout = const Duration(seconds: 5),
  });
  /// True when the receiver answered fileKept for it.
  Future<bool> sendFile({
    required String mediaIdHex,
    required File file,
    required int size,
    required WifiProgress onProgress,
    required bool Function() cancelled,
  });
  Future<void> close();
}

/// What the controller uses — a fake in tests.
abstract interface class AirDropWifi {
  Future<InternetAddress?> localAddress();
  Future<WifiLaneReceiver> startReceiver({...same named args as WifiLaneReceiver.start...});
  Future<WifiLaneSender?> connect({required NearbyWifiEndpoint endpoint, required Uint8List transferId});
}
final airdropWifiProvider = Provider<AirDropWifi>((_) => const IoAirDropWifi());

/// Pure, tested: the address to offer, from what the phone's interfaces are.
InternetAddress? pickLanAddress(List<({String name, InternetAddress address})> candidates);
```

- [ ] **Step 1: Write the failing tests** — `test/wifi_lane_test.dart`:

```dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cubechat/core/transport/nearby_offer.dart';
import 'package:cubechat/features/airdrop/data/wifi_lane.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _bytes(int n, [int seed = 0]) =>
    Uint8List.fromList(List.generate(n, (i) => (i * 31 + seed) & 0xFF));

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('wifi-lane'));
  tearDown(() async => tmp.delete(recursive: true));

  final key = _bytes(32, 5);
  final tid = _bytes(16, 9);
  final loop = InternetAddress.loopbackIPv4;

  Future<File> source(String name, int size, int seed) async =>
      File('${tmp.path}/$name')..writeAsBytesSync(_bytes(size, seed));

  test('two files arrive whole, in order, and are kept', () async {
    final a = await source('a.bin', 200 * 1024 + 7, 1);
    final b = await source('b.bin', 10, 2);
    final kept = <String, Uint8List>{};
    final rxDir = await Directory('${tmp.path}/rx').create();
    final rx = await WifiLaneReceiver.start(
      address: loop,
      key: key,
      transferId: tid,
      expected: {'aa' * 16: 200 * 1024 + 7, 'bb' * 16: 10},
      tempDir: rxDir,
      onProgress: (_, __, ___) {},
      onFile: (id, f) async {
        kept[id] = await f.readAsBytes();
        return true;
      },
    );
    final tx = await WifiLaneSender.connect(
      endpoint: NearbyWifiEndpoint(
        address: loop.address,
        port: rx.port,
        key: key,
      ),
      transferId: tid,
    );
    expect(tx, isNotNull);
    expect(
      await tx!.sendFile(
        mediaIdHex: 'aa' * 16,
        file: a,
        size: 200 * 1024 + 7,
        onProgress: (_, __, ___) {},
        cancelled: () => false,
      ),
      isTrue,
    );
    expect(
      await tx.sendFile(
        mediaIdHex: 'bb' * 16,
        file: b,
        size: 10,
        onProgress: (_, __, ___) {},
        cancelled: () => false,
      ),
      isTrue,
    );
    await rx.done.timeout(const Duration(seconds: 5));
    expect(kept['aa' * 16], await a.readAsBytes());
    expect(kept['bb' * 16], await b.readAsBytes());
    await tx.close();
  });

  test('a connection with the wrong key is dropped, the right one still gets in',
      () async {
    final rx = await WifiLaneReceiver.start(
      address: loop,
      key: key,
      transferId: tid,
      expected: {'aa' * 16: 3},
      tempDir: tmp,
      onProgress: (_, __, ___) {},
      onFile: (_, __) async => true,
    );
    final intruder = await WifiLaneSender.connect(
      endpoint: NearbyWifiEndpoint(
        address: loop.address,
        port: rx.port,
        key: _bytes(32, 77),
      ),
      transferId: tid,
    );
    // The receiver refuses the hello and closes that socket; sending fails.
    final f = await source('x.bin', 3, 3);
    expect(
      await intruder?.sendFile(
            mediaIdHex: 'aa' * 16,
            file: f,
            size: 3,
            onProgress: (_, __, ___) {},
            cancelled: () => false,
          ) ??
          false,
      isFalse,
    );
    final real = await WifiLaneSender.connect(
      endpoint: NearbyWifiEndpoint(
        address: loop.address,
        port: rx.port,
        key: key,
      ),
      transferId: tid,
    );
    expect(
      await real!.sendFile(
        mediaIdHex: 'aa' * 16,
        file: f,
        size: 3,
        onProgress: (_, __, ___) {},
        cancelled: () => false,
      ),
      isTrue,
    );
    await real.close();
    await rx.close();
  });

  test('a file that is not the size offered is refused', () async {
    final rx = await WifiLaneReceiver.start(
      address: loop,
      key: key,
      transferId: tid,
      expected: {'aa' * 16: 5},
      tempDir: tmp,
      onProgress: (_, __, ___) {},
      onFile: (_, __) async => true,
    );
    final tx = await WifiLaneSender.connect(
      endpoint:
          NearbyWifiEndpoint(address: loop.address, port: rx.port, key: key),
      transferId: tid,
    );
    final f = await source('y.bin', 9, 1);
    expect(
      await tx!.sendFile(
        mediaIdHex: 'aa' * 16,
        file: f,
        size: 9,
        onProgress: (_, __, ___) {},
        cancelled: () => false,
      ),
      isFalse,
    );
    await tx.close();
    await rx.close();
  });

  test('nobody listening: connect gives up within the timeout', () async {
    final free = await ServerSocket.bind(loop, 0);
    final port = free.port;
    await free.close();
    final sw = Stopwatch()..start();
    final tx = await WifiLaneSender.connect(
      endpoint: NearbyWifiEndpoint(address: loop.address, port: port, key: key),
      transferId: tid,
      timeout: const Duration(seconds: 1),
    );
    expect(tx, isNull);
    expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
  });

  test('cancelling mid-file stops and reports false', () async {
    final rx = await WifiLaneReceiver.start(
      address: loop,
      key: key,
      transferId: tid,
      expected: {'aa' * 16: 3 * 1024 * 1024},
      tempDir: tmp,
      onProgress: (_, __, ___) {},
      onFile: (_, __) async => true,
    );
    final tx = await WifiLaneSender.connect(
      endpoint:
          NearbyWifiEndpoint(address: loop.address, port: rx.port, key: key),
      transferId: tid,
    );
    final f = await source('big.bin', 3 * 1024 * 1024, 4);
    var calls = 0;
    expect(
      await tx!.sendFile(
        mediaIdHex: 'aa' * 16,
        file: f,
        size: 3 * 1024 * 1024,
        onProgress: (_, __, ___) {},
        cancelled: () => ++calls > 1,
      ),
      isFalse,
    );
    await tx.close();
    await rx.close();
  });

  test('the receiver closes itself after the idle time', () async {
    final rx = await WifiLaneReceiver.start(
      address: loop,
      key: key,
      transferId: tid,
      expected: {'aa' * 16: 3},
      tempDir: tmp,
      onProgress: (_, __, ___) {},
      onFile: (_, __) async => true,
      idle: const Duration(milliseconds: 300),
    );
    await rx.done.timeout(const Duration(seconds: 3));
    await expectLater(
      Socket.connect(loop, rx.port, timeout: const Duration(seconds: 1)),
      throwsA(isA<SocketException>()),
    );
  });

  group('pickLanAddress', () {
    InternetAddress ip(String s) => InternetAddress(s);
    test('Wi-Fi over cellular, private IPv4 first', () {
      expect(
        pickLanAddress([
          (name: 'rmnet_data0', address: ip('10.77.1.2')),
          (name: 'wlan0', address: ip('fe80::1')),
          (name: 'wlan0', address: ip('192.168.1.23')),
        ])?.address,
        '192.168.1.23',
      );
    });
    test('a phone sharing its hotspot offers the hotspot address', () {
      expect(
        pickLanAddress([
          (name: 'pdp_ip0', address: ip('100.64.0.5')),
          (name: 'bridge100', address: ip('172.20.10.1')),
        ])?.address,
        '172.20.10.1',
      );
    });
    test('nothing but cellular and link-local: null', () {
      expect(
        pickLanAddress([
          (name: 'ccmni0', address: ip('10.1.1.1')),
          (name: 'wlan0', address: ip('169.254.3.3')),
        ]),
        isNull,
      );
    });
  });
}
```

- [ ] **Step 2: Run** `flutter test test/wifi_lane_test.dart` — Expected: FAIL, file missing.

- [ ] **Step 3: Implement** `lib/features/airdrop/data/wifi_lane.dart`. Behaviour the code must have (write it as one file, ~300 lines):

```dart
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/transport/nearby_offer.dart';
import '../../../core/util/debug_log.dart';
import 'wifi_lane_codec.dart';

typedef WifiProgress = void Function(String mediaIdHex, int done, int total);
typedef WifiKeep = Future<bool> Function(String mediaIdHex, File file);

/// Interfaces a phone never offers: cellular, VPN, tunnels. Names from
/// Android (`rmnet`, `ccmni`, `clat`), iOS (`pdp_ip`, `utun`, `ipsec`).
const _notLocal = ['rmnet', 'ccmni', 'pdp_ip', 'clat', 'v4-', 'tun', 'utun', 'ipsec', 'dummy', 'lo'];

InternetAddress? pickLanAddress(
  List<({String name, InternetAddress address})> candidates,
) {
  bool usable(({String name, InternetAddress address}) c) {
    final n = c.name.toLowerCase();
    if (_notLocal.any(n.startsWith)) return false;
    final a = c.address;
    if (a.isLoopback || a.isLinkLocal || a.isMulticast) return false;
    return true;
  }

  bool private4(InternetAddress a) {
    if (a.type != InternetAddressType.IPv4) return false;
    final b = a.rawAddress;
    return b[0] == 10 ||
        (b[0] == 172 && b[1] >= 16 && b[1] < 32) ||
        (b[0] == 192 && b[1] == 168);
  }

  final ok = candidates.where(usable).toList();
  for (final c in ok) {
    if (private4(c.address)) return c.address;
  }
  for (final c in ok) {
    if (c.address.type == InternetAddressType.IPv4) return c.address;
  }
  return ok.isEmpty ? null : ok.first.address;
}
```

`WifiLaneReceiver.start`:
1. `ServerSocket.bind(address, 0)`; arm an idle `Timer(idle, close)` that is re-armed on every byte received.
2. For each incoming socket while none is **proven**: new `WifiLaneCipher(key, toReceiver)` and `WifiLaneCipher(key, toSender)` pair and a `WifiRecordFramer`. On data: `framer.add`, `framer.take()`, `open()` the batch. If opening fails, or the first record is not `hello` with body equal to `transferId` → `socket.destroy()` and keep listening (log `AIRDROP wifi: refused a connection`). The first socket that proves itself becomes the only one; later sockets are destroyed on arrival. Call `onConnected`.
3. Proven socket, per record: `fileStart` → body is 24 bytes; `mediaIdHex = nearbyHex(body[0..16])`, `size` = u64 BE; refuse (send `fileRefused`, then close) when `expected[mediaIdHex] != size`; else open `File('${tempDir.path}/wifi-$mediaIdHex.part')` for write. `data` → append, count, `onProgress(id, received, size)` at most every 250 ms and at the end; refuse when `received > size`. `fileEnd` → flush and close; if `received != size` refuse; else `await onFile(id, file)` → send `fileKept` or `fileRefused` with the 16-byte id; remove from `expected`; when `expected` is empty complete `done` and close.
4. Records are processed strictly in order: chain every batch onto a `Future` (`_queue = _queue.then(...)`) so an isolate-opened batch cannot overtake the next one; pause the socket subscription while a batch is being opened and resume after (backpressure).
5. `close()`: cancel timer, close the server, destroy the socket, delete any `.part` files, complete `done` if not yet.

`WifiLaneSender.connect`: `Socket.connect(host, port, timeout: timeout)`, catching `SocketException`/`TimeoutException` → `null`. `socket.setOption(SocketOption.tcpNoDelay, true)`. Seal and write `hello(transferId)`. Listen on the socket through a framer + `toSender` cipher, turning `fileKept`/`fileRefused` records into completions of a `Map<String, Completer<bool>>`; `onDone`/`onError` completes every pending completer with `false`.

`sendFile`: register completer; write `fileStart`; read the file with `file.openRead()` in 1 MiB slices (use a `RandomAccessFile` and `read(1 << 20)`), cut each slice into `WifiLaneCodec.dataBytes` records, `seal` the slice's records in one call, write each as `WifiLaneCodec.frame(sealed)`, `await socket.flush()`, report `onProgress`, check `cancelled()` before every slice (cancelled → `close()` and return `false`). Then `fileEnd`, and `await completer.future.timeout(const Duration(seconds: 30), onTimeout: () => false)`. Any `SocketException` → `false`.

`IoAirDropWifi.localAddress()`:

```dart
  @override
  Future<InternetAddress?> localAddress() async {
    try {
      final list = await NetworkInterface.list(includeLinkLocal: false);
      return pickLanAddress([
        for (final i in list)
          for (final a in i.addresses) (name: i.name, address: a),
      ]);
    } on SocketException {
      return null;
    }
  }
```

`startReceiver`/`connect` delegate to the statics. The `Random.secure()` key is made by the controller, not here.

- [ ] **Step 4: Run** `flutter test test/wifi_lane_test.dart` — Expected: PASS (9 tests). If the loopback tests hang, the ordering chain in step 3.4 is missing a `resume()`.

- [ ] **Step 5: Commit**

```bash
git add lib/features/airdrop/data/wifi_lane.dart test/wifi_lane_test.dart
git commit -m "AirDrop can move files over the local network, to one connection that proves the key

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: "Channel: Auto / Bluetooth / Wi‑Fi"

**Files:**
- Create: `lib/features/airdrop/data/airdrop_lane_controller.dart`
- Modify: `lib/core/identity/wipe_service.dart` (reset beside `airdropReceiveProvider` at line ~116)
- Test: `test/airdrop_lane_controller_test.dart`

**Interfaces:**
- Produces: `enum AirDropLane { auto, bluetooth, wifi }`; `final airdropLaneProvider = NotifierProvider<AirDropLaneController, AirDropLane>(...)`; `Future<void> set(AirDropLane lane)`; `Future<void> reset()`; `Future<void> get loaded`; storage key `'airdrop.lane'` storing `lane.name`.

- [ ] **Step 1: Write the failing test.** Copy the Hive harness used by `test/airdrop_storage_test.dart` / the receive-controller tests (read one first: `grep -ln airdropReceiveProvider test/`). Tests: default is `auto`; `set(wifi)` survives a new `ProviderContainer` over the same box; an unknown stored string reads as `auto`; `reset()` returns to `auto` and deletes the key.

- [ ] **Step 2: Run** — FAIL (file missing).

- [ ] **Step 3: Implement** — same shape as `AirDropReceiveController` (`lib/features/airdrop/data/airdrop_receive_controller.dart`): open `HiveBoxes.settings` through `hiveCipherProvider.openEncryptedBox`, read `'airdrop.lane'`, `AirDropLane.values.asNameMap()[raw] ?? AirDropLane.auto`. Doc comment: the sender's setting decides; `wifi` means "fail rather than crawl over Bluetooth". In `wipe_service.dart` add `await ref.read(airdropLaneProvider.notifier).reset();` after the receive reset.

- [ ] **Step 4: Run** the new test and `flutter test test/wipe_service_test.dart` if it exists — PASS.

- [ ] **Step 5: Commit** — "AirDrop remembers which channel to send files over".

---

### Task 5: The controller sends and receives over Wi‑Fi, and falls back

**Files:**
- Modify: `lib/features/airdrop/domain/airdrop_transfer.dart`
- Modify: `lib/features/airdrop/data/airdrop_controller.dart`
- Test: `test/airdrop_controller_test.dart` (extend `_Port`; add `_Wifi` fake and a group)

**Interfaces:**
- Consumes: Tasks 1, 3, 4.
- Produces: `AirDropTransfer.wifi` (bool, default false — "files are moving over the local network") and `AirDropTransfer.wifiUnreachable` (bool, default false — a Wi‑Fi-only send that could not connect); both in `copyWith`.

- [ ] **Step 1: Add the fields** to `AirDropTransfer` (constructor `this.wifi = false, this.wifiUnreachable = false`, finals, `copyWith({bool? wifi, bool? wifiUnreachable})` passing `wifi ?? this.wifi` etc.). No test of its own — covered below.

- [ ] **Step 2: Write the failing controller tests.** In `test/airdrop_controller_test.dart` add a fake:

```dart
class _Wifi implements AirDropWifi {
  InternetAddress? address = InternetAddress('192.168.1.5');
  final started = <Map<String, int>>[];
  WifiKeep? keep;
  bool connectWorks = true;
  final sentOverWifi = <String>[];
  final failFiles = <String>{};

  @override
  Future<InternetAddress?> localAddress() async => address;

  @override
  Future<WifiLaneReceiver> startReceiver({
    required InternetAddress address,
    required Uint8List key,
    required Uint8List transferId,
    required Map<String, int> expected,
    required Directory tempDir,
    required WifiProgress onProgress,
    required WifiKeep onFile,
    void Function()? onConnected,
    Duration idle = const Duration(minutes: 2),
  }) async {
    started.add(expected);
    keep = onFile;
    return _FakeReceiver();
  }

  @override
  Future<WifiLaneSender?> connect({
    required NearbyWifiEndpoint endpoint,
    required Uint8List transferId,
  }) async =>
      connectWorks ? _FakeSender(this) : null;
}
```

`_FakeReceiver` and `_FakeSender` need to satisfy the types: make `WifiLaneReceiver` and `WifiLaneSender` in Task 3 non-final classes with the statics as factories, and in the test `implements` them (`port => 4000`, `done => Completer<void>().future`, `close() async {}`; sender `sendFile` records the id in `sentOverWifi` and returns `!failFiles.contains(id)`).

Override in the test container: `airdropWifiProvider.overrideWithValue(wifi)`, `airdropLaneProvider` default (`auto`), and a temp-dir override for wherever the controller asks for the `.part` directory (use `airdropDirectoryProvider` from `airdrop_storage.dart`).

Tests (each in `fakeAsync` like the existing ones; flush with `async.flushMicrotasks()`):

1. **offer sets the Wi‑Fi flag unless the lane is Bluetooth** — `offer(...)`; `port.sent.last.offer!.flags & nearbyFlagWifi` is 1; set lane `bluetooth`, new offer, flag is 0.
2. **accepting a flagged offer answers with an endpoint** — deliver `_offer(1)` with `flags: nearbyFlagWifi`; `accept(id)`; the last answer is `accepted` with `wifi!.address == '192.168.1.5'`, `port == 4000`, key length 32; `wifi.started.single` maps both media ids to size 10.
3. **no local address: a plain acceptance** — `wifi.address = null`; accept; `answer.wifi` is null; `wifi.started` empty.
4. **an unflagged offer never opens a port** — deliver `_offer(2)` (flags 0); accept; `wifi.started` empty.
5. **sender streams over Wi‑Fi when the endpoint answers** — `offer`, then `port.answer(_bob, tid, accepted)` with an endpoint; flush; `wifi.sentOverWifi` has both ids; `port.filesSent` is empty; transfer finished `done`; `state.byId` gone and history has `sent`.
6. **Auto falls back to Bluetooth when connect fails** — `wifi.connectWorks = false`; answer with endpoint; both ids in `port.filesSent`.
7. **Auto falls back mid-way** — `wifi.failFiles = {second}`; first in `sentOverWifi`, second in `port.filesSent`.
8. **Wi‑Fi-only fails instead** — lane `wifi`, `connectWorks = false`; history outcome `failed`, and before `_finish`, the transfer carried `wifiUnreachable: true` (assert via a listener capturing states).
9. **a Wi‑Fi file lands through keep()** — after test 2's accept, call `await wifi.keep!(mediaHex, tempFile)`; returns true; transfer file marked done with a path inside the AirDrop directory.

- [ ] **Step 3: Run** `flutter test test/airdrop_controller_test.dart` — the new tests FAIL.

- [ ] **Step 4: Implement** in `airdrop_controller.dart`:

Fields:

```dart
  /// Incoming transfer id → the port it listens on, while it is open.
  final Map<String, WifiLaneReceiver> _receivers = {};

  /// Incoming transfer ids whose sender can take Wi-Fi (offer flag bit 0).
  final Set<String> _senderCanWifi = {};

  /// Outgoing transfer id → where the receiver said to connect.
  final Map<String, NearbyWifiEndpoint> _endpoints = {};

  /// Outgoing transfer id → the open connection.
  final Map<String, WifiLaneSender> _senders = {};

  AirDropWifi get _wifi => ref.read(airdropWifiProvider);
```

`offer()`: `flags: ref.read(airdropLaneProvider) == AirDropLane.bluetooth ? 0 : nearbyFlagWifi` on the `NearbyOffer`.

`_onOffer()`: after the `request` is built and before `_put(request)`: `if (offer.flags & nearbyFlagWifi != 0) _senderCanWifi.add(id);`.

`accept()` — replace the final `_port.send(... accepted ...)` with:

```dart
    final wifi = _senderCanWifi.remove(id) ? await _openReceiver(t) : null;
    await _port.send(
      t.peerHex,
      answer: NearbyAnswer(
        transferId: nearbyUnhex(id),
        kind: NearbyAnswerKind.accepted,
        wifi: wifi,
      ),
    );
```

and add:

```dart
  /// A port for the files of [t], or null when this phone is on no local
  /// network (then they come over Bluetooth, as in part 1). The receiver
  /// agrees to Wi-Fi whatever its own setting: it costs it nothing.
  Future<NearbyWifiEndpoint?> _openReceiver(AirDropTransfer t) async {
    final address = await _wifi.localAddress();
    if (address == null) return null;
    final key = Uint8List.fromList(
      List<int>.generate(NearbyWifiEndpoint.keyLen, (_) => _random.nextInt(256)),
    );
    try {
      final rx = await _wifi.startReceiver(
        address: address,
        key: key,
        transferId: nearbyUnhex(t.id),
        expected: {for (final f in t.files) f.mediaIdHex: f.size},
        tempDir: await ref.read(airdropDirectoryProvider)(),
        onConnected: () => _update(t.id, (x) => x.copyWith(wifi: true)),
        onProgress: (id, done, total) => _trackIncoming(t, id, done, total),
        onFile: (id, file) async =>
            await keep(
              mediaIdHex: id,
              senderHex: t.peerHex,
              file: file,
              name: id,
            ) !=
            null,
      );
      _receivers[t.id] = rx;
      return NearbyWifiEndpoint(
        address: address.address,
        port: rx.port,
        key: key,
      );
    } on SocketException catch (e) {
      DebugLog.instance.log('AIRDROP', 'wifi: could not listen: $e');
      return null;
    }
  }
```

`_trackIncoming(t, mediaIdHex, done, total)`: if `fileTransferControllerProvider` has no task for `mediaIdHex`, `register(FileTransferTask(id: mediaIdHex, chatId: t.peerHex, fileName: <offered name>, filePath: '', mime: <offered mime>, bytesTotal: total, completedUnits: 0, totalUnits: total, direction: FileTransferDirection.incoming, status: FileTransferStatus.transferring, createdAt: _now, updatedAt: _now, source: FileTransferSource.airdrop, peerName: t.peerName))`; then `setProgress(mediaIdHex, done, total)`. `_noteProgress` already turns that into `_lastProgress`, so the stall timer works unchanged. After `keep` succeeds, call `complete(mediaIdHex, filePath: path, bytesTotal: size)` — put that in the `onFile` closure when `keep` returned a path.

`_onAnswer()`: at the top of the outgoing branch, before `onAnswer`: `if (a.kind == NearbyAnswerKind.accepted && a.wifi != null) _endpoints[t.id] = a.wifi!;`.

`_pump(id)` — at its start, before the loop:

```dart
    final endpoint = _endpoints.remove(id);
    final lane = ref.read(airdropLaneProvider);
    if (endpoint != null && lane != AirDropLane.bluetooth) {
      final tx = await _wifi.connect(
        endpoint: endpoint,
        transferId: nearbyUnhex(id),
      );
      final now = state.byId(id);
      if (now == null || now.phase != AirDropPhase.transferring) {
        await tx?.close();
        return;
      }
      if (tx != null) {
        _senders[id] = tx;
        _update(id, (x) => x.copyWith(wifi: true));
      } else if (lane == AirDropLane.wifi) {
        _finish(now.copyWith(phase: AirDropPhase.failed, wifiUnreachable: true));
        unawaited(_port.send(now.peerHex, answer: NearbyAnswer(
          transferId: nearbyUnhex(id),
          kind: NearbyAnswerKind.cancelled,
        )));
        return;
      } else {
        DebugLog.instance.log('AIRDROP', 'wifi: no route to ${_short(now.peerHex)} — Bluetooth');
      }
    }
```

In the loop, replace the single `_port.sendFile` call with:

```dart
      final tx = _senders[id];
      var ok = false;
      if (tx != null) {
        _trackOutgoing(t, current);
        ok = await tx.sendFile(
          mediaIdHex: current.mediaIdHex,
          file: source,
          size: current.size,
          onProgress: (m, done, total) => ref
              .read(fileTransferControllerProvider.notifier)
              .setProgress(m, done, total),
          cancelled: () =>
              ref.read(fileTransferControllerProvider)[current.mediaIdHex]
                  ?.status ==
              FileTransferStatus.canceled,
        );
        if (!ok) {
          await _senders.remove(id)?.close();
          final canceled = ref.read(fileTransferControllerProvider)[current.mediaIdHex]?.status ==
              FileTransferStatus.canceled;
          final latest = state.byId(id);
          if (canceled && latest != null) {
            _stop(latest, tell: true);
            return;
          }
          if (ref.read(airdropLaneProvider) != AirDropLane.wifi) {
            DebugLog.instance.log('AIRDROP', 'wifi: "${current.name}" failed — rest over Bluetooth');
            _update(id, (x) => x.copyWith(wifi: false));
            continue; // the same file again, now over Bluetooth
          }
        } else {
          ref.read(fileTransferControllerProvider.notifier).complete(current.mediaIdHex);
        }
      } else {
        ok = await _port.sendFile(t.peerHex, file: source, meta: current, peerName: t.peerName);
      }
```

(keep the existing `after`/`!ok`/`onFileDone` lines below it). `_trackOutgoing(t, f)` registers an outgoing `FileTransferTask` exactly as `_trackIncoming` does, with `direction: FileTransferDirection.outgoing`, `filePath: _sources[f.mediaIdHex]!.path`.

Cleanup: in `_finish(t)` add `unawaited(_receivers.remove(t.id)?.close()); unawaited(_senders.remove(t.id)?.close()); _endpoints.remove(t.id); _senderCanWifi.remove(t.id);`. In `_cancelRunning(t)` add `unawaited(_senders.remove(t.id)?.close());`. In `clearAll()` close and clear all four maps. In `build()`'s `onDispose` close every receiver and sender.

- [ ] **Step 5: Run** `flutter test test/airdrop_controller_test.dart test/airdrop_transfer_test.dart test/airdrop_page_test.dart` — PASS, including every part-1 test.

- [ ] **Step 6: Commit** — "AirDrop sends accepted files over Wi-Fi when both phones share a network, and falls back to Bluetooth".

---

### Task 6: The channel switch, the lane icon, and the words that go with them

**Files:**
- Modify: `lib/features/airdrop/presentation/airdrop_page.dart` (a `_LaneSwitch` under `_ReceiveSwitch`)
- Modify: `lib/features/airdrop/presentation/airdrop_cards.dart` (lane icon on `AirDropProgressCard`; `wifiUnreachable` text)
- Modify: `lib/l10n/app_en.arb`, `lib/l10n/app_uk.arb`, regenerate
- Modify: `ios/Runner/Info.plist` (`NSLocalNetworkUsageDescription`)
- Modify: `docs/legal/` — the privacy policy section that lists what AirDrop uses (`grep -rn "AirDrop" docs/legal`)
- Test: `test/airdrop_page_test.dart` (extend)

- [ ] **Step 1: Failing widget tests** in `test/airdrop_page_test.dart`: (a) the page shows three segments with the l10n labels `airdropLaneAuto`, `airdropLaneBluetooth`, `airdropLaneWifi`; tapping Wi‑Fi sets `airdropLaneProvider` to `AirDropLane.wifi`. (b) a transferring outgoing transfer with `wifi: true` shows `Icons.wifi_rounded` on its card; with `wifi: false`, `Icons.bluetooth_rounded`. (c) a transfer that ended with `wifiUnreachable` is not live anymore, so test the card directly: `AirDropProgressCard(transfer: t.copyWith(phase: AirDropPhase.failed, wifiUnreachable: true))` shows `airdropWifiUnreachable`.

- [ ] **Step 2: Run** — FAIL.

- [ ] **Step 3: Implement.** Strings (en / uk):

| key | en | uk |
|---|---|---|
| `airdropLaneTitle` | Channel | Канал |
| `airdropLaneAuto` | Auto | Авто |
| `airdropLaneBluetooth` | Bluetooth | Bluetooth |
| `airdropLaneWifi` | Wi‑Fi | Wi‑Fi |
| `airdropLaneHint` | Wi‑Fi works when you are both on one network or one shares a hotspot. | Wi‑Fi працює, коли ви в одній мережі або один роздає точку доступу. |
| `airdropWifiUnreachable` | Not on the same network | Не в одній мережі |

`_LaneSwitch` uses the same segmented control `_ReceiveSwitch` uses (read that widget and reuse its private segment builder — if it is private to the file, keep both in `airdrop_page.dart`). The hint is one line of `textOnGlassDim` 12 px under it. Insert it after `_ReceiveSwitch` with `AppearAnimation(delay: AppearAnimation.stagger(1))` and shift the send button's stagger to 2.

Card: in the card's title row add `Icon(t.wifi ? Icons.wifi_rounded : Icons.bluetooth_rounded, size: 14, color: AppColors.textOnGlassDim)` for phases `transferring`/`interrupted`; when `phase == failed && wifiUnreachable` the status line reads `airdropWifiUnreachable`.

Info.plist: `Cubechat uses your local network only between your own phones and people you send files to nearby — to move a profile to a new phone, or AirDrop files over Wi‑Fi. Nothing is sent to the internet this way.`

Legal: one sentence where AirDrop is described — files may travel over the local Wi‑Fi network directly between the two phones, encrypted with a key that exists only for that transfer; no server is involved.

Run `flutter gen-l10n`.

- [ ] **Step 4: Run** `flutter test test/airdrop_page_test.dart` and `flutter analyze` — PASS / no new warnings.

- [ ] **Step 5: Commit** — "The AirDrop page picks the channel and shows which one a transfer is using".

---

## Part B — the bump gesture

### Task 7: `nearbyBump` on the wire

**Files:**
- Modify: `lib/core/transport/inner_payload.dart` (enum value + the 0xE8/0xE9 comment)
- Modify: `lib/core/transport/nearby_offer.dart` (`NearbyBump`, `NearbyInbound.bump`)
- Modify: `lib/core/transport/messaging_service.dart` (dispatch at ~7646, channel ignore list at ~6580, `sendNearbyFrame`)
- Modify: `lib/features/airdrop/data/airdrop_port.dart` (`send(..., NearbyBump? bump)`)
- Modify: `test/airdrop_controller_test.dart` `_Port.send` signature
- Modify: `.claude/skills/wire-protocol/SKILL.md` — mention 0xEA where 0xE8/0xE9 are listed, if they are
- Test: `test/nearby_offer_test.dart` (group), `test/airdrop_transport_test.dart` (one test)

**Interfaces:**
- Produces:

```dart
/// `[version:1][bumpId:16][flags:1][cardLen:2 BE][card:cardLen]`
class NearbyBump {
  NearbyBump({required Uint8List bumpId, required bool hasFiles, required Uint8List card});
  static const int maxCard = 2048;
  final Uint8List bumpId; final bool hasFiles; final Uint8List card;
  Uint8List encode();
  static NearbyBump decode(Uint8List body);
}
```

`NearbyInbound` gains `final NearbyBump? bump;`. `InnerPayloadType.nearbyBump(0xEA)`. `MessagingService.sendNearbyFrame(peerHex, {offer, answer, bump})` — exactly one non-null.

- [ ] **Step 1: Verify the byte.** Run `grep -nE "0x[0-9A-Fa-f]{2}\)" lib/core/transport/inner_payload.dart` and confirm nothing uses `0xEA`. Stop and report if something does.

- [ ] **Step 2: Failing tests** — codec: round-trip (hasFiles true/false, 300-byte card); `card.length > 2048` throws `ArgumentError`; decode refuses unknown version, truncated, trailing byte, `cardLen` past the end, empty card — all `FormatException`. Transport (`test/airdrop_transport_test.dart`, following its existing harness): a sealed `nearbyBump` from a directly-linked peer comes out of `nearbyInbound` with `bump != null` and `direct == true`.

- [ ] **Step 3: Run** — FAIL.

- [ ] **Step 4: Implement.** Enum:

```dart
  /// 0xEA verified free against this enum on 2026-09-23. "I felt your phone
  /// against mine": the bump gesture on the AirDrop page. Direct links only.
  /// An old build drops it silently, and the gesture simply does not fire.
  nearbyBump(0xEA),
```

(and move the `;` from `nearbyAnswer(0xE9)`; update the "0xEA-0xEF are still empty" comment to "0xEB-0xEF"). Codec in `nearby_offer.dart` following `NearbyOffer`'s `_Reader` style; `flags` bit 0 = `hasFiles`. In `messaging_service.dart` add `case InnerPayloadType.nearbyBump:` beside the other two in both switches; in the dispatch:

```dart
            final type = unpacked.type;
            _nearbyInbound.add(
              NearbyInbound(
                peerHex: _hexOf(senderPub),
                direct: incomingRoute == MessageRoute.bluetooth,
                offer: type == InnerPayloadType.nearbyOffer
                    ? NearbyOffer.decode(unpacked.body)
                    : null,
                answer: type == InnerPayloadType.nearbyAnswer
                    ? NearbyAnswer.decode(unpacked.body)
                    : null,
                bump: type == InnerPayloadType.nearbyBump
                    ? NearbyBump.decode(unpacked.body)
                    : null,
              ),
            );
```

`sendNearbyFrame`: assert exactly one of three; `type:` picks by which is set; `innerBody: offer?.encode() ?? answer?.encode() ?? bump!.encode()`. `AirDropController._onInbound` returns early on `m.bump != null` (the bump controller handles it). Update `_Port` in the controller test to accept `NearbyBump? bump`.

- [ ] **Step 5: Run** `flutter test test/nearby_offer_test.dart test/airdrop_transport_test.dart test/airdrop_controller_test.dart` — PASS.

- [ ] **Step 6: Commit** — "Phones can tell each other they felt a bump, over the direct link".

---

### Task 8: `ProximityTracker` — who is touching this phone

**Files:**
- Create: `lib/features/airdrop/domain/proximity_tracker.dart`
- Test: `test/proximity_tracker_test.dart`

**Interfaces:**
- Produces:

```dart
class ProximityReading {
  const ProximityReading({this.closest, this.closestRssi, this.runnerUpRssi, required this.isClose, required this.warmth});
  final String? closest; final int? closestRssi; final int? runnerUpRssi;
  final bool isClose;   // closest ≥ closeRssi and ≥ margin over runner-up
  final double warmth;  // 0 at warmRssi or below, 1 at closeRssi or above
}

class ProximityTracker {
  ProximityTracker({
    this.window = const Duration(seconds: 1),
    this.hold = const Duration(seconds: 3),
    this.closeRssi = ProximityTracker.bumpRssi,
    this.margin = ProximityTracker.bumpMargin,
    this.warmRssi = ProximityTracker.glowRssi,
  });
  static const int bumpRssi = -40;   // comment: starting value, to be replaced by the owner's measurement
  static const int bumpMargin = 15;
  static const int glowRssi = -60;
  void add(String peerHex, int rssi, DateTime at);
  void forget(String peerHex);
  void clear();
  ProximityReading read(DateTime now);
}
```

- [ ] **Step 1: Failing tests:**

```dart
import 'package:cubechat/features/airdrop/domain/proximity_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 9, 23, 12);
  DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

  test('one loud sample in a quiet second is not a bump', () {
    final p = ProximityTracker();
    for (var i = 0; i < 5; i++) {
      p.add('a', -70, at(i * 200));
    }
    p.add('a', -30, at(900));
    expect(p.read(at(1000)).isClose, isFalse);
  });

  test('a steady -35 with nobody else near is a bump', () {
    final p = ProximityTracker();
    for (var i = 0; i < 6; i++) {
      p.add('a', -35, at(i * 150));
    }
    final r = p.read(at(900));
    expect(r.isClose, isTrue);
    expect(r.closest, 'a');
    expect(r.warmth, 1.0);
  });

  test('two phones close together are not a bump', () {
    final p = ProximityTracker();
    for (var i = 0; i < 6; i++) {
      p
        ..add('a', -36, at(i * 150))
        ..add('b', -45, at(i * 150));
    }
    final r = p.read(at(900));
    expect(r.isClose, isFalse);
    expect(r.runnerUpRssi, -45);
  });

  test('silence is held for three seconds, then forgotten', () {
    final p = ProximityTracker()..add('a', -35, at(0));
    expect(p.read(at(2500)).closest, 'a');
    expect(p.read(at(3500)).closest, isNull);
  });

  test('warmth rises from -60 to -40', () {
    final p = ProximityTracker()..add('a', -50, at(0));
    expect(p.read(at(10)).warmth, closeTo(0.5, 0.001));
    final q = ProximityTracker()..add('a', -75, at(0));
    expect(q.read(at(10)).warmth, 0);
  });

  test('the 127 sentinel is not a reading', () {
    final p = ProximityTracker()..add('a', 127, at(0));
    expect(p.read(at(10)).closest, isNull);
  });
}
```

- [ ] **Step 2: Run** — FAIL.

- [ ] **Step 3: Implement.** Per peer keep a `List<(DateTime, int)>`; `add` ignores `rssi >= 0` (sentinel and nonsense), appends, and drops samples older than `hold`. `read(now)`: for each peer take samples in `(now - window, now]`; if none, use the newest sample if `now - its time <= hold`, else skip the peer; median = sorted middle (lower middle for even counts). Closest = highest median; runner-up = second highest. `isClose = closestRssi >= closeRssi && (runnerUp == null || closestRssi - runnerUp >= margin)`. `warmth = ((closestRssi - warmRssi) / (closeRssi - warmRssi)).clamp(0.0, 1.0)`, 0 when none.

Constant comment above `bumpRssi`: `// Starting point, not a measurement: phones touching read about -30 to -40 dBm, and half a metre away about -55 to -65 on the two phones this was written for, but models differ by up to 10 dB. Replace with what the BUMP log lines show on the owner's phones, and say so here.`

- [ ] **Step 4: Run** — PASS (6 tests).

- [ ] **Step 5: Commit** — "AirDrop can tell which phone is touching this one from its Bluetooth signal".

---

### Task 9: A fast scan while the AirDrop page is on screen, and visible to strangers there

**Files:**
- Modify: `lib/core/ble/ble_constants.dart`, `lib/core/ble/ble_scanner.dart`
- Modify: `lib/features/peers/data/peer_discovery_controller.dart`
- Modify: `lib/core/transport/messaging_service.dart` (`_discoverableNow`, additive)
- Test: `test/ble_proximity_mode_test.dart`

**Interfaces:**
- Produces: `BleScanner.proximity` (bool getter) and `Future<void> setProximity(bool on)`; `BleConstants.proximityWindow = Duration(seconds: 10)`, `BleConstants.proximityGap = Duration(milliseconds: 300)`; `static int rssiMoveThreshold({required bool proximity}) => proximity ? 1 : 4;`.

- [ ] **Step 1: Failing test** — pure parts only (the radio cannot run here):

```dart
import 'package:cubechat/core/ble/ble_constants.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('proximity mode reports every decibel, normal mode only real moves', () {
    expect(BleConstants.rssiMoveThreshold(proximity: true), 1);
    expect(BleConstants.rssiMoveThreshold(proximity: false), 4);
  });

  test('proximity scanning barely pauses', () {
    expect(BleConstants.proximityGap, lessThan(const Duration(seconds: 1)));
    expect(BleConstants.proximityWindow, greaterThan(BleConstants.proximityGap));
  });
}
```

- [ ] **Step 2: Run** — FAIL.

- [ ] **Step 3: Implement.**
  - Constants with a comment: only while the AirDrop page is open, which is why the cost is acceptable; the idle and active cadences are untouched.
  - Scanner: `bool _proximity = false; bool get proximity => _proximity;` `Future<void> setProximity(bool on) async { if (on == _proximity) return; _proximity = on; if (!_running) return; await _stopScanWindow(); if (_running) await _startScanWindow(); }`. In `_startScanWindow`, after `_active = …`: `if (_proximity) _active = true;` and pick `_window`/`gap` from the proximity constants when `_proximity`. In `startScan(...)`: `androidScanMode: _proximity ? AndroidScanMode.lowLatency : (_active ? AndroidScanMode.balanced : AndroidScanMode.lowPower), continuousUpdates: _proximity,`. In `_onResults`: `final rssiMoved = (existing.rssi - r.rssi).abs() >= BleConstants.rssiMoveThreshold(proximity: _proximity);`.
  - `PeerDiscoveryController.build` (next to where `shouldScanActively` is wired): `ref.listen<bool>(airdropPageOnScreenProvider, (_, on) => unawaited(ref.read(bleScannerProvider).setProximity(on)));` and in `onDispose` `unawaited(scanner.setProximity(false))`.
  - `MessagingService._discoverableNow`: add `|| _ref.read(airdropPageOnScreenProvider)` with a comment: while the page is open this phone is meant to be found — a bump with someone not yet a contact must be able to start a session.

- [ ] **Step 4: Run** the new test, `flutter test test/ble_discovery_failure_test.dart`, and `flutter analyze` — PASS.

- [ ] **Step 5: Commit** — "The AirDrop page scans fast and makes the phone findable, only while it is open".

---

### Task 10: Staged files and the bump ledger

**Files:**
- Create: `lib/features/airdrop/data/airdrop_staged.dart`
- Create: `lib/features/airdrop/data/bump_ledger.dart`
- Modify: `lib/features/airdrop/data/airdrop_controller.dart` (`_onOffer` auto-accept)
- Test: `test/airdrop_controller_test.dart` (group "bumped offers")

**Interfaces:**
- Produces:
  - `final airdropStagedProvider = StateProvider<List<AirDropSource>>((_) => const []);`
  - `class BumpLedger { void note(String peerHex, DateTime at); bool recent(String peerHex, DateTime now); void clear(); static const Duration acceptWithin = Duration(seconds: 10); }` and `final bumpLedgerProvider = Provider<BumpLedger>((_) => BumpLedger());`

- [ ] **Step 1: Failing tests** in the controller test:
  1. ledger notes `_eve` (a stranger, contacts-only receive mode); an offer from `_eve` 3 s later is accepted with no user tap — the last answer to `_eve` is `accepted`, no `contactsOnly` decline, and no request card (state has it in `transferring`).
  2. the same offer 11 s after the note is declined `contactsOnly`, as in part 1.
  3. an offer from `_bob` while the ledger holds only `_eve` is an ordinary request.

- [ ] **Step 2: Run** — FAIL.

- [ ] **Step 3: Implement.** `BumpLedger` is a map of `peerHex → DateTime` with `recent = at != null && now.difference(at) <= acceptWithin`. In `_onOffer`, compute `final bumped = ref.read(bumpLedgerProvider).recent(peerHex, _now);` before the spam check. When `bumped`: skip the spam guard and the contacts-only refusal (keep `busy` and `noSpace`); after `_put(request)` call `await accept(id)` instead of notifying and arming the 60 s expiry. Comment: bringing the phone to theirs is the consent that "Прийняти" would have been.

- [ ] **Step 4: Run** `flutter test test/airdrop_controller_test.dart` — PASS.

- [ ] **Step 5: Commit** — "An offer from the phone you just bumped is taken without asking again".

---

### Task 11: `BumpController` — both phones must feel it

**Files:**
- Create: `lib/features/airdrop/data/bump_controller.dart`
- Test: `test/bump_controller_test.dart`

**Interfaces:**
- Consumes: `ProximityTracker` (Task 8), `NearbyBump` (Task 7), `BumpLedger`/`airdropStagedProvider` (Task 10), `AirDropPort.send(bump:)`, `airdropPortProvider`, `airdropControllerProvider.notifier.offer`, `airdropPeerNameProvider`, `airdropContactsProvider`, `airdropPageOnScreenProvider`, `airdropClockProvider`.
- Produces:

```dart
sealed class BumpEvent { const BumpEvent(this.peerHex, this.peerName, this.at); final String peerHex; final String peerName; final DateTime at; }
class BumpSentFiles extends BumpEvent { const BumpSentFiles(super.peerHex, super.peerName, super.at, this.count); final int count; }
class BumpReceivingFiles extends BumpEvent { const BumpReceivingFiles(super.peerHex, super.peerName, super.at); }
class BumpContact extends BumpEvent { const BumpContact(super.peerHex, super.peerName, super.at, {required this.card, required this.alreadyContact}); final Uint8List card; final bool alreadyContact; }

@immutable
class BumpState { const BumpState({this.warmth = 0, this.event}); final double warmth; final BumpEvent? event; }

class BumpController extends Notifier<BumpState> {
  /// Fed by the scan; public so the page's listener and the tests can drive it.
  void sample(String peerHex, int rssi);
  void dismiss();                     // clears state.event
  Future<String?> addContact();       // adds the card of the current BumpContact; returns the pubkey hex
}
final bumpControllerProvider = NotifierProvider<BumpController, BumpState>(BumpController.new);

/// Own signed card, injectable for tests.
final bumpOwnCardProvider = Provider<Future<Uint8List> Function()>(
  (ref) => () => ref.read(messagingServiceProvider).buildSignedAnnouncement(),
);
/// Who has a direct session now, injectable for tests.
final bumpDirectPeersProvider = Provider<Set<String>>(
  (ref) => {for (final p in ref.watch(airdropDirectPeersProvider)) p.hex},
);
```

- [ ] **Step 1: Failing tests** (`fakeAsync`, the `_Port` pattern from `airdrop_controller_test.dart` copied into this file, the page-on-screen provider set to `true`, `bumpDirectPeersProvider` overridden to `{_bob}`, `bumpOwnCardProvider` overridden to return fixed bytes, `airdropClockProvider` bound to the fake clock):
  1. **nothing happens while the page is closed** — page false; feed `_bob` -35 for 1.5 s; no bump sent.
  2. **close → our bump goes out, once** — feed `_bob` -35 every 100 ms for 1.5 s; exactly one `bump` sent to `_bob`; `hasFiles` false.
  3. **mutual within 2 s → contact event** — after test 2, deliver `_bob`'s bump (hasFiles false) with a card; `state.event` is `BumpContact` for `_bob`; ledger `recent(_bob)` true.
  4. **their bump 3 s later → nothing** — our bump at t, theirs at t+3 s; no event.
  5. **their bump first, ours within 2 s → event** — deliver theirs, then feed samples; event fires when ours goes out.
  6. **staged files → an offer, staged cleared** — stage one `AirDropSource`; mutual bump; `port.sent` has an offer to `_bob`; staged is empty; event is `BumpSentFiles(count: 1)`.
  7. **they have files, we do not → receiving event** — their bump `hasFiles: true`; event `BumpReceivingFiles`; no offer sent by us.
  8. **cooldown** — after an event, keep feeding -35 for 4 s and deliver another bump from `_bob` with a new id; no second event; after 5 s it may fire again.
  9. **a replayed bumpId is ignored** — deliver the same bump twice; the second does not count as a fresh one (no event when ours then goes out 3 s after the first delivery).
  10. **someone without a direct session is ignored** — samples for `_eve` (not in the direct set) never send a bump.
  11. **a card whose key is not the sender's is dropped** — the card is verified with `PeerAnnouncement.verifyAndDecode`; in the test override a `bumpCardCheckProvider` (`Provider<Future<bool> Function(Uint8List card, String senderHex)>`) to return false, and expect no event.

- [ ] **Step 2: Run** — FAIL.

- [ ] **Step 3: Implement.** Essentials:

```dart
class BumpController extends Notifier<BumpState> {
  static const Duration mutualWithin = Duration(seconds: 2);
  static const Duration cooldown = Duration(seconds: 5);

  final ProximityTracker _tracker = ProximityTracker();
  final Map<String, DateTime> _sentAt = {};
  final Map<String, ({DateTime at, NearbyBump bump})> _heard = {};
  final Map<String, DateTime> _quietUntil = {};
  final Set<String> _seenIds = {};
  StreamSubscription<NearbyInbound>? _inbound;
  Timer? _tick;
  DateTime? _lastLog;
  final _random = Random.secure();

  DateTime get _now => ref.read(airdropClockProvider)();

  @override
  BumpState build() {
    _inbound = ref.read(airdropPortProvider).inbound.listen(_onInbound);
    ref.listen<bool>(airdropPageOnScreenProvider, (_, on) => on ? _start() : _stop(), fireImmediately: true);
    ref.onDispose(() { unawaited(_inbound?.cancel()); _tick?.cancel(); });
    return const BumpState();
  }

  void _start() {
    _tick ??= Timer.periodic(const Duration(milliseconds: 200), (_) => _evaluate());
  }

  void _stop() {
    _tick?.cancel();
    _tick = null;
    _tracker.clear();
    _sentAt.clear();
    _heard.clear();
    ref.read(airdropStagedProvider.notifier).state = const [];
    if (state.warmth != 0) state = BumpState(event: state.event);
  }

  void sample(String peerHex, int rssi) {
    if (_tick == null) return;
    if (!ref.read(bumpDirectPeersProvider).contains(peerHex)) return;
    _tracker.add(peerHex, rssi, _now);
  }

  void _evaluate() {
    final now = _now;
    final r = _tracker.read(now);
    if ((r.warmth - state.warmth).abs() >= 0.05) {
      state = BumpState(warmth: r.warmth, event: state.event);
    }
    _logReading(r, now);
    final hex = r.closest;
    if (!r.isClose || hex == null || _quiet(hex, now)) return;
    final sent = _sentAt[hex];
    if (sent != null && now.difference(sent) < mutualWithin) return;
    _sentAt[hex] = now;
    unawaited(_sendBump(hex));
    final heard = _heard[hex];
    if (heard != null && now.difference(heard.at) <= mutualWithin) _fire(hex, heard.bump);
  }
  ...
}
```

`_sendBump(hex)`: `NearbyBump(bumpId: 16 random bytes, hasFiles: ref.read(airdropStagedProvider).isNotEmpty, card: await ref.read(bumpOwnCardProvider)())` → `_port.send(hex, bump: …)`.

`_onInbound(m)`: only `m.bump != null && m.direct && _tick != null`; drop if `!_seenIds.add(nearbyHex(m.bump!.bumpId))`; drop unless `await ref.read(bumpCardCheckProvider)(bump.card, m.peerHex)`; record `_heard[m.peerHex] = (at: _now, bump: bump)`; if `_sentAt[m.peerHex]` is within `mutualWithin` and not `_quiet` → `_fire`.

`bumpCardCheckProvider` default: `PeerAnnouncement.verifyAndDecode(card)` then compare `nearbyHex(ann.pubkey) == senderHex`, false on any exception.

`_fire(hex, theirs)`: `_quietUntil[hex] = now + cooldown`; `ref.read(bumpLedgerProvider).note(hex, now)`; `_sentAt.remove(hex); _heard.remove(hex);` log `BUMP fired with <short>`; then
- staged non-empty → `offer(peerHex: hex, peerName: name, files: staged)`, clear staged, event `BumpSentFiles(count)`; if `offer` returns null, event stays but log it.
- else if `theirs.hasFiles` → event `BumpReceivingFiles`.
- else → event `BumpContact(card: theirs.card, alreadyContact: ref.read(airdropContactsProvider).contains(hex))`.

`addContact()`: for a `BumpContact`, `await ref.read(messagingServiceProvider).addContactFromCard(ContactCard.encode(card))`, return the hex, and `dismiss()`.

`_logReading`: at most once a second while the page is open, `DebugLog.instance.log('BUMP', '${short(closest)} ${closestRssi} dBm, next ${runnerUpRssi ?? '-'}${isClose ? ' CLOSE' : ''}')` — only when there is a closest peer. These lines are the measurement for Task 8's constant.

Feeding samples (production): in `build()`, `ref.listen(peerDiscoveryControllerProvider, (_, s) { for (final p in s.peers) { final hex = p.resolvedPubkeyHex; if (hex != null && p.hasSignalReading) sample(hex, p.rssi); } });`. Strangers become resolvable because a peer who completed an XX handshake is in the roster that `PeerDiscoveryController` resolves rotating ids against.

- [ ] **Step 4: Run** `flutter test test/bump_controller_test.dart` — PASS (11 tests).

- [ ] **Step 5: Commit** — "Two phones held together on the AirDrop page agree they touched, then send or swap cards".

---

### Task 12: Choose files ahead of a bump

**Files:**
- Modify: `lib/features/airdrop/presentation/airdrop_page.dart`
- Modify: l10n arb files, regenerate
- Test: `test/airdrop_page_test.dart`

- [ ] **Step 1: Failing widget tests:** with `airdropStagedProvider` overridden to two sources, the page shows `airdropStagedTitle(2)` and a hint `airdropStagedHint`, a "Choose person" button (`airdropStagedPickPerson`), and a clear `IconButton` whose tap empties the provider. With nothing staged the page shows the `airdropChooseFiles` button.

- [ ] **Step 2: Run** — FAIL.

- [ ] **Step 3: Implement.** Strings:

| key | en | uk |
|---|---|---|
| `airdropChooseFiles` | Choose files | Вибрати файли |
| `airdropStagedTitle` (plural `count`) | {count, plural, one{1 file ready} other{{count} files ready}} | {count, plural, one{1 файл готовий} few{{count} файли готові} other{{count} файлів готові}} |
| `airdropStagedHint` | Hold your phone against theirs, or choose a person | Піднесіть телефон до іншого або виберіть людину |
| `airdropStagedPickPerson` | Choose person | Вибрати людину |

Under the existing "Send files" button, a second `FloatingGlass` row "Вибрати файли" (`Icons.touch_app_rounded`) calls `pickAirDropFiles(context, ref)` and puts the result into `airdropStagedProvider`. When staged is non-empty, that row is replaced by a card: title, hint, "Вибрати людину" → `startAirDropSend(context, ref, files: staged)` then clear staged; ✕ clears.

- [ ] **Step 4: Run** tests and gen-l10n — PASS.

- [ ] **Step 5: Commit** — "Files can be chosen on the AirDrop page first, then sent by bringing the phones together".

---

### Task 13: The glow, the wave, and the contact card

**Files:**
- Create: `lib/features/airdrop/presentation/bump_glow.dart`
- Modify: `lib/features/airdrop/presentation/airdrop_page.dart` (wrap the list in a `Stack` with the glow on top, `IgnorePointer` for the glow)
- Modify: l10n arb files, regenerate
- Test: `test/bump_glow_test.dart`

**Interfaces:**
- Consumes: `bumpControllerProvider` (`warmth`, `event`, `dismiss`, `addContact`).
- Produces: `class BumpGlow extends ConsumerStatefulWidget` (the overlay) and `class BumpContactCard extends ConsumerWidget`.

- [ ] **Step 1: Failing widget tests:**
  1. warmth 0 and no event → `find.byType(CustomPaint)` under `BumpGlow` paints nothing and **no ticker is active**: `expect(tester.binding.transientCallbackCount, 0)` after `pump()`.
  2. warmth 0.6 → the glow painter is present (find by a `Key('bump-glow')`).
  3. a `BumpContact` event (not a contact yet) → the card shows the peer's name, `airdropBumpAdd`; tapping it calls `addContact` (override the controller with a fake `Notifier` recording the call).
  4. a `BumpContact` with `alreadyContact: true` → `airdropBumpAlreadyContact` and `airdropBumpWrite`.
  5. reduced motion (`MediaQuery(disableAnimations: true)`) → the event card appears without the wave (no transient callbacks after the first frame).

- [ ] **Step 2: Run** — FAIL.

- [ ] **Step 3: Implement.** Strings:

| key | en | uk |
|---|---|---|
| `airdropBumpAdd` | Add | Додати |
| `airdropBumpAlreadyContact` | Already in your contacts | Вже у контактах |
| `airdropBumpWrite` | Message | Написати |
| `airdropBumpSending` | Sending to {name} | Надсилаю {name} |
| `airdropBumpReceiving` | {name} is sending you files | {name} надсилає вам файли |

`BumpGlow`:
- One `AnimationController` for the wave (600 ms, `Curves.easeOutCubic`) and one for the bubble (420 ms, `Curves.easeOutBack`); both created in `initState` but only `forward()`ed when `ref.listen` sees a new `event`. No repeating animation anywhere. The warmth glow is driven by `TweenAnimationBuilder<double>(duration: 180ms, tween: Tween(end: warmth))` so it only animates when warmth changes — at rest it schedules nothing.
- `_GlowPainter(warmth, wave, color: AppColors.brandPrimary)`: a vertical `LinearGradient` from the top edge, height `lerp(24, 180, warmth)`, alpha `0.55 * warmth`; the wave is a horizontal band at `y = wave * size.height`, 90 px tall, gradient transparent → `color.withValues(alpha: 0.45 * (1 - wave))` → transparent. `shouldRepaint` compares the three values.
- On a new event: `HapticFeedback.heavyImpact()`, run the wave, then show the bubble: `IdentityAvatar` of the peer (size 72) scaling from 0.4 at the top edge down to the card slot, then the card (`FloatingGlass`, radius 22) — `BumpContactCard` for `BumpContact`, a one-line status (`airdropBumpSending` / `airdropBumpReceiving`) for the file events, auto-dismissed after 2.5 s (the progress card on the page takes over).
- Contact card: avatar, name, then either "Додати" (`addContact()`, then a `showGlassToast` with the existing "contact added" string — `grep -n "ContactAdded\|contactAdded" lib/l10n/app_en.arb`) or "Вже у контактах" + "Написати" (navigate the same way the people list's "Написати" does — `grep -n "Написати\|airdropWrite\|peersWrite" lib/features/peers/presentation/peers_screen.dart` and reuse its route call). A ✕ calls `dismiss()`.
- Honour `MediaQuery.disableAnimationsOf(context)`: skip the wave and the bubble scale, show the card directly.

Mount in `AirDropPage`: `Stack(children: [<existing ListView>, const Positioned.fill(child: BumpGlow())])`, with the glow layer under `IgnorePointer` except the card itself.

- [ ] **Step 4: Run** `flutter test test/bump_glow_test.dart test/airdrop_page_test.dart test/layer_budget_test.dart` — PASS (the layer budget must not grow for the idle page: at warmth 0 the painter draws nothing and adds no layer; if it does, return early from `paint` and wrap in `RepaintBoundary` only while animating).

- [ ] **Step 5: Commit** — "Bringing phones together lights the top of the screen and rolls a wave, the way NameDrop does".

---

### Task 14: Whole-suite check and the protocol notes

**Files:**
- Modify: `.claude/skills/wire-protocol/SKILL.md` if it lists AirDrop bytes (add 0xEA and answer v2)
- Modify: `docs/superpowers/specs/2026-09-23-airdrop-wifi-and-bump-design.md` only if implementation diverged — say where and why

- [ ] **Step 1:** `flutter analyze` — grep the output for `error -`, `warning -`, `error •`, `warning •`; zero new.
- [ ] **Step 2:** `flutter test --exclude-tags golden` — all pass; report the count. Any failure other than the known stale golden is fixed before going on.
- [ ] **Step 3:** Commit — "Note the AirDrop Wi-Fi answer and the bump frame in the protocol guide".
- [ ] **Step 4:** Report to the owner, in Russian, what only two phones can prove: the real RSSI of touching phones (ask for the log right after a bump attempt — the `BUMP` lines), Wi‑Fi speed, a guest network with client isolation falling back, and the iOS local-network prompt. Version bump and APK/TestFlight happen only when the owner asks.
