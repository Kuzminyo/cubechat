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
  static const defaultUrls = <String>[
    'wss://nos.lol',
    'wss://relay.primal.net',
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
