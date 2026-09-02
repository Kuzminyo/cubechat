import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../storage/hive_cipher.dart';
import '../storage/hive_init.dart';

import '../crypto/identity_service.dart';
import '../locale/locale_controller.dart';
import '../transport/nostr/nostr_event.dart';
import '../transport/nostr/nostr_signer.dart';
import '../util/debug_log.dart';
import '../util/platform_info.dart';

/// Telling a small server where to knock.
///
/// ## Why there is a server at all
///
/// A terminated iOS app receives nothing. The socket died with the process,
/// `BGAppRefreshTask` is not scheduled for an app the user swiped away, and the
/// significant-change wake-up next door is triggered by the user moving rather
/// than by anybody writing. APNs is the only mechanism Apple provides for
/// "wake up, there is a message", and APNs can only be driven by a server.
///
/// ## What the server is given
///
/// One line: this npub, that device token. It subscribes to the same relays the
/// app publishes to, and when an event addressed to the npub lands it sends a
/// push carrying a fixed string. It has no key and cannot decrypt anything; the
/// message is fetched from the relay and opened on the phone, as it always was.
///
/// ## What it costs, said plainly
///
/// The server learns that a given npub received something, and when — and since
/// Nostr events carry the sender's pubkey, who wrote to whom. The relay already
/// sees all of that, so this is a second observer of the same metadata rather
/// than a new kind of exposure. It is still a real cost, which is why this is
/// off until somebody turns it on.
///
/// One thing the relay does *not* already see is added here: the language the
/// app is set to, sent so the banner can be written in it. Two values are
/// possible today, so it narrows a person about as much as knowing they
/// installed a Ukrainian-language app does. Worth naming rather than leaving
/// for somebody to find in a packet.
///
/// ## Why the registration is signed
///
/// It is an ordinary Nostr event, of a kind of its own, signed by the identity
/// key. The server checks it exactly the way a relay checks any event. Without
/// that, anybody could register their own device token against somebody else's
/// npub and turn the service into an oracle for "did they get mail".
class PushRegistration {
  PushRegistration(this._ref);

  final Ref _ref;

  static const _channel = MethodChannel('cubechat/push');

  /// Where the doorbell lives, tried in order until one answers.
  ///
  /// The sslip.io name came first because `wake.cubechat.qpon` was never
  /// delegated in the `.qpon` registry, so no resolver could find it. That is
  /// no longer the constraint — cubechat.tech is ours and answers — and the
  /// stand-in turns out to have a fault of its own worth naming.
  ///
  /// `a-b-c-d.sslip.io` is a wildcard resolver that maps any name of that
  /// shape to the address written in it. That is precisely the shape DNS
  /// rebinding protection exists to block, and plenty of home routers,
  /// company networks and carrier resolvers do block it. Measured on
  /// 2026-09-02: 1.1.1.1 and 8.8.8.8 both answered for this name while the
  /// system resolver on the developer's own machine returned "no such host".
  /// A phone behind such a resolver could never register, and the only trace
  /// would be one `registration failed` line.
  ///
  /// So: the real name first, the old one behind it. Two entries rather than
  /// one because the swap cannot be atomic — a build reaches phones before,
  /// during and after a DNS record propagates, and this way the order does not
  /// matter. Drop the second once no shipped build is asking for it.
  static const endpoints = <String>[
    'https://push.cubechat.tech/register',
    'https://209-38-225-225.sslip.io/register',
  ];

  /// Its own kind, so a registration can never be mistaken for a frame — and so
  /// a relay would simply ignore one if a phone ever published it by mistake.
  static const registrationKind = 24242;

