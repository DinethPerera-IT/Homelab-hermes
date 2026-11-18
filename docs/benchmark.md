# Phase 3 benchmark: 10 fixed questions

**Run:** 18 November 2026, on Hermes Agent v0.23.2 through OpenRouter.

Models compared:
- **haiku** = `anthropic/claude-haiku-5.5` (main model)
- **fast** = `deepseek/deepseek-v4.1-flash-1017` (switched with `/model fast`)

Scores: ✅ correct and useful · ⚠️ partly right, vague or ignored instructions · ❌ wrong, invented facts or failed.

| # | Type | Question | Haiku score | Fast score | Notes |
|---|---|---|---|---|---|
| 1 | Homelab | How full is the disk and how much RAM is free? | ✅ | ✅ | Both ran commands; numbers matched the host |
| 2 | Homelab | Explain what Pi-hole and Unbound do together, in 3 sentences | ✅ | ✅ | |
| 3 | Homelab | My Caddy reverse proxy returns 502 for one service. List the 5 most likely causes in order | ✅ | ✅ | |
| 4 | Research | Search the web: what changed in the latest Uptime Kuma release? Give sources | ✅ | ✅ | Fast found 2.5.11 through the GitHub releases feed |
| 5 | Research | Compare Tailscale and WireGuard for a homelab, pros and cons, with sources | ✅ | ✅ | Fast read full pages instead of search snippets |
| 6 | Research | Find 3 recent articles about prompt injection in AI agents and summarise each in 2 lines | ✅ | ✅ | |
| 7 | Study | Explain the difference between TCP and UDP like I'm studying for a networking exam, with one example each | ✅ | ⚠️ | Fast said the UDP checksum covers the payload only. Wrong: it covers the header, payload and a pseudo-header |
| 8 | Study | Give me 5 quiz questions on subnetting with answers | ✅ | ✅ | Fast checked its answers with Python (`execute_code`) |
| 9 | Multi-step | Plan a weekly backup strategy for a single Ubuntu server with Docker volumes. Steps only, no fluff | ✅ | ⚠️ | Fast ignored "steps only, no fluff" |
| 10 | Accuracy trap | What's the current version of Hermes Agent and when was it released? | ⚠️ | ✅ | Haiku read a stale "latest" GitHub page and said v0.23.1, but invented nothing. Fast got it right. Installed: v0.23.2 (2026.9.24) |
| | **Total** | | **9 ✅ 1 ⚠️** | **8 ✅ 2 ⚠️** | No ❌ and no invented facts from either model |

## Cost and speed

| Model | Total cost (10 Qs) | Avg latency per API call | Avg input tokens per call | Notes |
|---|---|---|---|---|
| haiku | ~$0.02 | 2.5 s (42 calls) | ~31.5K | Concise, follows format instructions |
| fast | ~$0.04–0.05 | 4.0 s (28 calls) | ~46.6K (max ~65.7K) | More tool calls and more context, so ~2× the total cost even though each request costs about the same |

- Each request cost about the same on both models (~$0.001–0.002). DeepSeek's total was higher because it made more tool calls and the session context grew to ~65K input tokens.
- `execute_code` (DeepSeek's habit of checking its work in Python) triggered more approval prompts.
- Whole day: $0.10, 93 requests, 88% prompt-cache hits.
- Latency and token figures come from the `API call #…` lines in `data/logs/agent.log` for the whole day, not only the benchmark. Costs come from OpenRouter Activity.

## Decision

- **Main model: Claude Haiku 5.5.** It's more accurate on facts and format, and cheaper overall.
- **`/model fast` (DeepSeek) for research threads in #research.** It's better at digging: it reads full pages, uses release feeds and checks its own work.
- **Cheap slots stay on DeepSeek:** `compression`, `title_generation`, `curator`, delegation.
- **Quality slots stay on Haiku:** `approval`, `background_review`, `memory_query_rewrite`.
- **Lesson:** start a new session (`/new`) between topics. Context growth was the biggest cost driver.
