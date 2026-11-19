# Phase 7: Homelab tools and scheduled jobs

**Date:** 19 November 2026
**Result:** Hermes answers homelab questions with measured numbers from my own read-only MCP server, `homelab-mcp`,
and posts a daily brief and a weekly capacity report to Discord. Along the way: Hermes is now firewalled off from
every host service (it could reach all of them, including the HR System pentest target), and `data/` is backed up
nightly.

## What is it

- **MCP (Model Context Protocol)** is a standard way to give an AI agent tools. An MCP server lists tools (name,
  inputs, description); the agent calls them and gets structured results back.
- **homelab-mcp** is my own MCP server (Python, official MCP SDK 2.3.0, streamable HTTP) in its own container. It has
  **six read-only tools** that run **fixed PromQL** against Prometheus. No tool accepts raw PromQL, so the agent can
  only ask the questions I designed. "Code collects the facts; the AI only explains them."
- Code: separate private repo `homelab-mcp` (`~/homelab-mcp`), with its own README, tests and host scripts.

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

**Scheduled jobs** (Hermes cron, both pinned to `anthropic/claude-haiku-5.5` via OpenRouter, Pacific/Auckland,
delivered to `#homelab`, the Discord home channel):

| Job | Schedule | Skill | Output |
|---|---|---|---|
| Homelab daily brief (`e50a4e711080`) | `0 8 * * *` | `homelab-brief` | ~10 lines: "All quiet" + key numbers, or one line per issue with number and threshold |
| Homelab weekly capacity (`7173f6504f39`) | `0 10 * * 0` | `homelab-capacity` | ~15 lines: disk trend, CPU/RAM/load week, restarts, maintenance, top 3 risks |

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
    repositories. The repo is created in the GitHub UI and pushed over SSH.
13. **Accepted:** homelab-mcp can also reach Prometheus through the host's LAN address, because the rule allows port
    9090 on the host whichever address is used. It is still only Prometheus.

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
| Daily brief run by hand | ✅ all 5 tools called (< 0.1 s each), delivered to `#homelab`; numbers matched the tools |
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
