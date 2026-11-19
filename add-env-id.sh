#!/usr/bin/env bash
# usage: ./add-env-id.sh VAR_NAME ID   (run in ~/hermes; ENV_FILE=path overrides .env, for testing)
# Appends ID to a comma-separated list in .env, once. Prints only names and counts, never values.
# Refuses when the list is empty or missing: for DISCORD_ALLOWED_CHANNELS, empty means "every
# channel", so adding one ID would silently restrict the bot.
set -euo pipefail
VAR="${1:?VAR_NAME}"; ID="${2:?ID}"; F="${ENV_FILE:-.env}"
[[ "$VAR" =~ ^[A-Z][A-Z0-9_]*$ && "$ID" =~ ^[0-9]{15,22}$ ]] || { echo "bad name or ID"; exit 1; }
get() { sed -nE "s/^$VAR=[\"']?([^\"']*)[\"']?$/\1/p" "$F"; }
n=$(grep -c "^$VAR=" "$F" || true)
[ "$n" = "1" ] || { echo "$VAR: found $n lines, expected 1 — not changed"; exit 1; }
cur=$(get)
[ -n "$cur" ] || { echo "$VAR is empty — not changed (empty may mean 'all'; decide by hand)"; exit 1; }
case ",$cur," in *",$ID,"*) echo "$VAR: already contains that ID"; exit 0;; esac
sed -i -E "s/^($VAR=[\"']?)([^\"']*)([\"']?)$/\1\2,$ID\3/" "$F"
echo "$VAR: added ID ($(get | tr ',' '\n' | grep -c .) entries now)"
