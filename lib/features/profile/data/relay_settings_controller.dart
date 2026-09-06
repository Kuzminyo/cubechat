import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';
import '../../../core/transport/nostr/websocket_relay_client.dart';

/// User configuration for the Nostr internet fallback (M6).
@immutable
class RelaySettings {
  const RelaySettings({required this.enabled, required this.urls});

  /// Off by default. cubechat's whole promise is that it needs no servers, so
  /// touching one is a decision the user makes explicitly: a relay learns your
  /// Nostr pubkey, your recipient's, and when you talk (never the plaintext).
  final bool enabled;

  /// Relay endpoints (`wss://…`). Frames are published to all of them; the
  /// recipient only has to be listening on one.
  final List<String> urls;

  /// Dropped `wss://relay.damus.io`. Two device logs had it answering
  /// `rate-limited: you are noting too much` to very nearly every publish, and
  /// dropping its socket with "not upgraded to websocket" between times. It was
  /// costing a third of every fan-out — a presence beacon goes to each relay per
  /// contact — to store nothing at all. A relay that refuses is worse than one
  /// fewer relay: the recipient only has to be listening on one.
  /// Added `wss://nostr.mom` on 2026-09-06, because two was one too few.
  ///
  /// Both incumbents spent a day failing in turn — `nos.lol` refusing the
  /// upgrade to a websocket five times in a row with the backoff climbing to
  /// 32 s, `relay.primal.net` answering 502 — and a phone log from that day
  /// counted 112 publishes of which **none** were confirmed by both relays and
  /// 42 went to one. Delivery rested on a single road most of the time, and a
  /// recipient only has to be listening on one: a third is the whole fix.
  ///
  /// Chosen by probe rather than by reputation. Seven candidates were asked for
  /// their NIP-11 document and given a REQ for kind 1059, six rounds twenty
  /// seconds apart. What that could settle, it settled — `relay.nostr.band` and
  /// `relay.nostr.bg` were unreachable, and the rest declared no payment, no
  /// AUTH and no restricted writes. What it could **not** settle is the thing
  /// actually being fixed: all seven answered 6/6 from a desktop on a good
  /// line, including the two that had been dropping sockets on the phone all
  /// day. So the flapping is not the relays being down for everyone, and no
  /// probe from here would have found it.
  ///
  /// The choice among the survivors is therefore latency (186 ms median, joint
  /// fastest with `nostr.oxtr.dev`) and independence: a third relay run by the
  /// same people as one of the first two would buy nothing on the day one
  /// operator has trouble.
  ///
  /// `relay.damus.io` stays out. See above — it was dropped for rate-limiting
  /// real messages out of a fan-out, and being short of relays is not a reason
  /// to take back one that refuses.
  static const defaultUrls = <String>[
    'wss://nos.lol',
    'wss://relay.primal.net',
    'wss://nostr.mom',
  ];

  static const initial = RelaySettings(enabled: false, urls: defaultUrls);

  /// True when the fallback should actually run.
  bool get isActive => enabled && urls.isNotEmpty;

  RelaySettings copyWith({bool? enabled, List<String>? urls}) => RelaySettings(
        enabled: enabled ?? this.enabled,
        urls: urls ?? this.urls,
      );

  @override
  bool operator ==(Object other) =>
      other is RelaySettings &&
      other.enabled == enabled &&
      listEquals(other.urls, urls);

  @override
  int get hashCode => Object.hash(enabled, Object.hashAll(urls));
}

/// Persists [RelaySettings] in the shared (encrypted) Hive settings box.
class RelaySettingsController extends Notifier<RelaySettings> {
  static const _enabledKey = 'nostr.enabled';
  static const _urlsKey = 'nostr.relays';

  /// Relay endpoints retired from the defaults, dropped once from lists that
  /// were saved while they were still stock.
  ///
  /// Changing [RelaySettings.defaultUrls] alone reaches nobody who has ever
  /// touched the relay screen: the stored list wins over the defaults, and
  /// enabling the fallback at all writes one. Every phone actually testing this
  /// therefore had the retired relay saved.
  static const _retiredUrls = <String>['wss://relay.damus.io'];

  /// Marks the one-time removal as done, so a user who deliberately adds a
  /// retired relay back keeps it.
  static const _retiredAppliedKey = 'nostr.relays.retiredApplied';

  /// Relay endpoints added to the defaults, folded once into lists that were
  /// saved before they were stock.
  ///
  /// The mirror of [_retiredUrls] and needed for exactly the same reason: a
  /// stored list wins over the defaults, and merely switching the internet
  /// fallback on writes one. So every phone that has ever used the relay
  /// screen — which is every phone testing this — would have kept its two and
  /// never seen the third, and the fix for "delivery rests on one road" would
  /// have reached nobody who reported it.
  static const _addedUrls = <String>['wss://nostr.mom'];

