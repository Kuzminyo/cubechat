# Legal and store documents

Written from the source on 2026-09-07. Every factual claim in them was checked
against the code rather than assumed, and `store-disclosures.md` names the file
behind each answer so the next person can verify instead of trusting.

| File | What it is | Where it has to end up |
|---|---|---|
| `privacy-policy.en.md` | Privacy policy, English | A public URL — both stores reject a 404 |
| `privacy-policy.uk.md` | Privacy policy, Ukrainian | Same, e.g. `/privacy/uk` |
| `terms.en.md` | Terms of use, English | A public URL |
| `terms.uk.md` | Terms of use, Ukrainian | Same |
| `store-disclosures.md` | Filled-in answers for Apple App Privacy and Google Play Data safety, plus the export-compliance situation | Nowhere public — it is the crib sheet for filling the forms |

## Who these name

- **Controller / provider:** Kuzminyo
- **Contact:** cubechatble@gmail.com
- **Governing law:** Ukraine (`terms.*.md` §12)

**No postal address, by decision.** The GDPR asks for the controller's identity
and *contact details*; an address that is read is what that comes to, and for a
sole developer an email satisfies it. Worth knowing anyway: **Google Play
publishes the developer's physical address on the store listing regardless** —
that is a requirement of the developer account, not of the policy, so leaving
it out here does not keep it private there.

**The contact address has to stay answered.** A privacy policy naming a mailbox
nobody reads fails on the first access request, and both stores treat an
unreachable contact as grounds for removal.

**None of this is legal advice.** It is an accurate description of what the
software does, written so that a lawyer has something true to work from. Have
it reviewed before you rely on it.

## Publishing

The marketing site lives in its own repository — `Kuzminyo/landing_cubechat`,
serving `cubechat.tech` — so these files have to be copied there and rendered.
The URLs the app and the policy already name:

- `https://cubechat.tech/privacy`

That URL appears inside `privacy-policy.*.md` §14. If you publish somewhere
else, change it there too, or the policy will point at a page that does not
exist.

## Keeping them true

`store-disclosures.md` ends with a short list of the code changes that would
make one of these declarations false — a new analytics SDK, a new field stored
by the push server, anything that uploads content. Those are statements made to
a regulator, so they change in the same commit as the code that invalidates
them, not afterwards.
