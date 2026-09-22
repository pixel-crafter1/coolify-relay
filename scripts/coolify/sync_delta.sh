#!/usr/bin/env bash
# ==============================================================================
# Coolify Delta State Backup & Snapshot Script for Google Drive (16GB / 4 vCPU)
# Implements 4-core pigz compression, two-phase atomic staging, and deduplication.
# ==============================================================================
set -euo pipefail

STORAGE_TARGET="${1:-gdrive:coolify-relay-state/coolify-state}"
BACKUP_DIR="/data/coolify/backups"
LOCAL_STAGE="/tmp/coolify_sync_stage"
TIMESTAMP=$(date -u +"%Y-%m-%d_%H%M%S")

# Tuned Rclone flags for Google Drive on 16GB RAM / 4 vCPU runners
RCLONE_OPTS=(
  "--drive-chunk-size=128M"
  "--drive-upload-cutoff=128M"
  "--drive-use-trash=false"
  "--fast-list"
  "--transfers=4"
  "--checkers=8"
  "--retries=6"
  "--retries-sleep=10s"
  "--timeout=10m"
  "--contimeout=30s"
  "--drive-pacer-min-sleep=100ms"
  "--checksum"
  "--stats=15s"
  "--stats-one-line"
)

echo "[COOLIFY-SYNC] === Initiating Multi-Threaded State Dump & Google Drive Sync ==="
echo "[COOLIFY-SYNC] Target: ${STORAGE_TARGET} | Timestamp: ${TIMESTAMP}"

