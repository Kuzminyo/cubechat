---
name: calls
description: Voice calls in cubechat — WebRTC through our own TURN, signalled inside the message envelope, rung by CallKit on iOS and a full-screen notification on Android. Load when touching lib/features/call/**, lib/core/transport/call_signal.dart, lib/core/audio/**, CubechatCallKit.swift, CubechatCallPlugin.kt, TURN credentials or the push server's VoIP path — or when a report says a call did not ring, rang late, rang after the caller hung up, had no sound, showed no name, or lost its lock-screen permission.
user-invocable: true
---

# Calls

The rationale is in `docs/superpowers/specs/2026-09-10-calls-design.md` (Russian)
and the two plans beside it. This file describes the code as it stands; where the
two disagree, the code wins. Example: the spec puts a native bridge in
`lib/core/call/`, which was never created — the platform side is
`lib/features/call/data/incoming_call_surface.dart` talking to
`ios/Runner/CubechatCallKit.swift` on iOS, and on Android to
`CubechatCallPlugin.kt`, `IncomingCall.kt` and `IncomingCallActivity.kt` in
`android/app/src/main/kotlin/com/cubechat/cubechat/`.

**Voice only, one to one**, WebRTC via `flutter_webrtc`, over the internet. Video,
groups and calls over the mesh are out of scope. The mesh is the planned second
stage on the same signalling — which is why the invite carries its own
`sentAtMs` instead of trusting a relay timestamp the mesh will not have.

## Where things are

| File | Holds |
|---|---|
| `call/data/call_controller.dart` | the Riverpod Notifier that runs a call |
| `call/domain/call_state_machine.dart` | the states and every legal transition |
| `call/domain/call_rules.dart` | **every timing** — read before changing any wait |
| `call/data/call_media.dart` | the peer connection and the audio track |
| `call/data/turn_credentials_controller.dart` | short-lived TURN login from the push server |
| `call/data/incoming_call_surface.dart` | the incoming call the *phone* draws |
| `call/data/call_screen_access.dart` | the lock-screen permission and its loss on update |
| `call/domain/call_record.dart` | the history line each side writes locally |
| `core/transport/call_signal.dart` | the wire codec |

Outgoing: `dialing → ringing → connecting → talking → ended`.
Incoming: `incoming → connecting → talking → ended`.

## On the wire

One `InnerPayloadType`, `callSignal` **0xE7**, riding the same envelope as text —
so the SDP, DTLS fingerprint included, is protected by the session already
established. No new cryptographic primitive.

```
[version:1][kind:1][callId:16][len:2 BE][body:len]
```

| kind | | body |
|---|---|---|
| 0x01 | invite | `[sentAtMs:8][sdp]` |
| 0x02 | ringing | empty |
| 0x03 | accept | `[sdp]` |
| 0x04 | decline | `[reason:1]` |
| 0x05 | busy | empty |
| 0x06 | hangup | `[reason:1]` |

There is no message for ICE candidates. Media goes through our TURN by default,
so each side has exactly one candidate and it is already inside the SDP: one
event each way is the whole handshake.

The history line (`cubechat:call:v1:`) is written by **both sides locally** and
never sent — each already knows how the call ended.

## Timings — `call_rules.dart`

| Constant | Value | Why |
|---|---|---|
| `ringingAck` | 8 s | no `ringing` back means "unavailable", not an endless tone |
| `noAnswer` | 45 s | then a missed call |
| `inviteFreshness` | 60 s | older invites are dropped silently |
| `connecting` | 30 s | an answered call that carries no sound by then is given up |
| `clockSkew` | 30 s | how far ahead a sender's clock may be |
| `endedMemory` | 90 s | a finished `callId` is remembered this long |

## Rules that each fixed a real failure

1. **The caller rings only after an explicit `ringing` (0x02).** An old build
   drops an unknown inner type silently; without the ack the caller would hear a
   tone forever against a phone that heard nothing.
2. **Stale invites never ring.** Relays keep events and replay them on
   reconnect, so an hour-old invite arrives looking new — a phone ringing for a
   call nobody is making. `sentAtMs` older than `inviteFreshness` is dropped with
   no trace; `callId` drops redelivery.
3. **A hangup can arrive before its invite** — relays replay newest first, and
   the mesh can carry a frame the long way round. That is what `endedMemory` is
   for; do not shorten it below `inviteFreshness + clockSkew`.
4. **Glare**: both dial at once → the lexicographically lower `callId` wins, and
   both sides cancel the loser locally. No negotiation, same answer on each end.
5. **TURN down means the call fails, with a reason.** It never falls back to a
   direct connection on its own. A direct connection shows each side the other's
   IP — provider and rough location — which is exactly what the default hides.
   Direct mode exists, and a person turns it on knowingly. This is the one place
   in the design that refuses service rather than connecting somehow; keep it.
6. **Only the invite carries the VoIP tag** `['c','1']` (beside `p` and `w`), and
   the push server picks the VoIP path by it. iOS kills an app that receives a
   VoIP push without reporting a *new incoming call*, so a hangup must never
   carry `c`. It does not need to: the app is awake by then.
7. **The caller's name is not in the push** — the event is gift-wrapped and the
   server cannot decrypt it. CallKit shows a placeholder and the app updates the
   name once it has read and decrypted the event from the relay.
8. **A call takes audio focus unconditionally.** The pause-the-music toggle
   belongs to round messages, not calls. On iOS the camera patch restores the
   audio session only if it is still its own, so a call's `.voiceChat` mode is
   never undone (`third_party/camera_avfoundation/CUBECHAT_PATCH.md`).

## Android incoming-call surface

Unlocked: a heads-up notification in the shade with Answer and Decline — **no
screen drawn over other apps.** Locked: a full-screen call
(`IncomingCallActivity`, `showWhenLocked`), answerable without the PIN. Do not
re-add "appear on top": the manifest deliberately has no `SYSTEM_ALERT_WINDOW`,
and the comment there says why.

Android re-decides the full-screen-intent permission when an APK from outside
Google Play is installed over itself, and MIUI does the same with its lock-screen
permission — so it is off after **every sideloaded update**, and no app can grant
it back to itself. Nothing asks about it: builds 1090–1093 put up a sheet on
the chats screen after each update, and the owner had it removed (2026-09-21) —
do not bring it back. `call_screen_access.dart` only reads what Android says,
for the switch in Profile, and reads it again on every return to the app. The
one install that keeps the permission across updates is one Google Play
updates.

## Server side

TURN is coturn on the droplet, beside the push server. The TURN secret cannot
live in the APK, so the app asks the push server for a short-lived login with a
request signed like push-token registration. Tests: `push/test/turn_credentials.test.js`
and `turn_endpoint.test.js`, run with `node --test` in `push/`. In the default
mode the droplet is a hard dependency for calls — the accepted price of not
showing anyone your IP. See `push/README.md` and `push/deploy/README.md`.

## What can be proven here, and what cannot

Here, without a device: the codec round trip and tampered bytes, invite
freshness and `callId` dedup, the state machine including glare and "no ack means
unavailable", the call screen in widget tests, and the server's choice of push
path by tag. `call_controller_test.dart` builds its controller **inside**
`fakeAsync` — see the `flutter-testing` skill for why that matters.

Not here, by anything: WebRTC itself, CallKit, PushKit, the Android service,
coturn. That is two live phones and nothing else. Say only what was confirmed on
a device; a green suite says nothing about whether a call connects.
