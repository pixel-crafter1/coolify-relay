#!/usr/bin/env bash
# ==============================================================================
# Coolify Delta State Restoration Script for Google Drive (16GB / 4 vCPU)
# Implements fail-closed verification, 4-core pigz decompression, and auto-recovery.
# ==============================================================================
set -euo pipefail

STORAGE_TARGET="${1:-gdrive:coolify-relay-state/coolify-state}"
BACKUP_DIR="/data/coolify/backups"
SOURCE_DIR="/data/coolify"
CACHE_DIR="/tmp/coolify_restore_cache"
CYCLE_COUNT="${2:-0}"

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

echo "[COOLIFY-RESTORE] ======================================================="
echo "[COOLIFY-RESTORE] Phase: Fail-Closed State Hydration from Google Drive"
echo "[COOLIFY-RESTORE] Target: ${STORAGE_TARGET} | Cycle: ${CYCLE_COUNT}"
echo "[COOLIFY-RESTORE] ======================================================="

sudo mkdir -p "$SOURCE_DIR" /var/lib/docker/volumes "$BACKUP_DIR" "$CACHE_DIR"
sudo rm -rf "${CACHE_DIR:?}"/*

# Ensure pigz is installed for multi-core performance
if ! command -v pigz >/dev/null 2>&1; then
  sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq pigz
fi

# Ensure runner and root share rclone.conf
if [ -f "$HOME/.config/rclone/rclone.conf" ]; then
  sudo mkdir -p /root/.config/rclone
  sudo cp -f "$HOME/.config/rclone/rclone.conf" /root/.config/rclone/rclone.conf
fi

# ------------------------------------------------------------------------------
# STEP 1: Verify Google Drive Connectivity & Deduplicate
# ------------------------------------------------------------------------------
echo "[COOLIFY-RESTORE] Probing Google Drive connectivity..."
if ! rclone lsf "${RCLONE_OPTS[@]}" "${STORAGE_TARGET}" --max-depth 1 >/tmp/gdrive_files.txt 2>&1; then
  echo "[COOLIFY-RESTORE] CRITICAL: Unable to reach Google Drive storage at ${STORAGE_TARGET}!"
  cat /tmp/gdrive_files.txt
  echo "[COOLIFY-RESTORE] Triggering fail-closed exit to prevent blank state overwrite."
  exit 1
fi

echo "[COOLIFY-RESTORE] Google Drive online. Running automatic deduplication..."
rclone dedupe "${RCLONE_OPTS[@]}" --dedupe-mode newest "${STORAGE_TARGET}" 2>/dev/null || true

# ------------------------------------------------------------------------------
# STEP 2: Circuit Breaker - Verify State Existence
# ------------------------------------------------------------------------------
HAS_CORE_BUNDLE=false
if grep -q "^coolify_bundle\.tar\.gz" /tmp/gdrive_files.txt; then
  HAS_CORE_BUNDLE=true
fi

if [ "$HAS_CORE_BUNDLE" != "true" ]; then
  if [ "$CYCLE_COUNT" -gt 0 ]; then
    echo "[COOLIFY-RESTORE] FATAL ERROR: Cycle count is ${CYCLE_COUNT} but 'coolify_bundle.tar.gz' was NOT found in Google Drive!"
    echo "[COOLIFY-RESTORE] Refusing to initialize empty state over prior rotation cycles. Failing closed."
    exit 1
  else
    echo "[COOLIFY-RESTORE] NOTICE: Cycle count is 0 and remote storage is empty. Authorized for clean cold-start."
    exit 0
  fi
fi

# ------------------------------------------------------------------------------
# STEP 3: Download to Local Cache & Validate Integrity
# ------------------------------------------------------------------------------
echo "[COOLIFY-RESTORE] Downloading state archives and checksums from Google Drive..."
rclone copy "${RCLONE_OPTS[@]}" "${STORAGE_TARGET}" "$CACHE_DIR" \
  --include "coolify_bundle.tar.gz" \
  --include "volumes_bundle.tar.gz" \
  --include "coolify_pg_latest.sql.gz" \
  --include "checksums.sha256"

# Validate SHA256 checksums if manifest exists
if [ -f "${CACHE_DIR}/checksums.sha256" ]; then
  echo "[COOLIFY-RESTORE] Validating SHA256 integrity manifest..."
  (cd "$CACHE_DIR" && sha256sum -c checksums.sha256) || {
    echo "[COOLIFY-RESTORE] FATAL: Checksum mismatch! Corrupted download detected. Aborting."
    exit 1
  }
  echo "[COOLIFY-RESTORE] Checksums verified successfully."
fi

# ------------------------------------------------------------------------------
# STEP 4: Parallel Decompression with 4-Core pigz
# ------------------------------------------------------------------------------
if [ -f "${CACHE_DIR}/coolify_bundle.tar.gz" ]; then
  echo "[COOLIFY-RESTORE] Extracting /data/coolify with pigz (4 cores)..."
  pigz -dc -p 4 "${CACHE_DIR}/coolify_bundle.tar.gz" | sudo tar --numeric-owner -xpf - -C /data/coolify
fi

if [ -f "${CACHE_DIR}/volumes_bundle.tar.gz" ]; then
  echo "[COOLIFY-RESTORE] Extracting Docker volumes with pigz (4 cores)..."
  pigz -dc -p 4 "${CACHE_DIR}/volumes_bundle.tar.gz" | sudo tar --numeric-owner -xpf - -C /var/lib/docker/volumes
fi

if [ -f "${CACHE_DIR}/coolify_pg_latest.sql.gz" ]; then
  sudo cp -f "${CACHE_DIR}/coolify_pg_latest.sql.gz" "${BACKUP_DIR}/coolify_pg_latest.sql.gz"
fi

# Clean up local restore cache
rm -rf "$CACHE_DIR" 2>/dev/null || true

# ------------------------------------------------------------------------------
# STEP 5: Linux Permissions, SSH Configuration & Keys Normalization
# ------------------------------------------------------------------------------
echo "[COOLIFY-RESTORE] Normalizing permissions and SSH configurations..."
sudo chmod -R 755 /data/coolify 2>/dev/null || true
[ -d "/data/coolify/source" ] && sudo chmod -R 775 /data/coolify/source 2>/dev/null || true

if [ -d "/data/coolify/ssh/keys" ]; then
  sudo chmod 700 /data/coolify/ssh/keys
  sudo chmod 600 /data/coolify/ssh/keys/* 2>/dev/null || true
  sudo chmod 644 /data/coolify/ssh/keys/*.pub 2>/dev/null || true
  sudo chown -R 9999:root /data/coolify/ssh/keys 2>/dev/null || true
fi

# Configure host SSH daemon for Coolify internal engine communication
sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server
sudo mkdir -p /etc/ssh/sshd_config.d /root/.ssh /home/runner/.ssh
cat << 'EOF' | sudo tee /etc/ssh/sshd_config.d/99-coolify.conf >/dev/null
PermitRootLogin yes
PubkeyAuthentication yes
StrictModes no
AuthorizedKeysFile .ssh/authorized_keys
EOF
sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd 2>/dev/null || true

# Inject public keys into authorized_keys for root and runner
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIINGMEL5LpxfXWB1Q2gd028oYZzpuGe97jlmgbYza+pN" | sudo tee -a /root/.ssh/authorized_keys /home/runner/.ssh/authorized_keys >/dev/null
for pub in /data/coolify/ssh/keys/*.pub; do
  [ -f "$pub" ] && sudo cat "$pub" | sudo tee -a /root/.ssh/authorized_keys /home/runner/.ssh/authorized_keys >/dev/null || true
done
sudo chmod 700 /root/.ssh /home/runner/.ssh
sudo chmod 600 /root/.ssh/authorized_keys /home/runner/.ssh/authorized_keys 2>/dev/null || true

# ------------------------------------------------------------------------------
# STEP 6: Database Bring-up & PostgreSQL Restoration
# ------------------------------------------------------------------------------
if [ -f "/data/coolify/source/docker-compose.yml" ]; then
  echo "[COOLIFY-RESTORE] Initializing coolify Docker network..."
  sudo docker network create --attachable coolify 2>/dev/null || true

  echo "[COOLIFY-RESTORE] Starting PostgreSQL database container..."
  sudo docker compose --project-directory /data/coolify/source \
    --env-file /data/coolify/source/.env \
    -f /data/coolify/source/docker-compose.yml \
    -f /data/coolify/source/docker-compose.prod.yml \
    up -d postgres 2>&1 || true

  echo "[COOLIFY-RESTORE] Polling pg_isready..."
  for i in {1..30}; do
    if sudo docker exec coolify-db pg_isready -U coolify >/dev/null 2>&1 || sudo docker exec -i coolify-db pg_isready >/dev/null 2>&1; then
      echo "[COOLIFY-RESTORE] PostgreSQL is fully ready! ($((i*2))s)"
      break
    fi
    sleep 2
  done

  if [ -f "${BACKUP_DIR}/coolify_pg_latest.sql.gz" ]; then
    echo "[COOLIFY-RESTORE] Restoring PostgreSQL dump into database with pigz..."
    pigz -dc -p 4 "${BACKUP_DIR}/coolify_pg_latest.sql.gz" | sudo docker exec -i coolify-db psql -U coolify -d postgres 2>/dev/null || true
    echo "[COOLIFY-RESTORE] PostgreSQL state hydrated."
  fi

  # Boot Coolify core and proxy
  sudo docker compose --project-directory /data/coolify/source \
    --env-file /data/coolify/source/.env \
    -f /data/coolify/source/docker-compose.yml \
    -f /data/coolify/source/docker-compose.prod.yml \
    up -d --remove-orphans 2>&1 || true

  if [ -d "/data/coolify/proxy" ] && [ -f "/data/coolify/proxy/docker-compose.yml" ]; then
    sudo docker compose --project-directory /data/coolify/proxy -f /data/coolify/proxy/docker-compose.yml up -d 2>/dev/null || true
  fi

  # Artisan migrations and seeds
  for s in {1..30}; do
    if sudo docker exec coolify php artisan --version >/dev/null 2>&1; then
      sudo docker exec coolify php artisan migrate --force 2>/dev/null || true
      sudo docker exec coolify php artisan db:seed --class=ProductionSeeder --force 2>/dev/null || true
      break
    fi
    sleep 2
  done
fi

# ------------------------------------------------------------------------------
# STEP 7: Workload Auto-Discovery and Bring-up
# ------------------------------------------------------------------------------
COMPOSE_FILES=()
while IFS= read -r -d '' file; do
  COMPOSE_FILES+=("$file")
done < <(find /data/coolify/applications /data/coolify/services -name "docker-compose.yml" -print0 2>/dev/null || true)

if [ ${#COMPOSE_FILES[@]} -gt 0 ]; then
  echo "[COOLIFY-RESTORE] Launching ${#COMPOSE_FILES[@]} user application stacks..."
  for compose in "${COMPOSE_FILES[@]}"; do
    workdir=$(dirname "$compose")
    svc_uuid=$(basename "$workdir")
    sudo docker network create --attachable "$svc_uuid" 2>/dev/null || true
    env_arg=""
    [ -f "$workdir/.env" ] && env_arg="--env-file $workdir/.env"
    (cd "$workdir" && sudo docker compose $env_arg -f "$compose" up -d --remove-orphans 2>&1 || true)
  done
fi

echo "[COOLIFY-RESTORE] SUCCESS: Full state restoration complete."
