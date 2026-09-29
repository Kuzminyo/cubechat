import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/dart.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/crypto/identity_service.dart';
import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';
import '../../../core/transport/announcement.dart';
import '../../../core/transport/contact_card.dart';
import '../../../core/transport/messaging_service.dart';
import '../../../core/transport/nostr/nostr_signer.dart';
import '../../../core/util/debug_log.dart';
import '../domain/cube_name.dart';
import 'cube_id_client.dart';
import 'cube_id_events.dart';
import 'known_names_controller.dart';

/// This phone's own @name, as far as it knows.
@immutable
class CubeIdState {
  const CubeIdState({this.name, this.renewedAt, this.cardDigest});

  final String? name;
  final DateTime? renewedAt;

  /// Hex SHA-256 of the card last sent to the server. A different digest for
  /// the card we would send now means the nickname, avatar or prekey changed,
  /// and a lookup would otherwise hand out the old ones.
  final String? cardDigest;

  static const empty = CubeIdState();

  Map<String, Object?> toMap() => {
        'name': name,
        'renewedAt': renewedAt?.millisecondsSinceEpoch,
        'cardDigest': cardDigest,
      };

  static CubeIdState fromMap(Map<dynamic, dynamic> m) => CubeIdState(
        name: m['name'] as String?,
        renewedAt: m['renewedAt'] is int
            ? DateTime.fromMillisecondsSinceEpoch(m['renewedAt'] as int)
            : null,
        cardDigest: m['cardDigest'] as String?,
      );
}

sealed class LookupResult {
  const LookupResult();
}

class LookupFound extends LookupResult {
  const LookupFound(this.pubkeyHex, this.name);
  final String pubkeyHex;
  final String name;
}

class LookupNotFound extends LookupResult {
  const LookupNotFound();
}

class LookupOffline extends LookupResult {
  const LookupOffline();
}

final cubeIdClientProvider = Provider<CubeIdClient>((_) => CubeIdClient());

/// Takes, keeps and gives back this phone's @name, and finds other people's.
///
/// The server keeps a name alive only while it is renewed (six months), and
/// hands out whatever card it was last given — so [maintain] renews weekly
/// and re-sends the card whenever ours has changed. Every call is signed with
/// the same Nostr key the card carries; see `id/src/registry.js`.
class CubeIdController extends Notifier<CubeIdState> {
  static const _key = 'cubeId.state';

  /// How stale a renewal may get before [maintain] sends another. The server
  /// forgets a name after 182 days; weekly leaves every margin.
  static const renewEvery = Duration(days: 7);

  /// Tests set this to avoid building a real announcement.
  @visibleForTesting
  static Future<Uint8List> Function(Ref ref)? cardSourceOverride;

  Box<dynamic>? _box;
  Future<void>? _loading;
  bool _touched = false;

  Future<void> get loaded => _loading ?? Future<void>.value();

  CubeIdClient get _client => ref.read(cubeIdClientProvider);

