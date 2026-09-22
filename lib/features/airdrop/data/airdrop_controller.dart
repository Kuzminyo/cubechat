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
    ref.listen(
      fileTransferControllerProvider,
      (_, tasks) => _noteProgress(tasks),
    );
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
      if (record != null) {
        spam.put(t.peerHex, AirDropSpamGuard.onAccept(record));
      }
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
    ref
        .read(airdropHistoryProvider.notifier)
        .add(AirDropHistoryEntry.of(t, _now));
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
