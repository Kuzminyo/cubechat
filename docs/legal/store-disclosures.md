# Store disclosures — the answers, and what each one is based on

Every answer below is taken from the source, and the source is named so the
next person can check it rather than trust it. When the app changes, change
this file in the same commit; a disclosure that drifts from the code is worse
than a missing one, because it is a statement made to a regulator.

Two facts do most of the work:

1. **There is no account and no message server.** Nothing about a conversation
   reaches us, ever.
2. **One exception, and only one:** the push notification service at
   `push.cubechat.tech`. It holds a public key and a device token, and that is
   the whole of what we collect. Since build 986 its switch **starts on** — the
   operating system's own notification prompt is still the gate, and declining
   it means nothing is ever registered.

---

## Apple — App Privacy ("nutrition label")

App Store Connect → your app → App Privacy.

### Do you or your third-party partners collect data from this app?

**Answer: Yes** — and then declare exactly one item, below.

> **Why not "No", which is tempting.** Apple counts a device token tied to a
> user-specific identifier as *Identifiers → User ID* when it is transmitted
> off device and stored. `push.cubechat.tech` stores it. `No data collected`
> would be a false declaration, and it is the kind that gets found.
>
> Note the deliberate difference from `ios/Runner/PrivacyInfo.xcprivacy`, which
> declares **zero** `NSPrivacyCollectedDataTypes` and is *also* correct: the
> privacy manifest describes what the shipped binary and its SDKs do, and the
> app binary itself collects nothing. The label describes the service behind it.
> Two questions, two honest answers.

### The one item to declare

| Field | Answer |
|---|---|
| Category | **Identifiers → User ID** |
| Used for | **App Functionality** |
| Linked to the user's identity | **No** |
| Used for tracking | **No** |

The value is a Nostr public key plus an APNs/FCM device token. It is not linked
to a name, an email or a phone number, because the app never learns any of
those.

### Everything else: declare *not* collected

| Category | Answer | Basis |
|---|---|---|
| Contact Info (name, email, phone, address) | Not collected | No account exists — `README.md` §"Status"; there is no registration screen |
| Health & Fitness | Not collected | No such API is used |
| Financial Info | Not collected | No payments |
| **Location** | **Not collected** | Position is end-to-end encrypted to chosen contacts only and never reaches us — `lib/features/map/data/map_presence_controller.dart` |
| Sensitive Info | Not collected | — |
| Contacts (address book) | Not collected | No address-book permission is requested; check `Info.plist` for the absence of `NSContactsUsageDescription` |
| User Content (messages, photos, audio) | Not collected | Encrypted end to end; we operate no server that receives it |
| Browsing History | Not collected | — |
| Search History | Not collected | In-app search runs against the local database only |
| Usage Data | Not collected | No analytics SDK — verified by grep for `firebase_analytics`, `crashlytics`, `sentry`, `amplitude`, `mixpanel`, `posthog`: no matches in `pubspec.yaml` |
| Diagnostics | Not collected | The diagnostic log stays on the device unless the user exports it by hand |
| Other Data | Not collected | — |

### App Tracking Transparency

**No ATT prompt, and none is needed.** `NSPrivacyTracking` is `false` in
`ios/Runner/PrivacyInfo.xcprivacy`; the app reads no IDFA and shares nothing
with a data broker.

---

## Google Play — Data safety form

Play Console → Policy → App content → Data safety.

### Section 1 — Data collection and security

| Question | Answer |
|---|---|
| Does your app collect or share any of the required user data types? | **Yes** (the push token, below) |
| Is all of the user data collected by your app encrypted in transit? | **Yes** — registration is signed and sent over HTTPS; messages are sealed before they leave the device |
| Do you provide a way for users to request that their data is deleted? | **Yes** — switching push off deletes the registration; uninstalling removes everything else. Give the Privacy Policy URL as the deletion instructions |

### Section 2 — Data types

Declare **one** type:

| Data type | Collected | Shared | Ephemeral | Required | Purpose |
|---|---|---|---|---|---|
| **Device or other IDs** | Yes | **No** | No | Optional | **App functionality** (message notifications) |

> "Shared" is **No** deliberately. The token is transmitted to Google's own FCM
> to deliver the notification, and Play's definition explicitly excludes
> transfer to a service provider acting on your behalf for that purpose. It is
> not passed to any other party.

Declare **not collected** for everything else, in particular the three that
reviewers look for in a messenger:

- **Messages** — not collected. End-to-end encrypted; no server of ours
  receives them.
- **Photos and videos / Audio files / Files and docs** — not collected. They
  travel encrypted between devices and are stored in the app's private
  container.
- **Location (approximate and precise)** — not collected. Shared only with
  contacts the user picks, end-to-end encrypted, expiring after six minutes.
  Sharing stays off until switched on; the permission is requested at the end
  of first-run onboarding, which grants nothing by itself.

