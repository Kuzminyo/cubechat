# Profile sections — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the profile's four expandable groups with a short list of eight sections, each opening its own screen, while leaving every setting's behaviour untouched.

**Architecture:** New shared tiles in `lib/features/profile/presentation/settings/`. The section screens are `part of` files of `profile_screen.dart`, so they reuse the existing private setting widgets without moving them, and "Chats & media" is a `part of` file of `customize_screen.dart` for the same reason. `_PrivacyCard` is split into one private widget per setting (bodies moved verbatim), because its settings land in three different sections. The profile's main screen keeps `_ProfileCover` and gains an @name line and two chips.

**Tech Stack:** Flutter, Riverpod, go_router (`fadeSlidePage` + `AuroraBackground` routes), `AppLocalizations`.

**Spec:** `docs/superpowers/specs/2026-09-30-profile-sections-design.md` (Russian; authority).

## Global Constraints

- No setting changes behaviour: same providers, same Hive keys, same hints, same `onChanged` bodies (moved verbatim with their comments).
- Every existing setting lands in exactly one place per the table in spec §2.
- Every new user-visible string goes in both `lib/l10n/app_en.arb` and `app_uk.arb`, then `flutter gen-l10n`; commit the generated files.
- Colours via `AppColors`, except the eight fixed section-icon colours in `settings_section_icons.dart` (spec §1).
- Edit with Edit/Write only. `flutter analyze` must show 0 errors and 0 warnings (grep both `-` and `•` separators). Never stage the owner's unrelated changes (design-previews, stickers, `tool/build_sticker_assets.py`, `.agents/`, `.codex_edit_headless_fix.py`, `push/package-lock.json`, `tool/__pycache__/`).
- Commit subjects are a sentence about the effect; every commit ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- `test/layer_budget_test.dart` profile budget stays `lessThanOrEqualTo(12)` or goes lower.

## Review Focus

1. **Android-only rows on iOS** (call full-screen, install-update): must not appear on iOS and must not leave an empty group. Test in Task 3.
2. **App lock grace row**: must appear only while the lock is on, as before, now inside the privacy section. Test in Task 2.
3. **Back navigation from a section**: returns to the profile at the same scroll position; the profile cover's open/closed state is not reset. Checked on the phone in Task 7.
4. **A setting changed inside a section**: the summary on the profile row updates when returning (e.g., reach → "Через запит"). Test in Task 5.
5. **Long values in a row** (a long @name, a Ukrainian summary): ellipsize, never overflow or push the chevron off. Test in Task 1.

## File map

| File | Responsibility |
|---|---|
| `lib/features/profile/presentation/settings/settings_tiles.dart` | `SettingsGroup`, `SettingsSectionRow`, `SettingsSubheader`, `SettingsSectionScaffold` |
| `lib/features/profile/presentation/settings/settings_section_icons.dart` | `SettingsSection` enum: icon, fixed colour |
| `lib/features/profile/presentation/settings/privacy_section.dart` | `part of profile_screen.dart` — privacy & security screen |
| `.../settings/notifications_section.dart` | `part of profile_screen.dart` — notifications & calls |
| `.../settings/connection_section.dart` | `part of profile_screen.dart` — connection |
| `.../settings/data_section.dart` | `part of profile_screen.dart` — data & storage |
| `lib/features/profile/presentation/chats_section.dart` | `part of customize_screen.dart` — chats & media |
| `lib/features/profile/presentation/profile_screen.dart` | split `_PrivacyCard`; new main list; `part` directives |
| `lib/features/profile/presentation/customize_screen.dart` | appearance only + language; `part` directive |
| `lib/features/moderation/presentation/about_screen.dart` | + Diagnostics row |
| `lib/core/routing/app_router.dart` | `/settings/privacy|notifications|connection|chats|data` |
| `test/settings_tiles_test.dart`, `test/profile_sections_test.dart` | tests |

---

### Task 1: Shared tiles and section identities

**Files:**
- Create: `lib/features/profile/presentation/settings/settings_tiles.dart`, `.../settings/settings_section_icons.dart`, `test/settings_tiles_test.dart`
- Modify: `lib/l10n/app_en.arb`, `lib/l10n/app_uk.arb` (+ generated)

