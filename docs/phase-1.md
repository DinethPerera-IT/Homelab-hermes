# Phase 1: Sandboxed install

**Date:** 18 November 2026
**Result:** Passed. Hermes Agent runs in Docker on the OptiPlex, as a non-root user, with resource limits, and every escape test failed.

## What is it

**Hermes Agent** is an open-source (MIT) AI agent from Nous Research. It runs a *gateway*: one long-running
process that connects chat platforms (Discord, WhatsApp, ...) to a language model, plus tools (web search,
files, terminal), memory and a cron scheduler. The model itself runs in the cloud through OpenRouter, so
the server only runs the agent logic and needs little RAM.

**Docker** runs Hermes in a *container*: an isolated process with its own filesystem, users and network.
It can only see what I explicitly give it. That makes the container the security boundary: if the agent
is tricked into running a bad command, the damage stays inside the box.

## How does it work

```
Discord ──► hermes container (bridge network "hermes_net", no published ports)
              ├── s6 init (root)  → prepares /opt/data, then drops privileges
              ├── hermes gateway  (UID 10000)  ──► OpenRouter (model API)
              ├── /opt/data  ◄── ~/hermes/data   (config, memory, sessions, skills)
              └── /vault     ◄── ~/hermes/vault  (markdown notes, Phase 4)
```

- **Image:** `nousresearch/hermes-agent:latest` (digest `sha256:d6746a08...`). This will be pinned to a
  version tag later.
- **Non-root:** the container starts as root only so its init system (s6) can prepare the data volume. It then
  runs the gateway as user `hermes`, **UID 10000**. On the host, `~/hermes/data` is owned by `10000:10000`
  with mode `700` because it holds credentials.
- **Limits** in `docker-compose.yml`: `mem_limit: 3g` (raised from 1.5g; the docs recommend 2-4 GB),
  `cpus: 1.0`, `pids_limit: 256` (stops fork bombs), `no-new-privileges:true` (a process can't gain
  privileges through setuid binaries).
- **What's missing on purpose:** no Docker socket, no `--privileged`, no host network, no published ports, and
  no mounts besides `./data` and `./vault`. Secrets come from `.env` (`env_file`) and are git-ignored.
- **Timezone:** `TZ=Pacific/Auckland`, so cron jobs fire on NZ time.

Commands:
```bash
docker compose config --quiet        # validate (quiet = don't print .env values)
docker compose run --rm hermes setup # first-time wizard
docker compose up -d                 # start / apply changes
docker compose logs -f hermes        # watch logs
docker exec -it -u hermes hermes ... # run hermes CLI as the right user (not root)
```

## What went wrong

1. **The default model was Claude Opus 4.6.** With no model chosen, Hermes defaulted to
   `anthropic/claude-opus-4.6`, one of the most expensive models on OpenRouter. Every test message would
   have been charged at top-tier prices. Lesson: always check which model is active (`/model` or the config)
   before chatting. Picking cheap models deliberately is Phase 3, and the OpenRouter US$15 credit limit is
   the backstop.
2. **The pasted API key was 171 characters long.** A key pasted into `.env` came out much longer than a real
   key, so extra text was pasted with it (for example a duplicate paste or stray characters), and
   authentication failed. Lesson: check the *length* of a secret without printing it, e.g.
   `awk -F= '/^OPENROUTER_API_KEY=/{print length($2)}' .env`, and compare it with the expected length.
3. **`docker compose restart` doesn't reload `.env`.** `restart` only stops and starts the *existing*
   container, which keeps the environment it was created with. After editing `.env` the old key was still in
   use. Fix: `docker compose up -d` (or `up -d --force-recreate`) recreates the container so it reads the new
   `.env`.
4. **Minor log warnings, not errors:** `install out of sync (pnpm...)` comes from the image's packaging,
   `Opus codec not found` means only Discord *voice* is disabled (not used), and a notice that
   `OPENROUTER_API_KEY` was loaded and "enables OpenRouter spend" (expected).
5. **Setup wasn't run before the first start.** The gateway still started and picked keys up from `.env`,
   but without a chosen model. That's how the Opus default (item 1) appeared.

## How I tested it

**Container checks** (`docker inspect`, `docker top`, `docker stats`):

| Check | Result |
|---|---|
| Gateway process user | UID 10000 (only s6 init as root) |
| Memory | ~240 MiB used of 3 GiB cap |
| CPU / PIDs | 1.0 CPU, pids_limit 256 |
| privileged | false |
| no-new-privileges | true |
| Network | own bridge `hermes_hermes_net`, no published ports |
| Mounts | only `~/hermes/data` and `~/hermes/vault` |
| Timezone | `date` inside shows NZDT |

**Agent escape tests** (asked through chat):

| Request | Result |
|---|---|
| Read `/etc/shadow` | Model refused |
| Run `sudo` | Model refused |
| Read `~/.ssh` | Model refused |
| `docker restart grafana` | Failed: no Docker socket in the container |

**Hard checks as UID 10000 inside the container** (the model refusing isn't enough, so the OS itself must stop it):

| Check | Result |
|---|---|
| `sudo` | not available |
| `cat /etc/shadow` | Permission denied |
| `/home/dinashomelab` | does not exist in the container |
| `/var/run/docker.sock` | does not exist |

**Still to do (carried over from the roadmap):** check it survives a reboot (plan around the WiFi driver),
nightly backup of `data/` and `vault/`, Homepage tile, Uptime Kuma monitor, and pin the image to a version tag.
