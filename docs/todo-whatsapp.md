# TODO: Phase 6, WhatsApp notifications (parked)

**Status:** Parked (18 November 2026). Research done, nothing changed. Resume from "Plan" below.

> **Do now, independent of WhatsApp: nightly backup of `~/hermes/data/`.** It holds config, memory, sessions, skills,
> cron jobs and (once paired) the WhatsApp session keys. Today only `notes/` and `agent-history/` are versioned; a lost
> `data/` means rebuilding Hermes and re-pairing WhatsApp (re-pairing raises the ban risk). This was already an open
> Phase 1 item.

## What we found (checked 18 Nov 2026, Hermes v0.23.2)
| Item | State |
|---|---|
| Bridge | Baileys 7.0.0-rc13, ships in the image at `/opt/hermes/scripts/whatsapp-bridge`, **dependencies not installed** (no `node_modules`) |
| Where `npm install` runs | The image is read-only, so Hermes mirrors the bridge to **`data/scripts/whatsapp-bridge`** and installs there (persistent) |
| Lazy-install check | `security.allow_lazy_installs: false` does **not** block it: the install in `hermes whatsapp` (`_whatsapp_install_bridge`) is an explicit, user-started step, not gated by that setting. After a Hermes update that changes the bridge's `package.json`, re-run `hermes whatsapp` if the bridge won't start |
| Session | Not paired. Will live in `data/platforms/whatsapp/session` (mode 0700, a Hermes-protected path; agent-history doesn't copy it) |
| `.env` | `WHATSAPP_ALLOWED_USERS` is a placeholder (9 chars, no digits). `WHATSAPP_ENABLED`, `WHATSAPP_MODE`, `WHATSAPP_HOME_CHANNEL` missing |
| Toolsets | WhatsApp has 17 enabled, including terminal, file, code_execution, delegation, browser, computer_use |

## Corrections to the roadmap
- `WHATSAPP_ALLOWED_USERS` = country code + number, **digits only, no `+`** (e.g. `6421…`).
- Also needed: `WHATSAPP_ENABLED=true`, `WHATSAPP_MODE=bot`, `WHATSAPP_HOME_CHANNEL=<number>@s.whatsapp.net`.
- `unauthorized_dm_behavior` defaults to `pair` (strangers get a pairing code), so the "no reply to other numbers" test
  would fail. Set it to **`ignore`**.
- Pair as the hermes user: `docker exec -it -u hermes hermes hermes whatsapp`, terminal at least 60 columns wide.
- Hermes has **no quiet-hours setting**: quiet hours come from cron schedules plus the `whatsapp-format` skill.
- Delivery target syntax: cron `deliver: whatsapp:<number>@s.whatsapp.net` (or `all`); CLI `hermes send --to whatsapp:<chat_id>`.
- After `.env` changes: `docker compose up -d --force-recreate`, never `restart`.

## Plan
1. **Spare number.** A prepaid SIM, never the main number. Option to consider: run the bot number on **WhatsApp
   Business** (the free app, same Baileys pairing via Linked Devices). The bot account's phone must come online every
   couple of weeks or the link drops, and the prepaid SIM must be kept active. The official Cloud API (no ban risk) needs
   a Meta Business account and a public webhook: possible later via Cloudflare Tunnel, overkill for now.
2. **`.env`** (Dina fills the values with `set-secret.sh`):
   ```
   WHATSAPP_ENABLED=true
   WHATSAPP_MODE=bot
   WHATSAPP_ALLOWED_USERS=<own number, digits only>
   WHATSAPP_HOME_CHANNEL=<own number>@s.whatsapp.net
   WHATSAPP_GROUP_POLICY=pairing        # explicit default: nothing from groups
   ```
3. **Config:** `unauthorized_dm_behavior: ignore`, read receipts off (default). Confirm the key path in the source
   (`whatsapp.*` vs `platforms.whatsapp.*`) before setting it.
4. **Toolsets for WhatsApp:** keep `clarify`, `memory`, `session_search`, `skills`, `todo`, `cronjob`, `web`. Turn off
   `terminal`, `file`, `code_execution`, `delegation`, `browser`, `computer_use`, `image_gen`, `tts`, `connections`,
   `vision`. Reason: a phone chat is a weaker control channel than Discord, so it gets far less power.
5. **Pair:** recreate, then `docker exec -it -u hermes hermes hermes whatsapp` (one-time `npm install`, a few minutes,
   ~100–200 MB in `data/`). Scan the QR with the spare-number phone (Linked Devices). Then message the bot once from the
   own number first (ban-risk advice: no automated messages to anyone who hasn't messaged first).
6. **`whatsapp-format` skill** through `skill_manage` (review in `/skills pending`; description ≤60 chars, one sentence,
   trigger first, ends with a period, no category name): max 3 lines, plain text, lead with the point, end with
   "details in Discord" when longer; no non-urgent messages scheduled 22:00–07:00 NZ; alerts are the exception.
7. **Move the "Sunday timesheet reminder"** cron job to WhatsApp (`deliver: whatsapp:<own number>@s.whatsapp.net`) and
   pin its model to Haiku (it has `model: null`).
8. **Tests:** "remind me in 5 minutes to check the oven" from Discord arrives on WhatsApp on time; a message from any
   other number gets no reply; then a week of reliable reminders and alerts, nothing long or noisy.

## Sources
- Hermes docs, WhatsApp: hermes-agent.nousresearch.com/docs/user-guide/messaging/whatsapp
- Source checked in the container: `gateway/platforms/whatsapp_common.py` (`resolve_whatsapp_bridge_dir`),
  `hermes_cli/main_platform_setup.py` (`_whatsapp_install_bridge`), `tools/cronjob_tools.py` (`deliver` grammar)
