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

  static const defaultUrls = <String>[
    'wss://relay.damus.io',
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
      final stored = (box.get(_urlsKey) as List<dynamic>?)
          ?.map((e) => e.toString())
          .where(isValidRelayUrl)
          .toList();
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
