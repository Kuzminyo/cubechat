import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/crypto/identity_service.dart';
import '../../../core/identity/nickname_controller.dart';
import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';
import 'channel_controller.dart';

@immutable
class ChannelMember {
  const ChannelMember({
    required this.id,
    required this.name,
    required this.isAdmin,
    required this.lastSeen,
    this.mutedUntil,
    this.removedAt,
    this.provisionalAdmin = false,
    this.isOwner = false,
  });

  final String id;
  final String name;
  final bool isAdmin;
  final DateTime lastSeen;

  /// Silenced by an administrator until this moment. Their posts are dropped
  /// on arrival; they stay in the room and keep reading.
  final DateTime? mutedUntil;

  /// Put out of the room by an administrator.
  ///
  /// The row stays rather than being deleted, and that is the point: a roster
  /// grows from traffic, so deleting somebody would last exactly until their
  /// next message re-created them. Kept and marked, the row is what every
  /// later frame of theirs is checked against.
  ///
  /// Not a ban. Nothing stops them deriving the key from the room's name
  /// again — a shared key is the only membership there is — so this is every
  /// other member declining to accept what they write, which is the strongest
  /// thing a room without a server can do.
  final DateTime? removedAt;

  /// A seat this phone handed itself because the room looked unowned.
  ///
  /// Joining is deriving a key from a name, so two people who each typed it
  /// start with an empty roster and each grant themselves the room — and then
  /// refuse each other's claim, because a claim is only accepted on a room
  /// with nobody in the seat. Both ended up administrators of the same
  /// channel, which is why nobody ever saw a reader's view of one.
  ///
  /// Marking the claim as unconfirmed is what makes it possible to give up:
  /// a seat granted by somebody who already held one is settled, and one
  /// granted by an empty roster is a guess. See the `channelAdmin` ingest,
  /// where two guesses are resolved the same way on both phones.
  final bool provisionalAdmin;

  /// The one member who may close the room for everybody.
  ///
  /// **This is a record, not a proof.** The protocol has no creation event to
  /// attach ownership to — joining is deriving a key from a name, and the
  /// first person to type it is indistinguishable from the tenth — so there is
  /// nothing to check a claim against. What this records is the first *settled*
  /// administrator each phone saw: the seat somebody took and everyone else
  /// accepted. In a room made by one person and joined by others that is the
  /// person who made it, on every phone, because the claim spreads from one
  /// place.
  ///
  /// Written once and never moved. Ownership does not follow the admin list,
  /// or an owner could appoint an administrator and be deleted by them.
  final bool isOwner;

  bool get isRemoved => removedAt != null;

  bool get isMutedNow =>
      mutedUntil != null && mutedUntil!.isAfter(DateTime.now());

  /// Whether what this member writes is accepted at all.
  bool get canPost => !isRemoved && !isMutedNow;

  ChannelMember copyWith({
    String? name,
    bool? isAdmin,
    DateTime? lastSeen,
    DateTime? mutedUntil,
    DateTime? removedAt,
    bool clearModeration = false,
    bool? provisionalAdmin,
    bool? isOwner,
  }) =>
      ChannelMember(
        id: id,
        name: name ?? this.name,
        isAdmin: isAdmin ?? this.isAdmin,
        lastSeen: lastSeen ?? this.lastSeen,
        mutedUntil: clearModeration ? null : (mutedUntil ?? this.mutedUntil),
        removedAt: clearModeration ? null : (removedAt ?? this.removedAt),
        provisionalAdmin: provisionalAdmin ?? this.provisionalAdmin,
        isOwner: isOwner ?? this.isOwner,
      );
}

