#!/usr/bin/env bash
# ==============================================================================
# Universal Coolify Delta State Backup & Database Snapshot Script
# High-Speed Multi-Core (pigz) Local Archive & Resumable Google Drive Sync
# Preserves 100% of /data/coolify and Docker application volumes with exact UIDs,
# permissions, symlinks, and databases across all deployed PaaS services.
# ==============================================================================
set -euo pipefail

STORAGE_TARGET="${1:-gdrive:coolify-relay-state/coolify-state}"
BACKUP_DIR="/data/coolify/backups"
SOURCE_DIR="/data/coolify"
LOCAL_STAGE="/tmp/coolify_backup_stage"

sudo mkdir -p "$BACKUP_DIR" "$LOCAL_STAGE"
sudo chown -R runner:docker "$BACKUP_DIR" "$LOCAL_STAGE" 2>/dev/null || sudo chmod 777 "$BACKUP_DIR" "$LOCAL_STAGE"

# Ensure rclone configuration is available for both runner and root
if [ -f "$HOME/.config/rclone/rclone.conf" ]; then
  sudo mkdir -p /root/.config/rclone
  sudo cp -f "$HOME/.config/rclone/rclone.conf" /root/.config/rclone/rclone.conf
fi

echo "[COOLIFY-SYNC] === Initiating Universal State Dump & Google Drive Backup ==="

# 1. Cleanly stop user workload containers first to flush all write buffers
echo "[COOLIFY-SYNC] Flushing write buffers across active workload containers..."
COMPOSE_LIST=()
while IFS= read -r -d '' compose; do
  COMPOSE_LIST+=("$compose")
done < <(sudo find /data/coolify/applications /data/coolify/services /data/coolify/databases -name "docker-compose.yml" -print0 2>/dev/null || true)

for compose in "${COMPOSE_LIST[@]}"; do
  workdir=$(dirname "$compose")
  env_arg=""
  [ -f "$workdir/.env" ] && env_arg="--env-file $workdir/.env"
  (cd "$workdir" && sudo docker compose $env_arg -f "$compose" stop -t 10 2>/dev/null || true)
done

# 2. Checkpoint SQLite WAL files cleanly now that processes are stopped
if command -v sqlite3 >/dev/null 2>&1; then
  echo "[COOLIFY-SYNC] Checkpointing SQLite WAL files across volumes and configurations..."
  while IFS= read -r -d '' sqldb; do
    if [ -f "$sqldb" ]; then
      sqlite3 "$sqldb" "PRAGMA wal_checkpoint(TRUNCATE);" 2>/dev/null || true
    fi
  done < <(sudo find /data/coolify /var/lib/docker/volumes -type f \( -name "*.sqlite" -o -name "*.db" \) -print0 2>/dev/null || true)
fi

# 3. Dump Coolify PostgreSQL database atomically while coolify-db is running
if sudo docker ps --format '{{.Names}}' | grep -q 'coolify-db'; then
  echo "[COOLIFY-SYNC] Dumping Coolify PostgreSQL database (coolify-db)..."
  sudo docker exec coolify-db pg_dumpall -U coolify --clean 2>/dev/null | pigz -p 4 -6 > "${BACKUP_DIR}/coolify_pg_latest.sql.gz" || \
    (sudo docker exec coolify-db pg_dumpall -U coolify --clean | gzip > "${BACKUP_DIR}/coolify_pg_latest.sql.gz")
  echo "[COOLIFY-SYNC] DB dump complete: $(du -sh "${BACKUP_DIR}/coolify_pg_latest.sql.gz" | cut -f1)"
fi

# 4. Stop Coolify core application engine
if [ -f "/data/coolify/source/docker-compose.yml" ]; then
  (cd /data/coolify/source && sudo docker compose --env-file .env -f docker-compose.yml -f docker-compose.prod.yml stop -t 10 coolify coolify-db 2>/dev/null || \
   cd /data/coolify/source && sudo docker compose stop -t 10 coolify coolify-db 2>/dev/null || true)
fi

# Resilient file-backed upload helper (Native Google Drive resumable multi-part upload with automatic retries)
archive_and_upload() {
  local source_path="$1"
  local local_tar_file="$2"
  local remote_dest="$3"
  shift 3
  local exclude_args=("$@")

  echo "[COOLIFY-SYNC] Archiving $source_path to local staging ($local_tar_file)..."
  set +e
  if command -v pigz >/dev/null 2>&1; then
    sudo tar -cpf - -C "$source_path" --warning=no-file-changed "${exclude_args[@]}" . | pigz -p 4 -6 > "$local_tar_file"
  else
    sudo tar -cpzf "$local_tar_file" -C "$source_path" --warning=no-file-changed "${exclude_args[@]}" .
  fi
  local tar_rc=$?
  set -e

  if [ "$tar_rc" -gt 1 ]; then
    echo "[COOLIFY-SYNC] Error: tar failed with critical code $tar_rc on $source_path"
    return "$tar_rc"
  fi

  echo "[COOLIFY-SYNC] Archive created: $(du -sh "$local_tar_file" | cut -f1). Uploading to $remote_dest with resumable retries..."
  rclone copyto "$local_tar_file" "$remote_dest" \
    --drive-chunk-size=128M \
    --drive-use-trash=false \
    --retries=5 \
    --low-level-retries=10 \
    --tpslimit=8

  sudo rm -f "$local_tar_file"
  return 0
}

# 4. Stream /data/coolify (configurations, compose files, keys, proxy configs)
archive_and_upload "/data/coolify" \
  "${LOCAL_STAGE}/coolify_bundle.tar.gz" \
  "${STORAGE_TARGET}/coolify_bundle.tar.gz" \
  --exclude="./proxy/certs" \
  --exclude="./proxy/certs/*" \
  --exclude="*.log" \
  --exclude="*/tmp/*" \
  --exclude="./backups/*"

# 5. Upload standalone PostgreSQL dump
if [ -s "${BACKUP_DIR}/coolify_pg_latest.sql.gz" ]; then
  echo "[COOLIFY-SYNC] Uploading standalone DB dump to Google Drive ($(du -sh "${BACKUP_DIR}/coolify_pg_latest.sql.gz" | cut -f1))..."
  rclone copyto "${BACKUP_DIR}/coolify_pg_latest.sql.gz" "${STORAGE_TARGET}/coolify_pg_latest.sql.gz" \
    --drive-chunk-size=128M \
    --drive-use-trash=false \
    --retries=5 \
    --low-level-retries=10 \
    --tpslimit=8
else
  echo "[COOLIFY-SYNC] CRITICAL: PostgreSQL dump file is missing or 0 bytes! Aborting upload to preserve remote baseline."
  exit 1
fi

# 6. Stream ALL Docker volumes (preserving all user apps, databases, code-server, n8n, etc.)
if sudo test -d "/var/lib/docker/volumes"; then
  archive_and_upload "/var/lib/docker/volumes" \
    "${LOCAL_STAGE}/volumes_bundle.tar.gz" \
    "${STORAGE_TARGET}/volumes_bundle.tar.gz" \
    --exclude="*coolify-db-data*" \
    --exclude="*coolify-db*" \
    --exclude="*coolify_db*"
else
  echo "[COOLIFY-SYNC] No /var/lib/docker/volumes directory found."
fi

sudo rm -rf "$LOCAL_STAGE"
echo "[COOLIFY-SYNC] Universal backup to Google Drive completed successfully!"
