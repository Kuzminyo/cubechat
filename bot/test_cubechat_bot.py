import json
import os
import tempfile
import unittest

from cubechat_bot import (
    Admin,
    AdminError,
    Bot,
    BotState,
    Telegram,
    TelegramError,
    redact_url,
    report_text,
)


class FakeAdmin:
    """Records calls; a test configures what each method returns/raises."""

    def __init__(self):
        self.new_reports_calls = []
        self.ban_calls = []
        self.dismiss_calls = []
        self.unban_calls = []
        self._new_reports_result = ([], 0)
        self._ban_result = None
        self._ban_error = None
        self._dismiss_result = None
        self._dismiss_error = None
        self._unban_result = True
        self._unban_error = None

    def new_reports(self, since):
        self.new_reports_calls.append(since)
        return self._new_reports_result

    def open_reports(self):
        return self._open_reports_result

    def ban(self, report_id):
        self.ban_calls.append(report_id)
        if self._ban_error:
            raise self._ban_error
        return self._ban_result or {"ok": True}

    def dismiss(self, report_id):
        self.dismiss_calls.append(report_id)
        if self._dismiss_error:
            raise self._dismiss_error
        return self._dismiss_result or {"ok": True}

    def unban(self, key):
        self.unban_calls.append(key)
        if self._unban_error:
            raise self._unban_error
        return self._unban_result


class FakeTelegram:
    def __init__(self):
        self.sent = []  # (chat_id, text, buttons)
        self.edits = []  # (chat_id, message_id, text)
        self.answers = []  # (callback_id, text)
        self._updates = []
        self._next_message_id = 100
        self.fail_next_send = False

    def send(self, chat_id, text, buttons=None):
        if self.fail_next_send:
            self.fail_next_send = False
            raise TelegramError(500, {"description": "boom"})
        self._next_message_id += 1
        self.sent.append((chat_id, text, buttons))
        return self._next_message_id

    def edit(self, chat_id, message_id, text):
        self.edits.append((chat_id, message_id, text))

    def answer(self, callback_id, text=""):
        self.answers.append((callback_id, text))

    def updates(self, offset, timeout=30):
        return self._updates


OWNER_CHAT_ID = 42
OTHER_CHAT_ID = 999


def make_report(**overrides):
    report = {
        "id": "abc123",
        "seq": 1,
        "at": 1000,
        "reporter": "1111111122222222333333334444444455555555666666667777777788888888",
        "status": "open",
        "reason": "spam",
        "context": "direct",
        "target": "aaaaaaaabbbbbbbbccccccccddddddddeeeeeeeeffffffff0000000011111111",
    }
    report.update(overrides)
    return report


def callback_query(data, chat_id=OWNER_CHAT_ID, message_id=7, text="original text"):
    return {
        "id": "cbq1",
        "data": data,
        "message": {"chat": {"id": chat_id}, "message_id": message_id, "text": text},
    }


class ReportTextTests(unittest.TestCase):
    def test_truncates_to_1000_chars_and_never_shows_full_keys(self):
        long_note = "x" * 2000
        report = make_report(note=long_note)
        text = report_text(report)
        self.assertLessEqual(len(text), 1000)
        self.assertNotIn(report["reporter"], text)
        self.assertNotIn(report["target"], text)
        self.assertIn(report["reporter"][:8], text)
        self.assertIn(report["target"][:8], text)

    def test_includes_reason_and_context_labels(self):
        report = make_report(reason="abuse", context="channel", channelId="chan1")
        text = report_text(report)
        self.assertIn("Образа або цькування", text)
        self.assertIn("Канал", text)
        self.assertIn("chan1", text)

    def test_includes_message_excerpt(self):
        report = make_report(message={"text": "hello there", "kind": "text"})
        text = report_text(report)
        self.assertIn("hello there", text)


class RedactUrlTests(unittest.TestCase):
    def test_strips_bot_token_from_url(self):
        url = "https://api.telegram.org/bot123456:SECRET/sendMessage"
        self.assertNotIn("SECRET", redact_url(url))
        self.assertIn("/bot<redacted>/sendMessage", redact_url(url))


class ForwardReportsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile(delete=False)
        self.tmp.close()
        self.admin = FakeAdmin()
        self.telegram = FakeTelegram()
        self.state = BotState(self.tmp.name)
        self.bot = Bot(self.admin, self.telegram, OWNER_CHAT_ID, self.state)

    def tearDown(self):
        os.unlink(self.tmp.name)

    def test_new_report_sent_once_with_both_buttons_and_seq_advances(self):
        report = make_report(seq=5)
        self.admin._new_reports_result = ([report], 5)
        self.bot._forward_reports()
        self.assertEqual(len(self.telegram.sent), 1)
        chat_id, text, buttons = self.telegram.sent[0]
        self.assertEqual(chat_id, OWNER_CHAT_ID)
        self.assertIn(report["id"], text)
        self.assertEqual(buttons, [("Забанити", f"ban:{report['id']}"), ("Відхилити", f"dismiss:{report['id']}")])
        self.assertEqual(self.state.seq, 5)
        # Persisted: a fresh BotState over the same path sees the same seq.
        reloaded = BotState(self.tmp.name)
        self.assertEqual(reloaded.seq, 5)

    def test_failed_send_leaves_seq_for_retry(self):
        report = make_report(seq=7)
        self.admin._new_reports_result = ([report], 7)
        self.telegram.fail_next_send = True
        self.bot._forward_reports()
        self.assertEqual(self.state.seq, 0)
        # Next tick (send now works) re-sends the same report.
        self.bot._forward_reports()
        self.assertEqual(len(self.telegram.sent), 1)
        self.assertEqual(self.state.seq, 7)


class CallbackTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile(delete=False)
        self.tmp.close()
        self.admin = FakeAdmin()
        self.telegram = FakeTelegram()
        self.state = BotState(self.tmp.name)
        self.bot = Bot(self.admin, self.telegram, OWNER_CHAT_ID, self.state)

    def tearDown(self):
        os.unlink(self.tmp.name)

    def test_ban_callback_calls_api_and_edits_message(self):
        self.bot._handle_callback(callback_query("ban:abc123"))
        self.assertEqual(self.admin.ban_calls, ["abc123"])
        self.assertEqual(len(self.telegram.edits), 1)
        chat_id, message_id, text = self.telegram.edits[0]
        self.assertEqual(chat_id, OWNER_CHAT_ID)
        self.assertIn("Забанено", text)
        self.assertEqual(self.telegram.answers[-1][0], "cbq1")

    def test_dismiss_callback_calls_api_and_edits_message(self):
        self.bot._handle_callback(callback_query("dismiss:abc123"))
        self.assertEqual(self.admin.dismiss_calls, ["abc123"])
        self.assertIn("Відхилено", self.telegram.edits[0][2])

    def test_callback_from_other_chat_does_nothing(self):
        self.bot._handle_callback(callback_query("ban:abc123", chat_id=OTHER_CHAT_ID))
        self.assertEqual(self.admin.ban_calls, [])
        self.assertEqual(self.telegram.edits, [])
        self.assertEqual(self.telegram.answers, [])

    def test_409_conflict_edits_with_status_and_leaves_no_crash(self):
        self.admin._ban_error = AdminError(409, {"ok": False, "status": "dismissed"})
        self.bot._handle_callback(callback_query("ban:abc123"))
        self.assertIn("вже вирішено: dismissed", self.telegram.edits[0][2])
        self.assertIn("вже вирішено: dismissed", self.telegram.answers[-1][1])

    def test_503_tells_owner_and_leaves_buttons_in_place(self):
        self.admin._ban_error = AdminError(503, {"reason": "bans unavailable"})
        self.bot._handle_callback(callback_query("ban:abc123"))
        # No edit call at all: the message (and its buttons) is untouched.
        self.assertEqual(self.telegram.edits, [])
        self.assertEqual(self.telegram.answers[-1][1], "Бан не вдався, спробуйте ще раз")

    def test_404_reports_not_found(self):
        self.admin._ban_error = AdminError(404, {"reason": "no such report"})
        self.bot._handle_callback(callback_query("ban:missing"))
        self.assertEqual(self.telegram.answers[-1][1], "Скаргу не знайдено")


class CommandTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile(delete=False)
        self.tmp.close()
        self.admin = FakeAdmin()
        self.telegram = FakeTelegram()
        self.state = BotState(self.tmp.name)
        self.bot = Bot(self.admin, self.telegram, OWNER_CHAT_ID, self.state)

    def tearDown(self):
        os.unlink(self.tmp.name)

    def message(self, text, chat_id=OWNER_CHAT_ID):
        return {"chat": {"id": chat_id}, "text": text}

    def test_reports_command_lists_open_reports(self):
        self.admin._open_reports_result = [make_report(id="r1"), make_report(id="r2")]
        self.bot._handle_message(self.message("/reports"))
        self.assertEqual(len(self.telegram.sent), 1)
        self.assertIn("r1", self.telegram.sent[0][1])
        self.assertIn("r2", self.telegram.sent[0][1])

    def test_reports_command_when_none_open(self):
        self.admin._open_reports_result = []
        self.bot._handle_message(self.message("/reports"))
        self.assertEqual(self.telegram.sent[0][1], "Відкритих скарг немає")

    def test_unban_success(self):
        self.admin._unban_result = True
        self.bot._handle_message(self.message("/unban deadbeef"))
        self.assertEqual(self.admin.unban_calls, ["deadbeef"])
        self.assertEqual(self.telegram.sent[0][1], "Розблоковано")

    def test_unban_no_such_ban(self):
        self.admin._unban_result = False
        self.bot._handle_message(self.message("/unban deadbeef"))
        self.assertEqual(self.telegram.sent[0][1], "Такого бану немає")

    def test_unban_service_unavailable(self):
        self.admin._unban_error = AdminError(503, {"reason": "bans unavailable"})
        self.bot._handle_message(self.message("/unban deadbeef"))
        self.assertEqual(self.telegram.sent[0][1], "Сервіс банів недоступний")

    def test_unban_other_error_reports_status(self):
        self.admin._unban_error = AdminError(500, {})
        self.bot._handle_message(self.message("/unban deadbeef"))
        self.assertEqual(self.telegram.sent[0][1], "Помилка: 500")

    def test_reports_command_caps_at_20_and_notes_the_rest(self):
        self.admin._open_reports_result = [make_report(id=f"r{i}") for i in range(60)]
        self.bot._handle_message(self.message("/reports"))
        self.assertEqual(len(self.telegram.sent), 1)
        text = self.telegram.sent[0][1]
        self.assertLess(len(text), 4096)
        self.assertIn("і ще 40", text)
        self.assertEqual(text.count("·"), 20 * 2)  # 20 lines, two separators each

    def test_unknown_command_gets_help(self):
        self.bot._handle_message(self.message("hello"))
        self.assertIn("Команди:", self.telegram.sent[0][1])

    def test_message_from_other_chat_ignored(self):
        self.bot._handle_message(self.message("/reports", chat_id=OTHER_CHAT_ID))
        self.assertEqual(self.telegram.sent, [])
        # Logged once, not repeated for a second message from the same chat.
        self.bot._handle_message(self.message("/reports", chat_id=OTHER_CHAT_ID))
        self.assertEqual(self.telegram.sent, [])


class StatePersistenceTests(unittest.TestCase):
    def test_state_survives_a_new_bot_over_the_same_path(self):
        tmp = tempfile.NamedTemporaryFile(delete=False)
        tmp.close()
        try:
            state = BotState(tmp.name)
            state.seq = 12
            state.update_offset = 34
            state.save()

            reloaded = BotState(tmp.name)
            self.assertEqual(reloaded.seq, 12)
            self.assertEqual(reloaded.update_offset, 34)
        finally:
            os.unlink(tmp.name)

    def test_missing_state_file_defaults_to_zero(self):
        path = tempfile.mktemp()
        state = BotState(path)
        self.assertEqual(state.seq, 0)
        self.assertEqual(state.update_offset, 0)


class UpdateOffsetTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile(delete=False)
        self.tmp.close()
        self.admin = FakeAdmin()
        self.telegram = FakeTelegram()
        self.state = BotState(self.tmp.name)
        self.bot = Bot(self.admin, self.telegram, OWNER_CHAT_ID, self.state)

    def tearDown(self):
        os.unlink(self.tmp.name)

    def test_update_offset_advances_past_processed_updates(self):
        self.telegram._updates = [
            {"update_id": 10, "message": {"chat": {"id": OWNER_CHAT_ID}, "text": "/reports"}},
            {"update_id": 11, "message": {"chat": {"id": OWNER_CHAT_ID}, "text": "/reports"}},
        ]
        self.admin._open_reports_result = []
        self.bot._handle_updates()
        self.assertEqual(self.state.update_offset, 12)
        reloaded = BotState(self.tmp.name)
        self.assertEqual(reloaded.update_offset, 12)

    def test_handler_exception_does_not_block_the_next_update(self):
        class ExplodingAdmin(FakeAdmin):
            def __init__(self):
                super().__init__()
                self.open_reports_calls = 0

            def open_reports(self):
                self.open_reports_calls += 1
                if self.open_reports_calls == 1:
                    raise RuntimeError("boom")
                return []

        admin = ExplodingAdmin()
        telegram = FakeTelegram()
        bot = Bot(admin, telegram, OWNER_CHAT_ID, self.state)
        telegram._updates = [
            {"update_id": 20, "message": {"chat": {"id": OWNER_CHAT_ID}, "text": "/reports"}},
            {"update_id": 21, "message": {"chat": {"id": OWNER_CHAT_ID}, "text": "/reports"}},
        ]
        bot._handle_updates()
        # Both updates were consumed: the offset moved past both, not just
        # the one before the exploding handler.
        self.assertEqual(self.state.update_offset, 22)
        reloaded = BotState(self.tmp.name)
        self.assertEqual(reloaded.update_offset, 22)
        texts = [text for _, text, _buttons in telegram.sent]
        self.assertIn("Помилка обробки команди", texts)
        # Update 21's handler ran normally despite update 20's failure.
        self.assertIn("Відкритих скарг немає", texts)


