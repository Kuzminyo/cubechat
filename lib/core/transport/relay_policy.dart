/// How a phone passes on somebody else's broadcast — a channel post, an
/// announcement — without turning a crowd into a storm.
///
/// Both ideas are bitchat's (WHITEPAPER.md, "Routing and Flood Control",
/// read 2026-09-29), whose hop budget cubechat already shares (7, cut to 5 at
/// six or more links):
///
/// * **A subset of links, not all of them.** A relay re-sends a broadcast on
///   about log₂ of its links, chosen by the message id. Neighbours of
///   neighbours overlap, so the flood still covers the mesh, while the copies
///   in the air — which grow with every link at every hop — drop sharply in a
///   dense room. The choice is seeded by the message id so one message takes
///   one path through this phone, and different messages spread over all of
///   them.
/// * **A random pause first.** Phones that heard the same frame at the same
///   moment would otherwise all re-send it at the same moment and collide on
///   the radio. Longer where it is crowded.
///
/// Only relaying is shaped. What this phone sends itself, and anything
/// addressed to one person, still goes on every link at once: a private
/// message has one destination and must not be thinned on its way there.
/// Nothing here changes a byte on the wire, so every build interoperates.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// How many of [links] direct links a relayed broadcast goes out on.
///
/// Everything up to two: a phone in a chain with two neighbours is the only
/// bridge between them, and dropping either would cut the mesh in half.
int relayLinkCount(int links) {
  if (links <= 2) return links;
  final k = (log(links) / ln2).ceil();
  return k < 2 ? 2 : k;
}

/// The links a relayed broadcast with [msgId] goes out on — deterministic for
/// one message whatever order [links] are listed in.
List<String> relayLinkSubset(List<String> links, Uint8List msgId) {
  final k = relayLinkCount(links.length);
  if (k >= links.length) return List<String>.of(links);
  final scored = [
    for (final link in links) (link, _score(msgId, link)),
  ]..sort((a, b) {
      final byScore = a.$2.compareTo(b.$2);
      return byScore != 0 ? byScore : a.$1.compareTo(b.$1);
    });
  return [for (final entry in scored.take(k)) entry.$1];
}

/// FNV-1a over the message id and the link id, then the murmur3 finaliser.
/// Not security: only a stable, well-spread order. Plain FNV was not enough —
/// link ids differ in their last byte only, and without the finaliser two of
/// eight links were never chosen across forty messages.
int _score(Uint8List msgId, String link) {
  var h = 0x811c9dc5;
  for (final b in [...msgId, ...utf8.encode(link)]) {
    h ^= b;
    h = (h * 0x01000193) & 0xffffffff;
  }
  h ^= h >> 16;
  h = (h * 0x85ebca6b) & 0xffffffff;
  h ^= h >> 13;
  h = (h * 0xc2b2ae35) & 0xffffffff;
  h ^= h >> 16;
  return h;
}

/// Link count at which a neighbourhood counts as crowded — the same line the
/// hop budget uses (`TransportEnvelope.denseLinkThreshold`).
const int relayDenseLinks = 6;

/// The pause before relaying a broadcast: 10–220 ms, 10–400 ms when crowded.
Duration relayJitter({required int linkCount, Random? random}) {
  final rng = random ?? _random;
  final spread = linkCount >= relayDenseLinks ? 390 : 210;
  return Duration(milliseconds: 10 + rng.nextInt(spread + 1));
}

final Random _random = Random();
