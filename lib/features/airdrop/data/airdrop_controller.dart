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
import '../presentation/airdrop_navigation.dart'
    show kAirDropNotificationThread;
import '../presentation/airdrop_text.dart';
import 'airdrop_clock.dart';
import 'airdrop_history_controller.dart';
import 'airdrop_lane_controller.dart';
import 'airdrop_port.dart';
import 'airdrop_receive_controller.dart';
import 'airdrop_source.dart';
import 'airdrop_spam_store.dart';
import 'airdrop_storage.dart';
import 'bump_ledger.dart';
import 'wifi_lane.dart';

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
              threadKey: kAirDropNotificationThread,
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

  /// Incoming transfer id → the port its files come to, while it is open.
  final Map<String, WifiLaneReceiver> _receivers = {};

  /// Incoming transfer ids whose sender can take Wi-Fi (offer flag bit 0).
  final Set<String> _senderCanWifi = {};

  /// Outgoing transfer id → where the receiver said to connect.
  final Map<String, NearbyWifiEndpoint> _endpoints = {};

  /// Outgoing transfer ids accepted by an app too old for Wi-Fi — see
  /// [NearbyDeclineReason.noLocalNetwork].
  final Set<String> _noWifiApp = {};

  /// Outgoing transfer id → the open connection.
  final Map<String, WifiLaneSender> _senders = {};

  /// Outgoing transfer id → the channel setting when it was offered.
  final Map<String, AirDropLane> _lanes = {};

  /// Media ids whose Files-centre row this controller set to "cancelled"
  /// itself (a stall, a stop). An incoming row cancelled by anyone else is
  /// the person pressing the cross, which stops the transfer — see
  /// [_userCancelledIncoming].
  final Set<String> _selfCancelled = {};

  /// Incoming transfer ids whose receiver is inside its `onFile` right now.
  /// A transfer that ends there must not close that receiver: `close()`
  /// waits for the batch that is waiting on `onFile` (a deadlock if awaited),
  /// and even unawaited it destroys the socket before the receiver has told
  /// the sender "kept" — the sender then counts the last file as failed and
  /// sends it again over Bluetooth, into a transfer that has already ended.
  final Set<String> _keeping = {};

  StreamSubscription<NearbyInbound>? _inbound;
  Timer? _ticker;
  final _random = Random.secure();

  AirDropPort get _port => ref.read(airdropPortProvider);
  AirDropWifi get _wifi => ref.read(airdropWifiProvider);
  DateTime get _now => ref.read(airdropClockProvider)();

  @override
  AirDropState build() {
    final port = ref.read(airdropPortProvider);
    _inbound = port.inbound.listen((m) => unawaited(_onInbound(m)));
    port.sink = this;
    ref.listen(
      fileTransferControllerProvider,
      (_, tasks) => _noteProgress(tasks),
    );
    ref.onDispose(() {
      unawaited(_inbound?.cancel());
      port.sink = null;
      _cancelAllTimers();
      _closeAllWifi();
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
    // The setting loads from its box on first read; a send right after the
    // app starts would otherwise go out as "Auto" whatever was chosen.
    await ref.read(airdropLaneProvider.notifier).loaded;
    final lane = ref.read(airdropLaneProvider);
    final transferId = _newId();
    // Pinned here: the flag on the wire was chosen from it, and a switch of
    // the setting while this one is in flight must not turn a Bluetooth offer
    // into a "no Wi-Fi route" failure.
    _lanes[nearbyHex(transferId)] = lane;
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
        flags: lane == AirDropLane.bluetooth ? 0 : nearbyFlagWifi,
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
            AirDropSource(
              file: file,
              name: f.name,
              size: f.size,
              mime: f.mime,
            ),
    ];
    _finish(AirDropTransitions.expire(t, _now));
    if (left.isNotEmpty) {
      await offer(peerHex: t.peerHex, peerName: t.peerName, files: left);
    }
  }

  /// Sends the files of an accepted offer one after another — over the local
  /// network when the receiver gave an endpoint and the setting allows it,
  /// over Bluetooth otherwise.
  Future<void> _pump(String id) async {
    var endpoint = _endpoints.remove(id);
    final lane = _lanes[id] ?? AirDropLane.auto;
    final oldApp = _noWifiApp.remove(id);
    if (endpoint != null &&
        lane != AirDropLane.bluetooth &&
        !_senders.containsKey(id) &&
        !lanEndpointAllowed(
          endpoint.address,
          own: await _wifi.localAddress().catchError((Object _) => null),
        )) {
      // Treated as no endpoint at all — see [lanEndpointAllowed].
      DebugLog.instance.log(
        'AIRDROP',
        'wifi: not dialling ${endpoint.address} — not a local address',
      );
      endpoint = null;
    }
    if (endpoint != null &&
        lane != AirDropLane.bluetooth &&
        !_senders.containsKey(id)) {
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
      } else if (lane != AirDropLane.wifi) {
        DebugLog.instance.log(
          'AIRDROP',
          'wifi: no route to ${_short(now.peerHex)} — Bluetooth',
        );
      }
    }
    // "Wi-Fi" means fail rather than crawl: no connection — including a
    // receiver that gave no endpoint at all (an older build, or a phone on no
    // network) — ends the send here instead of quietly using Bluetooth.
    if (lane == AirDropLane.wifi && !_senders.containsKey(id)) {
      final now = state.byId(id);
      if (now != null && now.phase == AirDropPhase.transferring) {
        _failWifiOnly(now, noRoute: !oldApp, oldApp: oldApp);
      }
      return;
    }
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
      final tx = _senders[id];
      final bool ok;
      if (tx != null) {
        _trackOutgoing(t, current, source);
        final files = ref.read(fileTransferControllerProvider.notifier);
        bool canceled() =>
            ref.read(fileTransferControllerProvider)[current.mediaIdHex]
                ?.status ==
            FileTransferStatus.canceled;
        // A phone that walks out of range mid-file leaves the socket's flush
        // waiting until TCP gives up, which is minutes. Nothing for this long
        // closes the connection, and the failure goes the usual way.
        Timer? watchdog;
        void arm() {
          watchdog?.cancel();
          watchdog = Timer(AirDropRules.wifiStallAfter, () {
            DebugLog.instance.log(
              'AIRDROP',
              'wifi: "${current.name}" stalled — closing the connection',
            );
            unawaited(tx.close());
          });
        }

        arm();
        final bool sent;
        try {
          sent = await tx.sendFile(
            mediaIdHex: current.mediaIdHex,
            file: source,
            size: current.size,
            onProgress: (m, done, total) {
              arm();
              files.setProgress(m, done, total);
            },
            cancelled: canceled,
          );
        } finally {
          watchdog?.cancel();
        }
        if (sent) {
          files.complete(current.mediaIdHex);
        } else {
          final latest = state.byId(id);
          if (latest == null || latest.phase != AirDropPhase.transferring) {
            return;
          }
          // The cross in the Files centre is a stop of the whole transfer,
          // as it would be on the AirDrop page — not a cue to go on by
          // Bluetooth.
          if (canceled()) {
            _stop(latest, tell: true);
            return;
          }
          await _senders.remove(id)?.close();
          files.setStatus(current.mediaIdHex, FileTransferStatus.failed);
          if (lane == AirDropLane.wifi) {
            // Connected, so a route exists: a refused file or a dropped
            // connection is not "not on the same network".
            _failWifiOnly(latest, noRoute: false);
            return;
          }
          DebugLog.instance.log(
            'AIRDROP',
            'wifi: "${current.name}" failed — the rest over Bluetooth',
          );
          _update(id, (x) => x.copyWith(wifi: false));
          continue; // the same file again, now over Bluetooth
        }
        ok = sent;
      } else {
        ok = await _port.sendFile(
          t.peerHex,
          file: source,
          meta: current,
          peerName: t.peerName,
        );
      }
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

  /// A "Wi-Fi only" send that cannot go on that way. What already went stays
  /// (partial), and the receiver is told, so its port closes and its card
  /// goes rather than waiting out the stall timer. [noRoute] only when the
  /// phones never connected — a failed connect or no endpoint at all.
  void _failWifiOnly(
    AirDropTransfer t, {
    required bool noRoute,
    bool oldApp = false,
  }) {
    _finish(
      t.copyWith(
        phase: t.doneCount > 0 ? AirDropPhase.partial : AirDropPhase.failed,
        wifiUnreachable: noRoute,
        wifiOldVersion: oldApp,
      ),
    );
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

  /// The Files centre row for a file going over Wi-Fi — the Bluetooth path
  /// gets its row from the messaging service. Made afresh for every attempt:
  /// a row left "cancelled" or "failed" by an earlier one would stop this one
  /// at its first chunk.
  void _trackOutgoing(AirDropTransfer t, AirDropFile f, File source) {
    final now = _now;
    ref.read(fileTransferControllerProvider.notifier).register(
          FileTransferTask(
            id: f.mediaIdHex,
            chatId: t.peerHex,
            fileName: f.name,
            filePath: source.path,
            mime: f.mime,
            bytesTotal: f.size,
            completedUnits: 0,
            totalUnits: f.size,
            direction: FileTransferDirection.outgoing,
            status: FileTransferStatus.transferring,
            createdAt: now,
            updatedAt: now,
            source: FileTransferSource.airdrop,
            peerName: t.peerName,
          ),
        );
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
    if (answer != null) {
      _onAnswer(m.peerHex, answer);
      return;
    }
    // The bump gesture itself: a later task's BumpController matches it
    // against the device's own recent bump. Nothing for AirDrop to do here.
    if (m.bump != null) return;
  }

  Future<void> _onOffer(String peerHex, NearbyOffer offer) async {
    final id = nearbyHex(offer.transferId);
    if (state.byId(id) != null) return;
    final contact = ref.read(airdropContactsProvider).contains(peerHex);
    // Bringing the phone to theirs is the consent that "Прийняти" would have
    // been: no spam accounting for it (nothing to guard against — the person
    // is standing right here), and it is not "a stranger asking", so the
    // contacts-only filter below does not apply to it either. `take` spends
    // the note: one bump buys exactly one auto-accepted offer, not every
    // offer that arrives in the next ten seconds.
    final bumped = ref.read(bumpLedgerProvider).take(peerHex, _now);
    if (!bumped) {
      final spam = ref.read(airdropSpamProvider.notifier);
      if (contact) {
        spam.remove(peerHex);
      } else {
        final record =
            AirDropSpamGuard.onRequest(spam.recordFor(peerHex), _now);
        spam.put(peerHex, record);
        if (AirDropSpamGuard.isBanned(record, _now)) {
          DebugLog.instance.log(
            'AIRDROP',
            'ignored an offer from ${_short(peerHex)} — declined too often',
          );
          return;
        }
      }
    }
    // Decided before the first await: a second offer from the same phone that
    // arrives while this one is being looked at must see it and be "busy".
    NearbyDeclineReason? refusal;
    if (!bumped &&
        !contact &&
        !ref.read(airdropReceiveProvider).everyoneAt(_now)) {
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
      if (offer.flags & nearbyFlagWifi != 0) _senderCanWifi.add(id);
      _put(request);
      if (bumped && request.totalBytes <= AirDropRules.bumpAutoAcceptBytes) {
        // The bump already was the "yes" — no card to notify about and no
        // sixty-second clock on an answer nobody needs to give. Past
        // [AirDropRules.bumpAutoAcceptBytes] it is an ordinary card.
        await accept(id);
      } else {
        ref.read(airdropNotifyProvider)(request);
        _after(id, AirDropRules.answerWithin, () => unawaited(_expire(id)));
      }
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
    if (a.kind == NearbyAnswerKind.accepted && a.wifi != null) {
      _endpoints[t.id] = a.wifi!;
    } else if (a.kind == NearbyAnswerKind.accepted &&
        a.reason != NearbyDeclineReason.noLocalNetwork) {
      // An acceptance with no endpoint and no word of a missing network:
      // 1107/1108 answer every offer this way. Only read when the send is
      // Wi-Fi-only and has nothing else to go on.
      _noWifiApp.add(t.id);
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
      if (record != null) {
        spam.put(t.peerHex, AirDropSpamGuard.onAccept(record));
      }
    }
    _cancelTimers(id);
    // In the state before the answer leaves: the manifests race right behind
    // it, and each one is judged against this.
    _put(AirDropTransitions.accept(t, _now));
    final senderCanWifi = _senderCanWifi.remove(id);
    final wifi = senderCanWifi ? await _openReceiver(t) : null;
    // Taken back or wiped while the port was opening: _openReceiver has
    // already closed it, and a "yes" now would answer nothing.
    final now = state.byId(id);
    if (now == null || now.phase.isFinal) return;
    await _port.send(
      t.peerHex,
      answer: NearbyAnswer(
        transferId: nearbyUnhex(id),
        kind: NearbyAnswerKind.accepted,
        wifi: wifi,
        // Lets a Wi-Fi-only sender tell "no network here" from an app too
        // old for Wi-Fi — see [NearbyDeclineReason.noLocalNetwork].
        reason: senderCanWifi && wifi == null
            ? NearbyDeclineReason.noLocalNetwork
            : NearbyDeclineReason.user,
      ),
    );
  }

  /// A port for the files of [t], or null when this phone is on no local
  /// network (then they come over Bluetooth, as in part 1). The receiver
  /// agrees to Wi-Fi whatever its own setting: it costs it nothing.
  Future<NearbyWifiEndpoint?> _openReceiver(AirDropTransfer t) async {
    final key = Uint8List.fromList(
      List<int>.generate(
        NearbyWifiEndpoint.keyLen,
        (_) => _random.nextInt(256),
      ),
    );
    final InternetAddress address;
    final WifiLaneReceiver rx;
    // Anything at all that goes wrong here costs only the fast lane: the
    // acceptance still goes out, and the files come over Bluetooth.
    try {
      final found = await _wifi.localAddress();
      if (found == null) return null;
      address = found;
      rx = await _wifi.startReceiver(
        address: address,
        key: key,
        transferId: nearbyUnhex(t.id),
        expected: {for (final f in t.files) f.mediaIdHex: f.size},
        tempDir: await _wifiTempDir(),
        onConnected: () {
          if (_receivers.containsKey(t.id)) {
            _update(t.id, (x) => x.copyWith(wifi: true));
          }
        },
        onProgress: (id, done, total) => _trackIncoming(t, id, done, total),
        onFile: (id, file) => _keepFromWifi(t, id, file),
      );
    } on Object catch (e) {
      DebugLog.instance.log('AIRDROP', 'wifi: could not listen: $e');
      return null;
    }
    // Taken back (or wiped) while the port was opening: nobody would ever
    // close it but its own two-minute idle timer.
    final now = state.byId(t.id);
    if (now == null || now.phase.isFinal) {
      await rx.close();
      return null;
    }
    _receivers[t.id] = rx;
    // The port closes when the sender hangs up — it went on by Bluetooth, or
    // left. The card should stop saying Wi-Fi then.
    unawaited(
      rx.done.then((_) {
        if (!identical(_receivers[t.id], rx)) return;
        _update(t.id, (x) => x.wifi ? x.copyWith(wifi: false) : x);
      }),
    );
    return NearbyWifiEndpoint(
      address: address.address,
      port: rx.port,
      key: key,
    );
  }

  /// Where half-received Wi-Fi files are written: a folder of their own
  /// inside the AirDrop one, so a `.part` never sits among kept files.
  /// Synchronous on purpose — one mkdir per accepted transfer, and it keeps
  /// the controller drivable under a fake clock, where real async file I/O
  /// never completes.
  Future<Directory> _wifiTempDir() async {
    final base = await ref.read(airdropDirectoryProvider)();
    final dir = Directory('${base.path}${Platform.pathSeparator}wifi-in');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// The receiver's `onFile`. Never awaits a receiver's close — see
  /// [_keeping].
  Future<bool> _keepFromWifi(
    AirDropTransfer t,
    String mediaIdHex,
    File file,
  ) async {
    // Ended, wiped or disposed while the file was still arriving.
    if (!_receivers.containsKey(t.id)) return false;
    // Checked before [_keeping]: this stop wants the port shut at once — the
    // unawaited close in _finish cannot deadlock, and no "kept" is owed.
    if (_userCancelledIncoming(mediaIdHex)) {
      _stopForCancelledRow(t.id);
      return false;
    }
    _keeping.add(t.id);
    final files = ref.read(fileTransferControllerProvider.notifier);
    try {
      final path = await keep(
        mediaIdHex: mediaIdHex,
        senderHex: t.peerHex,
        file: file,
        name: mediaIdHex,
      );
      if (path == null) {
        // The last chunk's progress already marked the row completed.
        files.setStatus(mediaIdHex, FileTransferStatus.failed);
        return false;
      }
      final size = t.files.firstWhere((f) => f.mediaIdHex == mediaIdHex).size;
      files.complete(mediaIdHex, filePath: path, bytesTotal: size);
      return true;
    } finally {
      _keeping.remove(t.id);
    }
  }

  /// The person pressed the cross on an incoming Wi-Fi row in the Files
  /// centre — not this controller cancelling it on a stall or a stop.
  bool _userCancelledIncoming(String mediaIdHex) =>
      ref.read(fileTransferControllerProvider)[mediaIdHex]?.status ==
          FileTransferStatus.canceled &&
      !_selfCancelled.contains(mediaIdHex);

  /// A cancel in the Files centre stops the whole transfer, as it does for a
  /// file going out. Refusing just the one file is not enough: an "Auto"
  /// sender would send it again over Bluetooth.
  void _stopForCancelledRow(String id) {
    final live = state.byId(id);
    if (live != null && !live.phase.isFinal) _stop(live, tell: true);
  }

  /// The Files centre row for a file coming over Wi-Fi, and its progress —
  /// which [_noteProgress] also reads, so the stall timer works as it does
  /// for Bluetooth.
  void _trackIncoming(
    AirDropTransfer t,
    String mediaIdHex,
    int done,
    int total,
  ) {
    // A last chunk racing the end of the transfer must not leave a row behind.
    if (!_receivers.containsKey(t.id)) return;
    final files = ref.read(fileTransferControllerProvider.notifier);
    var row = ref.read(fileTransferControllerProvider)[mediaIdHex];
    if (row != null && row.status == FileTransferStatus.canceled) {
      if (!_selfCancelled.remove(mediaIdHex)) {
        _stopForCancelledRow(t.id);
        return;
      }
      // Cancelled by a stall, and the bytes came back: a fresh row, or
      // progress would never move it off "cancelled" again.
      row = null;
    }
    if (row == null) {
      // A fresh row is nobody's cancel yet: a mark left from before must not
      // excuse the person's cross on it later.
      _selfCancelled.remove(mediaIdHex);
      final offered = t.files.firstWhere((f) => f.mediaIdHex == mediaIdHex);
      final now = _now;
      files.register(
        FileTransferTask(
          id: mediaIdHex,
          chatId: t.peerHex,
          fileName: offered.name,
          filePath: '',
          mime: offered.mime,
          bytesTotal: total,
          completedUnits: 0,
          totalUnits: total,
          direction: FileTransferDirection.incoming,
          status: FileTransferStatus.transferring,
          createdAt: now,
          updatedAt: now,
          source: FileTransferSource.airdrop,
          peerName: t.peerName,
        ),
      );
    }
    files.setProgress(mediaIdHex, done, total);
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
    _closeAllWifi();
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
    final rx = _receivers.remove(t.id);
    if (rx != null) {
      // Ended by the last file kept inside the receiver's own callback: it
      // closes itself once the sender has heard "kept" (see [_keeping]).
      // `done` also completes on its idle close, so this cannot leak.
      unawaited(
        _keeping.contains(t.id) ? rx.done.then((_) => rx.close()) : rx.close(),
      );
    }
    unawaited(_senders.remove(t.id)?.close());
    _endpoints.remove(t.id);
    _noWifiApp.remove(t.id);
    _senderCanWifi.remove(t.id);
    _lanes.remove(t.id);
    for (final f in t.files) {
      _selfCancelled.remove(f.mediaIdHex);
    }
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
    ref
        .read(airdropHistoryProvider.notifier)
        .add(AirDropHistoryEntry.of(t, _now));
    DebugLog.instance.log(
      'AIRDROP',
      '${t.direction.name} ${_short(t.id)} ended: ${t.phase.name}'
          '${t.reason == null ? '' : ' (${t.reason!.name})'}'
          '${t.wifiUnreachable ? ' (no Wi-Fi route)' : ''}',
    );
  }

  /// Stop whatever file of [t] is still moving.
  void _cancelRunning(AirDropTransfer t) {
    final rows = ref.read(fileTransferControllerProvider);
    for (final f in t.files) {
      if (!f.done) {
        // Only a row this call really flips to "cancelled" is ours. One with
        // no row yet is untouched by cancelFile, and one already cancelled
        // was the person — marking either would later read their cross as
        // this controller's own and ignore it.
        final status = rows[f.mediaIdHex]?.status;
        if (status != null && status != FileTransferStatus.canceled) {
          _selfCancelled.add(f.mediaIdHex);
        }
        _port.cancelFile(f.mediaIdHex);
      }
    }
    unawaited(_senders.remove(t.id)?.close());
  }

  /// Every port and connection, for the wipe and for disposal. Unawaited: a
  /// receiver's close waits for the batch it is running, and neither caller
  /// may hang on a file still being written.
  void _closeAllWifi() {
    for (final rx in _receivers.values) {
      unawaited(rx.close());
    }
    for (final tx in _senders.values) {
      unawaited(tx.close());
    }
    _receivers.clear();
    _senders.clear();
    _endpoints.clear();
    _noWifiApp.clear();
    _senderCanWifi.clear();
    _lanes.clear();
    _selfCancelled.clear();
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