/// Locally verified roster for every joined channel.
///
/// A shared-key channel has no server-side membership list. The roster grows
/// only from signed channel traffic and signed 1:1 invitations, so an arbitrary
/// mesh relay cannot invent a visible participant.
class ChannelRosterController
    extends Notifier<Map<String, Map<String, ChannelMember>>> {
  static const _key = 'channel_rosters_v2';

  Box<dynamic>? _box;
  Future<void>? _loading;

  Future<void> get loaded => _loading ?? Future<void>.value();

  @override
  Map<String, Map<String, ChannelMember>> build() {
    unawaited(_loading = _load());
    return const {};
  }

  /// Everyone in the room, administrators first.
  ///
  /// Removed members are not in the room and are not listed. They are still in
  /// the map — see [ChannelMember.removedAt] — because that is what their next
  /// message is checked against.
  List<ChannelMember> membersFor(String channel) {
    final members = state[channel]
            ?.values
            .where((m) => !m.isRemoved)
            .toList() ??
        <ChannelMember>[];
    members.sort((a, b) {
      if (a.isAdmin != b.isAdmin) return a.isAdmin ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return members;
  }

  bool isAdmin(String channel, String memberId) =>
      state[channel]?[memberId]?.isAdmin ?? false;

  /// Whether anybody at all is recorded as running this channel.
  ///
  /// A channel has no creation event to attach ownership to. There is no
  /// server, and [ChannelController] only knows how to *join* a name — the
  /// first person to type it is indistinguishable from the tenth, so "who made
  /// this" is not a question the protocol can answer.
  ///
  /// Admin was therefore being handed out by [ensureSelf] to whoever opened the
  /// info screen while the roster still happened to be empty. The roster fills
  /// up from other people's messages, so in a channel where two people talk
  /// before either opens the screen, the answer is nobody — and nobody was then
  /// able to set the picture or the topic, on either phone, with no way to
  /// appoint anyone because appointing is itself an admin action. A tester hit
  /// exactly that with a two-person channel.
  ///
  /// So a channel with no admin is treated as unowned rather than as locked:
  /// see the caller. That is also the honest description of it — an empty admin
  /// list is not a permission being enforced, it is the absence of one.
  bool hasAdmin(String channel) =>
      state[channel]?.values.any((m) => m.isAdmin) ?? false;

  /// Whether anybody holds this room on more than their own say-so.
  ///
  /// [hasAdmin] answers "is the seat taken", and it is taken the instant this
  /// phone hands it to itself — which is why two people who each typed the
  /// room's name both ended up administrators and each refused the other's
  /// claim. This asks the question that can actually settle it: does anybody
  /// hold the room by something other than a guess made on an empty roster.
  bool hasConfirmedAdmin(String channel) =>
      state[channel]?.values.any((m) => m.isAdmin && !m.provisionalAdmin) ??
      false;

  /// True when our seat here is one we handed ourselves.
  bool holdsProvisionalSeat(String channel, String memberId) {
    final member = state[channel]?[memberId];
    return member != null && member.isAdmin && member.provisionalAdmin;
  }

  /// Record ourselves in [channel]'s roster, claiming the admin seat if it is
  /// going spare.
  ///
  /// [adminWhenFirst] used to mean "when the roster is empty", which made
  /// ownership an accident of timing: the roster fills from other people's
  /// messages, so whether you became admin depended on opening the info screen
  /// before anyone spoke. In a room where two people talked first, nobody ever
  /// did, and nobody could be appointed either — appointing is an admin action.
  ///
  /// It now means "when nobody is admin". A room with an unclaimed seat gives
  /// it to the first member who reaches for it, which is deterministic enough
  /// to be explicable and leaves the room with a real owner rather than a rule
  /// that never applies to anyone.
  ///
  /// An invitee never claims: [Channel.viaInvite] is the one fact this protocol
  /// can establish about seniority, and someone who was invited demonstrably
  /// arrived after whoever invited them. Without that check the seat would go
  /// to whichever member happened to open a screen first, which is how this got
  /// into trouble the last time.
  Future<ChannelMember> ensureSelf(
    String channel, {
    bool adminWhenFirst = false,
  }) async {
    final identity = await ref.read(identityProvider.future);
    final id = fingerprintOf(identity.signPublicKey);
    final existing = state[channel]?[id];
    final invited =
        ref.read(channelControllerProvider.notifier).byName(channel)?.viaInvite ??
            false;
    final claiming =
        existing == null && adminWhenFirst && !invited && !hasAdmin(channel);
    final member = ChannelMember(
      id: id,
      name: ref.read(nicknameControllerProvider),
      isAdmin: existing?.isAdmin ?? claiming,
      lastSeen: DateTime.now(),
      // Ours by guess, not by grant. See [ChannelMember.provisionalAdmin] —
      // it is what lets this phone stand down when somebody else turns out to
      // have made the same guess first.
      provisionalAdmin: existing?.provisionalAdmin ?? claiming,
    );
    await record(channel, member);
    return member;
  }

  /// Our own id in every roster: the first 16 hex characters of our Ed25519
  /// key, which is all a signed channel frame reveals about who wrote it.
  Future<String> selfMemberId() async {
    final identity = await ref.read(identityProvider.future);
    return fingerprintOf(identity.signPublicKey);
  }

  Future<void> record(String channel, ChannelMember member) async {
    final current = state[channel] ?? const <String, ChannelMember>{};
    final old = current[member.id];
    final merged = old == null
        ? member
        : member.copyWith(
            isAdmin: old.isAdmin || member.isAdmin,
            name: member.name.trim().isEmpty ? old.name : member.name,
            // A moderator's decision is not undone by the next thing the
            // member says. This method is called for every frame that arrives
            // from them, so without these two a removal would last until they
            // typed again.
            mutedUntil: old.mutedUntil,
            removedAt: old.removedAt,
            provisionalAdmin: old.provisionalAdmin,
          );
    state = {
      ...state,
      channel: {...current, member.id: merged},
    };
    await _persist();
  }

  Future<void> setAdmin(
    String channel,
    String memberId,
    bool admin,
  ) async {
    final current = state[channel] ?? const <String, ChannelMember>{};
    // Recorded on the spot when the room has never heard of them. A seat can
    // be granted to somebody whose first frame has not arrived yet — an
    // invitation names them, a claim of their own names them — and dropping it
    // because there is no row to edit is how a room ends up with an admin
    // nobody has.
    final member = current[memberId] ??
        ChannelMember(
          id: memberId,
          name: '',
          isAdmin: false,
          lastSeen: DateTime.now(),
        );
    if (member.isAdmin == admin && current.containsKey(memberId)) return;
    // The first settled seat in a room is its owner, and stays its owner.
    //
    // Not "the current administrator": ownership that followed the admin list
    // would let an owner appoint somebody and be deleted by them an hour
    // later. Written once, when there is nobody to displace.
    final claimsRoom =
        admin && !current.values.any((m) => m.isOwner) && member.isOwner != true;
    state = {
      ...state,
      channel: {
        ...current,
        // Settled either way: somebody said so out loud. A seat granted here
        // is no longer a guess, and one taken away leaves nothing to be
        // provisional about.
        memberId: member.copyWith(
          isAdmin: admin,
          provisionalAdmin: false,
          isOwner: claimsRoom ? true : null,
        ),
      },
    };
    await _persist();
  }

  /// Who may close this room for everybody, or null when nobody is recorded.
  ///
  /// Null is the normal answer for a room that existed before ownership did,
  /// and for one whose seat is still a guess. The caller decides what to do
  /// about it — see the channel delete ingest, which will not act on a room
  /// with no owner rather than falling back to "any administrator".
  String? ownerOf(String channel) {
    for (final member in (state[channel] ?? const <String, ChannelMember>{})
        .values) {
      if (member.isOwner) return member.id;
    }
    return null;
  }

  bool isOwner(String channel, String memberId) =>
      ownerOf(channel) == memberId;

  /// Apply an administrator's decision about one member.
  ///
  /// Local, like every other channel rule: what a moderator sends is a signed
  /// claim, and this is one device deciding to honour it. The caller has
  /// already checked that the sender is an administrator here.
  ///
  /// Records the member first when the room has never heard of them, so a
  /// removal that arrives before their first message still lands.
  Future<void> moderate(
    String channel, {
    required String memberId,
    required bool removed,
    DateTime? mutedUntil,
    bool clear = false,
  }) async {
    final current = state[channel] ?? const <String, ChannelMember>{};
    final member = current[memberId] ??
        ChannelMember(
          id: memberId,
          name: '',
          isAdmin: false,
          lastSeen: DateTime.now(),
        );
    final next = clear
        ? member.copyWith(clearModeration: true)
        : ChannelMember(
            id: member.id,
            name: member.name,
            isAdmin: member.isAdmin,
            lastSeen: member.lastSeen,
            mutedUntil: mutedUntil,
            removedAt: removed ? DateTime.now() : null,
          );
    state = {
      ...state,
      channel: {...current, memberId: next},
    };
    await _persist();
  }

  /// Whether this member's posts are accepted in [channel].
  ///
  /// Unknown members pass: a roster is learned from traffic, so somebody's
  /// first message necessarily arrives before there is a row for them, and
  /// refusing that would make the room unjoinable.
  bool canPost(String channel, String memberId) =>
      state[channel]?[memberId]?.canPost ?? true;

  Future<void> forget(String channel) async {
    if (!state.containsKey(channel)) return;
    state = {...state}..remove(channel);
    await _persist();
  }

  Future<void> clear() async {
    state = const {};
    await _box?.delete(_key);
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider.openEncryptedBox<dynamic>(
        HiveBoxes.settings,
      );
      _box = box;
      final raw = box.get(_key);
      if (raw is! Map) return;
      final loaded = <String, Map<String, ChannelMember>>{};
      for (final channelEntry in raw.entries) {
        if (channelEntry.key is! String || channelEntry.value is! Map) continue;
        final members = <String, ChannelMember>{};
        for (final memberEntry in (channelEntry.value as Map).entries) {
          if (memberEntry.key is! String || memberEntry.value is! Map) continue;
          final data = memberEntry.value as Map;
          final seen = DateTime.tryParse(data['lastSeen'] as String? ?? '');
          if (seen == null) continue;
          members[memberEntry.key as String] = ChannelMember(
            id: memberEntry.key as String,
            name: data['name'] as String? ?? 'Member',
            isAdmin: data['admin'] as bool? ?? false,
            lastSeen: seen,
            mutedUntil: DateTime.tryParse(data['mutedUntil'] as String? ?? ''),
            removedAt: DateTime.tryParse(data['removedAt'] as String? ?? ''),
            // Absent for a seat stored before the distinction existed. Read as
            // provisional, because that is what those seats were: every one of
            // them was handed out by an empty roster.
            provisionalAdmin: data['confirmedAdmin'] != true,
            // Absent for every roster stored before ownership existed. Those
            // rooms have no owner until somebody's seat settles again, which
            // is the honest answer: nothing recorded who made them.
            isOwner: data['owner'] == true,
          );
        }
        loaded[channelEntry.key as String] = members;
      }
      state = {...loaded, ...state};
    } catch (error) {
      debugPrint('Channel roster load failed: $error');
    }
  }

  Future<void> _persist() async {
    final box = _box;
    if (box == null) return;
    await box.put(_key, {
      for (final channel in state.entries)
        channel.key: {
          for (final member in channel.value.entries)
            member.key: {
              'name': member.value.name,
              'admin': member.value.isAdmin,
              'lastSeen': member.value.lastSeen.toIso8601String(),
              if (member.value.mutedUntil != null)
                'mutedUntil': member.value.mutedUntil!.toIso8601String(),
              if (member.value.removedAt != null)
                'removedAt': member.value.removedAt!.toIso8601String(),
              // Written as the *settled* case, so its absence means a guess.
              // The other way round, a confirmed seat would store nothing and
              // read back as provisional on the next launch — which is also
              // exactly what every seat stored before this existed was.
              if (!member.value.provisionalAdmin) 'confirmedAdmin': true,
              if (member.value.isOwner) 'owner': true,
            },
        },
    });
  }

  /// Public so callers outside a room can derive the same id.
  static String fingerprintOf(Uint8List bytes) => bytes
      .take(8)
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
}

final channelRosterControllerProvider = NotifierProvider<
    ChannelRosterController,
    Map<String, Map<String, ChannelMember>>>(ChannelRosterController.new);

/// The sixteen hex characters of our own signing key that a channel frame
/// carries as its author id.
///
/// The same thing [ChannelRosterController.ensureSelf] files us under, but
/// without needing a room to ask about — the id is a property of this phone,
/// not of any membership. Read by anything that has to answer "is this frame
/// about me", such as a contact invitation posted into a room.
final myChannelFingerprintProvider = FutureProvider<String>((ref) async {
  final identity = await ref.watch(identityProvider.future);
  return ChannelRosterController.fingerprintOf(identity.signPublicKey);
});
