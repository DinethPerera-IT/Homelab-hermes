# Phase 2: Discord command centre

**Date:** 18 November 2026
**Result:** Passed. I can talk to Hermes from Discord, and nobody else can.

## What is it

**Discord** is the command centre for Hermes: the place I ask it to do things (questions, research, homelab
checks) from my phone or PC. Hermes connects as a **Discord bot**: a separate application account (not the
shift-tracker bot) created in the Discord Developer Portal, invited to a private server that only I and the
bot are in.

## How does it work

```
Phone / PC ──► Discord servers ◄── outbound WebSocket ── hermes container (OptiPlex)
```

- **No open ports.** The bot *connects out* to Discord over a WebSocket (the Discord "gateway") and Discord
  pushes messages down that connection. Nothing on the OptiPlex accepts inbound connections, so the compose
  file still publishes no ports and there is nothing new to firewall or tunnel.
- **Intents:** *Message Content* (required to read message text) and *Server Members* (needed to resolve
  users for the allowlist) are switched on in the Developer Portal.
- **Access control** lives in `~/hermes/.env` (git-ignored). Only the variable names are listed here:

| Variable | What it does |
|---|---|
| `DISCORD_BOT_TOKEN` | The bot's login. Secret. |
| `DISCORD_ALLOWED_USERS` | My **numeric** Discord user ID. Everyone else is ignored. |
| `DISCORD_ALLOWED_CHANNELS` | The only channels the bot answers in. |
| `DISCORD_FREE_RESPONSE_CHANNELS` | Channels where it replies **without** an @mention. |
| `DISCORD_HOME_CHANNEL` | Where cron output and notifications go. |

- **Fails closed:** if no allowlist is set, Hermes connects but denies everyone. The allowlist only *opens*
  access for me, so a missing or broken value means silence, not exposure.
- **Two layers:** the server itself is locked (only me + the bot, no invite links), and Hermes has its own
  user allowlist. Even if someone got into the server or DMed the bot, Hermes would ignore them.
- **Applying `.env` changes:** `docker compose up -d --force-recreate`, because `restart` keeps the old
  environment (see Phase 1).

## What went wrong

1. **The bot once guessed the time instead of checking it.** TZ is set correctly (it reports NZ time when it
   checks), but on one occasion it answered with a made-up time without running `date`. A language model
   has no clock, so any time or number it doesn't get from a tool is a guess. This is exactly the ground
   rule "code collects facts, the AI explains them". Fix (planned): a skill / core memory rule that time,
   disk, RAM and service status must always come from a command or Prometheus, never from the model
   (Phase 4 core files and Phase 7 tools).
2. **Hermes edits its own memory automatically ("Self-improvement review").** After a conversation it
   showed a "Self-improvement review" and updated its memory. Per the Memory docs, after a turn a
   background review replays the conversation and may save notes to `MEMORY.md` / `USER.md` (in
   `data/memories/`) or update a skill. Writes hit disk immediately and are used from the next session.
   Not a failure, but it matters because:
   - it runs on the **main model** by default, so every review costs extra tokens;
   - the agent changes its own long-term behaviour without me approving it.

   Plan: in Phase 3 point `auxiliary.background_review` at the cheap model; in Phase 4 decide on
   `memory.write_approval: true` / `skills.write_approval: true` (stage changes for review with
   `/memory pending`, `/skills pending`) and review the memory files weekly.

## How I tested it

| Test | Expected | Result |
|---|---|---|
| Server membership | Only me + bot, no invite links | ✅ Locked |
| Message in a free-response channel, no @mention | Bot replies | ✅ |
| Message in another allowed channel, no @mention | No reply | ✅ Needs @mention |
| Stranger account messages in a channel | No reply | ✅ Ignored |
| Stranger account DMs the bot | No reply | ✅ Ignored |
| "What time is it?" | NZ time | ✅ NZ time (TZ works), but once guessed without running `date` (see above) |
| "How full is the disk?" | Runs `df -h`, matches host | ✅ Ran `df -h`, 38% used, matched the host |

Why `df -h` in the container matches the host: `/opt/data` is a bind mount of `~/hermes/data`, which is on
the host's root filesystem, so `df` inside the container reports the same disk. It can *see* the disk usage
but can only *write* to `data/` and `vault/`.
