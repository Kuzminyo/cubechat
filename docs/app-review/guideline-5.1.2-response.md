# App Store review — Guideline 5.1.2(i): ответ и заметки для проверяющего

Сборка: **1.0.0 (1042)**, штамп `2026-09-14-the-live-map-is-back-and-asks-first`.

Порядок:

1. App Store Connect → приложение → **App Information** → **Age Ratings** →
   **Set Up Age Ratings** → раздел **Age Categories and Override** →
   **Override to Higher Age Rating** → **18+** → **Save**.
2. Там же, в **App Information** (или **App Privacy**), поле **Privacy Policy
   URL** → `https://cubechat.tech/privacy`. Сначала опубликовать там текст из
   `docs/legal/privacy-policy.en.md` / `.uk.md` (сайт — отдельный репозиторий
   `Kuzminyo/landing_cubechat`).
3. Выбрать сборку **1042** в версии приложения.
4. **App Review Information → Notes**: вставить текст из раздела B.
5. Лучше приложить короткое видео экрана (раздел C): у проверяющего один
   телефон, и без второго он не увидит карту в работе.
6. В **Resolution Center** ответить текстом из раздела A и нажать
   **Submit for Review**.

---

## A. Ответ в Resolution Center (копировать как есть)

```text
Hello, and thank you for the detailed feedback.

We have made the following changes in build 1.0.0 (1042):

1. Age rating — the app is now rated 18+ in App Store Connect.

2. Privacy policy — the Privacy Policy URL is set to
   https://cubechat.tech/privacy. It describes exactly what location data is
   used, who can see it, and how to stop sharing.

3. Blocking — any contact can be blocked from their profile (Block). A blocked
   contact receives no location from the user, a location already shown to
   them is withdrawn from their map immediately, and the blocked contact's
   location is no longer drawn on the user's map.

4. Permission with the option to decline — before the user's location is
   shown on the map for the first time, the app asks in its own dialog
   ("Show your location on the map?") with "Allow" and "Don't allow".
   "Don't allow" leaves sharing off, and the app does not even read the
   device location. The same dialog appears every time sharing is turned
   back on, whether from the Map tab, from Profile, when sending a map
   invitation, or when accepting one. The system location permission is
   requested only after the user allows, never during onboarding.

5. Check-ins — we would like to explain how location sharing works in
   Cubechat, because we believe it is closer to a friends map than to a
   check-in feature with public visibility:

   - Location is shared only between people who explicitly agreed to it:
     the user invites a contact to their map, or accepts a contact's
     invitation. It is never shown to strangers, to nearby users, or in any
     public or discoverable place. There is no public map and no user search
     by location.
   - Sharing is off by default and is turned on only by the user, after the
     consent dialog above.
   - It is end-to-end encrypted between the two devices. We do not operate a
     location server and never receive anyone's location.
   - The user can stop at any moment with one tap: "Hide" on the Map tab
     (always visible there), or the "Show me on map" switch in Profile.
     Hiding withdraws the user's pin from every friend's map immediately.
   - The user can remove any single person from their map ("Remove from
     map"), or block them.
   - Each location update expires on the friend's map after six minutes
     unless a newer one arrives, so a stale position is never left behind.

   This is the same model as established friends-map apps already on the App
   Store, for example Bump by amo (Social Networking, live location shared
   with friends, "Ghost mode" to stop sharing), Find My, and Life360: live
   location, visible only to people the user chose, with an always-available
   way to stop.

   If, after reviewing this, a live location visible to mutually accepted
   friends is still not acceptable, please let us know which specific change
   you require, and we will implement it.

Steps to review:
- Map tab → the pill at the bottom reads "You are hidden · Show me".
  Tap "Show me" → the consent dialog appears with "Allow" / "Don't allow".
- After allowing, the pill reads "Friends on your map see you · Hide".
  Tap "Hide" → sharing stops and the pin is withdrawn from friends' maps.
- Profile → Privacy → "Show me on map" switch does the same.
- Map tab → "People on the map" → "Invite" / "Remove from map".
- Any chat → contact profile → "Block".

Seeing a friend's live pin requires a second device with Cubechat and an
accepted map invitation between the two. We have attached a short screen
recording that shows the full flow on two devices.

Thank you.
```

**Перевод (для себя):** благодарим за отзыв; в сборке 1042 сделали: (1) рейтинг
18+; (2) ссылка на политику конфиденциальности; (3) блокировка — заблокированный
не получает геопозицию, уже показанная позиция отзывается, его позиция не
рисуется; (4) перед показом на карте свой диалог «Показать местоположение на
карте?» с «Разрешить / Не разрешать», при отказе телефон даже не читает
координаты; диалог появляется каждый раз при включении; системный запрос
геолокации — только после согласия, не на онбординге; (5) объясняем модель:
только взаимно добавленные друзья, никаких незнакомцев и публичной карты,
выключено по умолчанию, сквозное шифрование, сервера геолокации у нас нет,
«Скрыться» одним нажатием прямо на карте, можно убрать конкретного человека или
заблокировать, каждое обновление гаснет через 6 минут. Это та же модель, что у
Bump (amo), «Локатора» и Life360. Если всё равно нельзя — скажите, какое именно
изменение нужно. Дальше — шаги, где что найти, и что для живой метки нужен
второй телефон (прикладываем видео).

---

## B. App Review Information → Notes (короче, копировать как есть)

```text
Cubechat is an end-to-end encrypted messenger. Its map shows a user's live
location only to contacts the user personally invited to the map or whose
invitation they accepted. There is no public map, no nearby-user discovery,
and no location server: locations travel end-to-end encrypted between devices.

Precautions:
- Rated 18+. Privacy policy: https://cubechat.tech/privacy
- Consent: before location is shown on the map, an in-app dialog asks
  "Show your location on the map?" with "Allow" / "Don't allow". It appears
  every time sharing is turned on. Declining reads no location at all.
- Stop at any time: "Hide" on the Map tab (always visible), or Profile →
  Privacy → "Show me on map". Hiding withdraws the pin from friends' maps
  immediately.
- Per-person control: Map tab → "People on the map" → "Remove from map".
- Blocking: contact profile → "Block". Blocked contacts receive no location,
  and a pin already shown to them is withdrawn at once.

How to test: Map tab → "Show me" → consent dialog → Allow / Don't allow.
A friend's live pin needs a second device with an accepted map invitation;
a screen recording of the two-device flow is attached in Resolution Center.
```

---

## C. Что снять на видео (1–2 минуты, два телефона)

1. Телефон A: вкладка «Карта» → плашка «Вас не видно · Показать мене» →
   нажать → диалог согласия → **«Не дозволяти»** → ничего не включилось.
2. Снова «Показать мене» → **«Дозволити»** → системный запрос геолокации →
   разрешить → плашка «Друзі на мапі бачать вас · Сховатися».
3. «Люди на мапі» → «Запросити» → выбрать чат с телефоном B → отправить.
4. Телефон B: принять приглашение в чате → диалог согласия → «Дозволити».
5. Показать метки друг друга на обоих телефонах.
6. Телефон A: «Сховатися» → на телефоне B метка A пропала.
7. Телефон B: профиль контакта A → «Заблокувати» → метка B у A пропала.

Интерфейс на видео лучше переключить на английский — проверяющему так проще.
