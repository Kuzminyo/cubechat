# Cubechat Privacy Policy

**Last updated: 8 September 2026**

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

None of it is uploaded anywhere. It is removed when you uninstall the app, use
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

---

## 5. The push notification service

To wake a phone whose app is fully closed, Cubechat runs one small service at
`push.cubechat.tech`. This is the only server we operate.

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

---

## 6. Location

Cubechat requests location permission for two separate features. **Sharing is
off until you turn it on**, whatever you answered to the permission prompt.

The app asks for the permission once, at the end of the first-run introduction,
because both iOS and Android show that prompt only once and remember a refusal.
Granting it does not start sharing anything — it only means the switch will
work when you reach for it.

**Sharing your position on the map.** When enabled, your coordinates are sent
**end-to-end encrypted, only to the specific contacts you added to your map**,
and each beacon expires after six minutes. Switching the feature off retracts
your pin immediately rather than waiting for that to lapse. We never receive your
location — it travels the same encrypted path as a message.

**Background location on iOS ("Always").** This permission exists so the app
can be woken when you move a significant distance, and refresh a pin your
contacts are watching. Granting it is optional; without it, sharing works only
while the app is open.

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

## 8. What Cubechat does not do

- **No analytics.** No Firebase Analytics, no Crashlytics, no Sentry, no
  Amplitude, no Mixpanel — none of it, and no home-grown equivalent.
- **No advertising and no ad identifiers.** The app does not read the IDFA or
  the Android advertising ID.
- **No tracking as Apple's App Tracking Transparency defines it.** Nothing is
  linked to you or your device for advertising, and nothing is shared with a
  data broker. The app's `PrivacyInfo.xcprivacy` declares zero collected data
  types, and that declaration is accurate.
- **No selling or sharing of personal data.** There is nothing to sell.
- **No content scanning.** We cannot read your messages; the design makes it
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

In practice these rights are mostly satisfied by the design: the only personal
data we hold is the push registration described in section 5, and you can erase
it yourself at any moment by switching push off. For anything else, or to
complain, use the contact address in section 1. You may also complain to your
national supervisory authority.

**Legal basis**, where one is required: consent for the push service and for
location sharing. Both are revocable at any moment from inside the app, and
both sit behind an operating-system permission prompt that you answer yourself
— declining it means nothing is collected, whatever the in-app switch says.
Legitimate interest covers keeping the push service secure and operational.

---

## 12. Children

Cubechat is not directed at children. If you believe a child has provided us
with personal data — which, given section 2, would be limited to a push
registration — contact us and it will be deleted.

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
`https://cubechat.tech/privacy`.

---

## 15. Contact

Write to **cubechatble@gmail.com** with any question about this policy, to
exercise a right described in section 11, or to report a security problem.
