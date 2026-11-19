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

1. **The image's default model was Claude Opus 4.6, with reasoning effort set to high.** The official image
   ships with `anthropic/claude-opus-4.6` as the default model, one of the most expensive on OpenRouter, and
   defaults reasoning effort to `high`, which spends even more tokens per answer. I found it by running
   `hermes model` and switched to `anthropic/claude-haiku-5.5` **before sending any messages**, so nothing
   was charged at Opus prices. Lesson: check the active model and reasoning effort right after install,
   before the first message. Choosing models properly is Phase 3, and the OpenRouter US$15 credit limit is
   the backstop.
2. **The pasted API key was 171 characters long.** I pasted the OpenRouter key through `set-secret.sh`,
   which hides input, so I couldn't see that extra text went in with it (probably pasted twice). OpenRouter
   answered with **401 "User not found"**. Fix: re-pasted the key once, then checked its *length* without
   printing it (73 characters, which is correct) and confirmed that OpenRouter's `/api/v1/key` endpoint
   accepted it. Lesson: hidden input hides mistakes too, so check a secret's length after setting it, e.g.
   `awk -F= '/^OPENROUTER_API_KEY=/{print length($2)}' .env`.
3. **`docker compose restart` doesn't reload `.env`.** After fixing `.env`, the bot *still* got 401.
   `restart` only stops and starts the *existing* container, which keeps the environment it was created
   with, so it was still using the broken key. Fix: `docker compose up -d --force-recreate` built a new
   container that read the corrected `.env`. Lesson: always recreate the container after changing `.env`.
4. **Minor log warnings, not errors:** `install out of sync (pnpm...)` comes from the image's packaging,
   `Opus codec not found` means only Discord *voice* is disabled (not used), and a notice that
   `OPENROUTER_API_KEY` was loaded and "enables OpenRouter spend" (expected).

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
| My home folder on the host (`~`) | does not exist in the container |
| `/var/run/docker.sock` | does not exist |

**Still to do (carried over from the roadmap):** check it survives a reboot (plan around the WiFi driver),
nightly backup of `data/` and `vault/`, Homepage tile, Uptime Kuma monitor, and pin the image to a version tag.
