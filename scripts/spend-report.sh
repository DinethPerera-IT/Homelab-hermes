#!/bin/sh
# OpenRouter spend report for Hermes, posted to Discord #agent-log. Runs on the HOST under Dina's user.
#   spend-report.sh daily   21:30 NZ: today's spend, month to date, budget left, requests per model
#   spend-report.sh check   hourly: records the NZ-midnight baseline; posts one alert per day over $ALERT_USD
# Reads OPENROUTER_API_KEY and DISCORD_AGENTLOG_WEBHOOK from
# ~/hermes/.env. Secrets go to curl through a config on stdin: never in argv, output or logs.
set -eu
umask 077
MODE="${1:-daily}"
ALERT_USD="0.50"
ENV_FILE="$HOME/hermes/.env"
STATE="$HOME/.local/state/hermes-spend"
API="https://openrouter.ai/api/v1"
mkdir -p "$STATE"

getenv() { sed -nE "s/^[[:space:]]*$1=[\"']?([^\"']*)[\"']?[[:space:]]*$/\1/p" "$ENV_FILE" | tail -n 1; }
api() {   # $1 = path, $2 = key  -> JSON on stdout
    printf 'url = "%s%s"\nheader = "Authorization: Bearer %s"\n' "$API" "$1" "$2" | curl -sf --max-time 20 -K -
}
post() {  # $1 = message text (Discord limit 2000 chars)
    payload=$(jq -n --arg c "$1" '{content: $c, allowed_mentions: {parse: []}}')
    printf 'url = "%s"\n' "$HOOK" | curl -sf --max-time 20 -K - -H 'Content-Type: application/json' --data-binary "$payload" -o /dev/null
}
money() { awk -v v="$1" -v d="${2:-2}" 'BEGIN { printf "$%.*f", d, v }'; }
gt()    { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }

KEY=$(getenv OPENROUTER_API_KEY)
HOOK=$(getenv DISCORD_AGENTLOG_WEBHOOK)
[ -n "$KEY" ]  || { echo "error: OPENROUTER_API_KEY missing from .env"; exit 1; }
[ -n "$HOOK" ] || { echo "error: DISCORD_AGENTLOG_WEBHOOK missing from .env"; exit 1; }

KJ=$(api /key "$KEY") || { echo "error: OpenRouter /key request failed"; exit 1; }
total=$(printf '%s' "$KJ" | jq -r '.data.usage // 0')
utc_day=$(printf '%s' "$KJ" | jq -r '.data.usage_daily // 0')
utc_month=$(printf '%s' "$KJ" | jq -r '.data.usage_monthly // 0')
limit=$(printf '%s' "$KJ" | jq -r '.data.limit // empty')
left=$(printf '%s' "$KJ" | jq -r '.data.limit_remaining // empty')
reset=$(printf '%s' "$KJ" | jq -r '.data.limit_reset // empty')

# NZ-day spend = all-time usage now minus the usage recorded at the first run after NZ midnight.
today=$(date +%F)
base_file="$STATE/baseline-$today"
if [ ! -f "$base_file" ]; then
    if [ "$(date +%H)" = "00" ]; then echo "$total full" > "$base_file"; else echo "$total partial" > "$base_file"; fi
fi
find "$STATE" -name 'baseline-*' -mtime +40 -delete 2>/dev/null || true
read -r base kind < "$base_file"
if [ "$kind" = "full" ]; then
    nz_day=$(awk -v t="$total" -v b="$base" 'BEGIN { printf "%.6f", t - b }')
    today_line="Today (NZ day): **$(money "$nz_day" 3)**  ·  UTC day so far: $(money "$utc_day" 3)"
    spend_today="$nz_day"
else
    today_line="Today: **$(money "$utc_day" 3)** (UTC day, since 13:00 NZDT; NZ-day tracking starts after midnight)"
    spend_today="$utc_day"
fi

if [ "$MODE" = "check" ]; then
    flag="$STATE/alerted-$today"
    if gt "$spend_today" "$ALERT_USD" && [ ! -f "$flag" ]; then
        post "⚠️ **Hermes spend alert**: today's spend is $(money "$spend_today" 2), over the $(money "$ALERT_USD" 2) daily threshold. Month to date: $(money "$utc_month" 2)." \
            && touch "$flag" && echo "alert posted: today $(money "$spend_today" 3)"
    else
        echo "check ok: today $(money "$spend_today" 3) (threshold $(money "$ALERT_USD" 2))"
    fi
    exit 0
fi

if [ -n "$limit" ]; then
    budget_line="Budget: **$(money "$left" 2) left** of $(money "$limit" 2)${reset:+ (resets $reset)}"
else
    budget_line="Budget: no spending limit set on this key"
fi

# Sonnet route (#auto profile): its own OpenRouter key "hermes-auto-sonnet", $1/day cap, resets 00:00 UTC.
# The key is read through the container (data/ is mode 700) and only ever passed to curl on stdin.
SKEY=$(docker exec -u hermes hermes sed -nE "s/^OPENROUTER_SONNET_API_KEY=[\"']?([^\"']*)[\"']?$/\\1/p" \
       /opt/data/profiles/auto/.env 2>/dev/null | tail -n 1 || true)
if [ -n "$SKEY" ] && SJ=$(api /key "$SKEY"); then
    s_day=$(printf '%s' "$SJ" | jq -r '.data.usage_daily // 0')
    s_lim=$(printf '%s' "$SJ" | jq -r '.data.limit // empty')
    sonnet_line="Sonnet (#auto): **$(money "$s_day" 2)** today (UTC day)${s_lim:+ of $(money "$s_lim" 2)} · resets 13:00 NZDT"
else
    sonnet_line="Sonnet (#auto): key not readable or OpenRouter /key failed"
fi
SKEY=
calls=$(docker exec -u hermes hermes sh -c "grep -h '^$today .*API call #' /opt/data/logs/agent.log 2>/dev/null" \
        | sed -nE 's/.* model=([^ ]+) .*/\1/p' | sort | uniq -c | sort -rn || true)
n_calls=$(printf '%s\n' "$calls" | awk '{ s += $1 } END { print s + 0 }')
per_model=$(printf '%s\n' "$calls" | awk 'NF { printf "%s%s %s", (n++ ? "  ·  " : ""), $2, $1 }')

msg=$(printf '**Hermes spend · %s (NZ)**\n%s\nMonth to date (UTC month): **%s**\n%s\n%s\nHermes API calls today: **%s**%s' \
    "$(date '+%a %d %b %Y, %H:%M')" "$today_line" "$(money "$utc_month" 2)" "$budget_line" "$sonnet_line" \
    "$n_calls" "${per_model:+ — $per_model}")
post "$msg" && echo "daily report posted" && printf '%s\n' "$msg"