  /// Ask for permission, get the token, and hand the server a signed line.
  ///
  /// The three failures are told apart because only one of them has a way out.
  /// A refusal iOS has already recorded is permanent as far as the app is
  /// concerned — `requestAuthorization` returns false without showing anything,
  /// because the system will not put the prompt up twice — so the only honest
  /// answer is to send the user to Settings. Reporting that the same way as "it
  /// did not work" leaves a switch that can never be turned on and never says
  /// why.
  Future<PushOutcome> enable() async {
    if (!PlatformInfo.isIOS) {
      return const PushOutcome(PushEnableResult.unsupported);
    }
    if (await systemStatus() == 'denied') {
      DebugLog.instance.log('PUSH', 'notifications denied in system settings');
      return const PushOutcome(PushEnableResult.denied);
    }
    final String? token;
    try {
      token = await _channel.invokeMethod<String>('register');
    } on PlatformException catch (e) {
      // The two that actually happen: a simulator, which has no APNs at all,
      // and a build signed without the Push Notifications entitlement, which
      // is refused with "no valid aps-environment".
      DebugLog.instance.log('PUSH', 'no token: ${e.message}');
      return PushOutcome(PushEnableResult.failed, e.message);
    } on MissingPluginException {
      // The build predates the plugin. Worth its own answer: the switch is
      // visible because the *Dart* is new, and a phone can easily be running
      // an app whose native half is older than the screen drawing it.
      DebugLog.instance.log('PUSH', 'plugin missing — build has no push code');
      return const PushOutcome(
        PushEnableResult.failed,
        'this build has no push support (native half is older)',
      );
    }
    if (token == null || token.isEmpty) {
      // Asked and declined just now, rather than declined at some point in the
      // past — the prompt did appear, so Settings is still where it is undone.
      DebugLog.instance.log('PUSH', 'permission refused');
      return const PushOutcome(PushEnableResult.denied);
    }
    return await _publish(token)
        ? const PushOutcome(PushEnableResult.ok)
        : const PushOutcome(
            PushEnableResult.failed,
            'the server did not accept the registration',
          );
  }

  /// Take the user to the one place a refusal can be undone.
  Future<void> openSystemSettings() => openAppSettings();

  /// Ask the server to forget this phone.
  ///
  /// The same signed shape with an empty content, so the right to leave needs
  /// the key the right to arrive needed. A registration nobody can withdraw is
  /// worse than none.
  Future<bool> disable() => _publish('');

  Future<bool> _publish(String token) async {
    final NostrEvent event;
    try {
      final signer = await _signer();
      event = await signer.sign(
        NostrEvent(
          pubkey: signer.npubHex,
          createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          kind: registrationKind,
          tags: <List<String>>[
            <String>['lang', await _language()],
          ],
          content: token,
        ),
      );
    } catch (e) {
      DebugLog.instance.log('PUSH', 'could not sign the registration: $e');
      return false;
    }
    // Signed once and offered to each in turn: the same event is valid at any
    // of them, and re-signing per attempt would only move the timestamp.
    for (final endpoint in endpoints) {
      if (await _post(endpoint, event, token)) return true;
    }
    DebugLog.instance.log(
      'PUSH',
      'no doorbell answered — tried ${endpoints.length}',
    );
    return false;
  }

  /// One attempt at one endpoint. Never throws; the caller tries the next.
  Future<bool> _post(String endpoint, NostrEvent event, String token) async {
    final host = Uri.parse(endpoint).host;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await client.postUrl(Uri.parse(endpoint));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(event.toJson()));
      final response = await request.close().timeout(
            const Duration(seconds: 20),
          );
      final body = await response.transform(utf8.decoder).join();
      final ok = response.statusCode == 200;
      DebugLog.instance.log(
        'PUSH',
        '${token.isEmpty ? 'unregister' : 'register'} '
            '${ok ? 'accepted' : 'refused'} by $host: $body',
      );
      return ok;
    } catch (e) {
      // Named rather than swallowed, because "could not resolve host" is the
      // failure this list exists for and it must be readable in a log.
      DebugLog.instance.log('PUSH', '$host did not answer: $e');
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// What the system already decided, without asking again.
  ///
  /// `undecided`, `granted` or `denied`. The switch reads it so a phone where
  /// notifications were turned off in Settings does not show an on switch that
  /// can never do anything — iOS will not put the prompt up a second time.
  Future<String> systemStatus() async {
    if (!PlatformInfo.isIOS) return 'unsupported';
    try {
      return await _channel.invokeMethod<String>('status') ?? 'undecided';
    } on PlatformException {
      return 'undecided';
    }
  }

  /// Which language the banner should be written in.
  ///
  /// The server cannot read the message, so the banner says a fixed sentence —
  /// and a fixed sentence still has to be in a language the reader has. It
  /// travels inside the signed event rather than as a separate field, so it
  /// cannot be altered in flight or set for somebody else's npub.
  ///
  /// Read from storage rather than from [localeControllerProvider], because
  /// this runs at launch and that controller restores asynchronously; whichever
  /// won the race would decide, and losing it means the wrong language until
  /// something re-registers. Falls back to the controller, then to the app's
  /// build-time default.
  Future<String> _language() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(localePrefsKey);
      if (stored != null && stored.isNotEmpty) return stored;
    } catch (_) {
      // Storage unavailable is not a reason to skip the registration.
    }
    return _ref.read(localeControllerProvider).languageCode;
  }

  Secp256k1NostrSigner? _cache;

  Future<Secp256k1NostrSigner> _signer() async {
    final cached = _cache;
    if (cached != null) return cached;
    final identity = await _ref.read(identityProvider.future);
    return _cache = await Secp256k1NostrSigner.deriveFromSeed(
      Uint8List.fromList(identity.signPrivateKey),
    );
  }
}