  @override
  CubeIdState build() {
    unawaited(_loading = _load());
    return CubeIdState.empty;
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      if (_touched) return;
      final raw = box.get(_key);
      if (raw is Map) state = CubeIdState.fromMap(raw);
    } catch (e) {
      debugPrint('CubeIdController load failed: $e');
    }
  }

  Future<void> _set(CubeIdState next) async {
    _touched = true;
    state = next;
    try {
      await loaded;
      if (next.name == null) {
        await _box?.delete(_key);
      } else {
        await _box?.put(_key, next.toMap());
      }
    } catch (e) {
      debugPrint('CubeIdController persist failed: $e');
    }
  }

  Future<Secp256k1NostrSigner> _signer() async {
    final identity = await ref.read(identityProvider.future);
    return Secp256k1NostrSigner.deriveFromSeed(
      Uint8List.fromList(identity.signPrivateKey),
    );
  }

  Future<Uint8List> _card() =>
      cardSourceOverride?.call(ref) ??
      ref.read(messagingServiceProvider).buildSignedAnnouncement();

  static String _digest(List<int> bytes) => const DartSha256()
      .hashSync(bytes)
      .bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();

  static String _b64(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  /// The server's own `reach` for us. Until the privacy setting exists this
  /// is always `all`.
  String _reach() => 'all';

  Future<CubeIdResult> _send(
    Map<String, Object?> content, {
    bool proofOfWork = false,
  }) async {
    final event = await buildCubeIdEvent(
      signer: await _signer(),
      content: content,
      now: DateTime.now(),
      proofOfWork: proofOfWork,
    );
    return _client.send(event);
  }

  /// Take [raw] as our name, or move to it when we already have one (the old
  /// one keeps pointing at us for 30 days on the server).
  Future<CubeIdResult> claim(String raw) async {
    await loaded;
    final name = normalizeCubeName(raw);
    final problem = cubeNameProblem(name);
    if (problem != null) return CubeIdRefused(problem.name);
    final card = await _card();
    final result = await _send(
      {
        'op': state.name == null ? 'claim' : 'rename',
        'name': name,
        'card': _b64(card),
      },
      proofOfWork: true,
    );
    if (result is CubeIdOk) {
      await _set(
        CubeIdState(
          name: name,
          renewedAt: DateTime.now(),
          cardDigest: _digest(card),
        ),
      );
    }
    return result;
  }

  Future<CubeIdResult> rename(String raw) => claim(raw);

  /// Give the name back. Local state is cleared whatever the server says:
  /// the person asked for it gone, and a server that cannot be reached frees
  /// it on its own after six months.
  Future<CubeIdResult> release({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    await loaded;
    if (state.name == null) return const CubeIdOk(null);
    CubeIdResult result;
    try {
      result = await _send({'op': 'release'})
          .timeout(timeout, onTimeout: () => const CubeIdOffline());
    } catch (e) {
      result = const CubeIdOffline();
    }
    await _set(CubeIdState.empty);
    return result;
  }

  /// Weekly renewal, and a fresh card whenever ours changed. Never throws;
  /// a failure is simply tried again at the next start or resume.
  Future<void> maintain() async {
    try {
      await loaded;
      if (state.name == null) return;
      final card = await _card();
      final digest = _digest(card);
      CubeIdResult? result;
      if (digest != state.cardDigest) {
        result = await _send({
          'op': 'update',
          'card': _b64(card),
          'reach': _reach(),
        });
        if (result is CubeIdOk) {
          await _set(
            CubeIdState(
              name: state.name,
              renewedAt: DateTime.now(),
              cardDigest: digest,
            ),
          );
        }
      } else {
        final renewed = state.renewedAt;
        if (renewed == null ||
            DateTime.now().difference(renewed) > renewEvery) {
          result = await _send({'op': 'renew'});
          if (result is CubeIdOk) {
            await _set(
              CubeIdState(
                name: state.name,
                renewedAt: DateTime.now(),
                cardDigest: state.cardDigest,
              ),
            );
          }
        }
      }
      if (result is CubeIdRefused && result.code == 'no-name') {
        // Expired or revoked on the server: showing it here would be a lie.
        DebugLog.instance.log('CUBEID', 'server no longer has our name');
        await _set(CubeIdState.empty);
      }
    } catch (e) {
      DebugLog.instance.log('CUBEID', 'maintain failed: $e');
    }
  }

  /// Tell the server who may find us — `none` hides the name from lookups.
  Future<void> pushReach(String reach) async {
    try {
      await loaded;
      if (state.name == null) return;
      final card = await _card();
      final result = await _send({
        'op': 'update',
        'card': _b64(card),
        'reach': reach,
      });
      if (result is CubeIdOk) {
        await _set(
          CubeIdState(
            name: state.name,
            renewedAt: state.renewedAt,
            cardDigest: _digest(card),
          ),
        );
      }
    } catch (e) {
      DebugLog.instance.log('CUBEID', 'reach update failed: $e');
    }
  }

  /// Find [raw] and add them as a contact, through the same verified path a
  /// card from a QR code takes. A card whose signature does not hold is
  /// treated as not found — the server cannot slip in a forged identity.
  Future<LookupResult> lookupAndAdd(String raw) async {
    final name = normalizeCubeName(raw);
    if (cubeNameProblem(name) == CubeNameProblem.invalid) {
      return const LookupNotFound();
    }
    final bytes = await _client.card(name);
    if (bytes == null) {
      return await _client.available(name) == null
          ? const LookupOffline()
          : const LookupNotFound();
    }
    try {
      await PeerAnnouncement.verifyAndDecode(bytes);
    } on FormatException {
      DebugLog.instance.log('CUBEID', 'card for @$name failed verification');
      return const LookupNotFound();
    }
    final String pubkeyHex;
    try {
      pubkeyHex = await ref
          .read(messagingServiceProvider)
          .addContactFromCard(ContactCard.encode(bytes));
    } on StateError {
      // Our own card.
      return const LookupNotFound();
    }
    await ref.read(knownNamesProvider.notifier).remember(pubkeyHex, name);
    return LookupFound(pubkeyHex, name);
  }

  Future<void> clear() => _set(CubeIdState.empty);

  @visibleForTesting
  void debugSetRenewedAt(DateTime at) => state = CubeIdState(
        name: state.name,
        renewedAt: at,
        cardDigest: state.cardDigest,
      );

  @visibleForTesting
  void debugSetCardDigest(String digest) => state = CubeIdState(
        name: state.name,
        renewedAt: state.renewedAt,
        cardDigest: digest,
      );
}

final cubeIdControllerProvider =
    NotifierProvider<CubeIdController, CubeIdState>(CubeIdController.new);