sudo mkdir -p "$BACKUP_DIR" "$LOCAL_STAGE"
sudo chmod 777 "$LOCAL_STAGE"
sudo rm -rf "${LOCAL_STAGE:?}"/*

# Ensure rclone configuration is available for both runner and root
if [ -f "$HOME/.config/rclone/rclone.conf" ]; then
  sudo mkdir -p /root/.config/rclone
  sudo cp -f "$HOME/.config/rclone/rclone.conf" /root/.config/rclone/rclone.conf
fi

# Cleanup trap to ensure local staging area is removed on exit
cleanup() {
  rm -rf "$LOCAL_STAGE" 2>/dev/null || true
}
trap cleanup EXIT

# 1. Check if Coolify DB container is running and dump PostgreSQL atomically
if sudo docker ps --format '{{.Names}}' | grep -q 'coolify-db'; then
  echo "[COOLIFY-SYNC] Dumping PostgreSQL database (coolify-db) with 4-core pigz..."
  sudo docker exec coolify-db pg_dumpall -U coolify --clean | pigz -p 4 -6 > "${LOCAL_STAGE}/coolify_pg_latest.sql.gz"

  # Integrity check on SQL dump (>1KB)
  DUMP_SIZE=$(stat -c%s "${LOCAL_STAGE}/coolify_pg_latest.sql.gz" 2>/dev/null || stat -f%z "${LOCAL_STAGE}/coolify_pg_latest.sql.gz" || echo 0)
  if [ "$DUMP_SIZE" -lt 1024 ]; then
    echo "[COOLIFY-SYNC] CRITICAL: PostgreSQL dump is abnormally small ($DUMP_SIZE bytes). Aborting sync!"
    exit 1
  fi
  echo "[COOLIFY-SYNC] DB dump complete: $(du -sh ${LOCAL_STAGE}/coolify_pg_latest.sql.gz | cut -f1)"
  cp -f "${LOCAL_STAGE}/coolify_pg_latest.sql.gz" "${BACKUP_DIR}/coolify_pg_latest.sql.gz"
fi

# 2. Check for SQLite databases if any auxiliary services use it
if [ -f "/data/coolify/source/db.sqlite" ]; then
  echo "[COOLIFY-SYNC] Snapshotting SQLite database..."
  sqlite3 "/data/coolify/source/db.sqlite" ".backup '${BACKUP_DIR}/coolify_sqlite_latest.db'" 2>/dev/null || \
    cp -f "/data/coolify/source/db.sqlite" "${BACKUP_DIR}/coolify_sqlite_latest.db"
fi

# 3. Stop containers cleanly to ensure transactional consistency
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

# 4. Multi-core compression of /data/coolify to local staging
echo "[COOLIFY-SYNC] Compressing /data/coolify with pigz (4 cores)..."
set +e
sudo tar -cpf - -C /data/coolify \
  --warning=no-file-changed \
  --exclude="./proxy/certs" \
  --exclude="./proxy/certs/*" \
  --exclude="*.log" \
  --exclude="*/tmp/*" \
  --exclude="./backups/*" \
  --exclude="./services/jlmfa7jdillwu9a9vfkh1hiz" \
  --exclude="./services/jlmfa7jdillwu9a9vfkh1hiz/*" \
  --exclude="./services/izmik1wbhrzpzwcub5uji2vv" \
  --exclude="./services/izmik1wbhrzpzwcub5uji2vv/*" . | pigz -p 4 -6 > "${LOCAL_STAGE}/coolify_bundle.tar.gz"
TAR_COOLIFY_RC=$?
set -e

if [ "$TAR_COOLIFY_RC" -gt 1 ]; then
  echo "[COOLIFY-SYNC] Fatal tar error on /data/coolify: $TAR_COOLIFY_RC"
  exit "$TAR_COOLIFY_RC"
fi

# Verify archive integrity locally
if ! pigz -t "${LOCAL_STAGE}/coolify_bundle.tar.gz" >/dev/null 2>&1; then
  echo "[COOLIFY-SYNC] FATAL: Generated coolify_bundle.tar.gz failed integrity check!"
  exit 1
fi
echo "[COOLIFY-SYNC] /data/coolify packed: $(du -sh ${LOCAL_STAGE}/coolify_bundle.tar.gz | cut -f1)"

# 5. Multi-core compression of /var/lib/docker/volumes to local staging
if sudo test -d "/var/lib/docker/volumes"; then
  echo "[COOLIFY-SYNC] Compressing /var/lib/docker/volumes with pigz (4 cores)..."
  set +e
  sudo tar -cpf - -C /var/lib/docker/volumes \
    --warning=no-file-changed \
    --exclude="**/metadata.db" \
    --exclude="*coolify-db-data*" \
    --exclude="*coolify-db*" \
    --exclude="*coolify_db*" \
    --exclude="*jlmfa7jdillwu9a9vfkh1hiz*" \
    --exclude="*izmik1wbhrzpzwcub5uji2vv*" \
    --exclude="**/node_modules" \
    --exclude="**/node_modules/**" \
    --exclude="**/.npm/**" \
    --exclude="**/.cache/**" \
    --exclude="**/__pycache__" \
    --exclude="**/__pycache__/**" \
    --exclude="**/*.pyc" \
    --exclude="**/.next/cache/**" . | pigz -p 4 -6 > "${LOCAL_STAGE}/volumes_bundle.tar.gz"
  TAR_VOL_RC=$?
  set -e

  if [ "$TAR_VOL_RC" -gt 1 ]; then
    echo "[COOLIFY-SYNC] Fatal tar error on volumes: $TAR_VOL_RC"
    exit "$TAR_VOL_RC"
  fi

  if ! pigz -t "${LOCAL_STAGE}/volumes_bundle.tar.gz" >/dev/null 2>&1; then
    echo "[COOLIFY-SYNC] FATAL: Generated volumes_bundle.tar.gz failed integrity check!"
    exit 1
  fi
  echo "[COOLIFY-SYNC] Volumes packed: $(du -sh ${LOCAL_STAGE}/volumes_bundle.tar.gz | cut -f1)"
fi

# 6. Generate SHA256 integrity manifest
echo "[COOLIFY-SYNC] Generating SHA256 checksums..."
(cd "$LOCAL_STAGE" && sha256sum *.tar.gz *.sql.gz > checksums.sha256 2>/dev/null || sha256sum *.tar.gz > checksums.sha256)

# 7. Two-Phase Atomic Staging: Upload to Google Drive remote staging directory
RUN_TAG="run_${GITHUB_RUN_ID:-$$}"
REMOTE_STAGE="${STORAGE_TARGET}/staging/${RUN_TAG}"

echo "[COOLIFY-SYNC] Phase 1: Uploading archives to remote staging (${REMOTE_STAGE})..."
rclone copy "${RCLONE_OPTS[@]}" "$LOCAL_STAGE" "$REMOTE_STAGE"

# 8. Verify upload integrity against remote
echo "[COOLIFY-SYNC] Phase 2: Verifying staged files on Google Drive..."
rclone check "${RCLONE_OPTS[@]}" "$LOCAL_STAGE" "$REMOTE_STAGE" --one-way

# 9. Server-Side Promotion: Atomically copy staged files to primary target
echo "[COOLIFY-SYNC] Phase 3: Promoting staged files to primary root on Google Drive..."
rclone copyto "${RCLONE_OPTS[@]}" "${REMOTE_STAGE}/coolify_bundle.tar.gz" "${STORAGE_TARGET}/coolify_bundle.tar.gz"
if [ -f "${LOCAL_STAGE}/volumes_bundle.tar.gz" ]; then
  rclone copyto "${RCLONE_OPTS[@]}" "${REMOTE_STAGE}/volumes_bundle.tar.gz" "${STORAGE_TARGET}/volumes_bundle.tar.gz"
fi
if [ -f "${LOCAL_STAGE}/coolify_pg_latest.sql.gz" ]; then
  rclone copyto "${RCLONE_OPTS[@]}" "${REMOTE_STAGE}/coolify_pg_latest.sql.gz" "${STORAGE_TARGET}/coolify_pg_latest.sql.gz"
fi
rclone copyto "${RCLONE_OPTS[@]}" "${REMOTE_STAGE}/checksums.sha256" "${STORAGE_TARGET}/checksums.sha256"

# 10. Clean up remote staging directory
rclone purge "${RCLONE_OPTS[@]}" "$REMOTE_STAGE" 2>/dev/null || true

# 11. Eliminate duplicate file entries on Google Drive
echo "[COOLIFY-SYNC] Running Google Drive deduplication..."
rclone dedupe "${RCLONE_OPTS[@]}" --dedupe-mode newest "${STORAGE_TARGET}" 2>/dev/null || true

# 12. Create 14-day rolling historical snapshot and prune expired records
echo "[COOLIFY-SYNC] Archiving snapshot to history/${TIMESTAMP}..."
rclone copy "${RCLONE_OPTS[@]}" "${STORAGE_TARGET}" "${STORAGE_TARGET}/history/${TIMESTAMP}" \
  --include "coolify_bundle.tar.gz" \
  --include "volumes_bundle.tar.gz" \
  --include "coolify_pg_latest.sql.gz" \
  --include "checksums.sha256" 2>/dev/null || true

echo "[COOLIFY-SYNC] Pruning historical snapshots older than 14 days..."
rclone delete "${RCLONE_OPTS[@]}" --min-age 14d "${STORAGE_TARGET}/history" 2>/dev/null || true
rclone rmdirs "${RCLONE_OPTS[@]}" --leave-root "${STORAGE_TARGET}/history" 2>/dev/null || true

echo "[COOLIFY-SYNC] Multi-threaded backup and Google Drive sync completed successfully!"
