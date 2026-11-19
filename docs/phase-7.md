# Phase 7: Homelab tools and scheduled jobs

**Date:** 19 November 2026
**Result:** Hermes answers homelab questions with measured numbers from my own read-only MCP server, `homelab-mcp`,
and posts a daily AI digest and a weekly capacity report to Discord. Along the way: Hermes is now firewalled off from
every host service (it could reach all of them, including the HR System pentest target), and `data/` is backed up
nightly. A new `#auto` channel routes each request to the right model automatically (Haiku front desk, DeepSeek
research, Sonnet for hard problems), without changing any other channel.

## What is it

- **MCP (Model Context Protocol)** is a standard way to give an AI agent tools. An MCP server lists tools (name,
  inputs, description); the agent calls them and gets structured results back.
- **homelab-mcp** is my own MCP server (Python, official MCP SDK 2.3.0, streamable HTTP) in its own container. It has
  **six read-only tools** that run **fixed PromQL** against Prometheus. No tool accepts raw PromQL, so the agent can
  only ask the questions I designed. "Code collects the facts; the AI only explains them."
- Code: separate private repo [`DinethPerera-IT/homelab-mcp`](https://github.com/DinethPerera-IT/homelab-mcp)
  (`~/homelab-mcp`), with its own README, tests and host scripts.

## How does it work

```
Discord ─► Hermes ──mcp_internal (internal)──► homelab-mcp ──mcp_prom──► Prometheus (host :9090)
           br-hermes: internet only            no internet; host :9090 only        │
           ✗ host services + other containers                                       ▼
                                          node-exporter ◄── textfile collector ◄── host cron jobs
                                          (CPU, RAM, disk, load)  (containers, apt, reboot, backup age)
```

**Tools** (all marked read-only; inputs are enums or bounded ints, validated by the SDK before a tool runs):

| Tool | Inputs | What it answers |
|---|---|---|
| `host_summary` | none | CPU %, RAM %, root disk % (df formula), load 1/5/15, cores, uptime, apt updates, reboot needed, backup age |
| `disk_trend` | `days` 1–14 | disk % now vs then, change, days until full (`deriv`) |
| `resource_trend` | `metric` cpu/ram/load1, `hours` 1/6/24/168 | min / avg / max |
| `targets_status` | none | Prometheus targets up/down, textfile errors |
| `container_status` | `hours` 24/168 | containers meant to run that aren't, crash restarts, (re)starts, unhealthy |
| `service_checks` | none | Uptime Kuma monitors down, expiring certificates (once Kuma is scraped) |

**Network and firewall:**
- `hermes_net` now has a fixed bridge name `br-hermes` (`172.30.10.0/24`).
- `mcp_internal` (`br-mcp-int`, `internal: true`) connects only Hermes and homelab-mcp.
- `mcp_prom` (`br-mcp-prom`) lets homelab-mcp reach Prometheus at `172.30.12.1:9090`.
- Docker networks can't stop a container reaching host services that listen on every interface, so an **nftables
  table of my own** (`inet homelab_isolation`, `/etc/homelab/homelab-isolation.nft`, loaded at boot by
  `homelab-isolation.service`) enforces it: input from `br-hermes`/`br-mcp-int` dropped; `br-mcp-prom` allowed to
  port 9090 only; forward from `br-hermes` to other container bridges dropped (published ports); nothing leaves the
  MCP bridges. Replies to connections the host starts (dashboard, `docker exec`) are allowed. It never touches Docker's
  or Tailscale's rules and only matches container bridges, so SSH can't be locked out.

**Container hardening (homelab-mcp):** non-root `10001`, `read_only` + 16 MB `noexec` tmpfs, `cap_drop: ALL`,
`no-new-privileges`, 64 pids, 128 MB RAM, 0.25 CPU, no published ports, no Docker socket or host mounts; base image
pinned by digest, all 31 dependencies hash-locked (`pip install --require-hashes --no-deps`); bearer token
(constant-time compare, refuses to start with a placeholder or < 32 chars) and MCP DNS-rebinding protection
(`Host: homelab-mcp:8000` only). Tests run in a Docker build stage, so a failing test fails the build.

**Hermes side:**
```yaml
mcp_servers:
  homelab:
    url: http://homelab-mcp:8000/mcp
    headers: { Authorization: "Bearer ${HOMELAB_MCP_TOKEN}" }   # filled from .env at connect time
    tools: { include: [host_summary, disk_trend, resource_trend, targets_status, container_status, service_checks],
             resources: false, prompts: false }
    timeout: 20
    connect_timeout: 10
```
Cron runs get enabled MCP servers' tools automatically.

**Host-side facts** (node-exporter's textfile collector, `/var/lib/node_exporter/textfile`):
- `homelab-mcp/host/textfile-metrics.sh`, every 5 min: per container running (+ restart policy), Docker restart
  count, health, start time; hourly: pending apt upgrades (simulated) and reboot-required.
- `hermes/scripts/data-backup.sh`, 02:15: backup age and size.
- node-exporter now runs from `homelab-mcp/host/node-exporter.compose.yaml`, pinned to the same v1.12.1 digest.

**Nightly `data/` backup** (`scripts/data-backup.sh`, 02:15): SQLite databases snapshotted with the online backup API
inside the container (`*.db.snap`), then one archive of `data/` (minus live databases, caches, locks, sockets) streamed
to `~/backups/hermes/` (mode 600, 14 kept), verified with `tar -t`.

**Scheduled jobs** (Hermes cron, each pinned to a model via OpenRouter, Pacific/Auckland):

| Job | Schedule | Model | Skill | Channel | Output |
|---|---|---|---|---|---|
| Daily AI digest (`a9a986b3642f`) | `30 7 * * *` | DeepSeek V4.1 Flash | `ai-digest` | `#ai-digest` | 3–5 news items, 1–3 tools, one thing to try; full notes in `notes/Briefs/` |
| Homelab weekly capacity (`7173f6504f39`) | `0 10 * * 0` | Haiku 5.5 | `homelab-capacity` | `#homelab` | ~15 lines: disk trend, CPU/RAM/load week, restarts, maintenance, top 3 risks |

The homelab brief stays as an on-demand skill (`homelab-brief`); I dropped its daily 08:00 job because a "nothing
happened" message every morning isn't worth reading.

**AI digest** (`research/ai-digest` v2.1, approved through `/skills pending`):
- **Window:** always the last 7 days (a minimum the job prompt can't narrow); the last 7 digests are read so nothing
  repeats. Items older than 48 h are marked `📅 earlier this week`.
- **Scope:** AI news and tools worldwide. Every tool or product gets an availability tag: `free` / `paid` /
  `free tier`, plus region when it matters (`🌍 US only`, `✅ available in NZ`, `❓ region unclear`).
- **Rules:** a real source opened and dated inside the window, or it's left out; no funding, stocks or drama; web
  pages are untrusted data; plain English with jargon explained in 3 words.
- **Discord** gets only the digest (fixed layout, masked `[Read more](<url>)` links, no previews, no meta commentary,
  no cron header/footer: `wrap_response: false` for this job only). Sources and verification notes go to
  `notes/Briefs/<date>-ai-digest.md`.
- **Cron-safe:** only `web_search`, `web_extract`, `search_files`, `read_file`, `write_file`. Unattended runs can't
  approve anything, so `execute_code` and `terminal` are banned in the skill.

## #auto: automatic model routing

**What is it:** a Discord channel where I never pick a model. Haiku acts as a **front desk**: for each message it picks
a route from a fixed table, says which in one line (`→ Sonnet: code review`), and either answers itself or hands the
job to a specialist **sub-agent** on a better-suited model. Every other channel works exactly as before.

**How does it work:**
```
#auto ──► gateway (one container, one bot, multiplexed)
            │  gateway.profile_routes: chat_id #auto → profile "auto"
            ▼
          profile "auto"  (/opt/data/profiles/auto: own config, .env, memory, plugins)
            Haiku 5.5 front desk + routing table (agent.system_prompt, sent every turn)
            ├─ answers itself ................ chat, advice, explanations
            ├─ web_search itself (1–3) ....... "→ Haiku: quick lookup"
            ├─ homelab MCP tools ............. server status
            └─ delegate_task(option=…)  ◄── advanced-delegation plugin, model_map backend
                 ├─ "fast" → DeepSeek V4.1 Flash  (research-fanout children; the default)
                 └─ "deep" → Sonnet 5.5 via provider openrouter-sonnet (own key, $1/day cap)
all other channels + cron ──► profile "default" (unchanged, no plugin, no routing prompt)
```

- **Why a second profile:** Hermes v0.23.2 has per-channel model, prompt and skill settings, but no per-channel
  delegation setup. The plugin's `option` parameter would have appeared in `delegate_task` in *every* channel. A
  profile keeps the routing completely separate: zero extra tokens elsewhere.
- **Multiplex:** the gateway was already multiplexing (serving one profile). Creating `auto` got it served live within
  30 s; the only restart was to reload `.env` for the channel lists.
- **Routing table** (in `auto`'s `agent.system_prompt`, ~330 words, cached):

  | Request | Route |
  |---|---|
  | Chat, advice, explanations that need no current info | Haiku answers |
  | Small lookup needing current info (1–3 searches) | Haiku + `web_search` ("quick lookup") |
  | Comparisons, deep dives, news roundups | `research-fanout` on DeepSeek |
  | Hard reasoning, code or document review, debugging | one Sonnet child |
  | Homelab status | homelab MCP tools |
  | Anything that changes files, config, cron, skills, or runs commands | asks first |

  Exceptions that don't ask: reminders I asked for, facts I asked it to remember, notes in `notes/Research/` and
  `notes/Briefs/`. Specialists start blank, so every hand-off carries the request word for word, a summary of the
  conversation, file paths, constraints and the answer format. Unsure → Haiku answers and offers Sonnet.
- **Guardrails:**
  - Sonnet uses its **own OpenRouter key** (`hermes-auto-sonnet`, $1 limit, `limit_reset: daily`, resets 00:00 UTC
    = 13:00 NZDT). The key is read from `OPENROUTER_SONNET_API_KEY` through a `providers:` entry with `key_env`, which
    never falls back to the main key. At most one Sonnet child per message; on a 402 Haiku says the cap is used up.
  - `spend-report.sh` adds a line: `Sonnet (#auto): $x today (UTC day) of $1.00`.
  - Approvals: smart mode with Haiku as the guardian, same as `default`.
- **The plugin** (`advanced-delegation`, official, MIT): installed only in `auto`, pinned to reviewed commit
  `13b2c1c9…`. I read the source first: standard library + Hermes imports only, no dependencies, no network calls,
  no lazy installs; the installed files matched the reviewed ones byte for byte.
- **Backups and history:** `data-backup.sh` already covers `profiles/`; `notes-commit.sh` now snapshots `auto`'s
  MEMORY, USER, SOUL and skills to `agent-history/profiles/auto/`.
- **Helper scripts** (`~/hermes`): `set-profile-secret.sh PROFILE VAR` (hidden input, value only on stdin) and
  `add-env-id.sh VAR ID` (adds a channel ID to a `.env` list; refuses empty lists, where empty means "all").

**Compared with the model-picker plugin:** it classifies every message in every channel with an extra LLM call carrying
~12,000 characters of recent chat, switches the main model (losing the prompt cache), and only knows low/default/high
tiers. The front desk costs nothing extra per message, keeps the cache, and has an MCP route and an ask-first route.

**Rollback:** (A) remove the `profile_routes` entry (and #auto from `.env`), recreate; (B) `hermes profile delete auto`
and restore `config.yaml.bak-2026-11-19-auto` + `.env.bak-2026-11-19-auto`; (C) restore `data/` from the archive.

## What went wrong

1. **Hermes could reach every service on the host.** From inside the container, TCP connects succeeded to Prometheus,
   node-exporter, Uptime Kuma, Pi-hole, Caddy, Homepage **and the deliberately vulnerable HR System**: they listen on
   all interfaces, the Docker gateway leads to the host, and the host firewall had no rules (ufw inactive, INPUT
   accept). A gap since Phase 1. Fixed with the nftables isolation above.
2. **Published ports bypassed the first firewall version.** Blocking `input` stopped host-network services, but Kuma
   (3001), Homepage (3005) and the HR System (3050) stayed open: Docker DNATs published ports to the target container,
   so they pass the `forward` hook. Added forward rules. Also caught: Docker passes traffic *inside* a bridge through
   `forward` too (br_netfilter), so my first MCP rule would have broken Hermes ↔ homelab-mcp; the MCP rules only drop
   traffic *leaving* their bridge.
3. **Prometheus scraped only node-exporter.** No container metrics (no cAdvisor), and Uptime Kuma's `/metrics` returns
   401 (Kuma 1.23 needs an API key). Instead of cAdvisor (deep host access), a host cron script writes container facts
   to the textfile collector. The Kuma scrape waits for an API key.
4. **node-exporter's flags were broken.** The mount-exclude regex read `…(96319|/)`: the shell had replaced `$$` with
   its process ID when the container was started. `--path.rootfs` was missing and the textfile directory unset. Fixed
   in the compose file (`$$` is a literal `$` in compose).
5. **The obvious disk formula disagreed with `df`** (40% vs 38%): `1 - avail/size` counts root-reserved blocks as used.
   The tools use df's formula (37.4% vs 38%).
6. **The backup script failed twice.** GNU tar exits 1 when a live file (a log) changes while archived; that is normal
   here and now accepted (2 still fails). Then my `--exclude='*.db'` also dropped the SQLite snapshots; renamed them
   `*.db.snap`. Verified: 9 snapshots, `state.db` passes `pragma integrity_check`.
7. **`pip-tools` broke on the newer pip** in `python:3.13-slim` (`allow_all_prereleases` missing). Locked dependencies
   with `uv pip compile --generate-hashes` instead.
8. **A test caught my own wrong assumption.** The df formula has 5 selectors, not 3; the build-stage test failed the
   build until I fixed the test to check that *every* selector gets the offset.
9. **Hermes registered 10 tools, not 6.** It adds resource/prompt helper tools per MCP server. Set
   `tools.resources: false` and `tools.prompts: false`: every tool schema costs tokens on every request.
10. **There is no `#homelab-brief` channel**; the Discord home channel is `#homelab` (found in Hermes's
    `channel_directory.json`), so the jobs deliver there.
11. **The first brief flagged "16 containers not running".** All had restart policy `no`: 14 leftover `docker run`
    containers from July, my `node-exporter-old` rollback copy, and one from today. The script now labels the restart
    policy and the tool only flags containers meant to stay up; the rest are counted as `stopped_on_purpose`.
12. **`gh` couldn't create the GitHub repo** (`Resource not accessible by personal access token`): the token can't create
    repositories. I created the repo in the GitHub UI (private) and pushed over SSH, after checking that `.env` was
    never committed and no commit contains anything key-like.
13. **Accepted:** homelab-mcp can also reach Prometheus through the host's LAN address, because the rule allows port
    9090 on the host whichever address is used. It is still only Prometheus.
14. **The first AI digest posted meta commentary, not news.** v1 used a strict 48-hour window, found "nothing", and
    explained what it had checked in Discord. v2 fixed the layout; v2.1 made the window a 7-day minimum.
15. **The cron job's own prompt overrode the skill.** It still said "only sources dated within 48 hours", so v2 ran
    with a 48-hour window anyway. The job prompt now only says "follow the skill".
16. **Cron runs blocked tool calls.** DeepSeek reached for `execute_code` and heredoc `terminal` commands; cron can't
    approve anything, so they were blocked (2 blocked of 40 calls). v2.1 bans them; the dry run used 19 calls, none
    blocked.
17. **Creating a profile is itself the switch.** A running gateway rescans `profiles/` every 30 s and starts serving
    a new profile live, so "create the profile, restart later" wasn't possible. Found in the code before creating it.
18. **`--clone` didn't copy every key.** The gateway reads a secondary profile's secrets only from its own `.env`
    (it never borrows from the container environment), and the clone left out `OPENROUTER_API_KEY`,
    `HOMELAB_MCP_TOKEN` and `TAVILY_API_KEY`, so the MCP failed in `auto`. Copied inside the container from its
    environment, without printing.
19. **`hermes config set` parsed the routing table as YAML** (it contains `: `). Passing it as a JSON string literal
    stored it as plain text; verified byte for byte.
20. **One smart-approval prompt in #auto.** Not a "dangerous" verdict: the Haiku guardian (16-token answer, thinking
    off) returned an empty answer (`finish_reason=length`) and the code escalates to me, which is the safe failure.
    It happens in ~6% of guardian calls in both profiles (3/59 default, 1/8 auto).
21. **The dashboard-auth warning in `auto`** is the cloned login plugin being ignored: only `default` serves the
    dashboard. Checked: `/`, `/api/sessions`, `/p/auto/*` and `/p/default/*` all require login; only `/api/status`
    (version and gateway state, the Homepage tile's health check) is public, and the port is on 127.0.0.1 only.

## How I tested it

| Test | Result |
|---|---|
| homelab-mcp test suite (build stage) | ✅ 21 passed (query validation, tool logic vs fake Prometheus, auth, MCP handshake) |
| Runtime image | ✅ 57 MB, uid 10001, no pytest inside, refuses a placeholder token |
| Hermes ↔ homelab-mcp | ✅ no token 401; with token 200; `host_summary` returned real values |
| homelab-mcp → Prometheus | ✅ 200 |
| homelab-mcp → internet, node-exporter, HR System, Pi-hole | ✅ all blocked |
| Hermes → host services (7 ports × 4 host addresses) | ✅ 0 of 28 open; internet (OpenRouter, Discord, Tavily) still 200 |
| `hermes mcp test homelab` | ✅ connected, 6 tools discovered, Authorization masked |
| Daily brief run by hand (before the job was dropped) | ✅ all 5 tools called (< 0.1 s each), delivered to `#homelab`; numbers matched the tools |
| AI digest v2.1 dry run (same job, model and delivery as 07:30) | ✅ 19 tool calls, 0 blocked, built-in tools only, full 7-day window, 4 news + 2 tools with availability tags, US$0.032 |
| advanced-delegation source | ✅ 6 code files reviewed at `13b2c1c`; installed files identical (sha256) |
| Sonnet key | ✅ `limit: 1`, `limit_reset: daily` (limit fields only) |
| After the restart | ✅ Discord connected; `default` + `auto` served; cron jobs and next runs identical; dashboard 302; MCP 6 tools in both profiles |
| #auto, 7 messages | ✅ every route line correct: Haiku · quick lookup (1 search) · DeepSeek research (3 children) · Sonnet review (1 child) · Homelab MCP · reminder without asking · delete → asked, nothing deleted |
| #auto test cost | Haiku front desk ~$0.017, DeepSeek children ~$0.050, Sonnet $0.10 (its key's daily usage; Hermes estimated $0.065): **~$0.17** |
| `container_status` after the fix | ✅ `not_running: []`, `stopped_on_purpose: 16` |
| Disk % vs `df` | ✅ 37.4% vs 38% |
| Backup | ✅ 5 MB archive, 9 DB snapshots, integrity ok, live DBs/caches excluded, metric written |
| Firewall persistence | ✅ `homelab-isolation.service` enabled and active, 6 counting rules |

## Found and left for later

- **32 apt upgrades pending, reboot required** (plan around the WiFi driver).
- **Prometheus**: unpinned `latest` image and listening on the LAN with no login. Pin it and add the Kuma scrape in one
  recreate, once a Kuma API key exists.
- Delete `node-exporter-old` after a week; consider removing the 14 leftover July containers.
- Backups are on the same disk: they protect against mistakes, not a dead disk.
- **Spend tracking for `auto`:** after the #auto tests the main key's usage (what `spend-report.sh` reads) didn't
  move, while the Sonnet key did. Check in OpenRouter's Activity page which key the `auto` Haiku/DeepSeek calls were
  billed to. The report's "API calls" line also only counts `default`'s log.
- If empty guardian answers become annoying, try another approval model; for now escalating is the safe failure.
