#!/bin/sh
# Nightly snapshot of the Hermes notes folder (~/hermes/notes, mounted at /opt/data/notes).
# Runs from Dina's host crontab, never from inside Hermes, so every change Hermes makes
# shows up as a reviewable commit (git log -p).
#
# Step 1 copies Hermes's three core files into notes/_agent-memory/ so memory changes are in
# git history too. Only these three files, read through the container (data/ is mode 700),
# and any file that looks like it contains a secret is skipped instead of copied.
set -eu
NOTES="$HOME/hermes/notes"
DEST="$NOTES/_agent-memory"
SECRET_RE='sk-or-v1-|sk-ant-|sk-proj-|ghp_|gho_|github_pat_|xox[abprs]-|tvly-|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY|[A-Za-z0-9_-]{24,}\.[A-Za-z0-9_-]{6}\.[A-Za-z0-9_-]{27,}'

copy_one() {   # $1 = path inside the container, $2 = file name in _agent-memory/
    tmp=$(umask 077; mktemp)
    if docker exec -u hermes hermes cat "$1" > "$tmp" 2>/dev/null; then
        if grep -qE "$SECRET_RE" "$tmp"; then
            echo "SKIPPED $2: content looks like it contains a secret, not copied"
        else
            install -m 444 "$tmp" "$DEST/$2"
        fi
    else
        echo "could not read $2 (is the hermes container running?)"
    fi
    rm -f "$tmp"
}

copy_one /opt/data/memories/MEMORY.md MEMORY.md
copy_one /opt/data/memories/USER.md   USER.md
copy_one /opt/data/SOUL.md            SOUL.md

cd "$NOTES"
git add -A
if git diff --cached --quiet; then
    echo "no changes"
    exit 0
fi
git commit -q -m "Nightly notes snapshot $(date +%F)"
echo "committed: $(git log --oneline -1)"
