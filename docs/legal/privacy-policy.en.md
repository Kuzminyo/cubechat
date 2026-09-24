# Cubechat Privacy Policy

**Last updated: 25 September 2026**

Cubechat is a peer-to-peer messenger. Messages travel directly between phones
over Bluetooth Low Energy, and optionally through public relays that carry them
sealed. There is no Cubechat account, no Cubechat message server, and no
company database holding your conversations.

This policy describes exactly what the app does with data, including the parts
that are not private, because a messenger that overstates its privacy is more
dangerous than one that has none.

> This document is written from the source code and is not legal advice; have
> it reviewed before you rely on it.

---

## 1. Who is responsible

**Controller:** Kuzminyo
**Contact:** cubechatble@gmail.com

If you are in the European Economic Area, the United Kingdom or Ukraine, you
have the rights described in section 11.

---

## 2. There is no account

Cubechat never asks for an email address, a phone number, a real name or a
password, and there is nothing to sign up for.

When you first open the app it generates a cryptographic key pair on your
device. That key pair **is** your identity. Nobody, including us, holds a copy.
Your display name and profile photo are chosen by you, stored on your device,
and sent only to people you actually communicate with.

**A consequence you should understand:** because we hold no account, we cannot
restore your identity, your contacts or your history if you lose the device or
delete the app. There is nothing on our side to restore from.

---

## 3. What stays on your device

All of the following is stored only on your phone, in AES-encrypted databases
whose key is held in the Android Keystore or the iOS Keychain:

- your identity keys and your contacts' public keys;
- your message history, including photos, voice messages and files;
- your display name, profile photo and app settings;
- pinned, archived, hidden and foldered conversations;
- the in-app diagnostic log (the most recent 1000 lines).

This history stays on the phone unless you choose a message and tap Report; that report sends only the selected excerpt described below. Local copies are removed when you uninstall the app, use
**Emergency Wipe**, or when the **dead man's switch** you configured fires.

The diagnostic log stays on the device unless you deliberately export it and
send it to somebody. It contains public key fragments, timings, transport
states and error messages. It does **not** contain message text, photos or
your location.

---

## 4. What travels between phones

### 4.1 Over Bluetooth (the default)

Messages between nearby phones are encrypted end-to-end using the Noise
Protocol (XX and IK patterns) with X25519, ChaCha20-Poly1305 and BLAKE2s, and
signed with Ed25519. They pass directly from one device to another, or hop
through other Cubechat devices that cannot read them.

The Bluetooth identifier the app advertises **rotates periodically**, so a
passive observer cannot follow one device across the day by its address alone.

Anyone within Bluetooth range can observe that a Cubechat device is present and
that encrypted traffic is occurring. They cannot read it.

### 4.2 Over Nostr relays (on by default, and you can switch it off)

When **Internet fallback** is on, a message the mesh could not deliver is
published to public Nostr relays, which forward it to the recipient. The relay
receives the message already sealed and signed; it cannot decrypt it.

**A relay does learn metadata, and this is the most important disclosure in
this policy:** it can see which two Nostr public keys exchanged a frame, when,
and how large it was. The Bluetooth mesh does not leak this.

This feature was off by default until September 2026 for exactly that reason.
It is now **on by default**, because with it off a message to somebody out of
Bluetooth range simply does not arrive until you are near each other again. You
can turn it off at any time in Profile → Internet fallback, and **Emergency
Wipe** switches it off too.

The relays are operated by unrelated third parties, not by us. The default list
is editable in the app.

### 4.3 Group rooms

A room's key is derived from its name and password. Anyone who knows both can
read the room. Rooms are not forward-secret, and a room password is only as
good as the care taken in sharing it.

### 4.4 AirDrop (sending files to someone nearby)

Files you send someone nearby through AirDrop travel directly between the two
phones, by default over Bluetooth like any other message. They may also
travel over the local Wi-Fi network when both phones are on one, encrypted
with a key that exists only for that transfer; no server is involved.

**While the AirDrop page is open, or "Everyone" is switched on for receiving,
your phone can be found by people nearby** even if "Discoverable nearby" is
off in your profile. For that time it answers Bluetooth handshakes from phones
it does not know, and sends its signed announcement unencrypted — your public
key, nickname and profile picture — to the phones it is linked to, which pass
it on through the mesh. Holding two phones together on the AirDrop page also
makes your phone connect to the other one by itself, so the two can exchange
files or contact cards. When you leave the page (or "Everyone" switches itself
off after ten minutes), your phone goes back to answering only people who
already know it.

---

## 5. The push notification service

