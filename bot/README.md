# The Telegram bot

A separate Python process (`cubechat_bot.py`, standard library only — nothing
to `pip install` on the droplet) that forwards every report the push server
stores to the owner's Telegram, with Забанити/Відхилити buttons on it, and
talks back to `push`'s admin API to act on them. It runs beside `push` on the
same droplet and never talks to Telegram or the admin API from anywhere else
(the server refuses `/admin/*` to any address but `127.0.0.1`/`::1` — see the
comment above `handleAdmin` in `push/src/index.js`).

## Requirements

Python ≥ 3.10. Nothing else — `urllib`, `json`, `time`, `logging` and
`unittest` are all it uses.

## Creating the bot

The owner already has a bot token from a prior `/newbot` with
[@BotFather](https://t.me/BotFather); this repo never holds it. If a new one
is ever needed: message @BotFather, `/newbot`, follow the prompts, and it
prints a token that looks like `123456789:AAExampleTokenTextGoesHere`.

To find the chat id the bot should answer to: send the bot any message, then
(with `<TOKEN>` filled in — never commit this URL anywhere with the real
token in it)

```bash
curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates" | python3 -m json.tool
```

and read `result[].message.chat.id`. That's `TELEGRAM_OWNER_CHAT_ID` — the
only chat the bot will ever act on; everything else is ignored (and logged
once per chat id).

## Configuration

Four environment variables, none of them checked into git:

| Variable | Meaning | Default |
|---|---|---|
| `TELEGRAM_BOT_TOKEN` | the bot's token from @BotFather | *(required)* |
| `TELEGRAM_OWNER_CHAT_ID` | the only chat the bot answers to | *(required)* |
| `ADMIN_URL` | the push server's admin API | `http://127.0.0.1:8080` |
| `ADMIN_TOKEN` | bearer token for that API (same value as `push`'s `.env`, see `push/deploy/README.md`'s "Moderation" section) | *(required)* |
| `STATE_PATH` | where the last forwarded report and Telegram update are remembered | `./bot-state.json` |

Example env file (placeholders only — never put a real token in this repo):

```
TELEGRAM_BOT_TOKEN=123456789:REPLACE_WITH_THE_REAL_TOKEN
TELEGRAM_OWNER_CHAT_ID=REPLACE_WITH_THE_OWNER_CHAT_ID
ADMIN_URL=http://127.0.0.1:8080
ADMIN_TOKEN=REPLACE_WITH_THE_SAME_ADMIN_TOKEN_PUSH_USES
STATE_PATH=/opt/cubechat-bot/bot-state.json
```

## Running it

```bash
python3 cubechat_bot.py
```

It long-polls Telegram (`getUpdates`, 25 s) and, on the same loop, asks the
admin API for anything new since the last forwarded report. A crash or a
restart loses nothing: `STATE_PATH` remembers the last report `seq` and the
last Telegram `update_id`, written atomically (temp file + `os.replace`), so
a restart neither re-sends a report nor replays an old button press.

## What it does

- **Forwarding.** Every report the server has stored since the last one this
  bot sent becomes one Telegram message with the reason (in Ukrainian), the
  context, the first 8 hex characters of the target and the reporter (never
  the full key), and up to a 1000-character excerpt — with "Забанити" and
  "Відхилити" buttons. `seq` only advances after Telegram confirms the send,
  so an outage re-sends later instead of losing a report.
- **Buttons**, from the owner's chat only: `Забанити` calls the admin API's
  ban route and appends "✅ Забанено" to the message; `Відхилити` dismisses
  and appends "✖️ Відхилено". If the report was already decided (409), the
  message is edited with "вже вирішено: `<status>`" instead. If a ban failed
  server-side (503 — the report is back to `open`), the bot tells the owner
  "Бан не вдався, спробуйте ще раз" and leaves the message and its buttons
  untouched, so tapping again is the whole retry.
- **Commands**, owner only: `/reports` lists open reports; `/unban <key>`
  calls the admin API's unban route; anything else gets a one-line help
  message.
- Anything from any other chat is ignored and logged once per chat id.

Neither `TELEGRAM_BOT_TOKEN` nor `ADMIN_TOKEN` is ever written to a log line.
The bot token lives in the path of every Telegram API URL, so every URL is
redacted (`/bot<redacted>/...`) before it's logged.

## Tests

```bash
python3 -m unittest discover -s bot
```

Both HTTP sides (the admin API and the Telegram Bot API) are faked in the
tests — nothing here makes a real network call.

## Putting it on the droplet

Same layout as `push` (`push/deploy/README.md`):

```bash
mkdir -p /opt/cubechat-bot
```

```powershell
scp -r D:\projects\cubechat\bot\. root@209.38.225.225:/opt/cubechat-bot
```

Then on the droplet, once:

```bash
adduser --system --group --home /opt/cubechat-bot cubechat-bot
cat > /etc/cubechat-bot.env <<'EOF'
TELEGRAM_BOT_TOKEN=<the real token>
TELEGRAM_OWNER_CHAT_ID=<the real chat id>
ADMIN_URL=http://127.0.0.1:8080
ADMIN_TOKEN=<the same value push's .env uses>
STATE_PATH=/opt/cubechat-bot/bot-state.json
EOF
chmod 600 /etc/cubechat-bot.env
chown -R cubechat-bot:cubechat-bot /opt/cubechat-bot
cp /opt/cubechat-bot/cubechat-bot.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now cubechat-bot
```

Check it landed:

```bash
journalctl -u cubechat-bot -n 30 --no-pager
```

A line naming the admin URL at startup, then silence until the first report
or button press, is what "working" looks like. `ImportError`/`ModuleNotFound`
lines mean the Python on the droplet is older than 3.10 — check with
`python3 --version` before anything else.

To redeploy after a code change, `scp -r ... /opt/cubechat-bot` again (the
trailing `\.` matters, same reason as `push/deploy/README.md` explains) and
`systemctl restart cubechat-bot`. `.env` and `bot-state.json` are never
touched by that, because neither is in the repository.
