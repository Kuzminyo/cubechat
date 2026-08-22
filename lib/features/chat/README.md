# The chat module

One conversation on screen: the transcript, the composer, and everything a
message can be. Peers, channels and Saved Messages all render through here —
`chatId` is a 64-hex peer key, a `#channel`, or the reserved `@saved`.

Transport lives in `lib/core/transport/`. This module never touches the wire; it
calls `MessagingService` and renders what `MessagesController` holds.

## Layout

```
data/          Riverpod controllers and pure derivation
models/        Message
presentation/  screens
presentation/widgets/  bubbles, composer, pickers, panels
```

## The three rules worth knowing before editing

**1. The transcript is addressed by index.**

`chat_screen.dart` builds a reversed `ListView`, and several things point into
it by position: the jump anchors (`_initialMessageKey`, `_jumpTargetKey`), the
search highlight, `_noteBuilt`, and the album fold. **Never filter the source
list.** Hide a message by returning a zero-height box from the `itemBuilder`, the
way a folded album photo and a tag-filtered saved note both do. Filtering the
list shifts every index above it, and the failure is silent — a jump lands
somewhere else, or on nothing.

**2. Bubbles are keyed by message id.**

`MessageBubble` carries `ValueKey(m.id)`. Without it Flutter matches elements to
*slots*, so a new message at the top reuses the element already there, its State
is not rebuilt, and `initState` — the only place the entry animation is armed —
never runs. That was "анимация отправки работает через раз". Keying also stops a
half-swiped offset showing on whatever message slid into that slot.

**3. A received message is stamped on arrival, not on send.**

Nothing on the wire carries the sender's clock. `sentAt` for an inbound message
is when its *last chunk landed*, so a photo that took four minutes over
Bluetooth is stamped four minutes after the text that followed it. Anything that
reasons about ordering has to survive that — see albums below.

## Message

`models/message.dart`. One row of the transcript, whatever it holds.

`kind` is `text | image | audio | file | poll`. Media keeps bytes on disk and
uses `text` for the caption or a mime label.

Fields that are not obvious:

| field | what it is for |
|---|---|
| `wireId` | The transport id both devices file this message under. Receipts, reactions, pins and replies all key on it. Null on legacy rows. |
| `albumId` | Local only, set by `sendImageBatch`. Says exactly where one batch starts and stops; never travels. |
| `replyPreview` | What the quoted message looked like when the reply was written, so the quote box says something when the original cannot be found. |
| `readBy` | Channels only — a 1:1 has one possible reader, which `readAt` already answers. |
| `viewOnceConsumedAt` | The tombstone. The row stays so a redelivered manifest is absorbed instead of arriving viewable again. |

Storage is a plain map in `messages_controller.dart` (`_encode`/`_decode`), not a
generated adapter. New fields are optional keys — write them behind a null check
and read them with a default, and old rows keep loading.

## Photo albums

`data/photo_albums.dart`. Derived on the way to the screen; nothing about
grouping is sent or stored.

A run is per **sender**, and several are open at once — two people sending a
batch at the same time interleave in the merged list, and requiring adjacency
shredded both. A run breaks on anything that is not a plain photo (that breaks
*everyone's* run), on view-once, at nine photos, and on pace.

Pace is the part that took three attempts. `albumId` decides it outright for
what we sent ourselves. For an inbound batch there is no id, and a fixed window
cannot work: the sentence a person typed between two batches is tiny, arrives at
once, and is stamped *before* the photos it followed — so it never lands between
the two runs at all. The rule is four times the run's own median gap, floored at
45 s. A relay batch (one second apart) splits after 45 s; a Bluetooth batch (a
minute apart) stays whole.

## The composer

`widgets/chat_input.dart`. Owns the text field, the record button, and the
keyboard-slot panel (emoji/stickers).

It talks to the screen through callbacks, and the screen talks back through
`ValueListenable<int>` counters — `openStickerPanel` and `focusInput`. A counter
rather than a flag, because the same request can arrive twice and both times
mean "now". `focusInput` is bumped when a reply target appears, which is what
raises the keyboard with the quote.

The composer knows nothing about replies; the quote bar above it is the screen's.

## Media out

`MessagingService.prepareImage` mints every bubble *before* any byte is sent —
that is why our own batch is always adjacent and always groups. `transferImage`
resolves the session per photo, because the last picture of a batch may go
minutes after it was minted and the link may have changed.

Progress is `data/media_send_progress.dart`, keyed by message id, quantised to
whole percent (a 300-chunk BLE transfer would otherwise write state 300 times).
Photos draw it over the picture, voice notes beside the waveform, files around
the icon disc — files read theirs from the transfer queue instead, which had the
number all along and never showed it.

## Selection, replies, pins

Four small session-scoped controllers: `message_selection`,
`message_reply_target`, `message_edit_target`, `pinned_controller`. None is
persisted except pins; a selection or a half-written reply waiting after a
restart would be a puzzle, not a convenience.

## The long-press menu

`widgets/message_spotlight.dart`. The room blurs, the message stays lit where it
is, reactions and actions arrange around it. Two things it needs that are easy
to lose:

- the full-screen `BackdropFilter` **must** have a bounding `ClipRect`, or it
  renders nothing at all;
- the whole stack needs a `Material` ancestor, or the text picks up Flutter's
  yellow-underline fallback.

Actions are ids; the result is `'r:<emoji>'`, `'r+'`, or an action id.

## Saved Messages

`@saved` is an ordinary chat with no peer and no session, written straight into
the same store — which is what makes it searchable, pinnable and wipeable like
anything else. Tags (`chats/data/saved_tags_controller.dart`) are local, one
emoji per note, keyed by the note's uuid. The filter hides non-matching notes by
height, per rule 1.

## Things already tried and rejected

- **Lowering `AppBlur.sigma`**, and dropping the blur while scrolling. Measured;
  the first proved nothing shipped alongside a refresh-rate change, the second
  flickered visibly for 13%.
- **A tighter radius inside the photo bubble** to fix the corner seam. It drew a
  sliver of bubble in each corner. The border is gone on photo bubbles instead —
  a picture already has an edge.
- **Filtering the message list** for search or tags. See rule 1.
