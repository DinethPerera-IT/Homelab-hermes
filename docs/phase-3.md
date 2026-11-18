# Phase 3: Models and routing

**Date:** 18 November 2026
**Result:** Done. Every job has a deliberate model. Haiku 5.5 is the main model, DeepSeek V4.1 Flash handles cheap
background work and research, and Sonnet is one command away. Benchmark: [benchmark.md](benchmark.md).

## What is it

Hermes doesn't use one model for everything. Several separate **model slots** decide which model does which job, and
all of them go through **OpenRouter**: one API key and one bill for models from Anthropic, DeepSeek, OpenAI and others.
Picking the right model for each slot keeps the bill small without hurting the answers that matter.

| Slot | Model | Why |
|---|---|---|
| Main (every Discord reply) | `anthropic/claude-haiku-5.5` | Won the benchmark: accurate and concise |
| `/model fast` (research threads) | `deepseek/deepseek-v4.1-flash-1017` | Better at digging (full pages, release feeds, checks itself) |
| `/model mid` | `openai/gpt-6.1-terra` | Optional middle step |
| `/model smart` (hard jobs) | `anthropic/claude-sonnet-5.5` | Escalation only, ~20× Haiku's price |
| `compression`, `title_generation`, `curator` | DeepSeek V4.1 Flash 1017 | Low-stakes background work, cheapest |
| `approval`, `background_review`, `memory_query_rewrite` | Haiku 5.5 | Security decisions and memory quality matter more than a tiny saving |
| Delegation (sub-agents) | DeepSeek V4.1 Flash 1017, max 30 iterations, 3 in parallel | Defaults were 250 and 10 |

Also added in this phase: the **Hermes web dashboard**, a Homepage tile, and access from the kiosk screen.

## How does it work

**Config** lives in `~/hermes/data/config.yaml`, which Hermes reads at startup. I changed it with
`docker exec -u hermes hermes hermes config set <key> <value>`, made a backup before each change, and recreated the
container to apply it.

```yaml
model:
  provider: openrouter
  default: anthropic/claude-haiku-5.5
model_aliases:              # canonical form: provider is pinned separately
  fast:  { model: deepseek/deepseek-v4.1-flash-1017, provider: openrouter }
  haiku: { model: anthropic/claude-haiku-5.5,        provider: openrouter }
  mid:   { model: openai/gpt-6.1-terra,              provider: openrouter }
  smart: { model: anthropic/claude-sonnet-5.5,       provider: openrouter }
agent:
  max_turns: 50             # tool-call rounds per request (default 500)
delegation: { provider: openrouter, model: deepseek/deepseek-v4.1-flash-1017, max_iterations: 30, max_concurrent_children: 3 }
auxiliary:                  # background tasks, each with its own model
  compression / title_generation / curator:                  DeepSeek V4.1 Flash 1017
  approval / background_review / memory_query_rewrite:       Haiku 5.5
web: { search_backend: tavily, extract_backend: tavily }
```

**Switching models in Discord:** `/model fast`, `/model smart`, `/model haiku`. The `agent.log` line
`API call #…: model=… provider=openrouter in=… out=… latency=…` shows which model actually answered and what it cost
in tokens.

**Web dashboard** (`HERMES_DASHBOARD=1`):
- Published only on the host's `127.0.0.1:9119`. Inside the container it has to bind `0.0.0.0` so Docker can forward to
  it, and Hermes then **requires a login**: `dashboard.basic_auth.username` plus a scrypt `password_hash` in config.yaml,
  and `HERMES_DASHBOARD_BASIC_AUTH_SECRET` (64 random hex characters) in `~/hermes/.env` to sign sessions.
- Remote access is through **Tailscale Serve**: `https://<server>.<tailnet>.ts.net:8443`, tailnet only, proxied to
  `127.0.0.1:9119`. No LAN or public port.
- All API routes return 401 without a login. Only `/api/status` (version and gateway health) is public, which makes it
  usable as a health check.
- The dashboard can edit config and `.env` keys. Keys added there go into `data/.env`, so I only add keys through
  `set-secret.sh` into `~/hermes/.env`.

**Homepage tile:** an "AI & Bots" → Hermes Agent tile linking to the Tailscale URL, with a status dot from Docker
(`server: local`, `container: hermes`). Homepage sits on the default Docker bridge and can't reach host-loopback ports,
so a siteMonitor on `/api/status` wasn't possible without opening a port.

## What went wrong

1. **The reasoning-effort setting is ignored.** The image defaulted to `high`; I set `medium` with `hermes model`. The
   CLI warns that `agent.reasoning_effort` is "not a recognized config key", even though the docs use that name. Checks
   on OpenRouter showed it isn't applied. Lesson: a value showing in the config file doesn't prove the program uses it.
   Check the effect (tokens on OpenRouter Activity), not just the setting.