/// Why turning it on did or did not work.
///
/// [denied] is the one with a way out, and the reason this is an enum rather
/// than a bool: the switch can send somebody to Settings only if it knows that
/// is the problem.
enum PushEnableResult { ok, denied, unsupported, failed }

/// What happened, and — when it went wrong — what the system said about it.
///
/// The reason is carried rather than logged and forgotten. "It did not work"
/// sends somebody hunting through a log; "no valid aps-environment" is the
/// answer itself, and it is the message Apple returns for the one failure that
/// looks exactly like a bug in this app and is not: a build signed by an Apple
/// ID that has no push entitlement.
class PushOutcome {
  const PushOutcome(this.result, [this.detail]);

  final PushEnableResult result;
  final String? detail;

  bool get ok => result == PushEnableResult.ok;
}

final pushRegistrationProvider = Provider<PushRegistration>(
  PushRegistration.new,
);

/// Whether this phone has asked to be woken, kept across launches.
///
/// The token itself is not stored: it is asked for again on every enable,
/// because iOS may hand out a different one after a restore or a reinstall and
/// a stale token is an address that answers to nobody.
class PushEnabled extends Notifier<bool> {
  static const _key = 'push.enabled';

  Box<dynamic>? _box;
  Future<void>? _loading;

  @override
  bool build() {
    unawaited(_loading = _load());
    return false;
  }

  /// The same box the rest of the settings live in, so an emergency wipe takes
  /// this with everything else rather than leaving a phone registered with a
  /// server it no longer has an app for.
  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      final stored = box.get(_key) as bool? ?? false;
      if (stored != state) state = stored;
      // Re-registered on every launch while it is on, because a token is not
      // forever: iOS hands out a new one after a restore or a reinstall, and
      // the old one is then an address that answers to nobody. The server
      // stores by npub, so a repeat is an update rather than a duplicate.
      if (stored) unawaited(ref.read(pushRegistrationProvider).enable());
    } catch (e) {
      debugPrint('push flag load failed: $e');
    }
  }

  /// Turn it on, which asks the system and then the server, or off, which asks
  /// the server to forget us.
  ///
  /// The flag follows what actually happened rather than what was tapped: a
  /// refused permission leaves it off, and the switch springs back on its own.
  Future<PushOutcome> set(bool on) async {
    final push = ref.read(pushRegistrationProvider);
    final result = on
        ? await push.enable()
        : PushOutcome(
            await push.disable()
                ? PushEnableResult.ok
                : PushEnableResult.failed,
          );
    state = on && result.ok;
    try {
      await _loading;
      await _box?.put(_key, state);
    } catch (e) {
      debugPrint('push flag persist failed: $e');
    }
    return result;
  }
}

final pushEnabledProvider = NotifierProvider<PushEnabled, bool>(
  PushEnabled.new,
);