  /// Applied once, so somebody who deliberately removes an added relay keeps it
  /// removed. The same promise the retirement above makes in the other
  /// direction: this may change a list once, and never again.
  static const _addedAppliedKey = 'nostr.relays.addedApplied.v1';

  Box<dynamic>? _box;

  @override
  RelaySettings build() {
    unawaited(_load());
    return RelaySettings.initial;
  }

  Future<void> _load() async {
    try {
      final box =
          await hiveCipherProvider.openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      final enabled = box.get(_enabledKey) as bool? ?? false;
      var stored = (box.get(_urlsKey) as List<dynamic>?)
          ?.map((e) => e.toString())
          .where(isValidRelayUrl)
          .toList();

      final retiredApplied = box.get(_retiredAppliedKey) as bool? ?? false;
      if (!retiredApplied) {
        if (stored != null) {
          final pruned =
              stored.where((u) => !_retiredUrls.contains(u)).toList();
          // Never leave someone with no relay at all: an empty list falls back
          // to the defaults below, which is the right answer anyway.
          if (pruned.length != stored.length) {
            stored = pruned;
            await box.put(_urlsKey, stored);
          }
        }
        await box.put(_retiredAppliedKey, true);
      }

      final addedApplied = box.get(_addedAppliedKey) as bool? ?? false;
      if (!addedApplied) {
        if (stored != null && stored.isNotEmpty) {
          final missing =
              _addedUrls.where((u) => !stored!.contains(u)).toList();
          if (missing.isNotEmpty) {
            stored = [...stored, ...missing];
            await box.put(_urlsKey, stored);
          }
        }
        // Marked done even when the list was empty or untouched: an empty list
        // already falls through to the defaults below, which now carry it.
        await box.put(_addedAppliedKey, true);
      }

      state = RelaySettings(
        enabled: enabled,
        urls: (stored == null || stored.isEmpty)
            ? RelaySettings.defaultUrls
            : stored,
      );
    } catch (e) {
      debugPrint('RelaySettings load failed: $e');
    }
  }

  Future<void> setEnabled(bool value) async {
    state = state.copyWith(enabled: value);
    await _persist();
  }

  /// Add a relay. Returns false when the URL isn't a valid `ws(s)://` endpoint
  /// or is already in the list.
  Future<bool> addRelay(String url) async {
    final normalized = url.trim();
    if (!isValidRelayUrl(normalized)) return false;
    if (state.urls.contains(normalized)) return false;
    state = state.copyWith(urls: [...state.urls, normalized]);
    await _persist();
    return true;
  }

  Future<void> removeRelay(String url) async {
    if (!state.urls.contains(url)) return;
    state = state.copyWith(
      urls: state.urls.where((u) => u != url).toList(),
    );
    await _persist();
  }

  /// Turn the fallback off and restore the stock relay list — used by
  /// Emergency Wipe, which must leave no trace of who you talked to.
  Future<void> reset() async {
    state = RelaySettings.initial;
    try {
      await _box?.delete(_enabledKey);
      await _box?.delete(_urlsKey);
    } catch (e) {
      debugPrint('RelaySettings reset failed: $e');
    }
  }

  Future<void> _persist() async {
    final box = _box;
    if (box == null) return;
    try {
      await box.put(_enabledKey, state.enabled);
      await box.put(_urlsKey, state.urls);
    } catch (e) {
      debugPrint('RelaySettings persist failed: $e');
    }
  }

  /// A relay URL must be an absolute `ws://` or `wss://` endpoint with a host.
  /// Anything else would either fail to connect or, worse, silently fall back
  /// to some other scheme.
  static bool isValidRelayUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.isAbsolute || uri.host.isEmpty) return false;
    return uri.scheme == 'wss' || uri.scheme == 'ws';
  }
}

final relaySettingsProvider =
    NotifierProvider<RelaySettingsController, RelaySettings>(
  RelaySettingsController.new,
);

/// Live connection state per relay, published by the relay pool inside
/// [MessagingService] (which owns the sockets) and read by the settings screen.
/// Empty while the fallback is off.
class RelayStatusController extends Notifier<Map<String, RelayState>> {
  @override
  Map<String, RelayState> build() => const {};

  void publish(Map<String, RelayState> states) => state = states;

  void clear() => state = const {};
}

final relayStatusProvider =
    NotifierProvider<RelayStatusController, Map<String, RelayState>>(
  RelayStatusController.new,
);