To wake a phone whose app is fully closed, Cubechat runs one small service at
`push.cubechat.tech`. This is the only server we operate; the same machine also
relays voice calls, described in section 5.1.

**It is on by default, and you can switch it off.** It never sees message
content.

Your phone's operating system asks separately before any notification can be
shown, and if you decline there, nothing is registered at all. Turning the
switch off in the app deletes your entry from the service. Before September
2026 this feature was off until switched on; it now starts on, because a
messenger whose notifications only work while it is already open is not doing
the job.

For each phone that registers, it stores:

| What | Why |
|---|---|
| Your Nostr public key (`npub`) | The address to watch for incoming mail |
| The APNs or FCM device token | The address of the phone to ring |
| Language code (`en` or `uk`) | So the banner is in a language you read |
| Platform (`ios` / `android`) | To choose between Apple and Google |
| Which Apple host answered | To avoid a wasted round trip on every push |
| Timestamp of the registration | So a stale entry can be replaced |

The service watches the relays for events addressed to your public key and asks
Apple or Google to ring your phone. **The banner text is a fixed string** —
"New message" or "Нове повідомлення" — because the service cannot decrypt
anything and has nothing else to say. The message itself is fetched and opened
by your phone.

Registrations are cryptographically signed, so nobody can register a token
against somebody else's key. Turning the feature off in the app deletes your
entry from the service. Uninstalling the app leaves the entry until the token
is refused by Apple or Google, at which point it is deleted automatically.

**Apple and Google are involved.** Apple Push Notification service (iOS) and
Firebase Cloud Messaging (Android) receive the device token and the fact that a
notification was sent. They do not receive message content. Their own privacy
policies apply to that processing.

Server logs are kept for operational purposes and contain shortened public key
fragments and delivery outcomes, not content.

### 5.1 Voice calls

A voice call is set up with encrypted messages, like any other message, and its
audio is carried through a call relay (TURN) on the same server. The audio is
encrypted between the two phones (DTLS-SRTP); the relay forwards it and cannot
listen to it.

**The relay does see network metadata:** the IP addresses of both phones, when
a call took place, how long it lasted and how much data it carried. To use it,
your phone asks the service for short-lived access with a request signed by
your key. We do not record calls. The relay's server logs, kept for operating
and securing the service, can contain those IP addresses and session times;
they never contain audio.

By default both phones only ever see the relay's address, not each other's. If
you turn on **direct calls** in your profile, a call may connect phone to phone
instead, and then the other person's phone can see your IP address.

---

## 6. Location

Cubechat uses your location for two things, and only when you ask for them:
sending a location into a chat, and showing yourself on the map to friends.
**Nothing is shared until you choose to.** The app does not ask for location
during the first-run introduction.

**Showing yourself on the map.** This is off until you turn it on. Before it
turns on, the app asks whether you allow your location to be shown on the map,
and you can decline. It asks again if you turn it off and later back on.

- Your location is shown **only to the contacts on your map**: people you
  invited, or whose invitation you accepted. It is never shown to strangers,
  to people nearby, or publicly.
- It is sent **end-to-end encrypted**, the same way as a message. We never
  receive it, and neither do the relays that carry it.
- While it is on, your pin **keeps updating**, including while Cubechat is in
  the background, so friends see where you are rather than where you last
  opened the app. Each update expires on their map after six minutes if no
  newer one arrives.
- **Hide** on the Map tab, or the switch in Profile, turns it off in one tap
  and withdraws your pin from every friend's map at once.

**Background location ("Always").** Only requested once you have agreed to be
shown on the map, and only used to keep that pin current. Granting it is
optional: without it, your pin updates only while Cubechat is open.

**Blocking.** You can block any contact from their profile. A blocked contact
receives no location from you, a pin you had already shown them is withdrawn at
once, and their location is not drawn on your map.

**Sending a location in a chat** reads your position once and sends it, like a
message, to the chat you chose, for the time you choose.

**Third parties who see something:**

- **Map tiles** are fetched from OpenStreetMap, CARTO, Esri ArcGIS,
  OpenTopoMap or Google Maps, depending on the layer you pick. Those servers
  see your IP address and which map squares you asked for — which reveals
  roughly where you are looking, though not necessarily where you are.
- **Reverse geocoding** (turning coordinates into a street name) is performed
  by the operating system's own geocoder — Apple's or Google's — which
  receives the coordinates being named.

Neither of these is avoidable while a map is on screen, and neither is reached
unless you open the Map tab.

---

## 7. Camera, microphone, photos and files

