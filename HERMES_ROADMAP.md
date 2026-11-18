# Hermes Agent on dinashomelab

Integration roadmap: setup, model routing, memory and knowledge, sub-agents, Discord and WhatsApp

Dineth Perera · November 2026 · Version 1

## 1. What this builds

A self-hosted Hermes Agent running in Docker on the OptiPlex. It has two front doors, each with a different job:

| Channel | Role | What you do there |
|---|---|---|
| **Discord** | Command centre | Ask it to do things: research, homelab questions, multi-agent tasks, drafting. Long answers, threads, files. |
| **WhatsApp** | Notification inbox | Reminders, alerts, short updates and summaries you can read straight from a phone notification. Quick replies only. |

Behind both channels sits one agent with one memory. It picks the right model for each job through OpenRouter, uses only the tools a job needs, and hands big jobs to sub-agents.

### Architecture

```
  You
   ├── Discord  (command centre: #hermes, #research, #homelab-brief, #agent-log)
   └── WhatsApp (notifications: reminders, alerts, short summaries)
          │
          ▼
  Hermes gateway  — Docker on the OptiPlex, non-root, 1.5 GB RAM cap
   ├── Models via OpenRouter
   │     main: cheap model · escalate: Claude Sonnet · sub-agents: cheap flash model
   ├── Memory: core files + session search + git-backed markdown notes folder
   ├── Tools: web search (free tiers), read-only MCPs
   │     Prometheus · GitHub (read-only) · notes folder only
   ├── Sub-agents: up to 3 in parallel (set; default 10), cheap model, inherit parent's tools
   └── Cron: daily brief, reminders, weekly reports → Discord / WhatsApp
```

### Ground rules (carried over from the original plan)

- **Read-only first.** Every new permission is a written-down decision.
- **Code collects facts, the AI explains them.** Numbers come from Prometheus and Uptime Kuma, never from the model guessing.
- **A human approves changes.** Restart, edit, install or delete needs your explicit "yes".
- **Least privilege.** Separate bot accounts, scoped keys, allowlists on every channel.
- **Uptime Kuma stays the backstop.** Hermes is a convenience, not the monitoring system.

## 2. Model strategy: the right model for each job

Hermes does not use one model for everything. There are five separate places a model is chosen, and setting each one deliberately is what keeps the bill small while quality stays high.

| Slot | Model (via OpenRouter) | Price in / out per 1M tokens | Used for |
|---|---|---|---|
| Main (default) | DeepSeek V4.1 Flash or Claude Haiku 5.5 (pick after testing) | $0.14 / $0.42 · $0.10 / $0.50 | Everyday Discord chat, homelab questions, reminders, planning |
| Escalation | Claude Sonnet 5.5 | $2.00 / $10.00 | Hard research synthesis, tricky reasoning, coordinating complex multi-agent runs |
| Mid-tier (optional) | GPT-6.1 Terra | $1.00 / $5.00 | Cheaper middle step before Sonnet |
| Sub-agents | DeepSeek V4.1 Flash 1017 (for now; benchmark decides) | $0.036 / $0.50 | Bulk reading, searching, summarising sources in parallel |
| Auxiliary slots (cheap) | DeepSeek V4.1 Flash 1017 (for now) | $0.036 / $0.50 | `compression`, `title_generation`, `curator` |
| Auxiliary slots (quality) | Claude Haiku 5.5 | $0.10 / $0.50 | `approval` (security), `background_review`, `memory_query_rewrite` (memory quality) |

**Prices:** read from OpenRouter on 16 Nov 2026 (BenchLM). They change often and vary by routed provider, so copy current prices and exact model slugs from openrouter.ai/models before configuring.

### How Hermes chooses the model automatically

Four mechanisms work together. Set them up in this order:

1. **Auxiliary slots.** Background tasks each have their own model setting (`auxiliary.<slot>`; real names: `compression`, `title_generation`, `curator`, `approval`, `background_review`, `memory_query_rewrite`, …). Point the low-stakes ones at the cheap model; keep approval and memory slots on Haiku.
2. **Delegation model.** Sub-agents use `delegation.model`. If left unset they inherit the main model, so three parallel sub-agents on Sonnet cost three times Sonnet. Defaults are `max_iterations: 250` and `max_concurrent_children: 10`, so set both lower.
3. **Smart routing (automatic tiers).** The official `model-picker` plugin (Hermes 0.21.5 or newer) classifies each turn and picks a `low`, `default` or `high` tier. It is deliberately conservative: it keeps the previous tier unless the turn clearly changes, and the high tier never sticks across turns.
4. **Manual escalation with aliases.** Define short names (`fast`, `smart`, `deep`) and switch with `/model smart` in Discord when you know a job is hard.

