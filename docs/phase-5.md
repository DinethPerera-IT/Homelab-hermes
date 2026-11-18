# Phase 5: Sub-agents

**Date:** 18 November 2026
**Result:** Delegation works and is capped. A 3-child fan-out found far more (and better) sources than a single agent,
at about 5× the cost. The `research-fanout` skill is approved; the next fan-out should use it end to end.

## What is it

**Sub-agents** (delegation) let the main agent hand parts of a big job to child agents that run **in parallel**. Hermes
calls `delegate_task` with a batch of tasks; each child works on its own, and only its **final summary** comes back to
the main conversation. Children run on a cheaper model, so the expensive "thinking" stays with the coordinator while
the bulk reading is cheap.

## How does it work

```
#research  ──►  coordinator (DeepSeek, /model fast)
                  │ delegate_task(tasks=[A, B, C])   ← one batch, max 3
                  ├──► child A  (DeepSeek, blank context, 30 iterations, 5-min inactivity timeout)
                  ├──► child B
                  └──► child C
                  ◄── 3 summaries ──  merge → one sourced note in notes/Research/
```

- **Children start blank.** They know only what the coordinator writes in `goal` and `context`, so the
  `research-fanout` skill gives a complete context template per child: topic, angle, out-of-scope, web tools only,
  untrusted pages, sources with dates, fixed output format, ~10 tool calls.
- **Limits** (`delegation` in config.yaml):

  | Key | Value | Why |
  |---|---|---|
  | `model` / `provider` | `deepseek/deepseek-v4.1-flash-1017` / openrouter | Children carry most of the tokens |
  | `max_concurrent_children` | 3 (default 10) | Caps parallel spend |
  | `max_iterations` | 30 (default 250) | A confused child can't loop forever |
  | `child_timeout_seconds` | 300 (default none) | A child that goes quiet for 5 minutes is stopped |
  | `max_spawn_depth` / `orchestrator_enabled` | 1 / false | Children can't spawn children |
  | `inherit_mcp_toolsets` | false | Strict once MCP servers exist |
  | `subagent_auto_approve` | false | Dangerous commands are never auto-approved |

- **Tools: the parent is the ceiling.** `delegate_task` has no per-child tool list; each child inherits the parent's
  enabled toolsets. So I cut Discord's toolsets from **19 to 13**, turning off `browser`, `computer_use`, `image_gen`,
  `tts`, `discord_admin` and `connections` (Nous Portal accounts and MCP lifecycle, which nothing here uses). Children can
  never use `memory`, `send_message`, `cronjob` or `clarify`.
