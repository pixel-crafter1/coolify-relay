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

# 0. Active Disk Reclamation & Scratch Space Purge (Audit Hardened)
echo "[COOLIFY-SYNC] Reclaiming disk space and purging scratch / dustbin directories..."
# Dotfile-inclusive deletion, preserves mountpoint, no symlink escape, no filesystem crossing (-xdev)
sudo find /tmp/dustbin /tmp/scratch -xdev -mindepth 1 -delete 2>/dev/null || true
sudo find /tmp -maxdepth 1 \( -name "*.tmp" -o -name "*.log" \) -delete 2>/dev/null || true
# Truncate running container logs under root subshell to ensure proper wildcard expansion
sudo sh -c 'truncate -s 0 /var/lib/docker/containers/*/*-json.log' 2>/dev/null || true
sudo journalctl --vacuum-size=100M 2>/dev/null || true
# Audit Fix (B-NEW-1): Purge contents only, never delete the directory itself
sudo find "$LOCAL_STAGE" -mindepth 1 -delete 2>/dev/null || true
sudo mkdir -p "$LOCAL_STAGE" 2>/dev/null || true
if command -v docker >/dev/null 2>&1; then
  # Prune dangling/unused images and build cache without deleting named volumes
  sudo docker image prune -af 2>/dev/null || true
  sudo docker builder prune -af 2>/dev/null || true
fi

# Print available disk space before dumping databases
echo "[COOLIFY-SYNC] Runner disk status before backup:"
df -h / | tail -n 1

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
    if sudo test -f "$sqldb"; then
      sudo sqlite3 "$sqldb" "PRAGMA wal_checkpoint(TRUNCATE);" 2>/dev/null || true
    fi
  done < <(sudo find /data/coolify /var/lib/docker/volumes -type f \( -name "*.sqlite" -o -name "*.db" \) -print0 2>/dev/null || true)
fi

# 3. Dump Coolify PostgreSQL database atomically while coolify-db is running
RUNNING_DB=$(sudo docker ps --format '{{.Names}}' 2>/dev/null || true)
if printf '%s\n' "$RUNNING_DB" | grep -qx 'coolify-db'; then
  echo "[COOLIFY-SYNC] Dumping Coolify PostgreSQL database (coolify-db)..."
  set +e
  local_pg_dump="${BACKUP_DIR}/coolify_pg_latest.sql.gz"
  local_pg_partial="${local_pg_dump}.partial"
  sudo rm -f "$local_pg_partial"
  local_pg_err="${BACKUP_DIR}/coolify_pg_dump.err"

  if command -v pigz >/dev/null 2>&1; then
    sudo docker exec coolify-db pg_dumpall -U coolify --clean --if-exists 2>"$local_pg_err" | pigz -p 4 -1 > "$local_pg_partial"
    ps=("${PIPESTATUS[@]}")
  else
    sudo docker exec coolify-db pg_dumpall -U coolify --clean --if-exists 2>"$local_pg_err" | gzip > "$local_pg_partial"
    ps=("${PIPESTATUS[@]}")
  fi
  set -e

  pg_rc="${ps[0]:-0}"
  comp_rc="${ps[1]:-0}"

  if [ "$pg_rc" -ne 0 ] || [ "$comp_rc" -ne 0 ]; then
    echo "[COOLIFY-SYNC] CRITICAL: pg_dumpall failed (pg_rc=$pg_rc, comp_rc=$comp_rc)! Stderr:"
    sudo cat "$local_pg_err" 2>/dev/null || true
    sudo rm -f "$local_pg_partial" "$local_pg_err"
    exit 1
  fi
  sudo rm -f "$local_pg_err"

  # Audit Hardening: verify minimum 1KB floor, gzip integrity, and end-of-dump sentinel
  local_pg_bytes=$(stat -c %s "$local_pg_partial" 2>/dev/null || wc -c < "$local_pg_partial" | tr -d ' ' || echo 0)
  if [ "$local_pg_bytes" -lt 1024 ]; then
    echo "[COOLIFY-SYNC] CRITICAL: PostgreSQL dump size (${local_pg_bytes}B) below 1KB threshold! Aborting."
    sudo rm -f "$local_pg_partial"
    exit 1
  fi

  if ! gzip -t "$local_pg_partial" 2>/dev/null; then
    echo "[COOLIFY-SYNC] CRITICAL: PostgreSQL dump archive failed gzip -t integrity test! Aborting."
    sudo rm -f "$local_pg_partial"
    exit 1
  fi

  # Validate completion sentinel at end of uncompressed stream
  if ! (pigz -dc "$local_pg_partial" 2>/dev/null || gzip -dc "$local_pg_partial" 2>/dev/null) | tail -c 1024 | grep -q 'PostgreSQL database dump complete'; then
    echo "[COOLIFY-SYNC] CRITICAL: Missing 'PostgreSQL database dump complete' sentinel! Dump was truncated. Aborting."
    sudo rm -f "$local_pg_partial"
    exit 1
  fi

  # Promote partial to final after verified integrity
  sudo mv -f "$local_pg_partial" "$local_pg_dump"
  echo "[COOLIFY-SYNC] DB dump verified intact with valid completion sentinel: $(du -sh "$local_pg_dump" | cut -f1)"
