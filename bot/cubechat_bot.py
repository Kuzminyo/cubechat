"""A Telegram bot that brings cubechat abuse reports to the owner.

Talks to the push server's localhost admin API (`push/src/index.js`,
`handleAdmin`) and to the Telegram Bot API. Standard library only — nothing
to `pip install` on the droplet (see `bot/README.md`).

Config comes entirely from the environment:
  TELEGRAM_BOT_TOKEN     — the bot's token from @BotFather.
  TELEGRAM_OWNER_CHAT_ID — the only chat the bot answers to.
  ADMIN_URL              — default http://127.0.0.1:8080.
  ADMIN_TOKEN            — the admin API's bearer token.
  STATE_PATH             — default ./bot-state.json.

Neither token is ever written to a log line. The Telegram token lives in the
URL path of every Bot API call, so every logged URL is redacted first.
"""

from __future__ import annotations

import json
import logging
import os
import re
import time
import urllib.error
import urllib.request

TELEGRAM_API_BASE = "https://api.telegram.org"

# reason/context enums mirror push/src/index.js's REPORT_REASONS / REPORT_CONTEXTS.
REASON_LABELS = {
    "spam": "Спам",
    "abuse": "Образа або цькування",
    "violence": "Насильство",
    "sexual": "Сексуальний вміст",
    "other": "Інше",
}
CONTEXT_LABELS = {
    "direct": "Особисте",
    "channel": "Канал",
    "airdrop": "AirDrop",
    "general": "Загальне",
}

REPORT_EXCERPT_MAX_CHARS = 1000

# Telegram refuses a message over 4096 characters outright; both caps stay
# safely under that so `/reports` never becomes the poison update that wedges
# the bot on itself (review round 1).
REPORTS_LIST_MAX_ITEMS = 20
REPORTS_LIST_MAX_CHARS = 4000

HELP_TEXT = (
    "Команди:\n"
    "/reports — список відкритих скарг\n"
    "/unban <ключ> — зняти бан"
)

_TOKEN_IN_URL = re.compile(r"/bot[^/]+/")


def redact_url(url: str) -> str:
    """Strips a Telegram bot token out of a URL before it is logged."""
    return _TOKEN_IN_URL.sub("/bot<redacted>/", url)


class TransportError(Exception):
    """The request never got a response at all (DNS, refused, timeout)."""


class AdminError(Exception):
    """The admin API answered with a non-200 status."""

    def __init__(self, status: int, body: object) -> None:
        super().__init__(f"admin api error {status}")
        self.status = status
        self.body = body if isinstance(body, dict) else {}


class TelegramError(Exception):
    """The Bot API answered with an error after any rate-limit wait."""

    def __init__(self, status: int, body: object) -> None:
        super().__init__(f"telegram api error {status}")
        self.status = status
        self.body = body if isinstance(body, dict) else {}