**Tip:** cron jobs should name their model explicitly so scheduled work never runs on the expensive tier by accident.

### Job → model → tools map

This is what "use the appropriate model and tool for the job" looks like in practice. Skills (Section 6) encode these rules so Hermes follows them every time.

| You ask in Discord… | Model tier | Tools it should use | Where the answer goes |
|---|---|---|---|
| "Is anything down?" / "How full is the disk?" | Cheap | Prometheus MCP | Discord reply |
| "Which container restarted most this week?" | Cheap → Smart if unclear | Prometheus MCP | Discord reply, saved to notes |
| "Research X and compare options" | Smart (coordinator) + cheap sub-agents | Web search/extract, notes write | Discord thread + note in notes/ |
| "Explain this concept for my course" | Cheap; Smart for deep dives | Web search, notes read | Discord |
| "Review my repo / summarise this week" | Cheap | GitHub MCP (read-only) | Discord + notes |
| "Remind me Friday 5pm to …" | Cheap | Cron | WhatsApp at that time |
| Scheduled brief / alert | Cheap (pinned) | Prometheus, Kuma | Discord (full) + WhatsApp (1–3 lines) |

## 3. Roadmap

Eight phases. Each one is built, tested and written up (What is X / How does it work / What went wrong / How I tested it) before the next starts. Rough timing assumes evenings and weekends.

| Phase | What | Effort |
|---|---|---|
| 0 | Prep: accounts, keys, spending caps, decisions | 1 evening |
| 1 | Sandboxed install in Docker | 1–2 evenings |
| 2 | Discord command centre | 1 evening |
| 3 | Models and routing | 1 week (includes testing) |
| 4 | Memory and knowledge | 1 week |
| 5 | Sub-agents | 2–3 evenings |
| 6 | WhatsApp notifications | 1–2 evenings |
| 7 | Homelab tools and scheduled jobs | 1–2 weeks |

### Phase 0 — Prep

**Goal:** everything you need is ready before anything is installed.

- Read the official docs: Installation (Docker), Security, Discord, WhatsApp, MCP, Delegation, Configuring Models.
- Read `install.sh` / the Docker guide before running anything.
- Create an OpenRouter account. Set a **US$15/month credit limit** and create a key just for Hermes.
- Get free web-search keys: Tavily (1,000/month) and Brave Search (2,000/month). Optional: Exa (1,000/month) for research.
- Create a **new Discord application** (not the shift-tracker bot). Enable Message Content and Server Members intents. Invite it to a private server.
- Decide the WhatsApp number (see Phase 6). Recommended: a cheap prepaid SIM, not your main number.
- Create the git repo `homelab-hermes` (config, skills, docs, no secrets).

**Done when:** keys are in a git-ignored `.env`, spending cap is set, both bot accounts exist.

### Phase 1 — Sandboxed install

**Goal:** Hermes runs in Docker with tight limits and cannot touch anything it should not.

Directory layout on the OptiPlex:

```
~/hermes/
├── docker-compose.yml
├── .env                 # secrets, git-ignored
├── data/                # mounted to /opt/data (memory, sessions, cron, skills)
└── notes/               # markdown knowledge base (Phase 4), its own git repo; NOT "vault" (see Phase 4)
```

Compose file (heredoc, paste as one block):

```bash
mkdir -p ~/hermes/data ~/hermes/notes && cd ~/hermes
cat > docker-compose.yml << 'EOF'
services:
  hermes:
    image: nousresearch/hermes-agent:latest
    container_name: hermes
    command: gateway run
    restart: unless-stopped
    env_file: .env
    volumes:
      - ./data:/opt/data
      - ./notes:/opt/data/notes   # Phase 4: inside /opt/data, not named vault
    mem_limit: 1.5g
    cpus: 1.0
    security_opt:
      - no-new-privileges:true
    networks:
      - hermes_net
networks:
  hermes_net:
    driver: bridge
EOF
```

