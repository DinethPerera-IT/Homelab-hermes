#!/bin/sh
# Nightly snapshots, run from Dina's host crontab (23:45), never from inside Hermes.
#   1. ~/hermes/agent-history  what Hermes can change about itself: MEMORY.md, USER.md, SOUL.md,
#      skills/ and cron/jobs.json. Host-only repo, not mounted into the container.
#   2. ~/hermes/notes          the shared notes folder (mounted at /opt/data/notes).
# Files are read through the container (data/ is mode 700). Only the paths listed below are
# copied, and any file that looks like it contains a real key is skipped and logged instead.
set -eu
HIST="$HOME/hermes/agent-history"
NOTES="$HOME/hermes/notes"
SECRET_RE='sk-or-v1-[A-Za-z0-9]{32,}|sk-ant-[A-Za-z0-9_-]{32,}|sk-proj-[A-Za-z0-9_-]{32,}|gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{40,}|xox[abprs]-[A-Za-z0-9-]{20,}|tvly-[A-Za-z0-9-]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY|[A-Za-z0-9_-]{24,}\.[A-Za-z0-9_-]{6}\.[A-Za-z0-9_-]{27,}'

copy_one() {   # $1 = path inside the container, $2 = path inside agent-history
    tmp=$(umask 077; mktemp)
    if docker exec -u hermes hermes cat "$1" > "$tmp" 2>/dev/null; then
        if grep -qE "$SECRET_RE" "$tmp"; then
            echo "SKIPPED $2: looks like it contains a secret, not copied"
        else
            mkdir -p "$(dirname "$HIST/$2")"
            install -m 644 "$tmp" "$HIST/$2"
        fi
    else
        echo "not copied: $2 (missing, or the hermes container isn't running)"
    fi
    rm -f "$tmp"
}

snapshot_skills() {
    tmp=$(umask 077; mktemp -d)
    if docker exec -u hermes hermes tar -C /opt/data --exclude=.locks --exclude='*.lock' -cf - skills \
         | tar -C "$tmp" -xf - 2>/dev/null; then
        grep -rlE "$SECRET_RE" "$tmp/skills" 2>/dev/null | while read -r f; do
            echo "SKIPPED ${f#"$tmp"/}: looks like it contains a secret, not copied"
            rm -f "$f"
        done
        rsync -a --delete "$tmp/skills/" "$HIST/skills/"
    else
        echo "not copied: skills/ (hermes container isn't running?)"
    fi
    rm -rf "$tmp"
}

commit_repo() {   # $1 = repo dir, $2 = commit message prefix
    cd "$1"
    git add -A
    if git diff --cached --quiet; then
        echo "$(basename "$1"): no changes"
    else
        git commit -q -m "$2 $(date +%F)"
        echo "$(basename "$1"): committed $(git log --oneline -1)"
    fi
}

copy_one /opt/data/memories/MEMORY.md memories/MEMORY.md
copy_one /opt/data/memories/USER.md   memories/USER.md
copy_one /opt/data/SOUL.md            SOUL.md
copy_one /opt/data/cron/jobs.json     cron/jobs.json
snapshot_skills
commit_repo "$HIST"  "Nightly agent snapshot"
commit_repo "$NOTES" "Nightly notes snapshot"