**Interfaces:**
- Produces:
  - `enum SettingsSection { cubeId, privacy, notifications, connection, chats, appearance, data, about }` with `IconData get icon` and `Color get color`.
  - `class SettingsGroup extends StatelessWidget { const SettingsGroup({required List<Widget> children}); }` — one glass block, a 1 px divider (`AppColors.glass(0.07)`) between children indented 62 px.
  - `class SettingsSectionRow extends StatelessWidget { const SettingsSectionRow({required SettingsSection section, required String title, String? value, required VoidCallback onTap, bool danger = false}); }` — 34×34 rounded-10 icon badge, title (15.5, w500), value (14, dim, 1 line, ellipsis), chevron (hidden when `danger`).
  - `class SettingsSubheader extends StatelessWidget { const SettingsSubheader(String text); }` — uppercase, 12 px, letter-spacing 1.1, `AppColors.textOnGlassDim`.
  - `class SettingsSectionScaffold extends StatelessWidget { const SettingsSectionScaffold({required String title, required List<Widget> children}); }` — transparent Scaffold + AppBar with BackButton and `AppTypography.heading(size: 18)`, `ListView` padding `fromLTRB(16, 8, 16, 140)`.
  - l10n keys (en / uk): `sectionPrivacy` "Privacy & security" / "Конфіденційність і безпека"; `sectionNotifications` "Notifications & calls" / "Сповіщення і дзвінки"; `sectionConnection` "Connection" / "Зв'язок"; `sectionChats` "Chats & media" / "Чати і медіа"; `sectionAppearance` "Appearance" / "Оформлення"; `sectionData` "Data & storage" / "Дані і пам'ять"; `sectionAbout` "About" / "Про застосунок"; `subWhoSeesMe` "Who sees me" / "Хто мене бачить"; `subProtection` "Protection" / "Захист"; `subNotifications` "Notifications" / "Сповіщення"; `subCalls` "Calls" / "Дзвінки"; `subMyCard` "My card" / "Моя картка"; `fingerprintCopy` "Copy" / "Копіювати".

- [ ] **Step 1: Failing test** — `test/settings_tiles_test.dart`: pump a `SettingsGroup` with two `SettingsSectionRow`s inside a 360-wide `MaterialApp`; one has `value: '@a_very_long_name_that_will_not_fit'`. Expect both titles found, the long value rendered with `maxLines: 1` and no overflow exception (`tester.takeException()` is null), one divider between rows, and tapping the first row calls its `onTap`. A `danger: true` row shows no chevron (`find.byIcon(Icons.chevron_right_rounded)` count equals the non-danger rows).
- [ ] **Step 2:** `flutter test test/settings_tiles_test.dart` → FAIL (files missing).
- [ ] **Step 3: Implement** both files. `settings_section_icons.dart`:

```dart
import 'package:flutter/material.dart';

/// The eight sections of the profile, each with the icon and colour its row
/// carries. Fixed colours on purpose — the one exception to "colours come from
/// AppColors": a section's badge is a label to recognise at a glance, the way
/// iOS Settings does it, not a surface that should take the theme's tint.
enum SettingsSection {
  cubeId(Icons.alternate_email_rounded, Color(0xFF2E8CFF)),
  privacy(Icons.shield_rounded, Color(0xFF12A86B)),
  notifications(Icons.notifications_rounded, Color(0xFFFF4F64)),
  connection(Icons.radar_rounded, Color(0xFF8A5CF6)),
  chats(Icons.chat_bubble_rounded, Color(0xFFF5A524)),
  appearance(Icons.palette_rounded, Color(0xFFE14EA8)),
  data(Icons.folder_rounded, Color(0xFF3BA7C9)),
  about(Icons.info_rounded, Color(0xFF6B7A73));

  const SettingsSection(this.icon, this.color);
  final IconData icon;
  final Color color;
}
```

`settings_tiles.dart` implements the four widgets per the Interfaces block with `GlassCard` (or `AppColors.glass(0.065)` fill, radius 22, border `AppColors.glass(0.08)`), `InkWell` rows (min height 54, padding 14×12), and the danger variant colouring title `AppColors.danger`.
- [ ] **Step 4:** add the l10n keys to both arb files, `flutter gen-l10n`, run the test → PASS; `flutter analyze lib/features/profile/presentation/settings` clean.
- [ ] **Step 5: Commit** "Give the profile one look for a section row and a group of them".

