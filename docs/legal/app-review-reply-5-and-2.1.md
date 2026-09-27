# Reply to App Review — guideline 5 (CallKit in China) and 2.1(a) (demo account)

Rejection of 1.0.0 (1118), 2026-09-27. The reply is the section below the line;
the checklist under it is for the owner and is not sent.

Answered without a new build: 1118 can already restore a backup, and the demo
backup is made by `flutter test tool/review_demo_backup_test.dart`, which writes
`build/review-demo.cchatbackup` and its password to
`build/review-demo-password.txt`. The identity inside is a throwaway minted by
that script; take the backup down once the app is approved.

---

Thank you for the review.

**Guideline 5 — CallKit in China.** We have removed China mainland from the
app's available territories in App Store Connect. The app is not offered on the
China App Store, so its CallKit functionality is not active there.

**Guideline 2.1(a) — demo account.** Cubechat has no accounts, no sign-up and no
login: on first launch the app creates an encryption key on the device, and that
key is the user's identity. There is no user name we could give you.

The equivalent of a demo account is an encrypted backup of a demo identity that
already has conversations in it. To load it:

1. On the review device, open https://cubechat.tech/review/demo.cchatbackup in
   Safari and tap Download. The file is saved to Files → Downloads.
2. Open Cubechat, accept the terms, then go to **Profile → Encrypted backup →
   Restore backup**.
3. Choose `demo.cchatbackup` in Downloads and enter the password:
   `PASSWORD` (it is also in the App Review Information notes).
4. Confirm. The demo identity ("App Review") appears with three contacts and a
   channel, all with messages from other users.

What to try:

- **Report / Hide** — long-press any message from Anna or Max, or any post in
  the channel "cubechat-demo".
- **Block** — open Max's profile and tap Block.
- **Filter** — the chat from "Unknown (demo)" and one post in the channel
  contain an offensive word; the filter folds them until you tap to show them.
  It can be switched off in Profile.
- **Contact** — Profile → About shows the developer's e-mail and a general
  Report button.

The demo contacts are not online, so messages sent to them are not answered.

---

## Owner checklist (not sent)

- [ ] App Store Connect → Pricing and Availability → untick **China mainland**,
      save. Do this before replying — the reply says it is already done.
- [ ] Put `build/review-demo.cchatbackup` on the site as
      `/review/demo.cchatbackup` (landing repo, `public/review/`), and check the
      link downloads the file rather than showing text.
- [ ] Restore it once on a **spare** device (never the main phone — a restore
      replaces the identity on it), and walk the "What to try" list.
- [ ] Replace `PASSWORD` above with the contents of
      `build/review-demo-password.txt`.
- [ ] App Review Information → Notes: paste the four steps and the password.
      Sign-in required: off.
- [ ] Reply in App Review with the text above.
- [ ] After approval, delete `/review/demo.cchatbackup` from the site.
