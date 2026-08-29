# cubechat push

A doorbell for iOS, and nothing else.

A terminated iOS app receives nothing: the socket died with the process, and
`BGAppRefreshTask` is not scheduled for an app the user swiped away. APNs is the
only mechanism Apple provides for "wake up, there is a message", and APNs can
only be driven by a server. This is the smallest server that can drive it.

## What it does

1. A phone registers: `POST /register` with a **signed Nostr event** whose
   content is its APNs device token. The signature is checked exactly the way a
   relay checks one — id is the SHA-256 of the canonical array, and the
   signature verifies against the pubkey in the event. That is what stops
   anybody registering a token against somebody else's npub and turning this
   into an oracle for "did they get mail".
2. It subscribes to the same relays the app uses, filtered to the npubs it holds
   tokens for.
3. An event addressed to one of them becomes one APNs push carrying a fixed
   string. The phone wakes, syncs from the relay, decrypts locally, and shows
   the real notification itself.

## What it never has

The message, the sender's plaintext, any key, any name. The database is two
columns wide: `npub → token`.

## What it does learn, and it is not nothing

That a given npub received something, and when. Nostr events carry the sender's
pubkey, so it also learns who wrote to whom. The relay already sees all of that
— this is a *second* observer of the same metadata, and that is the real cost of
having notifications at all. It is the reason this is opt-in on the phone rather
than on by default.

## What it cannot do

Anything about Bluetooth. A message that travelled the mesh and never touched a
relay is invisible here, because it is invisible to the internet. Push covers
the relay half of the app and only that half.

## Running it

```bash
cd push
npm install
cp .env.example .env   # fill in the APNs key and the relay list
npm start
```

Needs, from the Apple developer account:

- an **APNs auth key** (`.p8`), its key id and the team id;
- the app's bundle id (`app.cubechat`) as the APNs topic;
- **Push Notifications** enabled on the App ID. This is the one capability the
  project did not previously need.

State lives in `tokens.json` beside the process — two columns, and losing it
costs nothing but a re-registration, which every phone does on launch.
