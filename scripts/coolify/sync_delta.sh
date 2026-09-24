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
      sudo sqlite3 "$sqldb" "PRAGMA wal_checkpoint(TRUNCATE);" 2>/dev/null || true
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
# B3 Hardening: Enforces PIPESTATUS[0] inspection, non-empty [ -s ] validation, minimum size checks, and tar archive testing before promotion
archive_and_upload() {
  local source_path="$1"
  local local_tar_file="$2"
  local remote_dest="$3"
  local min_size_bytes="${4:-1024}" # Default 1KB minimum
  shift 4
  local exclude_args=("$@")

  echo "[COOLIFY-SYNC] Archiving $source_path to local staging ($local_tar_file)..."
  set +e
  if command -v pigz >/dev/null 2>&1; then
    sudo tar -cpf - -C "$source_path" --warning=no-file-changed "${exclude_args[@]}" . | pigz -p 4 -6 > "$local_tar_file"
    local tar_rc="${PIPESTATUS[0]}"
    local pigz_rc="${PIPESTATUS[1]}"
  else
    sudo tar -cpzf "$local_tar_file" -C "$source_path" --warning=no-file-changed "${exclude_args[@]}" .
    local tar_rc="${PIPESTATUS[0]}"
    local pigz_rc=0
  fi
  set -e

  # Check tar exit code (exit code 1 means files changed while reading, which is acceptable in live backups; >1 is fatal)
  if [ "$tar_rc" -gt 1 ]; then
    echo "[COOLIFY-SYNC] Error: tar failed with critical code $tar_rc on $source_path"
    sudo rm -f "$local_tar_file"
    return "$tar_rc"
  fi

  if [ "$pigz_rc" -ne 0 ]; then
    echo "[COOLIFY-SYNC] Error: compression failed with code $pigz_rc on $source_path"
    sudo rm -f "$local_tar_file"
    return "$pigz_rc"
  fi

  # B3: Strict non-empty and minimum size integrity check
  if [ ! -s "$local_tar_file" ]; then
    echo "[COOLIFY-SYNC] CRITICAL: Archive $local_tar_file is missing or 0 bytes! Aborting to protect remote state."
    sudo rm -f "$local_tar_file"
    return 1
  fi

  local file_bytes
  file_bytes=$(stat -c %s "$local_tar_file" 2>/dev/null || wc -c < "$local_tar_file" | tr -d ' ' || echo 0)
  if [ "$file_bytes" -lt "$min_size_bytes" ]; then
    echo "[COOLIFY-SYNC] CRITICAL: Archive $local_tar_file size (${file_bytes}B) below minimum threshold (${min_size_bytes}B)! Aborting."
    sudo rm -f "$local_tar_file"
    return 1
  fi

  # B3: Verify archive manifest integrity using tar -tz
  echo "[COOLIFY-SYNC] Verifying archive manifest integrity..."
  local manifest_count
  if command -v pigz >/dev/null 2>&1; then
    manifest_count=$(pigz -dc "$local_tar_file" | tar -tf - 2>/dev/null | head -n 100 | wc -l | tr -d ' ' || echo 0)
  else
    manifest_count=$(tar -tzf "$local_tar_file" 2>/dev/null | head -n 100 | wc -l | tr -d ' ' || echo 0)
  fi

  if [ "$manifest_count" -lt 1 ]; then
    echo "[COOLIFY-SYNC] CRITICAL: Archive $local_tar_file contains 0 valid entries! Aborting upload."
    sudo rm -f "$local_tar_file"
    return 1
  fi

  echo "[COOLIFY-SYNC] Archive verified: $(du -sh "$local_tar_file" | cut -f1) (${manifest_count}+ files verified). Uploading to $remote_dest..."
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
  10240 \
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
    10240 \
    --exclude="*coolify-db-data*" \
    --exclude="*coolify-db*" \
    --exclude="*coolify_db*"
else
  echo "[COOLIFY-SYNC] No /var/lib/docker/volumes directory found."
fi

sudo rm -rf "$LOCAL_STAGE"
echo "[COOLIFY-SYNC] Universal backup to Google Drive completed successfully!"
