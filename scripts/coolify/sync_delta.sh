#!/usr/bin/env bash
# ==============================================================================
# Coolify Delta State Backup & Database Snapshot Script for Backblaze B2
# Safely dumps PostgreSQL, pauses write containers, and streams tarball snapshots
# to preserve exact Linux permissions (0600/0700), UIDs, symlinks, and DB state.
# ==============================================================================
set -euo pipefail

STORAGE_TARGET="${1:-b2:coolify-relay-state/coolify-state}"
BACKUP_DIR="/data/coolify/backups"
SOURCE_DIR="/data/coolify"

sudo mkdir -p "$BACKUP_DIR"
sudo chown -R runner:docker "$BACKUP_DIR" 2>/dev/null || sudo chmod 777 "$BACKUP_DIR"

# Ensure rclone configuration is available for both runner and root
if [ -f "$HOME/.config/rclone/rclone.conf" ]; then
  sudo mkdir -p /root/.config/rclone
  sudo cp -f "$HOME/.config/rclone/rclone.conf" /root/.config/rclone/rclone.conf
fi

echo "[COOLIFY-SYNC] === Initiating Atomic State Dump & B2 Backup ==="

# 1. Check if Coolify DB container is running and dump PostgreSQL
if sudo docker ps --format '{{.Names}}' | grep -q 'coolify-db'; then
  echo "[COOLIFY-SYNC] Dumping PostgreSQL database (coolify-db)..."
  sudo docker exec coolify-db pg_dumpall -U coolify --clean | gzip > "${BACKUP_DIR}/coolify_pg_latest.sql.gz"
  echo "[COOLIFY-SYNC] DB dump complete: $(du -sh ${BACKUP_DIR}/coolify_pg_latest.sql.gz | cut -f1)"
fi

# 2. Check for SQLite databases if any auxiliary services use it
if [ -f "/data/coolify/source/db.sqlite" ]; then
  echo "[COOLIFY-SYNC] Snapshotting SQLite database..."
  sqlite3 "/data/coolify/source/db.sqlite" ".backup '${BACKUP_DIR}/coolify_sqlite_latest.db'" 2>/dev/null || \
    cp -f "/data/coolify/source/db.sqlite" "${BACKUP_DIR}/coolify_sqlite_latest.db"
fi

# 3. Stop containers cleanly to ensure transactional consistency
if [ -f "/data/coolify/source/docker-compose.yml" ]; then
  echo "[COOLIFY-SYNC] Stopping write workloads cleanly..."
  (cd /data/coolify/source && sudo docker compose --env-file .env -f docker-compose.yml -f docker-compose.prod.yml stop -t 10 coolify coolify-db 2>/dev/null || \
   cd /data/coolify/source && sudo docker compose stop -t 10 coolify coolify-db 2>/dev/null || true)
fi

# 4. Stream /data/coolify as a single compressed tarball directly to Backblaze B2
# This preserves Linux file permissions (0600/0700 SSH keys), symlinks, and UIDs.
echo "[COOLIFY-SYNC] Streaming compressed /data/coolify bundle to ${STORAGE_TARGET}/coolify_bundle.tar.gz..."
sudo tar -cpzf - -C /data/coolify \
  --exclude="./proxy/certs" \
  --exclude="./proxy/certs/*" \
  --exclude="*.log" \
  --exclude="*/tmp/*" \
  --exclude="./backups/*" . | rclone rcat "${STORAGE_TARGET}/coolify_bundle.tar.gz"

# 5. Backup standalone PostgreSQL dump for fast recovery
if [ -f "${BACKUP_DIR}/coolify_pg_latest.sql.gz" ]; then
  echo "[COOLIFY-SYNC] Uploading standalone DB dump to B2..."
  rclone copyto "${BACKUP_DIR}/coolify_pg_latest.sql.gz" "${STORAGE_TARGET}/coolify_pg_latest.sql.gz"
fi

# 6. Stream Docker application volumes if any exist
if [ -d "/var/lib/docker/volumes" ]; then
  echo "[COOLIFY-SYNC] Streaming Docker application volumes to ${STORAGE_TARGET}/volumes_bundle.tar.gz..."
  sudo tar -cpzf - -C /var/lib/docker/volumes \
    --exclude="**/metadata.db" . | rclone rcat "${STORAGE_TARGET}/volumes_bundle.tar.gz" 2>/dev/null || true
fi

echo "[COOLIFY-SYNC] Backup to Backblaze B2 complete!"
