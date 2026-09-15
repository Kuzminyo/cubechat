import 'package:cubechat/core/util/log_humanizer.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Diagnostics log as an ordinary user sees it: what they would recognise,
/// in their language, and nothing of the developer's.
void main() {
  late AppLocalizations uk;

  setUpAll(() async {
    uk = await AppLocalizations.delegate.load(const Locale('uk'));
  });

  FriendlyLogLine? read(String line) => humanizeLogLine(line, uk);

  test('the internet connection coming and going is said plainly', () {
    expect(read('[NOSTR] connected wss://relay.snort.social')?.text,
        'Підключено до relay.snort.social');
    expect(
      read('[NOSTR] wss://relay.snort.social down (closed by relay) — retry in 2s')
          ?.text,
      'Втрачено зв’язок з relay.snort.social',
    );
    expect(
      read('[NOSTR] internet fallback on — 3 relay(s) + 3 media + 2 location')
          ?.kind,
      LogKind.internet,
    );
    expect(read('[BOOT] cubechat 1.0.0 2026-09-15-x debug=false')?.text,
        'Застосунок запущено');
  });

  test('the traffic nobody can act on is left out', () {
    for (final line in [
      '[NOSTR] sent 190B to c7ee52e58470f4d991358650dd9ac839b951348a46ac5368 via relay — PublishReceipt(sent: 8, ok: 1)',
      '[NOSTR] published 44a552cc — PublishReceipt(sent: 8, ok: 1)',
      '[NOSTR] wss://nostr.oxtr.dev rejected publish: rate limited',
      '[NOSTR] wss://relay.cubechat.tech subscription cc-1 closed: ERROR: auth-required: requested filter requires authentication',
      '[RECEIPT] nothing to ack for f9ce147a — 0 not read yet',
      '[FRAME] slow frame — build 23.1 ms, raster 1.5 ms — chat x1',
      '[NAV-COST] open chat[circle, <500] [blur] · 455 ms · 38 frames',
      '[CPU] since Diagnostics was last open — GPU raster 9760 ms (10%)',
      '[PRESENCE] sent online beacon to 10 peer(s)',
      '[CRYPTO] FS (X3DH) body decrypted from nostr:relay',
      '[BOOT] display-mode took 558ms',
      'PrekeyService: restored signed prekey #1',
    ]) {
      expect(read(line), isNull, reason: line);
    }
  });

  test('anything that failed is shown, wherever it came from', () {
    final untagged = read('sendImage failed: MediaRouteUnavailable');
    expect(untagged?.kind, LogKind.problem);
    final crypto = read('[CRYPTO] could not decrypt body from nostr:relay');
    expect(crypto?.kind, LogKind.problem);
    final file = read('[FILE] sendFile failed for "a.pdf" (2000 B): timeout');
    expect(file?.kind, LogKind.problem);
  });

  test('chats, files and calls are kept, with the ids cut short', () {
    final chat = read(
      '[CHAT] delete 697caf726ef2d4de6409e598d17f05fa302bdc14f56ae36d109911efa8dea316 (channel=false, alsoForThem=false)',
    );
    expect(chat?.kind, LogKind.chats);
    expect(chat?.text, 'delete 697caf… (channel=false, alsoForThem=false)');
    expect(read('[CALL] ringing')?.kind, LogKind.calls);
    expect(read('[CIRCLE] recording')?.kind, LogKind.media);
    expect(read('[BLE-CENTRAL] connected to AA:BB')?.kind, LogKind.bluetooth);
  });

  test('a long line is held to one readable length', () {
    expect(shortenLogText('x' * 400).length, 140);
  });
}