- **Write limits** (checked with Hermes's own guard functions): `config.yaml`, `.env`, `state.db` and `sessions/` are
  denied; `SOUL.md` needs approval; **`skills/*/SKILL.md` and `cron/jobs.json` are writable without a prompt**, for the
  parent and every child. Mitigations:
  - SOUL rule: "Change skills only with skill_manage; never edit SKILL.md or cron files directly."
  - **`~/hermes/agent-history/`**, a host-only git repo (not mounted into the container). The nightly 23:45 job
    snapshots `MEMORY.md`, `USER.md`, `SOUL.md`, `skills/` and `cron/jobs.json` into it, so any change, gated or not,
    shows up in `git log -p`. A length-aware secret filter skips files that look like they contain real keys.
- **Spend reporting** (host, `scripts/spend-report.sh`):
  - Daily at 21:30 NZ it posts to #agent-log: today's spend, month to date, budget left, and Hermes API calls per model.
  - Hourly it records an NZ-midnight baseline (OpenRouter's "daily" is a UTC day) and alerts once a day over $0.50.
  - It reads only `OPENROUTER_API_KEY` and `DISCORD_AGENTLOG_WEBHOOK`, passing them to curl on stdin, never in argv or
    output.
  - Per-model *spend* would need an OpenRouter management key and only covers completed UTC days. Decided not to use one.

## What went wrong

1. **The fan-out skill wasn't used the first time:** it was still waiting in `/skills pending`. A staged skill doesn't
   exist for Hermes until it's approved.
2. **Approval failed: the description was too long.** The first version's description was 137 characters; the limit is
   60 (one sentence, trigger first, ends with a period, must not repeat the category name). Rejected and recreated
   through `skill_manage` as `dd9c7af3` with "Deep dives: 3 parallel sub-agents, merged sourced note." (55 chars), with the
   old description's detail moved into the body. Then approved.
3. **The fan-out test ran without the skill.** It fell back to `grounded-citations`, and the merged result was saved to
   cache/scratch instead of `notes/Research/`. The only note in `notes/Research/` is from the single-agent run. Lesson:
   check `/skills pending` is empty before a test that depends on a new skill.
4. **I accidentally gave `execute_code` a permanent approval.** Choosing "always" on a Discord approval card at 21:33
   added `execute_code` to `command_allowlist`. Removed by editing `config.yaml` (`command_allowlist: []`); Hermes
   re-reads the list on every check, so no restart was needed. `approvals.mode` is `smart`. Lesson: on approval cards,
   use "once" unless I really mean forever.
5. **The curator's patches now wait for approval (the gate works).** The background review staged 3 patches to
   `grounded-citations` (`1083a13f`): reject bot-challenge pages before citing, register sources right after each
   fetch, handle the same docs under two hostnames. I approved them after reading the full diff.
6. **The secret filter flagged documentation.** Two bundled skills mention token prefixes like `ghp_` as examples.
   Fixed by requiring a realistic key length after each prefix (catches 9 realistic fake keys, 0 false positives across
   308 skill files).
7. **The spend report's first test failed** (curl exit 6): `DISCORD_AGENTLOG_WEBHOOK` was still a 19-character
   placeholder. Checked its shape and length without printing it. Fixed by setting the real URL.
8. **One child used all 30 iterations** (30 API calls). The cap did its job. If research children keep hitting it,
   tighten the skill's "~10 tool calls" guidance before raising the cap.
9. **The roadmap's patterns assumed per-child toolsets and MCP servers that don't exist yet.** Homelab check needs the
   Prometheus MCP (Phase 7), and Repo review needs the GitHub MCP (skipped).

## How I tested it

Same topic (securing a self-hosted Discord bot in Docker), DeepSeek coordinator in #research.

| | Single agent | Fan-out (coordinator + 3 children) |
|---|---|---|
| Time | ~1 min (API calls 21:31:17–21:31:52) | ~4–5 min (21:32:23–21:36:29) |
| Sources | 5 searches, 1 page read | **49 sources, mostly primary docs** |
| Accuracy | 1 unverified specific claim | 6 points marked `[unverified]`, gaps noted |
| API calls | 8 | 96 (coordinator 15, children 30 / 22 / 29) |
| Input tokens (cached) | 186K (157K) | 4.38M (4.01M) |
| Output tokens | 4.6K | 53K |
| **Cost (OpenRouter)** | **~$0.01–0.02** | **~$0.08** (~5×) |
| Saved to | `notes/Research/Securing a Self-Hosted Discord Bot in Docker.md` | cache/scratch (skill not yet approved) |

Costs are from OpenRouter. All Phase 5 testing came to about **$0.12**; the whole day (Phases 1–5) was **$0.22** for
**251 requests**, with an **88.8% prompt-cache hit rate**. (An estimate from logged tokens × list prices put the single
run at ~$0.005; the real figure is higher, so list-price maths undercounts and OpenRouter Activity is the source of
truth.) **Takeaway:** the fan-out is ~5× the cost and ~4× the time for ~10× the sources and much better grounding. Worth it for real deep dives, not for quick questions (which is what the skill's "When to use" says).

Other checks:

| Test | Result |
|---|---|
| Discord toolsets | 13 enabled; deferred tool list shrank from ~5.5K to ~5.15K tokens per request |
| Delegation limits | Read back as set; children logged as `platform=subagent` on DeepSeek |
| Skills gate covers background review | ✅ `1083a13f` was staged, not applied |
| Agent history | First snapshot committed (312 files); second run "no changes" |
| Secret filter | 9 realistic fake keys caught; doc examples ignored; 0 false positives |
| Permanent approval removed | ✅ `command_allowlist: []`; Hermes's approval module reads an empty list |
| Spend report | ✅ Posted to #agent-log after the webhook was set; hourly check reports today's spend |

**Still to do:** re-run a fan-out with the approved `research-fanout` skill and confirm it writes
`notes/Research/YYYY-MM-DD-<slug>.md` with merged sources and a token summary (the roadmap's "Done when").
