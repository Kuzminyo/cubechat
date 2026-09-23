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
    this.wifi = false,
    this.wifiUnreachable = false,
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

  /// Files are moving over the local network right now, not Bluetooth.
  final bool wifi;

  /// A Wi-Fi-only send that could not reach the other phone that way — the
  /// "not on the same network" failure, which never falls back.
  final bool wifiUnreachable;

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
    bool? wifi,
    bool? wifiUnreachable,
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
        wifi: wifi ?? this.wifi,
        wifiUnreachable: wifiUnreachable ?? this.wifiUnreachable,
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
          phase:
              t.doneCount > 0 ? AirDropPhase.partial : AirDropPhase.cancelled,
        );

  static AirDropTransfer expire(AirDropTransfer t, DateTime now) =>
      t.phase == AirDropPhase.interrupted && !t.acceptedStill(now)
          ? t.copyWith(
              phase:
                  t.doneCount > 0 ? AirDropPhase.partial : AirDropPhase.failed,
            )
          : t;
}
