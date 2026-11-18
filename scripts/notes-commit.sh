#!/bin/sh
# Nightly snapshot of the Hermes notes folder (~/hermes/notes, mounted at /opt/data/notes).
# Runs from Dina's host crontab, never from inside Hermes, so every change Hermes makes
# shows up as a reviewable commit (git log -p).
set -eu
cd "$HOME/hermes/notes"
git add -A
if git diff --cached --quiet; then
    echo "no changes"
    exit 0
fi
git commit -q -m "Nightly notes snapshot $(date +%F)"
echo "committed: $(git log --oneline -1)"
