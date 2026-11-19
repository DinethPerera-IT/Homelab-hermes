#!/usr/bin/env bash
# usage: ./set-profile-secret.sh PROFILE VAR_NAME
# Sets VAR_NAME in /opt/data/profiles/PROFILE/.env inside the hermes container.
# Hidden input; the value travels on stdin only (never argv, output or logs).
set -euo pipefail
P="${1:?profile}"; VAR="${2:?VAR_NAME}"
[[ "$P" =~ ^[a-z0-9_-]+$ && "$VAR" =~ ^[A-Z][A-Z0-9_]*$ ]] || { echo "bad profile or variable name"; exit 1; }
read -rsp "Value for $VAR (profile $P): " V; echo
[ -n "$V" ] || { echo "empty value, nothing changed"; exit 1; }
printf '%s' "$V" | docker exec -i -u hermes -e P="$P" -e VAR="$VAR" hermes sh -c '
  f="/opt/data/profiles/$P/.env"; [ -d "/opt/data/profiles/$P" ] || { echo "no such profile"; exit 1; }
  v=$(cat); umask 077; touch "$f"
  grep -v "^$VAR=" "$f" > "$f.tmp" || true
  printf "%s=%s\n" "$VAR" "$v" >> "$f.tmp" && mv "$f.tmp" "$f" && chmod 600 "$f"'
unset V
echo "$VAR set in profile $P (length only: hidden)."