class FakeOpener:
    """Records requests; returns queued (status, bytes) responses in order."""

    def __init__(self, responses):
        self._responses = list(responses)
        self.calls = []

    def __call__(self, url, data=None, headers=None, method="GET", timeout=30):
        self.calls.append({"url": url, "data": data, "headers": headers, "method": method})
        return self._responses.pop(0)


class AdminHttpTests(unittest.TestCase):
    def test_new_reports_parses_body_and_sends_bearer_token(self):
        body = json.dumps({"reports": [{"id": "a"}], "next": 3}).encode()
        opener = FakeOpener([(200, body)])
        admin = Admin("http://127.0.0.1:8080", "sekrit", opener=opener)
        reports, next_seq = admin.new_reports(0)
        self.assertEqual(reports, [{"id": "a"}])
        self.assertEqual(next_seq, 3)
        self.assertEqual(opener.calls[0]["headers"]["Authorization"], "Bearer sekrit")
        self.assertIn("/admin/reports?since=0", opener.calls[0]["url"])

    def test_ban_raises_admin_error_on_non_200(self):
        body = json.dumps({"ok": False, "status": "dismissed"}).encode()
        opener = FakeOpener([(409, body)])
        admin = Admin("http://127.0.0.1:8080", "sekrit", opener=opener)
        with self.assertRaises(AdminError) as ctx:
            admin.ban("abc")
        self.assertEqual(ctx.exception.status, 409)
        self.assertEqual(ctx.exception.body["status"], "dismissed")

    def test_unban_raises_admin_error_on_non_200(self):
        # Review round 1: this used to swallow every non-200 into `False`,
        # so a 503 (bans service down) read to the owner exactly like "no
        # such ban". It must surface the status instead.
        opener = FakeOpener([(503, b"{}")])
        admin = Admin("http://127.0.0.1:8080", "sekrit", opener=opener)
        with self.assertRaises(AdminError) as ctx:
            admin.unban("key")
        self.assertEqual(ctx.exception.status, 503)

    def test_unban_returns_removed_flag(self):
        opener = FakeOpener([(200, json.dumps({"ok": False}).encode())])
        admin = Admin("http://127.0.0.1:8080", "sekrit", opener=opener)
        self.assertFalse(admin.unban("key"))


class TelegramHttpTests(unittest.TestCase):
    def test_send_returns_message_id(self):
        body = json.dumps({"ok": True, "result": {"message_id": 55}}).encode()
        opener = FakeOpener([(200, body)])
        telegram = Telegram("123:ABC", opener=opener)
        message_id = telegram.send(1, "hi")
        self.assertEqual(message_id, 55)

    def test_rate_limit_waits_retry_after_then_retries(self):
        first = (429, json.dumps({"ok": False, "error_code": 429, "parameters": {"retry_after": 2}}).encode())
        second = (200, json.dumps({"ok": True, "result": {"message_id": 1}}).encode())
        opener = FakeOpener([first, second])
        telegram = Telegram("123:ABC", opener=opener)
        sleeps = []
        import cubechat_bot

        original_sleep = cubechat_bot.time.sleep
        cubechat_bot.time.sleep = lambda seconds: sleeps.append(seconds)
        try:
            message_id = telegram.send(1, "hi")
        finally:
            cubechat_bot.time.sleep = original_sleep
        self.assertEqual(message_id, 1)
        self.assertEqual(sleeps, [2])
        self.assertEqual(len(opener.calls), 2)

    def test_error_raises_telegram_error(self):
        opener = FakeOpener([(400, json.dumps({"ok": False, "description": "bad"}).encode())])
        telegram = Telegram("123:ABC", opener=opener)
        with self.assertRaises(TelegramError):
            telegram.send(1, "hi")


if __name__ == "__main__":
    unittest.main()
