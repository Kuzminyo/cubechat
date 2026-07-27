# cubechat wake service

A doorbell, not a relay. It rings an iPhone that has encrypted mail waiting on
Nostr, and it is built so that ringing you tells it nothing about you.

Design and threat model: [`docs/private-apns-wake-relay.md`](../../docs/private-apns-wake-relay.md).
This is **Phase 1** of that document — registration, the generic alert, and the
API boundary. Per-contact capability exchange from the app is Phase 2.

**No runtime dependencies.** Node built-ins only, so the whole thing is
auditable in an afternoon and deploys anywhere Node runs.

```bash
npm test     # 14 tests, no network
npm start    # PORT, WAKE_STORE, APNS_* from the environment
```

## What it does and does not learn

| | Sees |
|---|---|
| Wake frontend | a capability hash, an opaque ticket, the time you rang, the source IP while the request is live |
| APNs gateway | an APNs token, the same opaque ticket, the time |
| Apple | the app topic, a device routing token, the time, a fixed localized string |

It never receives a message, a Nostr event id, either `npub`, a sender, a chat
id, a nickname, plaintext or ciphertext. A wake carries one 32-byte random
number and means "there is mail".

The two halves are separate tables and separate endpoints even though Phase 1
runs them in one process, because that is the property worth keeping: neither
half alone maps a capability to a device. Splitting them across two operators
later is a deployment change, not a protocol change.

Neither table stores the bearer secret used to look its row up — only
`SHA-256(domain ‖ secret)`. A dump of the database does not let anyone ring
anybody.

**It does not make you anonymous.** A frontend and gateway run by the same
operator can join ticket timing with token data. Timing and IP correlation can
associate a sender with a capability. A contact can hand its capability to
someone else, or spam it. Apple necessarily sees the topic, the routing token
and the time. Say this in the UI; "the server learns nothing" would be false.

## Endpoints

All `POST`, JSON, `no-store`, small fixed size limits. Bodies and authorization
headers are never logged: a body here is a bearer secret.

| Route | Half | Purpose |
|---|---|---|
| `/v1/tickets` | gateway | Register an APNs token, get a bearer delivery ticket. Ed25519-signed over a fixed binary transcript, with a timestamp window and a nonce, so it cannot be replayed. |
| `/v1/capabilities` | frontend | Bind `SHA-256("cubechat/wake-cap/v1" ‖ capability)` to an opaque ticket. |
| `/v1/wake` | frontend | Ring the device behind a capability. |
| `/v1/deliver` | gateway | Send a **compiled template** to a ticket. Never accepts caller text, badge, URL or custom fields. |

`/v1/wake` answers `202` for everything — delivered, unknown, expired, revoked,
rate-limited. Anything else would make it an oracle for whether a capability
exists, and capabilities are the only identifiers here worth probing for. It
carries no signature on purpose: signing it with the sender's Nostr key would
hand the service exactly the identity the design omits.

Defaults: coalesce 3 s per device, 6 wakes/minute and 60/hour per capability and
per device, 60/minute per source-address bucket (a daily-rotated keyed hash —
the address itself is never stored), 64 capabilities per device, 90-day leases.

Rate limiting bounds notification spam and never touches delivery: a throttled
wake means a missing alert, and the ciphertext is still on Nostr for the next
launch or background refresh to collect.

## What you have to do before any of this works

The client half cannot be exercised without these, and none of them can be done
from the repository:

1. **A paid Apple Developer Program membership.** Push Notifications is not
   available to free provisioning profiles — a sideloaded build signed with a
   free Apple ID cannot carry `aps-environment`, so `registerForRemoteNotifications`
   will fail and no token is ever issued.
2. Enable **Push Notifications** for `com.cubechat.cubechat` in the developer
   portal, and rebuild with a provisioning profile that includes it.
3. Create an **APNs auth key** (`.p8`), note its Key ID and your Team ID.
4. Run this service somewhere with TLS, and put the `.p8` in a secret manager —
   never in this repository, the frontend, the database, or the app.

```bash
APNS_KEY_ID=ABC123DEFG \
APNS_TEAM_ID=TEAM123456 \
APNS_KEY_PEM="$(cat AuthKey_ABC123DEFG.p8)" \
WAKE_STORE=/var/lib/cubechat/wake.json \
PORT=8080 npm start
```

Sandbox and production tokens are different namespaces and must never be mixed;
the environment travels with the registration and is stored per ticket.

## Storage

A JSON file rewritten atomically (write-then-rename), which is the right size
for one co-located process. The interface is narrow enough that moving to a
database touches only `src/store.js`. APNs tokens should be encrypted at rest
with envelope encryption before this carries anyone's real traffic; the database
key and the `.p8` are separate secrets with separate access policy.