These permissions are used only for what you explicitly do: take a photo to
send, record a voice message, attach a picture or a document. Nothing is
captured in the background, and nothing is uploaded anywhere except to the
conversation you send it to, encrypted.

Media you receive is stored inside the app's private container.

---

### Reports and moderation

When you tap Report, the app sends a signed complaint over HTTPS to our push
service. It contains your public signing key, the reason and optional note,
the reported person's public identity or channel-author fingerprint, and, if
you reported a specific message, its type, time and selected text or caption
(up to 4,000 characters). A channel report also names the channel. Nothing is
sent for an ordinary message you do not report. If you are offline, the report
waits in encrypted storage on your phone for up to seven days and is signed
again when delivery resumes.

The developer reviews reports through a private Telegram moderation bot. The bot forwards the reason, note, a shortened reporter and target key, and up to 1,000 characters of the selected message excerpt to Telegram, a third-party service. The
server stores the report for review and a decision; it does not yet delete old
report records automatically. Contact us to request deletion. A decision to
ban publishes a signed list containing public identity keys, Nostr public keys
and channel-author fingerprints only. Every app can download that public list
to suppress banned senders. The list never contains report text or your note.

---
## 8. What Cubechat does not do

- **No analytics.** No Firebase Analytics, no Crashlytics, no Sentry, no
  Amplitude, no Mixpanel — none of it, and no home-grown equivalent.
- **No advertising and no ad identifiers.** The app does not read the IDFA or
  the Android advertising ID.
- **No tracking as Apple's App Tracking Transparency defines it.** Nothing is
  linked to you or your device for advertising, and nothing is shared with a
  data broker.
- **No selling or sharing of personal data.** There is nothing to sell.
- **No server-side content scanning.** We cannot read ordinary messages; the design makes it
  impossible rather than merely forbidden.

---

## 9. Backups and transfers

Cubechat can produce an **encrypted backup** of your conversations and an
encrypted **phone-to-phone transfer**. Both are protected by a passphrase you
choose, and both stay under your control — the file goes wherever you put it.

If you lose the passphrase, the backup cannot be recovered. We do not hold a
key.

---

## 10. Deleting your data

- **Uninstall the app.** Everything on the device goes with it, including the
  keys. This is irreversible: reinstalling produces a *new* identity, and
  existing conversations cannot be resumed.
- **Emergency Wipe** does the same from inside the app, and switches the
  internet fallback back off.
- **The dead man's switch**, if you configured one, wipes the device after the
  period of inactivity you set.
- **Push registration** is deleted from our service when you switch push off.
- **Nostr relays** are third parties with their own retention. A frame already
  published cannot be recalled from them by us. It is ciphertext, and relays
  typically expire events after a period of their choosing.

---

## 11. Your rights

If the GDPR, the UK GDPR or Ukraine's law on personal data protection applies
to you, you have the right to access, correct, erase, restrict and port your
personal data, and to object to processing.

Push registrations can be erased by switching push off. Submitted reports are
also held by our service; contact us to request access or deletion. The call relay in section 5.1
keeps connection metadata only for operating and securing the service. For anything else, or to
complain, use the contact address in section 1. You may also complain to your
national supervisory authority.

**Legal basis**, where one is required: consent for the push service and for
location sharing. Both are revocable at any moment from inside the app, and
both sit behind an operating-system permission prompt that you answer yourself
— declining it means nothing is collected, whatever the in-app switch says.
Legitimate interest covers keeping the push service secure and operational and
reviewing abuse reports you choose to submit.

---

## 12. Children

Cubechat is intended for adults aged **18+**. It is not directed at
children. If you believe a child has provided us with personal data — which,
given section 2, could include a push registration or a submitted report — contact us and it
will be deleted.

---

## 13. Security, honestly stated

Cubechat is built to be private and its cryptography is implemented against
published test vectors. It is not audited by a third party, and you should
weigh that.

Known limitations, stated plainly because you deserve to know them:

- **Group rooms are not forward-secret**, and their key is derived from a
  name and a password.
- **Received media is stored decrypted** inside the app's private container,
  protected by the operating system's app sandbox rather than by a second
  layer of encryption.
- **Relay metadata is real**, as described in section 4.2.
- **A phone that is unlocked and in someone else's hands** can read Cubechat,
  as it can read any messenger.

---

## 14. Changes

If this policy changes materially, the app will say so and the date at the top
will change. The current version is always published at
`https://github.com/Kuzminyo/cubechat/blob/main/docs/legal/privacy-policy.en.md`.

---

## 15. Contact

Write to **cubechatble@gmail.com** with any question about this policy, to
exercise a right described in section 11, or to report a security problem.