**Check:** confirm the image name, data path and whether the image runs as a non-root user against the current Docker guide before first run. Run setup once with `docker compose run --rm hermes setup`.

- No `--privileged`, no host network, no raw Docker socket. If Docker info is needed later, add a GET-only docker-socket-proxy.
- Nothing from `~/.ssh` or other projects' `.env` files and data folders is mounted.
- Nightly backup of `~/hermes/data` and `~/hermes/notes` (tar to your backup location).
- Homepage tile and an Uptime Kuma monitor for the container.

**Test:** ask it to read `/etc/shadow`, run `sudo`, or `docker restart grafana`. All must fail.

**Done when:** the container survives a reboot, stays under its memory cap, and every escape test fails.

### Phase 2 — Discord command centre

**Goal:** you can talk to Hermes from your phone, and nobody else can.

Channel layout in your private server:

| Channel | Purpose | Setting |
|---|---|---|
| #hermes | Main chat, ask anything | Free-response (no @mention needed) |
| #research | Long research jobs; each job in its own thread | Free-response |
| #homelab-brief | Daily brief and weekly reports | Home channel for cron delivery |
| #agent-log | Which model and tools each job used, cost notes | Read-only for you |

Add to `.env` (heredoc appends; replace the IDs with your own):

```bash
cat >> ~/hermes/.env << 'EOF'
DISCORD_BOT_TOKEN=your-bot-token
DISCORD_ALLOWED_USERS=your-numeric-discord-user-id
DISCORD_ALLOWED_CHANNELS=id-hermes,id-research,id-homelab-brief,id-agent-log
DISCORD_FREE_RESPONSE_CHANNELS=id-hermes,id-research
DISCORD_HOME_CHANNEL=id-homelab-brief
EOF
docker compose up -d && docker logs -f hermes
```

- Allowlist uses your **numeric** user ID (Developer Mode → right-click your name → Copy User ID).
- Without an allowlist the gateway denies everyone, which is the safe default. Keep it that way.

**Test:** a second Discord account gets no reply. "How full is the disk?" matches `df -h`.

**Done when:** you can chat from Discord on your phone and the second account is ignored.

### Phase 3 — Models and routing

**Goal:** every job runs on the cheapest model that does it well, and you can escalate on demand.

Set the models with `hermes model` and `hermes config set`, or edit `config.yaml` with `hermes config edit`. Target values:

```yaml
# ~/hermes/data/config.yaml  (excerpt — merge, don't overwrite)
model:
  provider: openrouter
  default: anthropic/claude-haiku-5.5        # decided by the benchmark
# Aliases: use the canonical top-level form. The short form model.aliases.<name>: a/b
# reads "a" as the PROVIDER, so anthropic/… fails with "Anthropic is not connected".
model_aliases:
  fast:  { model: deepseek/deepseek-v4.1-flash-1017, provider: openrouter }
  haiku: { model: anthropic/claude-haiku-5.5,        provider: openrouter }
  mid:   { model: openai/gpt-6.1-terra,              provider: openrouter }
  smart: { model: anthropic/claude-sonnet-5.5,       provider: openrouter }
# reasoning effort: agent.reasoning_effort is ignored in v0.23.2 (see docs/phase-3.md)
 
delegation:
  provider: openrouter
  model: deepseek/deepseek-v4.1-flash-1017   # cheap model, decided by the benchmark
  max_iterations: 30                         # default 250
  max_concurrent_children: 3                 # default 10
 
# Real slot names (v0.23.2): compression, title_generation, curator, approval,
# background_review, memory_query_rewrite, review, mcp, vision (+ unused voice/kanban/moa…).
# There is no session_search or web_extract slot. "auto" = follow the main model.
auxiliary:
  compression:        { provider: openrouter, model: deepseek/deepseek-v4.1-flash-1017 }
  title_generation:   { provider: openrouter, model: deepseek/deepseek-v4.1-flash-1017 }
  curator:            { provider: openrouter, model: deepseek/deepseek-v4.1-flash-1017 }
  approval:           { provider: openrouter, model: anthropic/claude-haiku-5.5 }  # security decision
  background_review:  { provider: openrouter, model: anthropic/claude-haiku-5.5 }  # memory quality
  memory_query_rewrite: { provider: openrouter, model: anthropic/claude-haiku-5.5 }
 
web:
  search_backend: tavily
  extract_backend: tavily
```