fi

# 4. Stop Coolify core application engine
# Use direct docker stop first to bypass any compose file validation errors (e.g. invalid service definitions like soketi)
sudo docker stop -t 10 coolify coolify-db 2>/dev/null || true
if [ -f "/data/coolify/source/docker-compose.yml" ]; then
  (cd /data/coolify/source && sudo docker compose --env-file .env -f docker-compose.yml -f docker-compose.prod.yml stop -t 10 coolify coolify-db 2>/dev/null || \
   cd /data/coolify/source && sudo docker compose stop -t 10 coolify coolify-db 2>/dev/null || true)
fi

# Audit Hardening (M-3): Fail-closed container stop assertion to prevent split-brain behind shared tunnel
STILL_RUNNING=$(sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^(coolify|coolify-db)$' || true)
if [ -n "$STILL_RUNNING" ]; then
  echo "[COOLIFY-SYNC] CRITICAL: Failed to stop core engine containers: $STILL_RUNNING! Attempting recovery before abort."
  sudo docker start coolify coolify-db 2>/dev/null || true
  exit 1
fi
echo "[COOLIFY-SYNC] Core Coolify engine containers successfully stopped."

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
  local tar_err="${local_tar_file}.tar.err"
  set +e
  local tar_rc=0
  local pigz_rc=0
  if command -v pigz >/dev/null 2>&1; then
    sudo tar -cpf - -C "$source_path" --warning=no-file-changed "${exclude_args[@]}" . 2>"$tar_err" | pigz -p 4 -1 > "$local_tar_file"
    local ps=("${PIPESTATUS[@]}")
    tar_rc="${ps[0]:-0}"
    pigz_rc="${ps[1]:-0}"
  else
    sudo tar -cpzf "$local_tar_file" -C "$source_path" --warning=no-file-changed "${exclude_args[@]}" . 2>"$tar_err"
    local ps=("${PIPESTATUS[@]}")
    tar_rc="${ps[0]:-0}"
    pigz_rc=0
  fi
  set -e

  # Audit Hardening (S-1 / C2): Inspect tar stderr. Reject on disk exhaustion, I/O errors, unreadable files, or short writes
  if [ -s "$tar_err" ]; then
    if grep -Ei "No space left on device|Input/output error|Cannot open|Cannot stat|Cannot read|Wrote only|short write|Cannot allocate memory|Error is not recoverable" "$tar_err" >/dev/null 2>&1; then
      echo "[COOLIFY-SYNC] CRITICAL: Fatal I/O or permission error in tar stderr! Details:"
      cat "$tar_err"
      sudo rm -f "$local_tar_file" "$tar_err"
      return 1
    fi
  fi
  sudo rm -f "$tar_err"

  # Audit Hardening (C2): Because --warning=no-file-changed suppresses benign file modification warnings,
  # any non-zero exit code from tar is an indicator of missing/corrupt files. Treat tar_rc != 0 as fatal.
  if [ "$tar_rc" -ne 0 ]; then
    echo "[COOLIFY-SYNC] CRITICAL: tar returned non-zero code $tar_rc on $source_path! Aborting archive."
    sudo rm -f "$local_tar_file"
    return "$tar_rc"
  fi

  if [ "$pigz_rc" -ne 0 ]; then
    echo "[COOLIFY-SYNC] CRITICAL: compression failed with code $pigz_rc on $source_path"
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

  # Audit Hardening (C2 / R6-1): Full manifest stream inspection
  echo "[COOLIFY-SYNC] Verifying archive manifest integrity..."
  local manifest_count=0
  if command -v pigz >/dev/null 2>&1; then
    manifest_count=$(pigz -dc "$local_tar_file" 2>/dev/null | tar -tf - 2>/dev/null | wc -l || echo 0)
  else
    manifest_count=$(tar -tzf "$local_tar_file" 2>/dev/null | wc -l || echo 0)
  fi
  manifest_count=$(echo "$manifest_count" | tr -dc '0-9')
  manifest_count="${manifest_count:-0}"

  if [ "$manifest_count" -lt 1 ]; then
    echo "[COOLIFY-SYNC] CRITICAL: Archive $local_tar_file contains 0 valid entries! Aborting upload."
    sudo rm -f "$local_tar_file"
    return 1
  fi

  # Audit Hardening (R6-1 / FIX-1 / R7-1): For Docker volumes, assert 100% membership of all on-disk active volumes in archive manifest
  local norm_source="${source_path%/}"
  if [ "$norm_source" = "/var/lib/docker/volumes" ]; then
    echo "[COOLIFY-SYNC] Performing per-volume manifest catalog membership verification on $norm_source..."
    local excluded_pg="${PG_VOL_NAME:-coolify-db-data}"
    local on_disk_vols=()
    while IFS= read -r v; do
      [ -n "$v" ] && on_disk_vols+=("$v")
    done < <(sudo find "$norm_source" -mindepth 1 -maxdepth 1 -type d ! -name "$excluded_pg" 2>/dev/null | xargs -r -n1 basename | sort -u)

    if [ ${#on_disk_vols[@]} -gt 0 ]; then
      local manifest_top_levels
      if command -v pigz >/dev/null 2>&1; then
        manifest_top_levels=$(pigz -dc "$local_tar_file" 2>/dev/null | tar -tf - 2>/dev/null | sed -E 's|^\./||; s|/.*||' | sort -u)
      else
        manifest_top_levels=$(tar -tzf "$local_tar_file" 2>/dev/null | sed -E 's|^\./||; s|/.*||' | sort -u)
      fi

      local missing_vols=()
      for d_vol in "${on_disk_vols[@]}"; do
        if ! printf '%s\n' "$manifest_top_levels" | grep -qx "$d_vol"; then
          missing_vols+=("$d_vol")
        fi
      done

      if [ ${#missing_vols[@]} -gt 0 ]; then
        echo "[COOLIFY-SYNC] CRITICAL: Archive is missing ${#missing_vols[@]} active volume(s) present on disk: ${missing_vols[*]}!"
        echo "[COOLIFY-SYNC] Aborting upload to prevent blank volume overwrite on successor."
        sudo rm -f "$local_tar_file"
        return 1
      fi
      echo "[COOLIFY-SYNC] Per-volume catalog verified: all ${#on_disk_vols[@]} active volume(s) present in archive manifest."
    fi
  else
    echo "[COOLIFY-SYNC] Skipping per-volume catalog check for non-volumes path: $source_path"
  fi

  # Audit Hardening (R6-3): Atomic promotion via .partial upload and rclone moveto
  echo "[COOLIFY-SYNC] Archive verified: $(du -sh "$local_tar_file" | cut -f1) (${manifest_count} files verified). Uploading to ${remote_dest}.partial..."
  rclone copyto "$local_tar_file" "${remote_dest}.partial" \
    --drive-chunk-size=512M \
    --drive-upload-cutoff=32M \
    --drive-pacer-min-sleep=10ms \
    --buffer-size=64M \
    --use-mmap \
    --drive-use-trash=false \
    --retries=5 \
    --low-level-retries=10 \
    --timeout=3m

  echo "[COOLIFY-SYNC] Promoting ${remote_dest}.partial to final $remote_dest..."
  rclone moveto "${remote_dest}.partial" "$remote_dest" \
    --drive-use-trash=false \
    --retries=5 \
    --low-level-retries=10 \
    --timeout=3m

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

# 5. Upload standalone PostgreSQL dump (R6-3: Atomic Promotion, R9-6: Resilient moveto)
if [ -s "${BACKUP_DIR}/coolify_pg_latest.sql.gz" ]; then
  echo "[COOLIFY-SYNC] Uploading standalone DB dump to Google Drive ($(du -sh "${BACKUP_DIR}/coolify_pg_latest.sql.gz" | cut -f1))..."
  rclone copyto "${BACKUP_DIR}/coolify_pg_latest.sql.gz" "${STORAGE_TARGET}/coolify_pg_latest.sql.gz.partial" \
    --drive-chunk-size=512M \
    --drive-upload-cutoff=32M \
    --drive-pacer-min-sleep=10ms \
    --buffer-size=64M \
    --use-mmap \
    --drive-use-trash=false \
    --retries=5 \
    --low-level-retries=10 \
    --timeout=3m

  rclone moveto "${STORAGE_TARGET}/coolify_pg_latest.sql.gz.partial" "${STORAGE_TARGET}/coolify_pg_latest.sql.gz" \
    --drive-use-trash=false \
    --retries=5 \
    --low-level-retries=10 \
    --timeout=3m
else
  echo "[COOLIFY-SYNC] CRITICAL: PostgreSQL dump file is missing or 0 bytes! Aborting upload to preserve remote baseline."
  exit 1
fi

# 6. Stream ALL Docker volumes (preserving all user apps, databases, code-server, n8n, etc.)
if sudo test -d "/var/lib/docker/volumes"; then
  # Audit Hardening: Exclude only the exact Coolify database volume, not arbitrary user volumes
  PG_VOL_NAME=$(sudo docker inspect coolify-db --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Name}}{{end}}{{end}}' 2>/dev/null || true)
  PG_VOL_NAME="${PG_VOL_NAME:-coolify-db-data}"

  archive_and_upload "/var/lib/docker/volumes" \
    "${LOCAL_STAGE}/volumes_bundle.tar.gz" \
    "${STORAGE_TARGET}/volumes_bundle.tar.gz" \
    10240 \
    --exclude="./${PG_VOL_NAME}" \
    --exclude="./${PG_VOL_NAME}/*"
else
  echo "[COOLIFY-SYNC] No /var/lib/docker/volumes directory found."
fi

sudo rm -rf "$LOCAL_STAGE"
echo "[COOLIFY-SYNC] Universal backup to Google Drive completed successfully!"