def _default_opener(url, data=None, headers=None, method="GET", timeout=30):
    """(status, raw_bytes) over urllib — the shape both API clients use.

    HTTPError is not re-raised: its body is exactly what the caller needs to
    look at (an admin 409/503, a Telegram error description), so it is
    normalised into the same (status, body) shape a 200 would give.
    """
    request = urllib.request.Request(url, data=data, headers=headers or {}, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()
    except urllib.error.URLError as error:
        raise TransportError(str(error)) from error


def _parse_json_body(raw: bytes) -> dict:
    if not raw:
        return {}
    try:
        parsed = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return {}
    return parsed if isinstance(parsed, dict) else {}


class Admin:
    """Wraps S2's localhost admin API (push/src/index.js, `handleAdmin`)."""

    def __init__(self, base_url: str, token: str, opener=None) -> None:
        self._base_url = base_url.rstrip("/")
        self._token = token
        self._opener = opener or _default_opener

    def _request(self, method: str, path: str, body: dict | None = None):
        url = f"{self._base_url}{path}"
        headers = {"Authorization": f"Bearer {self._token}"}
        data = None
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        status, raw = self._opener(url, data=data, headers=headers, method=method, timeout=15)
        return status, _parse_json_body(raw)

    def new_reports(self, since: int) -> tuple[list[dict], int]:
        status, body = self._request("GET", f"/admin/reports?since={since}")
        if status != 200:
            raise AdminError(status, body)
        return body.get("reports", []), body.get("next", since)

    def open_reports(self) -> list[dict]:
        status, body = self._request("GET", "/admin/reports?status=open")
        if status != 200:
            raise AdminError(status, body)
        return body.get("reports", [])

    def ban(self, report_id: str) -> dict:
        status, body = self._request("POST", f"/admin/reports/{report_id}/ban")
        if status != 200:
            raise AdminError(status, body)
        return body

    def dismiss(self, report_id: str) -> dict:
        status, body = self._request("POST", f"/admin/reports/{report_id}/dismiss")
        if status != 200:
            raise AdminError(status, body)
        return body

    def unban(self, key: str) -> bool:
        status, body = self._request("POST", "/admin/unban", {"key": key})
        if status != 200:
            # Same treatment as ban/dismiss: a non-200 is a service problem,
            # not "no such ban" — the caller needs the status to tell those
            # apart (review round 1: this used to collapse both into False,
            # so a 503 read to the owner as "no such ban").
            raise AdminError(status, body)
        return bool(body.get("ok"))


class Telegram:
    """Wraps the Bot API methods this bot needs, over urllib."""

    def __init__(self, token: str, opener=None) -> None:
        self._token = token
        self._opener = opener or _default_opener

    def _url(self, method: str) -> str:
        return f"{TELEGRAM_API_BASE}/bot{self._token}/{method}"

    def _call(self, method: str, payload: dict, request_timeout: int = 30) -> dict:
        url = self._url(method)
        data = json.dumps(payload).encode("utf-8")
        headers = {"Content-Type": "application/json"}
        # One retry: a 429 is handled by waiting exactly as long as Telegram
        # asked and trying once more, not by looping indefinitely against a
        # bot that might be misconfigured some other way.
        for attempt in range(2):
            status, raw = self._opener(url, data=data, headers=headers, method="POST", timeout=request_timeout)
            body = _parse_json_body(raw)
            retry_after = _retry_after(status, body)
            if retry_after is not None and attempt == 0:
                logging.warning("telegram rate limited, waiting %ss (%s)", retry_after, redact_url(url))
                time.sleep(retry_after)
                continue
            if status >= 400 or body.get("ok") is False:
                logging.error(
                    "telegram api error %s calling %s: %s",
                    status,
                    redact_url(url),
                    body.get("description", body),
                )
                raise TelegramError(status, body)
            return body
        raise TelegramError(status, body)

    def send(self, chat_id, text: str, buttons=None) -> int:
        payload: dict = {"chat_id": chat_id, "text": text}
        if buttons:
            payload["reply_markup"] = {
                "inline_keyboard": [[{"text": label, "callback_data": data} for label, data in buttons]],
            }
        body = self._call("sendMessage", payload)
        return body["result"]["message_id"]

    def edit(self, chat_id, message_id, text: str) -> None:
        self._call("editMessageText", {"chat_id": chat_id, "message_id": message_id, "text": text})

    def answer(self, callback_id, text: str = "") -> None:
        payload: dict = {"callback_query_id": callback_id}
        if text:
            payload["text"] = text
        self._call("answerCallbackQuery", payload)

    def updates(self, offset: int, timeout: int = 30) -> list[dict]:
        body = self._call("getUpdates", {"offset": offset, "timeout": timeout}, request_timeout=timeout + 10)
        return body.get("result", [])


def _retry_after(status: int, body: dict):
    """None unless this response is a 429, in which case seconds to wait."""
    if status != 429 and body.get("error_code") != 429:
        return None
    params = body.get("parameters")
    if isinstance(params, dict) and isinstance(params.get("retry_after"), (int, float)):
        return params["retry_after"]
    return 1


def _short(hex_key) -> str:
    if not isinstance(hex_key, str) or not hex_key:
        return "—"
    return hex_key[:8]


def report_text(report: dict) -> str:
    """A Telegram message for one report: reason (uk), context, 8-hex target
    and reporter (never the full key), and an excerpt capped at 1000 chars.
    """
    reason = REASON_LABELS.get(report.get("reason"), str(report.get("reason")))
    context = CONTEXT_LABELS.get(report.get("context"), str(report.get("context")))
    lines = [
        f"Скарга #{report.get('id', '?')}",
        f"Причина: {reason}",
        f"Контекст: {context}",
        f"Ціль: {_short(report.get('target'))}",
        f"Скаржник: {_short(report.get('reporter'))}",
    ]
    channel_id = report.get("channelId")
    if channel_id:
        lines.append(f"Канал: {channel_id}")
    note = report.get("note")
    if note:
        lines.append(f"Нотатка: {note}")
    message = report.get("message")
    if isinstance(message, dict) and message.get("text"):
        lines.append(f"Повідомлення: {message['text']}")
    text = "\n".join(lines)
    return text[:REPORT_EXCERPT_MAX_CHARS]


class BotState:
    """The last forwarded report `seq` and Telegram `update_id`, persisted
    so a restart neither re-sends a report nor loses a callback.
    """

    def __init__(self, path: str) -> None:
        self.path = path
        self.seq = 0
        self.update_offset = 0
        self._load()

    def _load(self) -> None:
        try:
            with open(self.path, "r", encoding="utf-8") as handle:
                data = json.load(handle)
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            return
        if not isinstance(data, dict):
            return
        self.seq = int(data.get("seq", 0) or 0)
        self.update_offset = int(data.get("update_offset", 0) or 0)

    def save(self) -> None:
        data = {"seq": self.seq, "update_offset": self.update_offset}
        temp_path = f"{self.path}.tmp"
        with open(temp_path, "w", encoding="utf-8") as handle:
            json.dump(data, handle)
        os.replace(temp_path, self.path)


class Bot:
    def __init__(self, admin: Admin, telegram: Telegram, owner_chat_id, state: BotState) -> None:
        self._admin = admin
        self._telegram = telegram
        self._owner_chat_id = owner_chat_id
        self._state = state
        self._logged_other_chats: set = set()

    def tick(self) -> None:
        self._forward_reports()
        self._handle_updates()

    # -- forwarding -----------------------------------------------------

    def _forward_reports(self) -> None:
        reports, _next_seq = self._admin.new_reports(self._state.seq)
        advanced = False
        for report in reports:
            buttons = [
                ("Забанити", f"ban:{report['id']}"),
                ("Відхилити", f"dismiss:{report['id']}"),
            ]
            try:
                self._telegram.send(self._owner_chat_id, report_text(report), buttons=buttons)
            except (TelegramError, TransportError):
                logging.exception("failed to forward report %s", report.get("id"))
                # Stop here: `seq` stays at the last report that was
                # actually delivered, so the next tick re-sends this one
                # instead of skipping it because of a Telegram outage.
                break
            self._state.seq = report.get("seq", self._state.seq)
            advanced = True
        if advanced:
            self._state.save()

    # -- updates ----------------------------------------------------------

    def _handle_updates(self) -> None:
        updates = self._telegram.updates(self._state.update_offset, timeout=25)
        for update in updates:
            # Mark the update seen — and persist that — *before* handling
            # it. A handler that raises must not make the same update come
            # back on the next tick: that is exactly how one bad update (a
            # command whose reply is too long, say) would wedge every later
            # command and button press behind it forever (review round 1).
            self._state.update_offset = update["update_id"] + 1
            self._state.save()
            self._dispatch(update)

    def _dispatch(self, update: dict) -> None:
        try:
            if "callback_query" in update:
                self._handle_callback(update["callback_query"])
            elif "message" in update:
                self._handle_message(update["message"])
        except Exception:  # noqa: BLE001 - one bad update must not wedge the rest
            logging.exception("failed to handle update %s", update.get("update_id"))
            self._tell_owner_on_best_effort(update, "Помилка обробки команди")

    def _tell_owner_on_best_effort(self, update: dict, text: str) -> None:
        chat_id = (
            update.get("message", {}).get("chat", {}).get("id")
            or update.get("callback_query", {}).get("message", {}).get("chat", {}).get("id")
        )
        if not self._is_owner(chat_id):
            return
        try:
            self._telegram.send(chat_id, text)
        except (TelegramError, TransportError):
            # The handler already failed once; a second failure here just
            # means the owner finds out from the next successful message
            # instead, not that the loop should retry this update.
            logging.exception("failed to notify owner about a handling error")

    def _handle_callback(self, callback: dict) -> None:
        message = callback.get("message") or {}
        chat_id = message.get("chat", {}).get("id")
        message_id = message.get("message_id")
        callback_id = callback.get("id")
        if not self._is_owner(chat_id):
            self._log_foreign_chat(chat_id)
            return
        data = callback.get("data") or ""
        action, _, report_id = data.partition(":")
        if action not in ("ban", "dismiss") or not report_id:
            self._telegram.answer(callback_id)
            return
        label = "✅ Забанено" if action == "ban" else "✖️ Відхилено"
        try:
            if action == "ban":
                self._admin.ban(report_id)
            else:
                self._admin.dismiss(report_id)
        except AdminError as error:
            self._handle_decision_error(error, callback_id, chat_id, message_id, message.get("text", ""))
            return
        self._telegram.answer(callback_id, label)
        self._telegram.edit(chat_id, message_id, f"{message.get('text', '')}\n{label}")

    def _handle_decision_error(self, error: AdminError, callback_id, chat_id, message_id, original_text: str) -> None:
        if error.status == 409:
            status = error.body.get("status", "?")
            note = f"вже вирішено: {status}"
            self._telegram.answer(callback_id, note)
            self._telegram.edit(chat_id, message_id, f"{original_text}\n{note}")
        elif error.status == 503:
            # The report is back to 'open' server-side (handleAdmin reverts
            # it on a failed ban), so the buttons are left exactly as they
            # are — a retry tap is the whole recovery path.
            self._telegram.answer(callback_id, "Бан не вдався, спробуйте ще раз")
        elif error.status == 404:
            self._telegram.answer(callback_id, "Скаргу не знайдено")
        else:
            logging.error("admin api error %s deciding a report", error.status)
            self._telegram.answer(callback_id, "Помилка")

    def _handle_message(self, message: dict) -> None:
        chat_id = message.get("chat", {}).get("id")
        if not self._is_owner(chat_id):
            self._log_foreign_chat(chat_id)
            return
        text = (message.get("text") or "").strip()
        if text.startswith("/reports"):
            self._cmd_reports(chat_id)
        elif text.startswith("/unban"):
            self._cmd_unban(chat_id, text)
        else:
            self._telegram.send(chat_id, HELP_TEXT)

    def _cmd_reports(self, chat_id) -> None:
        reports = self._admin.open_reports()
        if not reports:
            self._telegram.send(chat_id, "Відкритих скарг немає")
            return
        # Capped two ways (review round 1): at most 20 lines, and the whole
        # message cut to 4000 chars regardless — a long note or a big enough
        # backlog must never build a message Telegram's 4096-char limit
        # rejects, since that turns `/reports` into a poison update.
        shown = reports[:REPORTS_LIST_MAX_ITEMS]
        lines = [
            f"{report.get('id')} · {REASON_LABELS.get(report.get('reason'), report.get('reason'))} · {_short(report.get('target'))}"
            for report in shown
        ]
        remaining = len(reports) - len(shown)
        if remaining > 0:
            lines.append(f"…і ще {remaining}")
        self._telegram.send(chat_id, "\n".join(lines)[:REPORTS_LIST_MAX_CHARS])

    def _cmd_unban(self, chat_id, text: str) -> None:
        parts = text.split(maxsplit=1)
        if len(parts) != 2 or not parts[1].strip():
            self._telegram.send(chat_id, HELP_TEXT)
            return
        key = parts[1].strip()
        try:
            removed = self._admin.unban(key)
        except AdminError as error:
            if error.status == 503:
                self._telegram.send(chat_id, "Сервіс банів недоступний")
            else:
                self._telegram.send(chat_id, f"Помилка: {error.status}")
            return
        self._telegram.send(chat_id, "Розблоковано" if removed else "Такого бану немає")

    # -- helpers ------------------------------------------------------------

    def _is_owner(self, chat_id) -> bool:
        return chat_id is not None and str(chat_id) == str(self._owner_chat_id)

    def _log_foreign_chat(self, chat_id) -> None:
        if chat_id in self._logged_other_chats:
            return
        self._logged_other_chats.add(chat_id)
        logging.info("ignoring message/callback from chat %s (not the owner)", chat_id)

    def run(self) -> None:
        while True:
            try:
                self.tick()
            except Exception:  # noqa: BLE001 - a tick must never kill the loop
                logging.exception("bot tick failed")
                time.sleep(5)


def _env_config():
    token = os.environ.get("TELEGRAM_BOT_TOKEN")
    owner_chat_id = os.environ.get("TELEGRAM_OWNER_CHAT_ID")
    admin_url = os.environ.get("ADMIN_URL", "http://127.0.0.1:8080")
    admin_token = os.environ.get("ADMIN_TOKEN")
    state_path = os.environ.get("STATE_PATH", "./bot-state.json")
    missing = [
        name
        for name, value in (
            ("TELEGRAM_BOT_TOKEN", token),
            ("TELEGRAM_OWNER_CHAT_ID", owner_chat_id),
            ("ADMIN_TOKEN", admin_token),
        )
        if not value
    ]
    if missing:
        raise SystemExit(f"missing required env vars: {', '.join(missing)}")
    return token, owner_chat_id, admin_url, admin_token, state_path


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
    token, owner_chat_id, admin_url, admin_token, state_path = _env_config()
    admin = Admin(admin_url, admin_token)
    telegram = Telegram(token)
    state = BotState(state_path)
    bot = Bot(admin, telegram, owner_chat_id, state)
    logging.info("cubechat bot starting, admin at %s", admin_url)
    bot.run()


if __name__ == "__main__":
    main()