### Task 2: Split the privacy card and build the privacy section

**Files:**
- Modify: `lib/features/profile/presentation/profile_screen.dart` (split `_PrivacyCard` lines ~1314–1545 into private widgets; add `part 'settings/privacy_section.dart';`)
- Create: `lib/features/profile/presentation/settings/privacy_section.dart`, `test/profile_sections_test.dart`
- Modify: `lib/core/routing/app_router.dart` (`/settings/privacy`)

**Interfaces:**
- Consumes: Task 1 widgets.
- Produces private widgets in `profile_screen.dart`, each a `ConsumerWidget` whose body is the corresponding `_SettingSwitch`/row moved **verbatim** from `_PrivacyCard` (with its comment): `_AppLockTile` (includes the `_GraceRow` shown only while locked), `_FilterTile`, `_CircleLensTile`, `_MapLocationTile`, `_CallDirectTile`, `_CallFullScreenTile` (returns `SizedBox.shrink()` off Android), `_LastSeenTile`, `_ReadReceiptsTile`, `_ForwardLinkTile`, `_AcceptCallsTile`. `_PrivacyCard` is deleted once nothing uses it.
- Produces `class PrivacySectionScreen extends ConsumerWidget` (public, in the part file): `SettingsSectionScaffold(title: t.sectionPrivacy)` with `SettingsSubheader(t.subWhoSeesMe)` + `SettingsGroup([_LastSeenTile(), _ReadReceiptsTile(), _ForwardLinkTile(), _DiscoverableCard(framed: false), _MapLocationTile()])`, then `SettingsSubheader(t.strangerReachTitle)` + `SettingsGroup([StrangerReachSelector(showHint: true)])` (the selector's own title is suppressed here — add a `showTitle` flag defaulting to true to `StrangerReachSelector`), then `SettingsSubheader(t.subProtection)` + `SettingsGroup([_AppLockTile(), _FilterTile(), _DeadMansRow()])`, then the existing `t.profilePrivacyExplainer` text.

- [ ] **Step 1: Failing test** in `test/profile_sections_test.dart` (Hive + SharedPreferences harness copied from `test/profile_sections_capture_test.dart` setUp/tearDown, without the golden tag): pump `PrivacySectionScreen` in a `ProviderScope` + localized `MaterialApp`; expect the titles `profileLastSeen`, `profileReadReceipts`, `privacyForwardLinkTitle`, `profileMapLocation`, `appLockTitle`, `filterToggle`, and `StrangerReachSelector`. Expect `_GraceRow`'s text absent while the lock is off (use the lock's grace label key from `_GraceRow`).
- [ ] **Step 2:** run → FAIL.
- [ ] **Step 3:** extract the tiles from `_PrivacyCard` (cut/paste each `_SettingSwitch` block and its comment into its own widget's `build`, reading `s`, `n`, `lock` the way `_PrivacyCard.build` did), add the part file and the route:

```dart
GoRoute(
  path: '/settings/privacy',
  parentNavigatorKey: _rootNavKey,
  pageBuilder: (context, state) => fadeSlidePage(
    child: const AuroraBackground(child: PrivacySectionScreen()),
    state: state,
  ),
),
```

Keep `_PrivacyCard` rendering the same tiles until Task 5 replaces the main screen, so the app works after every commit.
- [ ] **Step 4:** test PASS; `flutter analyze` clean; `flutter test test/profile_cover_test.dart` still green.
- [ ] **Step 5: Commit** "Give privacy and security a screen of their own".

### Task 3: Notifications & calls, connection, and data sections

**Files:**
- Create: `.../settings/notifications_section.dart`, `.../settings/connection_section.dart`, `.../settings/data_section.dart` (all `part of '../profile_screen.dart'`)
- Modify: `profile_screen.dart` (`part` directives), `app_router.dart` (three routes, same shape as Task 2), `test/profile_sections_test.dart`

**Interfaces:**
- Produces `NotificationsSectionScreen`, `ConnectionSectionScreen`, `DataSectionScreen` (public `ConsumerWidget`s):
  - Notifications: `SettingsSubheader(t.subNotifications)` + group `[if (PlatformInfo.isMobile) _PushWakeRow(), _QuietHoursRow()]`; `SettingsSubheader(t.subCalls)` + group `[_AcceptCallsTile(), _CallDirectTile(), if (PlatformInfo.isAndroid) _CallFullScreenTile()]`.
  - Connection: group `[_MeshSwitchCard(framed: false), _TransportRow(), _BackgroundModeCard(framed: false), _RelayFallbackCard(framed: false)]`.
  - Data: group `[_StorageRow(), _FileTransfersCard(framed: false), _BackupCard(framed: false), PhoneTransferCard(framed: false), if (PlatformInfo.isAndroid) _InstallUpdateRow()]`.

- [ ] **Step 1: Failing tests:** each screen shows its titles (keys from the spec §2 table). On a non-Android host (tests run on Windows, `PlatformInfo.isAndroid` false) `callFullScreenTitle` is absent and no empty `SettingsGroup` is rendered (Review Focus 1: count `SettingsGroup`s equals the number of subheaders).
- [ ] **Step 2:** run → FAIL.
- [ ] **Step 3:** implement the three part files and routes.
- [ ] **Step 4:** tests PASS, analyze clean.
- [ ] **Step 5: Commit** "Give notifications, connection and data their own screens".

### Task 4: Chats & media out of Customize; appearance keeps the look and gains the language

**Files:**
- Create: `lib/features/profile/presentation/chats_section.dart` (`part of 'customize_screen.dart'`)
- Modify: `customize_screen.dart` (remove moved cards from its list, add `part`, title becomes `t.sectionAppearance`, add `LanguageRow` at the end), `profile_screen.dart` (rename `_LanguageRow` → public `LanguageRow`), `app_router.dart` (`/settings/chats`), `test/profile_sections_test.dart`

**Interfaces:**
- Produces `ChatsSectionScreen`: `SettingsSectionScaffold(title: t.sectionChats)` with the existing cards in this order, spaced 12: `_SwipeCard()`, `_ArchiveRowCard()`, `_QuickReactionCard()`, `_CircleAudioCard()`, `_MediaQualityCard()`, `_MediaDownloadCard()`, `_TranscribeLanguageCard()`, and the circle-lens switch (`_CircleLensTile` is private to profile_screen.dart — expose it as public `CircleLensTile` for this one use).
- `CustomizeScreen` keeps `_ThemeCard`, `_ScaleCard`, `_GlassCard`, `_NavBarCard`, then `LanguageRow(locale: ...)` wrapped in a `GlassCard`.

- [ ] **Step 1: Failing tests:** `ChatsSectionScreen` shows the seven cards' titles plus `circleLensTitle`; `CustomizeScreen` no longer shows `_MediaQualityCard`'s title and does show `profileLanguageEn`/`profileLanguageUk`.
- [ ] **Step 2:** run → FAIL.
- [ ] **Step 3:** implement.
- [ ] **Step 4:** tests PASS, analyze clean.
- [ ] **Step 5: Commit** "Put chat and media settings together, and keep Appearance about how the app looks".

### Task 5: The new main profile

**Files:**
- Modify: `lib/features/profile/presentation/profile_screen.dart` (the `settings` sliver list in `build`, ~lines 164–273), `lib/features/moderation/presentation/about_screen.dart` (Diagnostics row), `test/profile_sections_test.dart`

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces: the main list, in order — `_IdentityChips()` (new private widget: `@name` line from `cubeIdControllerProvider` when set, then two chips: "Моя картка" `t.subMyCard` → `context.push('/contact-card')` (use the existing route `_ContactCardRow` pushes), and the short fingerprint (first two 4-char groups of `identityFingerprintProvider`) → `showGlassSheet` with the full fingerprint and a `t.fingerprintCopy` button copying it to the clipboard and showing `showGlassToast`); then `SettingsGroup([cubeId → '/cube-id', privacy → '/settings/privacy', notifications → '/settings/notifications', connection → '/settings/connection'])`, `SettingsGroup([chats → '/settings/chats', appearance → '/customize', data → '/settings/data'])`, `SettingsGroup([about → AboutScreen push as today])`, `SettingsGroup([SettingsSectionRow(danger: true, …)])` that calls the same confirm-and-wipe code `_EmergencyWipeCard` uses (extract its `onTap` body to `_confirmWipe(context, ref)` and call it from both).
- Values: cubeId `@name`; privacy = the reach label (`t.strangerReachAll/Request/None`); notifications = quiet-hours "HH:MM–HH:MM" when on, else null; connection `_connectionSummary`; appearance `_customizeSummary`; data `_dataSummary`; about `t.profileVersion(appVersion)` without the word if it reads long — use `appVersion`.
- Removes the fingerprint `GlassCard`, the four `_ExpandableSection`s, `_CustomizeRow`, `_EmergencyWipeCard` from the list; delete `_ExpandableSection`, `_privacySummary` and any widget left unused (analyzer `unused_element` will name them).
- About screen: a `_AboutAction` row "Діагностика" (`t.profileDiagnostics` — reuse the key `_DiagnosticsRow` shows) → `context.push('/diagnostics')`, after the privacy-policy row.

- [ ] **Step 1: Failing tests:** `ProfileScreen` shows eight section titles and the wipe row; tapping "Конфіденційність і безпека" pushes `/settings/privacy` (use a `GoRouter` test harness with stub routes); after `privacySettingsProvider.notifier.setStrangerReach(StrangerReach.request)` and a pump, the privacy row shows "Через запит" (Review Focus 4, uk locale); `AboutScreen` shows the Diagnostics row.
- [ ] **Step 2:** run → FAIL.
- [ ] **Step 3:** implement.
- [ ] **Step 4:** tests PASS; `flutter test test/profile_cover_test.dart test/profile_cover_scale_test.dart test/layer_budget_test.dart` green (profile ≤ 12); analyze clean.
- [ ] **Step 5: Commit** "Make the profile a short list of sections".

### Task 6: Every setting exactly once, goldens, full suite

**Files:**
- Modify: `test/profile_sections_test.dart`, `test/profile_sections_capture_test.dart` (golden) and its PNGs

- [ ] **Step 1: The census test.** A list of every setting title key from spec §2. Pump each section screen (Privacy, Notifications, Connection, Chats, Customize/Appearance, Data, About, CubeIdScreen) and the main profile; for each key assert it is found on exactly one of them (`find.text(...)` summed across screens equals 1). Android-only keys are excluded on this host.
- [ ] **Step 2:** run; fix any setting that is missing or duplicated, in the owning task's file.
- [ ] **Step 3: Golden.** Update `profile_sections_capture_test.dart` to capture the new main profile and the privacy section. Run `flutter test --tags golden test/profile_sections_capture_test.dart --update-goldens` only after rendering the new PNGs and looking at them (memory: render before claiming a visual fix); compare to the mock `cubechat-profile-maket.png`.
- [ ] **Step 4:** `flutter analyze` (0 errors/warnings), `flutter test --exclude-tags golden` all green.
- [ ] **Step 5: Commit** "Hold every setting to one place in the new profile".

### Task 7: Build and phone check

- [ ] Bump `pubspec.yaml` to the next build and `appBuildStamp` to `2026-09-30-profile-sections` (release-build skill), commit "Build <n> - …", push, dispatch `ios-testflight.yml`, build the APK in a clean worktree with the signing files copied, verify `CN=cubechat`.
- [ ] Give the owner Russian steps: open each section, change one setting, go back, confirm the summary on the row, restart the app, confirm the setting stuck; open/close the profile photo; check back navigation keeps the scroll position (Review Focus 3).

---

## Self-review

- Spec §1 → Task 5; §2 table → Tasks 2–5, pinned by Task 6's census; §3 code shape → Tasks 1–4 (part files per the 2026-09-30 amendment); §4 tests → Tasks 1–6; §5 nothing new.
- Names used across tasks: `SettingsSection`, `SettingsGroup`, `SettingsSectionRow`, `SettingsSubheader`, `SettingsSectionScaffold` (Task 1) in Tasks 2–5; `PrivacySectionScreen`, `NotificationsSectionScreen`, `ConnectionSectionScreen`, `DataSectionScreen`, `ChatsSectionScreen` in Task 5 routes; `LanguageRow`, `CircleLensTile` made public in Task 4.