**Check:** model slugs and auxiliary slot names change between releases. Copy slugs from openrouter.ai/models and slot names from `hermes config get auxiliary --json` on your installed version. Avoid `~…-latest` aliases (they silently change model) and `:batch` variants (offline only).

**Corrected 18 Nov 2026 (Phase 3 research):** GLM 5.3 Flash removed: the real `z-ai/glm-5.3-flash` is $0.15 / $0.50; the $0.04 / $0.078 price belonged to the `~z-ai/glm-flash-latest` alias. Cheap-slot candidates are now DeepSeek V4.1 Flash 1017 ($0.036 / $0.50) and Qwen 3.7 Flash ($0.03 / $0.13).

Then enable automatic tiering (later, after the benchmark; review the plugin's code before enabling):

- Install the `model-picker` plugin (needs Hermes 0.21.5+). Its tiers are **`low` (Quick) / `default` (Standard) / `high` (Expert)**, not cheap/work/high (`medium` is a deprecated alias for `default`). Map: low = main model, default = Haiku or Terra, high = Sonnet. All tiers must use the same provider (OpenRouter).
- Costs and privacy: by default the classifier runs on the active model, one extra call per turn with up to ~12,000 characters of context; it logs the first 120 characters of each prompt to `logs/model-picker.log`; a model switch drops the prompt cache for that turn.
- Leave it conservative at first. If it never escalates, that is by design: use `/model smart` manually.
- Log which model answered each request to `#agent-log` (a skill that posts a one-line summary at the end of each job).

**Test (the 10-question benchmark):** write 10 fixed questions (3 homelab, 3 research, 2 course concepts, 2 multi-step). Run them on DeepSeek V4.1 Flash, Claude Haiku 5.5 and MiniMax M3.1 Flash. Record cost, speed and correctness. Keep the winner as main.

**Done when:** one week of normal use costs under about US$3 and no answer had invented numbers.

### Phase 4 — Memory and knowledge

**Goal:** Hermes remembers what matters, can look up past work, and keeps durable notes you can read too.

| Tier | What it is | Your setup |
|---|---|---|
| 1. Core files | `memory.md`, `user.md`, `soul.md`, always loaded | Short: hostnames, services, rules, your preferences. Under about 1 page each. No secrets. |
| 2. Session search | Searches past conversations (SQLite) | On by default. Use it for "what did we try last time?" |
| 3. External memory (Honcho) | Third-party service that learns patterns | **Skip.** Sends homelab details off the server. |
| 4. Notes folder | Markdown notes, read and written by Hermes and you | `~/hermes/notes` mounted at `/opt/data/notes`, its own git repo, used with Hermes's built-in file tools (no filesystem MCP) |

#### Notes layout

```
notes/
├── Homelab/        Hosts.md · Services.md · Network.md · Decisions.md
├── Runbooks/       one file per procedure
├── Incidents/      YYYY-MM-DD-service.md
├── Research/       one note per research job, with sources
├── Study/          course concepts, explanations
└── Briefs/         daily briefs archive
```

#### Steps

- Write the three core files by hand first. Ask Hermes to keep them short and review them weekly.
- ~~Add the filesystem MCP pointed only at `/vault`.~~ **Built (18 Nov 2026):** `./notes` mounted at `/opt/data/notes` (inside `HERMES_WRITE_SAFE_ROOT`) so the built-in file tools work; ACLs give UID 10000 read/write except `.git`. Never name it `vault`: Hermes reserves `$HERMES_HOME/vault` for its encrypted credential store and blocks reads there.
- Add the GitHub MCP with a fine-grained, **read-only** token scoped to your homelab repos.
- Write a `research-note` skill: every research job saves a dated note with sources to `Research/`.
- Commit the notes nightly from the host (`scripts/notes-commit.sh`, crontab 23:45) so every change Hermes makes is reviewable.
- Review any skill Hermes creates itself before keeping it. Skills live in git; read the diff.

**Test:** in a fresh session, ask "what did we decide about the WhatsApp number?" (session search) and "show my runbook for Pi-hole" (notes). Both answers must be correct.

**Done when:** Hermes finds past decisions and notes without the core files growing past a page.

### Phase 5 — Sub-agents

**Goal:** big jobs are split across parallel workers on a cheap model, then combined by the main agent.

How it works: the main agent calls `delegate_task`. Each sub-agent starts with a **blank context** and only knows what the main agent puts in its goal and context fields, so instructions must be complete. Up to three run in parallel (`delegation.max_concurrent_children: 3`; the default is 10), and only each child's final summary comes back to the main conversation.

**Corrected 18 Nov 2026:** `delegate_task` has **no toolsets parameter**. Children inherit the parent's enabled toolsets (and MCP toolsets, via `delegation.inherit_mcp_toolsets: true`). So per-sub-agent tool restriction can't be done with a skill alone. Options to research in Phase 5: `delegation.inherit_mcp_toolsets: false`, delegation `profiles` (each profile has its own terminal policy/credentials), or keeping risky tools off the parent entirely.

#### Patterns to build, in order

| Pattern | How it splits | Toolsets per sub-agent |
|---|---|---|
| Research fan-out | 3 sub-agents each research one angle or source set; the coordinator (Sonnet) merges and writes the note in notes/ | web only |
| Homelab parallel check | Containers · DNS/Pi-hole · Cloudflare tunnel, merged into one answer | Prometheus MCP only |
| Study pack | One explains the concept, one finds examples, one writes quiz questions | web + notes read |
| Repo review | One reads code, one reads issues and commits, one checks docs | GitHub MCP only |

- Keep `delegation.model` on the cheap model. Only the coordinator escalates.
- Give each pattern a skill that describes which tools to use. A skill is guidance, not enforcement: children still inherit the parent's toolsets (see the correction above).
- Cap `max_iterations` (set to 30; default 250) so a confused sub-agent cannot loop and burn tokens.
- No sub-agent gets write access to anything except the notes folder.

**Test:** run the research fan-out on one topic, single-agent vs three sub-agents. Compare cost, time and the quality of the final note.

**Done when:** a research job in #research produces one merged, sourced note in notes/ and a clear cost line in #agent-log.

### Phase 6 — WhatsApp notifications

**Goal:** reminders, alerts and short updates land on your phone as readable notifications.

#### Choose the connection

|  | Baileys bridge (`hermes whatsapp`) | WhatsApp Cloud API (`hermes whatsapp-cloud`) |
|---|---|---|
| How | Links like WhatsApp Web, scan a QR code | Meta's official Business API |
| Needs | A phone number; Node.js runs inside the bridge | Meta Business account, dedicated number, public HTTPS webhook |
| Risk | Unofficial client: **the linked number can be banned** | Official, no ban risk; more setup |
| Fit for you | **Recommended**, on a cheap prepaid SIM so your main number is never at risk | Possible later via your Cloudflare Tunnel, but overkill for one person |

#### Setup

```bash
docker exec -it hermes hermes whatsapp     # scan the QR with the prepaid-SIM phone
cat >> ~/hermes/.env << 'EOF'
WHATSAPP_ALLOWED_USERS=+64XXXXXXXXX        # your own number, E.164 format
EOF
docker compose restart hermes
```

#### What goes to WhatsApp (and what does not)

| Send to WhatsApp | Keep in Discord |
|---|---|
| Reminders you set ("remind me Friday 5pm…") | Research results and long answers |
| Alerts: a service down, disk above 90% | Full daily brief and weekly reports |
| 1–3 line daily summary: "All quiet" or "2 issues, see Discord" | Anything with tables, code or files |
| Job finished: "Research on X done, note saved" | Agent logs and cost lines |

- Write a `whatsapp-format` skill: max 3 lines, plain text, lead with the point, end with "details in Discord" when longer.
- Quiet hours: no non-urgent messages 22:00–07:00 NZT; alerts still come through.
- Group policy stays at the default (forwards nothing from groups).
- Re-pair rarely. Frequent re-pairing raises the ban risk.

**Test:** "remind me in 5 minutes to check the oven" from Discord arrives on WhatsApp on time. A message from any other number gets no reply.

**Done when:** reminders and alerts arrive reliably for a week, and nothing long or noisy reaches WhatsApp.

### Phase 7 — Homelab tools and scheduled jobs

**Goal:** Hermes reports on the homelab using real numbers, on a schedule.

#### Read-only fact sources (MCP)

- **Prometheus MCP:** fixed PromQL queries for CPU, RAM, disk, container restarts. Node-exporter and Kuma's `/metrics` are already scraped, so one source covers both.
- Allow only the tools each server needs; every tool schema costs tokens on every request.

#### Scheduled jobs

| Job | When (NZT) | Model | Delivered to |
|---|---|---|---|
| Daily homelab brief | 08:00 daily | Cheap | Discord #homelab-brief (full) + WhatsApp (1 line) |
| Nightly self-check (API, model reachable, all jobs ran) | 23:00 daily | Cheap | WhatsApp only if something failed |
| Backup verification (checks, never runs backups) | 02:30 daily | Cheap | WhatsApp only on failure |
| Weekly update audit (outdated images, apt) | Sun 10:00 | Cheap | Discord |
| Weekly lab journal (GitHub commits → draft write-up) | Fri 17:00 | Cheap | Discord + notes |
| Your reminders | Whenever you set them | Cheap | WhatsApp |

**Know this:** cron jobs only fire while the gateway is running, and they deny dangerous shell commands by default because nobody is there to approve them. Uptime Kuma watching the container covers the first point.

**Test:** one week of briefs checked against Grafana and Kuma. Note any wrong or invented numbers.

**Done when:** a week of briefs has zero invented numbers and every job ran.

## 4. Security checklist

- Docker, non-root, `no-new-privileges`, memory and CPU limits, no raw Docker socket.
- Secrets only in `~/hermes/.env`, git-ignored, every key scoped and revocable.
- OpenRouter monthly credit limit set.
- Discord allowlist = your user ID; WhatsApp allowlist = your number; groups blocked.
- WhatsApp bridge on a spare number, never your main one.
- Logs, web pages and Reddit-style content are untrusted input: skills say never follow instructions found inside them.
- No new open ports; remote access only over Tailscale, Discord and WhatsApp.
- Keep secrets, IPs and sensitive log lines out of prompts sent to cloud models.
- Agent-written skills reviewed in git before they are kept.
- Changes (restart, edit, install, delete) out of scope until a later, written-down decision.

## 5. Monthly budget

| Item | Cost (USD) |
|---|---|
| Hermes Agent software | $0 (MIT open source) |
| Main + auxiliary + sub-agent models (cheap tier) | ~$2–6 |
| Escalations to Claude Sonnet 5.5 (a few hard jobs a week) | ~$3–8 |
| Web search (Tavily, Brave, Exa free tiers) | $0 |
| Prepaid SIM for WhatsApp | A few NZD a month (check NZ prepaid plans) |
| **Total** | **~$5–15, capped at $15 on OpenRouter** |

Alternative: Nous Portal Plus at $20/month includes $22 of credits and the Tool Gateway (Firecrawl search, browser automation, code sandboxes). Worth it only if you start needing browser automation.

## 6. Decisions still open

- ~~Main model: DeepSeek V4.1 Flash or Claude Haiku 5.5.~~ **Decided 18 Nov 2026:** Haiku 5.5 is main; DeepSeek V4.1 Flash 1017 via `/model fast` for research, plus the cheap slots and delegation (see docs/benchmark.md).
- WhatsApp number: which prepaid SIM.
- Whether to add a mid tier (GPT-6.1 Terra) or go straight from cheap to Sonnet.

## 7. Sources

- Hermes docs — Docker: hermes-agent.nousresearch.com/docs/user-guide/docker
- Hermes docs — Discord: hermes-agent.nousresearch.com/docs/user-guide/messaging/discord
- Hermes docs — WhatsApp: hermes-agent.nousresearch.com/docs/user-guide/messaging/whatsapp
- Hermes docs — Configuring models: hermes-agent.nousresearch.com/docs/user-guide/configuring-models
- Hermes docs — Model picker plugin: hermes-agent.nousresearch.com/docs/plugins/model-picker
- Hermes docs — Web search: hermes-agent.nousresearch.com/docs/user-guide/features/web-search
- Hermes docs — Providers: hermes-agent.nousresearch.com/docs/integrations/providers
- Fast.io — Sub-agent delegation patterns: fast.io/resources/hermes-agent-subagent-delegation-patterns
- BenchLM — OpenRouter prices (read 16 Nov 2026): benchlm.ai/hosts/openrouter
- Agent37 — Best model for Hermes Agent: agent37.com/blog/best-model-for-hermes-agent
- DEV — Nous Portal plans explained: dev.to/zackchew/nous-portal-explained-plans-models-tools-and-hermes-cloud-9hh
- Parallel — What is Hermes Agent: parallel.ai/articles/what-is-hermes-agent