2. **The roadmap had the wrong GLM price.** It listed GLM 5.3 Flash at $0.04 / $0.078. That price belonged to
   `~z-ai/glm-flash-latest`, an alias that silently points at whatever GLM Flash is newest. The real
   `z-ai/glm-5.3-flash` costs $0.15 / $0.50, more than Haiku on input, so I dropped it. Lesson: read prices and slugs
   from the OpenRouter API (`/api/v1/models`), and avoid `~…-latest` aliases and `:batch` variants.
3. **The short alias format picked the wrong provider.** `model.aliases.haiku: anthropic/claude-haiku-5.5` made
   `/model haiku` fail with "Anthropic is not connected": the short form reads the first part of the slug as the
   *provider*. Fix: the canonical top-level `model_aliases:` with separate `model` and `provider: openrouter` fields.
   The CLI calls these keys "not recognized" too (false alarm). I confirmed them with Hermes's own alias loader.
4. **The dashboard refused to start and spun the CPU.** With `HERMES_DASHBOARD=1` it refused to bind `0.0.0.0`
   without an auth provider. s6 kept restarting it, and the container sat at **99% CPU**. Stopped with
   `s6-svc -d /run/service/dashboard` (no config change), then fixed by adding basic auth.
5. **The kiosk couldn't open the tiles.** The server's own DNS is `1.1.1.1` / `8.8.8.8`. It doesn't use Pi-hole or
   Tailscale MagicDNS, so the kiosk Chromium got `DNS_PROBE_FINISHED_NXDOMAIN` for the Tailscale URL and **every**
   `.dinashomelab.internal` name. Fix: server-only entries in `/etc/hosts` (Tailscale name → `<tailscale-ip>`,
   `.internal` names → `192.168.1.10`) under the comment "add new .internal services here too". This doesn't touch
   netplan, Tailscale or Pi-hole, and keeps working if Pi-hole is down.
6. **Context growth was the biggest cost driver.** Long sessions re-send the whole history every turn. In the
   benchmark, DeepSeek sessions grew to ~65K input tokens per call, making its run cost ~2× Haiku's even though each
   request cost about the same. Prompt caching (88% hits) softened it. Lesson: `/new` between topics.
7. **The memory review costs money on every run.** The "Self-improvement review" (`auxiliary.background_review`)
   replays the conversation on Haiku, about **$0.002 per run**, every 10 turns (`memory.nudge_interval: 10`). Kept on
   Haiku on purpose, because memory quality matters. Revisit if it adds up.
8. **Risky defaults found along the way:**
   - `agent.max_turns` was **500** tool-call rounds per request. Lowered to 50.
   - Delegation allowed 250 iterations and 10 parallel children. Lowered to 30 and 3.
   - `delegate_task` has no toolsets parameter: sub-agents inherit the parent's tools (noted in the roadmap for Phase 5).
9. **A second `.env` exists.** Hermes keeps `data/.env` with tool defaults and a generated `API_SERVER_KEY`. No
   variable names overlap with `~/hermes/.env`, and the 401 in Phase 1 wasn't caused by it. Rule: secrets only go into
   `~/hermes/.env`.

## How I tested it

| Test | How | Result |
|---|---|---|
| 10-question benchmark | Same questions on Haiku and DeepSeek, `/new` per question | Haiku 9 ✅ 1 ⚠️, DeepSeek 8 ✅ 2 ⚠️, nothing invented ([benchmark.md](benchmark.md)) |
| Main model and provider | `agent.log` `API call` lines | `model=anthropic/claude-haiku-5.5 provider=openrouter` |
| Cheap slot routing | New session, then check the log | `Auxiliary title_generation: using openrouter (deepseek/deepseek-v4.1-flash-1017)` |
| Aliases | Hermes's alias loader (`_load_direct_aliases`), then `/model fast` in Discord | All four load with `provider=openrouter`; benchmark DeepSeek calls show `provider=openrouter` |
| Reasoning effort | Output tokens vs reply length, OpenRouter Activity | Not applied (see above) |
| Turn budget | Gateway startup log | `Agent budget: max_iterations=50` |
| Dashboard exposure | `ss -tlnp \| grep 9119` | `127.0.0.1:9119` only |
| Dashboard auth | `curl` without a login | `/` → 302 to `/login`; `/api/config`, `/api/env`, `/api/keys`, `/api/sessions`, `/api/logs` → 401; `/api/status` → 200 (health only) |
| Homepage tile | Homepage's status API | `{"status":"running"}`, green dot |
| Kiosk access | Clicked the tiles in the kiosk | Hermes "Sign in — Hermes Agent", Grafana and Pi-hole login pages all load |

**Cost of the whole day:** $0.10 for 93 requests, 88% cache hits.
