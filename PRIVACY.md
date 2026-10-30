# Privacy

Distraction Bot watches what you do during a focus session. This is exactly what it reads, what it keeps, and where it goes.

## Nothing leaves your Mac

The app makes two kinds of network request, and no others:

| To | When | What is sent |
|---|---|---|
| **Ollama on `localhost:11434`** (your own Mac) | during a session, when something needs judging; for the look, every few minutes | your goal, the front app's name and window title, the page address (Safari and Dia), recent answers you gave; for the look, a picture of the front window |
| **Your calendar's ICS address** | if you pasted one in Settings → Calendar, on its refresh interval | an ordinary download request for that file |

There is no analytics, no crash reporting, no account and no update check. The Ollama address can be changed with the `DBOT_OLLAMA` environment variable; if you point it at another machine, what's in the first row goes there.

## What is read, and when

Only while a session is running, except the calendar:

- **The front app** — its name and bundle id, to apply your rules.
- **Its window title** (with Screen Recording) — e.g. `Lab report 3 — Pages`.
- **The page address and title in Safari and Dia** (with Accessibility). Other browsers are judged by window title only.
- **The look** (optional, Judge → The look): a capture of the front window only, scaled down, sent to the local vision model, which returns a one-line description. **The image is never written to disk**; only the description is kept. The look is skipped when the title or address already settled the question, and for apps you've allowed.
- **Keyboard and mouse activity** — only *whether* there was any, to pause the session when you're away. No keys are recorded.

**The private list** — Messages, Mail, WhatsApp, Telegram, Discord and 1Password — is never read or captured. Those apps can still be blocked.

## What is kept

Everything lives in `~/Library/Application Support/Distraction Bot/`, plus a plain-text diagnostic log, `~/Library/Logs/Distraction Bot/app.log`, which notes the front app, verdicts and the look's descriptions as they happen — useful for a bug report, so read it before you share it:

| File | Holds |
|---|---|
| `subjects.json` | your courses and objectives |
| `settings.json` | your rules: apps, sites, search terms, pinned apps |
| `prefs.json` | your settings, including the calendar address and your escape phrase |
| `log.sqlite` | the session log: starts and ends, what was judged (app, window title, page address, the look's description), the verdicts, your answers, blocks, shutdowns |
| `calendar.ics`, `calendar.json` | a cached copy of your calendar and when it was fetched |
| `session.json` | the session in progress, so it survives a restart |

Nothing is encrypted beyond what macOS does for your user folder (FileVault). The calendar's secret address is stored in `prefs.json` in plain text — treat that file like a password.

## Deleting it

`scripts/uninstall.sh` asks before deleting the data folder, the logs and the app's preferences. To clear only the history, quit the app and delete `log.sqlite`. Ollama keeps no record of the requests beyond its own logs (`~/.ollama/logs`).

## The models

The judge and vision models are downloaded once by Ollama from its library and run entirely on your Mac. Their licences are their authors' (Qwen: Apache 2.0).