### Section 3 — Sensitive permissions that need a declaration

| Permission | Why it is there | Where |
|---|---|---|
| `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION` | Live map sharing chosen by the user; also required by Android for BLE scanning on older API levels | `AndroidManifest.xml` |
| `FOREGROUND_SERVICE_LOCATION` | Keeps a shared pin current while the app is backgrounded | `MeshForegroundService.kt` |
| `FOREGROUND_SERVICE_CONNECTED_DEVICE` | Holds the Bluetooth mesh open so messages arrive without the app on screen | `MeshForegroundService.kt` |
| `BLUETOOTH_SCAN`, `BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT` | The transport itself | `README.md` §"Architecture" |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | Aggressive OEMs kill the mesh service; this is offered, never forced | `README.md` §"Background delivery on aggressive OEMs" |
| `CAMERA`, `RECORD_AUDIO`, `READ_MEDIA_IMAGES` | Only for content the user chooses to send | — |

**Location prominent disclosure.** Play requires an in-app disclosure before
requesting background location. The app's own explanation screen and the iOS
`NSLocationAlwaysAndWhenInUseUsageDescription` string carry it; confirm the
Android flow shows it before the system dialog, and record a screen capture —
Play asks for a video of the flow.

---

## Export compliance — unresolved, and the only genuinely blocked item

`ITSAppUsesNonExemptEncryption` is **absent** from `ios/Runner/Info.plist`, and
the long comment above that spot explains why. The short version:

- `false` would be a false declaration. Cubechat encrypts *message content*
  with its own implementation (Noise over X25519, ChaCha20-Poly1305, in-repo
  secp256k1), not merely authentication and not merely what iOS provides.
  Neither usual exemption covers it.
- `true` alone will not upload. On 2026-08-31 App Store Connect refused the
  build: *"Invalid Export Compliance Code… doesn't match the key value of the
  app's export compliance documentation" (409)*. `true` requires
  `ITSEncryptionExportComplianceCode`, which Apple issues only after export
  documentation is on file — and the questionnaire that produces it hangs off
  an *uploaded build*. The code cannot be obtained until a build is accepted,
  and no build is accepted with `true` and no code.
- Absent, the question is asked per build in App Store Connect instead, which
  is answerable and true. **That is where it stands today.**

**What still has to be done before public release**, and it is a real task, not
a formality: a messenger of this kind is normally distributed under **License
Exception ENC / mass market (ECCN 5D992.c)**, which requires a
self-classification report to the US Bureau of Industry and Security and an
annual report. Answer the App Store Connect questionnaire, obtain the
compliance code, then put **both** keys back into `Info.plist` together — that
combination is the one that ships. `true` without the code is the one
combination that cannot.

France additionally requires a declaration for encryption apps distributed
there; Apple's questionnaire asks about it directly.

---

## Store listing requirements

| Requirement | Status | Note |
|---|---|---|
| Privacy Policy URL | **To publish** | `docs/legal/privacy-policy.en.md` and `.uk.md`. Must be a public, live URL — suggested `https://cubechat.tech/privacy`. Both stores reject a 404, and Apple checks it |
| Terms / EULA | **To publish** | `docs/legal/terms.en.md` and `.uk.md`. Apple uses its standard EULA unless you supply one; supplying one is better here because of the delivery and no-warranty sections |
| Support URL | **To do** | A page that answers mail — `cubechatble@gmail.com` is the address the documents name. Required by both stores |
| Developer contact | **Note** | Google Play publishes the developer's **physical address** on the listing. That is a developer-account requirement and is unaffected by its absence from the policy |
| Account deletion | **Done, needs stating** | Google Play requires an explanation even when there is no account. Point at Privacy Policy §10 |
| Data safety / App Privacy | Answers above | — |
| Content rating questionnaire | **To do** | Answer *yes* to "users can communicate with each other" and to "user-generated content"; this is what sets the rating for a messenger |
| Age rating | 13+ suggested | Matches Terms §4 |

---

## What to re-check when the code changes

A short list, because these are the changes that would make a declaration false:

- **Adding any analytics or crash reporting SDK** flips Usage Data and
  Diagnostics on both stores, and adds an entry to `PrivacyInfo.xcprivacy`.
- **Any new field stored by `push/src/index.js`** belongs in Privacy Policy §5
  and may add a data type. The current set is in `handleRegister`.
- **Anything that uploads content anywhere** ends the "not collected" answer
  for User Content, which is the single most consequential line here.
- **Flipping a privacy default** — the relay and the push switch both changed
  from off to on in 986 — changes what the Privacy Policy says in §4.2 and §5,
  and the README's paragraph on the fallback. All three moved in that commit;
  keep it that way, because a default is what most people will actually be
  running.
- **A new third-party map tile source** belongs in Privacy Policy §6.
- **Requesting the address book** would add Contacts, which is currently
  answerable as "not collected" only because the permission does not exist.
