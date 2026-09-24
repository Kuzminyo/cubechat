# Draft response for App Review guideline 1.2

This draft describes build 1112. Verify the App Store Connect age rating and
published privacy metadata before using it in a public App Review reply.

Cubechat is an end-to-end encrypted messenger. On first launch, the user must
accept the rules, which prohibit harassment, threats, exploitation of minors,
spam, impersonation, malware and other unlawful content. The terms require
users to be at least 18; the App Store Connect age-rating questionnaire still
needs to reflect that requirement before public submission.

Users can report a message, person, channel, or nearby transfer from within
the app. The report screen explains that a selected message excerpt and any
note are sent to Cubechat moderation and forwarded to its private Telegram
bot. A submitted report about a person blocks them locally; a reported message
is hidden locally. Users can also hide a message or block a person without
submitting a report. An optional offensive-content filter hides matching
messages from strangers and in channels until the reader chooses to reveal
them.

The developer reviews submitted reports. Bans are published as a signed list
of public identities or channel-author fingerprints, which the app verifies
before suppressing those senders. Ordinary message content remains
end-to-end encrypted; the moderation service sees selected text only when a
user explicitly reports it. Profile → About provides a developer email,
general report action, and current terms and privacy documents.

Do not promise a 24-hour review or 90-day server retention in a reply yet:
neither is enforced by the present service. The current privacy policy
discloses that report records have no automatic deletion schedule and gives
users a contact address for deletion requests. The privacy metadata must
also disclose report content and the Telegram forwarding before submission.