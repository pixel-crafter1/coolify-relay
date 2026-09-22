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

# 1. Check if Coolify DB container is running and dump PostgreSQL atomically
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
# Pause/stop all active user containers so SQLite, JSON, chat histories, and file locks flush cleanly to disk
echo "[COOLIFY-SYNC] Flushing and stopping active workloads cleanly..."
for compose in $(find /data/coolify/applications /data/coolify/services -name "docker-compose.yml" 2>/dev/null || true); do
  workdir=$(dirname "$compose")
  env_arg=""
  [ -f "$workdir/.env" ] && env_arg="--env-file $workdir/.env"
  (cd "$workdir" && sudo docker compose $env_arg -f "$compose" stop -t 5 2>/dev/null || true)
done

if [ -f "/data/coolify/source/docker-compose.yml" ]; then
  (cd /data/coolify/source && sudo docker compose --env-file .env -f docker-compose.yml -f docker-compose.prod.yml stop -t 10 coolify coolify-db 2>/dev/null || \
   cd /data/coolify/source && sudo docker compose stop -t 10 coolify coolify-db 2>/dev/null || true)
fi

# Robust tar-to-rclone streaming helper:
# In Linux, tar returns exit code 1 if a file changed/was read while archiving (harmless warning).
# Under 'set -e' and 'pipefail', exit code 1 terminates the entire script.
# This function permits exit code 0 and 1, but strictly errors on exit code >= 2 (fatal tar errors)
# or when rclone itself fails.
stream_tar_to_storage() {
  local source_path="$1"
  local remote_dest="$2"
  shift 2
  local exclude_args=("$@")

  set +e
  sudo tar -cpzf - -C "$source_path" --warning=no-file-changed "${exclude_args[@]}" . | rclone rcat "$remote_dest"
  local p_status=("${PIPESTATUS[@]}")
  set -e

  local tar_rc="${p_status[0]:-0}"
  local rclone_rc="${p_status[1]:-0}"

  if [ "$tar_rc" -gt 1 ]; then
    echo "[COOLIFY-SYNC] Error: tar failed with critical code $tar_rc on $source_path"
    return "$tar_rc"
  fi
  if [ "$rclone_rc" -ne 0 ]; then
    echo "[COOLIFY-SYNC] Error: rclone rcat failed with code $rclone_rc to $remote_dest"
    return "$rclone_rc"
  fi
  return 0
}

# 4. Stream /data/coolify as a single compressed tarball directly to Backblaze B2
# Preserves Linux file permissions (0600/0700 SSH keys), symlinks, and UIDs.
echo "[COOLIFY-SYNC] Streaming compressed /data/coolify bundle to ${STORAGE_TARGET}/coolify_bundle.tar.gz..."
stream_tar_to_storage "/data/coolify" "${STORAGE_TARGET}/coolify_bundle.tar.gz" \
  --exclude="./proxy/certs" \
  --exclude="./proxy/certs/*" \
  --exclude="*.log" \
  --exclude="*/tmp/*" \
  --exclude="./backups/*" \
  --exclude="./services/jlmfa7jdillwu9a9vfkh1hiz" \
  --exclude="./services/jlmfa7jdillwu9a9vfkh1hiz/*"

# 5. Backup standalone PostgreSQL dump for fast recovery
if [ -f "${BACKUP_DIR}/coolify_pg_latest.sql.gz" ]; then
  echo "[COOLIFY-SYNC] Uploading standalone DB dump to B2..."
  rclone copyto "${BACKUP_DIR}/coolify_pg_latest.sql.gz" "${STORAGE_TARGET}/coolify_pg_latest.sql.gz"
fi

# 6. Stream Docker application volumes if any exist (excluding coolify-db raw files to prevent double-restore conflicts & bloat)
if sudo test -d "/var/lib/docker/volumes"; then
  echo "[COOLIFY-SYNC] Streaming Docker application volumes to ${STORAGE_TARGET}/volumes_bundle.tar.gz..."
  stream_tar_to_storage "/var/lib/docker/volumes" "${STORAGE_TARGET}/volumes_bundle.tar.gz" \
    --exclude="**/metadata.db" \
    --exclude="*coolify-db-data*" \
    --exclude="*coolify-db*" \
    --exclude="*coolify_db*" \
    --exclude="*jlmfa7jdillwu9a9vfkh1hiz*"
else
  echo "[COOLIFY-SYNC] No /var/lib/docker/volumes directory found."
fi

echo "[COOLIFY-SYNC] Backup to Backblaze B2 complete!"
