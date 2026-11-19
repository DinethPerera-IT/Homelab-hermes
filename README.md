# Hermes Agent on dinashomelab

A personal AI agent running on my homelab server: I talk to it from Discord, and it answers questions, researches
topics, reports on the homelab with real numbers, and posts a daily AI digest. It runs sandboxed in Docker, every
model call goes through one OpenRouter key with a spending cap, and each job uses the cheapest model that does it well.

Built and documented one phase at a time (18–19 November 2026). Each phase has its own write-up in `docs/`:
**What is it · How does it work · What went wrong · How I tested it**.

## What is it

- **[Hermes Agent](https://hermes-agent.nousresearch.com)** (Nous Research, MIT, v0.23.2) is an open-source agent
  *gateway*: one long-running process that connects chat platforms to language models, plus tools (web search, files,
  memory, scheduled jobs, sub-agents).
- The models run in the cloud through **OpenRouter** (one key, one bill); the server only runs the agent logic.
- **[homelab-mcp](https://github.com/DinethPerera-IT/homelab-mcp)** (separate repo) is my own read-only MCP server that gives
  Hermes six fixed questions it can ask Prometheus: the AI explains the numbers, code collects them.

## How does it work

```
                 Discord (private server, only my user ID is allowed)
                                  │
   ┌──────────────────────────────▼──────────────────────────────────────────────┐
   │ hermes container: non-root (UID 10000), 3 GB / 1 CPU / 256 pids,            │
   │ no Docker socket, no host network, no published ports except the dashboard  │
   │ on 127.0.0.1                                                                │
   │                                                                             │
   │  gateway (multiplexed)                                                      │
   │   ├─ profile "default": all channels + cron jobs                            │
   │   └─ profile "auto":    #auto only (Haiku front desk → DeepSeek / Sonnet)   │
   └───────┬──────────────────────────────┬──────────────────────────────────────┘
           │ internet only                │ mcp_internal (no internet)
           ▼                              ▼
     OpenRouter, Tavily,            homelab-mcp ──► Prometheus ──► node-exporter
     Discord                        (6 read-only tools)            (+ host textfile metrics)

   nftables (homelab_isolation): Hermes can't reach any host service or other container.
```

### Channels

| Channel | What happens there | Model |
|---|---|---|
| `#hermes` | Everyday chat and questions | Claude Haiku 5.5 |
| `#research` | Research threads; `research-fanout` runs 3 sub-agents and writes a sourced note to `notes/Research/` | DeepSeek V4.1 Flash (`/model fast`) |
| `#auto` | Automatic routing: Haiku picks a route per message and says which (`→ Sonnet: code review`) | Haiku → DeepSeek / Sonnet 5.5 |
| `#ai-digest` | Daily AI digest, 07:30: 3–5 news items, 1–3 tools with price/region tags | DeepSeek V4.1 Flash |
| `#homelab` | Weekly capacity report, Sunday 10:00 (disk trend, CPU/RAM, restarts, top risks) | Haiku 5.5 |
| `#agent-log` | Spend report, 21:30 daily, plus an alert over US$0.50/day (host script, webhook) | none |

Haiku won a 10-question benchmark for the main chat ([docs/benchmark.md](docs/benchmark.md)); DeepSeek V4.1 Flash is
better at digging through sources for a fraction of the price, so it does research and background work.

### Scheduled work

| When (NZ) | What | Where it runs |
|---|---|---|
| 07:30 daily | AI digest | Hermes cron |
| Sun 10:00 | Homelab capacity report | Hermes cron |
| Sun 18:00 | Timesheet reminder | Hermes cron |
| 21:30 daily + hourly check | OpenRouter spend report / alert | host cron (`scripts/spend-report.sh`) |
| 23:45 daily | Snapshot memory, skills, cron jobs to `agent-history` (git); commit notes | host cron (`scripts/notes-commit.sh`) |
| 02:15 daily | Backup of `data/` (SQLite snapshots + archive, 14 kept) | host cron (`scripts/data-backup.sh`) |

## Security

- **Sandbox:** Docker, non-root, `no-new-privileges`, memory/CPU/pid limits, no Docker socket, no host network, no
  `--privileged`. Escape tests (read `/etc/shadow`, `sudo`, `~/.ssh`, restart other containers) all failed.
- **Network:** an nftables table of my own blocks Hermes from every host service and other container (it could reach
  all of them before Phase 7, including a deliberately vulnerable practice app on the LAN). homelab-mcp can reach only Prometheus.
- **Access:** Discord allowlist = my user ID; the bot ignores everyone else. Remote access only via Tailscale.
- **Approvals:** smart mode: Haiku reviews flagged commands and asks me when unsure; no permanent approvals; cron runs
  deny anything that needs approval. Skills the agent writes wait for my approval (`/skills pending`).
- **Secrets:** only in `.env` files, git-ignored, never printed; helper scripts take them with hidden input.
- **Untrusted input:** skills treat web pages as data and never follow instructions found in them.
- **Spending:** OpenRouter key capped at US$10; Sonnet in `#auto` has its own key capped at US$1/day.

## Cost

About **US$0.33** for the whole build (two days, including benchmarks and tests). Typical runs: a digest US$0.03, a
research fan-out about US$0.05, a Sonnet code review about US$0.10. Planned budget: a few dollars a month.

## Phases

| Phase | What | Status | Write-up |
|---|---|---|---|
| 0 | Prep: accounts, keys, spending caps | ✅ Done | [roadmap](HERMES_ROADMAP.md) |
| 1 | Sandboxed install in Docker | ✅ Done | [phase-1](docs/phase-1.md) |
| 2 | Discord command centre | ✅ Done | [phase-2](docs/phase-2.md) |
| 3 | Models and routing | ✅ Done | [phase-3](docs/phase-3.md), [benchmark](docs/benchmark.md) |
| 4 | Memory and knowledge | ✅ Done | [phase-4](docs/phase-4.md) |
| 5 | Sub-agents | ✅ Done | [phase-5](docs/phase-5.md) |
| 6 | WhatsApp notifications | ⏸ Parked | [todo-whatsapp](docs/todo-whatsapp.md) |
| 7 | Homelab tools, scheduled jobs, `#auto` routing | ✅ Built, in its test week | [phase-7](docs/phase-7.md) |

The full plan, decisions and budget are in [HERMES_ROADMAP.md](HERMES_ROADMAP.md).

## Repo layout

```
docker-compose.yml        Hermes service (limits, networks, mounts)
docs/                     one write-up per phase, benchmark, parked plans
scripts/                  host cron jobs: backups, nightly snapshots, spend report
set-profile-secret.sh     put a secret into a profile's .env (hidden input)
add-env-id.sh             add a Discord channel ID to a .env list safely
HERMES_ROADMAP.md         the plan
```
Not in git: `.env`, `data/` (agent state), `notes/` (its own repo), `agent-history/` (its own repo), backups.

## License

MIT, see [LICENSE](LICENSE).
