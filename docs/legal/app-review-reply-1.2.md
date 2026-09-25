# Reply to App Review — guideline 1.2 (User-Generated Content)

Draft for the build that carries the moderation work (1112 at the time of
writing). The reply itself is the section below the line; the checklist under
it is for the owner and is not sent.

---

Thank you for the review. Cubechat now includes the following safeguards for
user-generated content:

1. **Age rating.** The app is rated 18+.
2. **Terms at first launch.** Before anything else, the app shows its rules:
   zero tolerance for objectionable content and abusive users (harassment,
   threats, sexual content involving minors, spam, anything illegal). The app
   cannot be used until the user taps "I agree". The full terms are linked
   from that screen and from Profile → About.
3. **Reporting.** "Report" is on every message someone else sent (long-press
   the message, in direct chats and in channels), on every person's profile,
   and on every channel's info screen. One tap on Send files the report,
   blocks the person for the reporter (or hides that channel author, or
   leaves the reported channel) and removes the reported message from the
   screen at once.
4. **Hiding and blocking.** "Hide" removes any message someone else sent from
   the user's screen immediately, with undo. Any person can be blocked from
   their profile.
5. **Filter.** An offensive-content filter, on by default, folds messages with
   objectionable words from people the user has not written to and in
   channels, until the user chooses to see them. It can be switched off in
   Profile.
6. **Acting within 24 hours.** Every report reaches the developer
   immediately through a private moderation bot, with Ban and Dismiss
   actions. Reports are acted on within 24 hours.
7. **Removing offenders.** A ban puts the offender's public key on a list
   signed by our server. Every copy of the app verifies and applies it: the
   banned user's messages are hidden, their channels disappear, their files
   and nearby requests are ignored, and our servers refuse them notifications
   and call relays.
8. **Contact.** Profile → About shows the developer's email address
   (cubechatble@gmail.com) and a "Report a violation" action.

Messages are end-to-end encrypted, so we cannot read conversations; the
content of a message reaches us only when a user reports it, and only that
message.

---

## Before sending (owner)

- Set the age rating to 18+ in App Store Connect → Age Rating. The app cannot
  do this, and the reply says it is done.
- Update App Privacy to match `store-disclosures.md`: User ID and Other User
  Content, both linked, neither used for tracking.
- The server keeps report records with no automatic deletion yet; the privacy
  policy says so. Do not promise a retention period in the reply until one is
  enforced.
- `https://cubechat.tech/terms` answers 404 and `/privacy` serves the
  pre-moderation text; the app links the documents on GitHub instead. Update
  the site, or give App Store Connect the GitHub links.
- The push server must be running the build that accepts a channel author's
  16-hex fingerprint (`parseReportPayload`), or every report of a channel
  message is refused and dropped.
