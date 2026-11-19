#!/bin/sh
# Nightly backup of ~/hermes/data (Hermes config, memory, sessions, skills, cron, secrets), run from Dina's
# host crontab. SQLite databases are snapshotted with the online backup API inside the container first, so the
# archive never holds a half-written database. Restore: rename tmp/hermes-backup/db/<path>.db.snap to opt/data/<path>.db. Output: ~/backups/hermes/hermes-data-YYYY-MM-DD.tar.gz (mode 600),
# 14 kept. Writes homelab_last_backup_* metrics for node-exporter's textfile collector.
set -eu
umask 077
DEST="$HOME/backups/hermes"
TEXTFILE="/var/lib/node_exporter/textfile/homelab_backup.prom"
KEEP=14
out="$DEST/hermes-data-$(date +%F).tar.gz"
mkdir -p "$DEST"

# 1. consistent snapshots of every SQLite database (skips cache/), staged in the container's /tmp
docker exec -u hermes hermes python3 -I -c '
import os, sqlite3, shutil
src, stage = "/opt/data", "/tmp/hermes-backup/db"
shutil.rmtree("/tmp/hermes-backup", ignore_errors=True)
for root, dirs, files in os.walk(src):
    dirs[:] = [d for d in dirs if d not in ("cache", "node_modules", "notes")]
    for f in files:
        if f.endswith(".db"):
            p = os.path.join(root, f); dst = os.path.join(stage, os.path.relpath(p, src)) + ".snap"   # .db.snap: not hit by the *.db exclude
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            with sqlite3.connect(f"file:{p}?mode=ro", uri=True) as s, sqlite3.connect(dst) as d:
                s.backup(d)
'

# 2. stream one archive: data/ minus live databases, caches and locks, plus the snapshots
#    GNU tar exit 1 = "file changed as we read it" (logs are live; databases are covered by the snapshots): OK.
#    Exit 2 = real error: stop.
tmp="$out.part"
trap 'rm -f "$tmp"' EXIT
rc=0
docker exec -u hermes hermes tar -C / -czf - --warning=no-file-changed --warning=no-file-ignored \
    --exclude='opt/data/cache' --exclude='opt/data/scripts/whatsapp-bridge/node_modules' \
    --exclude='*.db' --exclude='*.db-wal' --exclude='*.db-shm' --exclude='*.lock' --exclude='*.sock' \
    opt/data tmp/hermes-backup > "$tmp" || rc=$?
docker exec -u hermes hermes rm -rf /tmp/hermes-backup
[ "$rc" -le 1 ] || { echo "backup FAILED: tar exit $rc"; exit 1; }
tar -tzf "$tmp" > /dev/null          # verify the archive reads back
mv "$tmp" "$out"

# 3. keep the newest $KEEP archives
ls -1t "$DEST"/hermes-data-*.tar.gz | tail -n +$((KEEP + 1)) | xargs -r rm -f

# 4. metrics for the daily brief
size=$(stat -c %s "$out")
cat > "$TEXTFILE.tmp" << METRICS
# HELP homelab_last_backup_timestamp_seconds Unix time of the last successful backup.
# TYPE homelab_last_backup_timestamp_seconds gauge
homelab_last_backup_timestamp_seconds{job="hermes-data"} $(date +%s)
# HELP homelab_last_backup_size_bytes Size of the last successful backup archive.
# TYPE homelab_last_backup_size_bytes gauge
homelab_last_backup_size_bytes{job="hermes-data"} $size
METRICS
chmod 644 "$TEXTFILE.tmp" && mv "$TEXTFILE.tmp" "$TEXTFILE"
echo "backup ok: $out ($size bytes)"
