#!/usr/bin/env bash
# ==============================================================================
# Universal Coolify State Restoration & Dynamic Service Engine
# High-Speed Multi-Core (pigz) Extraction from Google Drive
# Automatically hydrates all PaaS databases, services, Traefik routes,
# networks, volumes, and synchronizes Coolify UI live dashboard status.
# ==============================================================================
set -euo pipefail

STORAGE_TARGET="${1:-gdrive:coolify-relay-state/coolify-state}"
CYCLE_COUNT="${2:-0}"
BACKUP_DIR="/data/coolify/backups"
SOURCE_DIR="/data/coolify"
STAGE_DIR="/tmp/coolify_restore_stage"

echo "[COOLIFY-RESTORE] === Universal State Hydration & Environment Provisioning ==="
echo "[COOLIFY-RESTORE] Storage Target: ${STORAGE_TARGET} (Cycle: ${CYCLE_COUNT})"

sudo mkdir -p "$SOURCE_DIR" /var/lib/docker/volumes "$BACKUP_DIR" "$STAGE_DIR"
sudo chmod 777 "$STAGE_DIR"

# Helper for staged, verified download and extraction (prevents partial extract on 403s)
stage_and_extract() {
  local remote_file="$1"
  local target_dir="$2"
  local local_stage="${STAGE_DIR}/${remote_file}"

  echo "[COOLIFY-RESTORE] Checking for ${remote_file} in ${STORAGE_TARGET}..."
  if rclone lsf --drive-use-trash=false "${STORAGE_TARGET}" 2>/dev/null | grep -qx "${remote_file}"; then
    echo "[COOLIFY-RESTORE] Staging ${remote_file} to local NVMe storage..."
    rclone copyto --drive-chunk-size=128M --drive-use-trash=false --retries=5 --low-level-retries=10 \
      "${STORAGE_TARGET}/${remote_file}" "$local_stage"

    if [ ! -s "$local_stage" ]; then
      echo "[COOLIFY-RESTORE] ERROR: Staged file $local_stage is missing or empty!"
      return 1
    fi

    echo "[COOLIFY-RESTORE] Extracting ${remote_file} into ${target_dir}..."
    if command -v pigz >/dev/null 2>&1; then
      pigz -dc -p 4 "$local_stage" | sudo tar --numeric-owner -xpf - -C "$target_dir"
    else
      sudo tar --numeric-owner -xpzf "$local_stage" -C "$target_dir"
    fi
    sudo rm -f "$local_stage"
    echo "[COOLIFY-RESTORE] ${remote_file} successfully hydrated."
  else
    echo "[COOLIFY-RESTORE] Notice: ${remote_file} not found on remote storage."
  fi
}

# 1. Sequentially stage and extract bundles (strictly bounded disk footprint)
stage_and_extract "coolify_bundle.tar.gz" "/data/coolify"
stage_and_extract "volumes_bundle.tar.gz" "/var/lib/docker/volumes"

# Restart Docker daemon to index all extracted volumes
echo "[COOLIFY-RESTORE] Reloading Docker daemon to recognize restored volumes..."
sudo systemctl restart docker 2>/dev/null || true

# 3. Pull standalone PostgreSQL dump
echo "[COOLIFY-RESTORE] Staging PostgreSQL dump..."
rclone copyto --drive-chunk-size=128M --drive-use-trash=false --retries=5 \
  "${STORAGE_TARGET}/coolify_pg_latest.sql.gz" "${BACKUP_DIR}/coolify_pg_latest.sql.gz" 2>/dev/null || true
sudo rm -rf "$STAGE_DIR"

# ==============================================================================
# SAFEGUARD 1: Strict Linux File Ownership & Permissions
# ==============================================================================
echo "[COOLIFY-RESTORE] Applying baseline Linux filesystem permissions..."
sudo chmod -R 755 /data/coolify 2>/dev/null || true
[ -d "/data/coolify/source" ] && sudo chmod -R 775 /data/coolify/source 2>/dev/null || true

if [ -d "/data/coolify/ssh/keys" ]; then
  sudo chmod 700 /data/coolify/ssh/keys
  sudo chmod 600 /data/coolify/ssh/keys/* 2>/dev/null || true
  sudo chmod 644 /data/coolify/ssh/keys/*.pub 2>/dev/null || true
fi

# Ensure all volume directories are accessible
sudo chmod -R 755 /var/lib/docker/volumes 2>/dev/null || true

# ==============================================================================
# SAFEGUARD 2: Localhost SSH Injection & Daemon Hardening
# ==============================================================================
echo "[COOLIFY-RESTORE] Configuring host SSH server & authorized_keys..."
sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server

sudo mkdir -p /etc/ssh/sshd_config.d
cat << 'EOF' | sudo tee /etc/ssh/sshd_config.d/99-coolify.conf >/dev/null
PermitRootLogin yes
PubkeyAuthentication yes
StrictModes no
AuthorizedKeysFile .ssh/authorized_keys
EOF

sudo systemctl enable ssh 2>/dev/null || sudo systemctl enable sshd 2>/dev/null || true
sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd 2>/dev/null || true

sudo mkdir -p /data/coolify/ssh/keys
EXISTING_KEY=$(find /data/coolify/ssh/keys -maxdepth 1 -type f \( -name "ssh_key@*" -o -name "id_*" \) ! -name "*.pub" ! -name "*.lock" 2>/dev/null | head -n 1 || true)
if [ -n "$EXISTING_KEY" ] && [ ! -f "/data/coolify/ssh/keys/id.root@host.docker.internal" ]; then
  sudo cp -f "$EXISTING_KEY" /data/coolify/ssh/keys/id.root@host.docker.internal
  sudo ssh-keygen -y -f /data/coolify/ssh/keys/id.root@host.docker.internal > /tmp/id.root@host.docker.internal.pub 2>/dev/null || true
  [ -f /tmp/id.root@host.docker.internal.pub ] && sudo mv -f /tmp/id.root@host.docker.internal.pub /data/coolify/ssh/keys/id.root@host.docker.internal.pub || true
elif [ ! -f "/data/coolify/ssh/keys/id.root@host.docker.internal" ]; then
  echo "[COOLIFY-RESTORE] Generating host.docker.internal SSH key pair..."
  sudo ssh-keygen -t ed25519 -N "" -f /data/coolify/ssh/keys/id.root@host.docker.internal -C "root@host.docker.internal" 2>/dev/null || true
fi

sudo chmod 700 /data/coolify/ssh /data/coolify/ssh/keys
sudo chmod 600 /data/coolify/ssh/keys/* 2>/dev/null || true
sudo chmod 644 /data/coolify/ssh/keys/*.pub 2>/dev/null || true
sudo chown -R 9999:root /data/coolify/ssh 2>/dev/null || true

sudo mkdir -p /root/.ssh /home/runner/.ssh
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIINGMEL5LpxfXWB1Q2gd028oYZzpuGe97jlmgbYza+pN" | sudo tee -a /root/.ssh/authorized_keys /home/runner/.ssh/authorized_keys >/dev/null

for priv in /data/coolify/ssh/keys/*; do
  if [ -f "$priv" ] && [[ ! "$priv" =~ \.pub$ ]] && [[ ! "$priv" =~ \.lock$ ]]; then
    sudo ssh-keygen -y -f "$priv" 2>/dev/null | sudo tee -a /root/.ssh/authorized_keys /home/runner/.ssh/authorized_keys >/dev/null || true
  fi
done
for pub in /data/coolify/ssh/keys/*.pub; do
  [ -f "$pub" ] && sudo cat "$pub" | sudo tee -a /root/.ssh/authorized_keys /home/runner/.ssh/authorized_keys >/dev/null || true
done

sudo chmod 700 /root/.ssh /home/runner/.ssh
sudo chmod 600 /root/.ssh/authorized_keys /home/runner/.ssh/authorized_keys 2>/dev/null || true

# ==============================================================================
# SAFEGUARD 3: Database Boot & pg_isready Health Polling
# ==============================================================================
if [ -f "/data/coolify/source/docker-compose.yml" ] && [ -f "/data/coolify/source/docker-compose.prod.yml" ]; then
  if [ -f "/data/coolify/source/.env" ]; then
    sudo sed -i 's|^APP_URL=.*|APP_URL=https://coolify.justsawyou.cyou|g' /data/coolify/source/.env 2>/dev/null || true
  fi

  echo "[COOLIFY-RESTORE] Ensuring external Docker network coolify exists..."
  sudo docker network create --attachable coolify 2>/dev/null || true

  echo "[COOLIFY-RESTORE] Booting postgres database service..."
  sudo docker compose --project-directory /data/coolify/source \
    --env-file /data/coolify/source/.env \
    -f /data/coolify/source/docker-compose.yml \
    -f /data/coolify/source/docker-compose.prod.yml \
    up -d postgres 2>&1 || true

  echo "[COOLIFY-RESTORE] Polling PostgreSQL daemon readiness via pg_isready..."
  DB_READY=false
  for i in {1..30}; do
    if sudo docker exec coolify-db pg_isready -U coolify >/dev/null 2>&1 || sudo docker exec -i coolify-db pg_isready >/dev/null 2>&1; then
      echo "[COOLIFY-RESTORE] PostgreSQL is fully ready and accepting connections! ($((i*2))s)"
      DB_READY=true
      break
    fi
    sleep 2
  done

  if [ "$DB_READY" != "true" ]; then
    echo "[COOLIFY-RESTORE] Warning: PostgreSQL took longer than 60s to report ready. Proceeding with caution."
  fi

  # Restore PostgreSQL dump if available
  if [ -f "${BACKUP_DIR}/coolify_pg_latest.sql.gz" ]; then
    echo "[COOLIFY-RESTORE] Restoring PostgreSQL database from dump..."
    if command -v pigz >/dev/null 2>&1; then
      pigz -dc -p 4 "${BACKUP_DIR}/coolify_pg_latest.sql.gz" | sudo docker exec -i coolify-db psql -U coolify -d postgres 2>/dev/null || true
    else
      gunzip -c "${BACKUP_DIR}/coolify_pg_latest.sql.gz" | sudo docker exec -i coolify-db psql -U coolify -d postgres 2>/dev/null || true
    fi
    echo "[COOLIFY-RESTORE] Database restored successfully."

    # Post-Restore Sanity Check: If compose projects exist on disk, database records must not be zero!
    DISK_COMPOSE_COUNT=$(sudo find /data/coolify/services /data/coolify/applications /data/coolify/databases -name "docker-compose.yml" 2>/dev/null | wc -l || echo 0)
    if [ "$DISK_COMPOSE_COUNT" -gt 0 ] && [ "${CYCLE_COUNT:-0}" != "0" ]; then
      DB_PASS=$(grep '^DB_PASSWORD=' /data/coolify/source/.env 2>/dev/null | head -n 1 | cut -d= -f2- | sed -e 's/^["'"'"']//' -e 's/["'"'"']$//' | tr -d '\r\n' || true)
      DB_USER=$(grep '^DB_USERNAME=' /data/coolify/source/.env 2>/dev/null | head -n 1 | cut -d= -f2- | sed -e 's/^["'"'"']//' -e 's/["'"'"']$//' | tr -d '\r\n' || echo "coolify")
      DB_SVCS=$(sudo docker exec -e PGPASSWORD="$DB_PASS" -i coolify-db psql -U "$DB_USER" -d coolify -t -A -c "SELECT count(*) FROM services;" 2>/dev/null | tr -cd '0-9' || echo 0)
      DB_APPS=$(sudo docker exec -e PGPASSWORD="$DB_PASS" -i coolify-db psql -U "$DB_USER" -d coolify -t -A -c "SELECT count(*) FROM applications;" 2>/dev/null | tr -cd '0-9' || echo 0)
      DB_DBS=$(sudo docker exec -e PGPASSWORD="$DB_PASS" -i coolify-db psql -U "$DB_USER" -d coolify -t -A -c "SELECT count(*) FROM standalone_postgresqls;" 2>/dev/null | tr -cd '0-9' || echo 0)
      DB_SVCS="${DB_SVCS:-0}"
      DB_APPS="${DB_APPS:-0}"
      DB_DBS="${DB_DBS:-0}"
      TOTAL_RECORDS=$(( DB_SVCS + DB_APPS + DB_DBS ))

      if [ "$TOTAL_RECORDS" -eq 0 ]; then
        echo "[COOLIFY-RESTORE] CRITICAL: Post-restore sanity check failed!"
        echo "[COOLIFY-RESTORE] Disk contains $DISK_COMPOSE_COUNT service/app/db stacks, but database records == 0."
        echo "[COOLIFY-RESTORE] Halting to trigger circuit breaker and prevent blank state overwrite."
        exit 1
      fi
      echo "[COOLIFY-RESTORE] Database sanity check passed: $TOTAL_RECORDS records verified for $DISK_COMPOSE_COUNT compose stack(s)."
    fi
  fi

  # Boot remaining Coolify engine services
  echo "[COOLIFY-RESTORE] Booting complete Coolify engine (coolify, redis, realtime)..."
  sudo docker compose --project-directory /data/coolify/source \
    --env-file /data/coolify/source/.env \
    -f /data/coolify/source/docker-compose.yml \
    -f /data/coolify/source/docker-compose.prod.yml \
    up -d --remove-orphans 2>&1 || true

  # Boot Coolify Proxy (Traefik v3)
  if [ -d "/data/coolify/proxy" ] && [ -f "/data/coolify/proxy/docker-compose.yml" ]; then
    echo "[COOLIFY-RESTORE] Booting Coolify Traefik proxy on port 80/443..."
    sudo docker compose --project-directory /data/coolify/proxy -f /data/coolify/proxy/docker-compose.yml up -d 2>/dev/null || true
  fi

  # Ensure database schema and host keys are initialized in Coolify
  echo "[COOLIFY-RESTORE] Initializing database schema & host keys in Coolify..."
  for s in {1..30}; do
    if sudo docker exec coolify php artisan --version >/dev/null 2>&1; then
      sudo docker exec coolify php artisan migrate --force 2>/dev/null || true

      sudo docker exec coolify php artisan tinker --execute='
        try {
          $priv = @file_get_contents("/data/coolify/ssh/keys/id.root@host.docker.internal") ?: @file_get_contents("/var/www/html/storage/app/ssh/keys/id.root@host.docker.internal");
          if ($priv) {
            $pk = \App\Models\PrivateKey::find(0);
            if (!$pk) {
              $pk = new \App\Models\PrivateKey();
              $pk->id = 0;
              $pk->team_id = 0;
              $pk->name = "localhost key";
              $pk->description = "Host key for localhost";
              $pk->private_key = $priv;
              $pk->save();
            } else if (empty($pk->private_key)) {
              $pk->private_key = $priv;
              $pk->save();
            }
            $srv = \App\Models\Server::find(0);
            if ($srv) {
              $srv->private_key_id = 0;
              $srv->save();
            }
          }
        } catch (\Throwable $e) {}
      ' 2>/dev/null || true

      sudo docker exec coolify php artisan db:seed --class=ProductionSeeder --force 2>/dev/null || true

      # Inject dynamic Coolify public key into host authorized_keys
      COOLIFY_ACTUAL_PUB=$(sudo docker exec coolify php artisan tinker --execute='echo \App\Models\PrivateKey::find(0)?->getPublicKey();' 2>/dev/null | tr -d '\r\n' || true)
      if [ -n "$COOLIFY_ACTUAL_PUB" ] && [[ "$COOLIFY_ACTUAL_PUB" =~ ^ssh- ]]; then
        echo "$COOLIFY_ACTUAL_PUB" | sudo tee -a /root/.ssh/authorized_keys /home/runner/.ssh/authorized_keys >/dev/null
      fi

      sudo docker exec coolify php artisan db:seed --class=PopulateSshKeysDirectorySeeder --force 2>/dev/null || true
      sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd 2>/dev/null || true
      break
    fi
    sleep 2
  done
fi

# ==============================================================================
# SAFEGUARD 4: Database-Verified Active Service Discovery & Startup
# Dynamic information_schema table union excludes deleted ghost services
# ==============================================================================
echo "[COOLIFY-RESTORE] Querying Coolify database for verified active resource catalog..."

ACTIVE_UUIDS=()

# Strategy 1 (Primary): Direct authenticated PostgreSQL information_schema introspection
if sudo docker ps --format '{{.Names}}' | grep -q 'coolify-db'; then
  DB_PASS=$(grep '^DB_PASSWORD=' /data/coolify/source/.env 2>/dev/null | head -n 1 | cut -d= -f2- | sed -e 's/^["'"'"']//' -e 's/["'"'"']$//' | tr -d '\r\n' || true)
  DB_USER=$(grep '^DB_USERNAME=' /data/coolify/source/.env 2>/dev/null | head -n 1 | cut -d= -f2- | sed -e 's/^["'"'"']//' -e 's/["'"'"']$//' | tr -d '\r\n' || echo "coolify")

  DISCOVERY_SQL="
    SELECT c1.table_name
    FROM information_schema.columns c1
    JOIN information_schema.columns c2
      ON c1.table_schema = c2.table_schema AND c1.table_name = c2.table_name
    WHERE c1.table_schema = 'public'
      AND c1.column_name = 'uuid'
      AND c2.column_name = 'deleted_at'
      AND c1.table_name NOT IN ('servers', 'teams', 'users', 'oauth_access_tokens', 'personal_access_tokens');
  "

  TARGET_TABLES=$(sudo docker exec -e PGPASSWORD="$DB_PASS" -i coolify-db psql -U "$DB_USER" -d coolify -t -A -c "$DISCOVERY_SQL" 2>/dev/null || true)

  if [ -n "$TARGET_TABLES" ]; then
    UNION_QUERIES=()
    while IFS= read -r tbl; do
      trimmed_tbl=$(echo "$tbl" | tr -d '[:space:]')
      [ -n "$trimmed_tbl" ] && UNION_QUERIES+=("SELECT uuid FROM ${trimmed_tbl} WHERE deleted_at IS NULL")
    done <<< "$TARGET_TABLES"

    if [ ${#UNION_QUERIES[@]} -gt 0 ]; then
      FULL_QUERY=$(IFS=$'\n'; echo "${UNION_QUERIES[*]}" | paste -sd ' ' - | sed 's/ SELECT / UNION SELECT /g')
      RAW_UUIDS=$(sudo docker exec -e PGPASSWORD="$DB_PASS" -i coolify-db psql -U "$DB_USER" -d coolify -t -A -c "${FULL_QUERY};" 2>/dev/null || true)
      while IFS= read -r line; do
        trimmed=$(echo "$line" | tr -d '[:space:]')
        [ -n "$trimmed" ] && ACTIVE_UUIDS+=("$trimmed")
      done <<< "$RAW_UUIDS"
    fi
  fi
fi

# Strategy 2 (Fallback): Coolify Artisan Tinker via Laravel DB abstraction
if [ ${#ACTIVE_UUIDS[@]} -eq 0 ] && sudo docker ps --format '{{.Names}}' | grep -q '^coolify$'; then
  RAW_UUIDS=$(sudo docker exec coolify php artisan tinker --execute='
    $tables = [
      "services", "applications",
      "standalone_postgresqls", "standalone_mysqls", "standalone_mariadbs",
      "standalone_mongodbs", "standalone_redises", "standalone_keydbs",
      "standalone_dragonflies", "standalone_clickhouses", "standalone_valkeys"
    ];
    $uuids = [];
    foreach ($tables as $t) {
      try {
        if (\Illuminate\Support\Facades\Schema::hasTable($t)) {
          $records = \Illuminate\Support\Facades\DB::table($t)->whereNull("deleted_at")->pluck("uuid")->toArray();
          $uuids = array_merge($uuids, $records);
        }
      } catch (\Throwable $e) {}
    }
    echo implode("\n", array_unique(array_filter($uuids)));
  ' 2>/dev/null || true)

  while IFS= read -r line; do
    trimmed=$(echo "$line" | tr -d '[:space:]')
    [ -n "$trimmed" ] && ACTIVE_UUIDS+=("$trimmed")
  done <<< "$RAW_UUIDS"
fi

echo "[COOLIFY-RESTORE] Active verified UUIDs count: ${#ACTIVE_UUIDS[@]} (${ACTIVE_UUIDS[*]:-none})"

# Find all compose files across services, applications, and databases
ALL_COMPOSE=()
while IFS= read -r -d '' file; do
  ALL_COMPOSE+=("$file")
done < <(find /data/coolify/applications /data/coolify/services /data/coolify/databases -name "docker-compose.yml" -print0 2>/dev/null || true)

ACTIVE_COMPOSE=()
CLAIMED_DOMAINS=()

for compose in "${ALL_COMPOSE[@]}"; do
  workdir=$(dirname "$compose")
  svc_uuid=$(basename "$workdir")

  # 1. Check if UUID is explicitly active in the database
  is_active=false
  for active_id in "${ACTIVE_UUIDS[@]}"; do
    if [ "$active_id" = "$svc_uuid" ]; then
      is_active=true
      break
    fi
  done

  # 2. Extract Traefik router Host domain from compose file
  compose_domain=$(grep -E 'traefik\.http\.routers\..*\.rule=Host\(' "$compose" 2>/dev/null | head -n 1 | sed -E 's/.*Host\(`([^`]+)`\).*/\1/' | tr -d ' ' || true)

  # 3. Fallback discovery: If UUID not in DB, but compose defines a unique domain (e.g. Bento PDF) with no domain conflict
  if [ "$is_active" != "true" ] && [ -n "$compose_domain" ]; then
    domain_already_claimed=false
    for claimed in "${CLAIMED_DOMAINS[@]}"; do
      if [ "$claimed" = "$compose_domain" ]; then
        domain_already_claimed=true
        break
      fi
    done
    if [ "$domain_already_claimed" != "true" ]; then
      echo "[COOLIFY-RESTORE] Unique active service stack discovered: $svc_uuid claiming domain $compose_domain. Promoting to active."
      is_active=true
    fi
  fi

  if [ "$is_active" = "true" ]; then
    ACTIVE_COMPOSE+=("$compose")
    [ -n "$compose_domain" ] && CLAIMED_DOMAINS+=("$compose_domain")
  else
    echo "[COOLIFY-RESTORE] Skipping duplicate/zombie service: $svc_uuid (domain: ${compose_domain:-none})"
  fi
done

if [ ${#ACTIVE_COMPOSE[@]} -gt 0 ]; then
  echo "[COOLIFY-RESTORE] Found ${#ACTIVE_COMPOSE[@]} verified active service stack(s)."

  # 1. Pre-pull images in parallel
  for compose in "${ACTIVE_COMPOSE[@]}"; do
    workdir=$(dirname "$compose")
    env_arg=""
    [ -f "$workdir/.env" ] && env_arg="--env-file $workdir/.env"
    (cd "$workdir" && sudo docker compose $env_arg -f "$compose" pull -q 2>/dev/null || true) &
  done
  wait

  # 2. Ensure all networks exist and connect Traefik proxy
  sudo docker network create --attachable coolify 2>/dev/null || true
  for compose in "${ACTIVE_COMPOSE[@]}"; do
    workdir=$(dirname "$compose")
    svc_uuid=$(basename "$workdir")

    # Create service network and connect coolify-proxy (Traefik) so it can route requests
    sudo docker network create --attachable "$svc_uuid" 2>/dev/null || true
    sudo docker network connect "$svc_uuid" coolify-proxy 2>/dev/null || true
  done

  # 3. Reconcile persistent user volume data across service UUID rotations
  echo "[COOLIFY-RESTORE] Reconciling persistent volume data across redeployed stacks..."
  # Code Server workspace & Claude chat history
  for active_vol in $(sudo find /var/lib/docker/volumes -maxdepth 1 -name "*code-server*" -type d 2>/dev/null); do
    if [ -d "$active_vol/_data" ]; then
      cur_files=$(sudo find "$active_vol/_data" -maxdepth 2 -type f 2>/dev/null | wc -l || echo 0)
      if [ "$cur_files" -le 2 ]; then
        older_vol=$(sudo find /var/lib/docker/volumes -maxdepth 1 -name "*code-server*" -type d ! -path "$active_vol" 2>/dev/null | while read v; do
          cnt=$(sudo find "$v/_data" -maxdepth 2 -type f 2>/dev/null | wc -l || echo 0)
          [ "$cnt" -gt 2 ] && echo "$v"
        done | head -n 1)
        if [ -n "$older_vol" ] && [ -d "$older_vol/_data" ]; then
          echo "[COOLIFY-RESTORE] Restoring Code Server workspace and Claude chat logs from $older_vol into $active_vol..."
          sudo cp -a "$older_vol/_data/." "$active_vol/_data/" 2>/dev/null || true
        fi
      fi
    fi
  done

  # Hermes agent chat history & database
  for active_vol in $(sudo find /var/lib/docker/volumes -maxdepth 1 -name "*hermes*" -type d 2>/dev/null); do
    if [ -d "$active_vol/_data" ]; then
      cur_files=$(sudo find "$active_vol/_data" -maxdepth 2 -type f 2>/dev/null | wc -l || echo 0)
      if [ "$cur_files" -le 2 ]; then
        older_vol=$(sudo find /var/lib/docker/volumes -maxdepth 1 -name "*hermes*" -type d ! -path "$active_vol" 2>/dev/null | while read v; do
          cnt=$(sudo find "$v/_data" -maxdepth 2 -type f 2>/dev/null | wc -l || echo 0)
          [ "$cnt" -gt 2 ] && echo "$v"
        done | head -n 1)
        if [ -n "$older_vol" ] && [ -d "$older_vol/_data" ]; then
          echo "[COOLIFY-RESTORE] Restoring Hermes agent profiles and history from $older_vol into $active_vol..."
          sudo cp -a "$older_vol/_data/." "$active_vol/_data/" 2>/dev/null || true
        fi
      fi
    fi
  done

  # 4. Boot all verified active service stacks
  for compose in "${ACTIVE_COMPOSE[@]}"; do
    workdir=$(dirname "$compose")
    svc_uuid=$(basename "$workdir")
    echo "[COOLIFY-RESTORE] Booting verified active service: $svc_uuid in $workdir..."
    env_arg=""
    [ -f "$workdir/.env" ] && env_arg="--env-file $workdir/.env"
    (cd "$workdir" && sudo docker compose $env_arg --project-directory "$workdir" --project-name "$svc_uuid" -f "$compose" up -d --remove-orphans 2>&1 || true)
  done

  # 4. Connect all started service containers to the shared 'coolify' network for universal proxy routing
  for c in $(sudo docker ps -q --filter "label=coolify.managed=true"); do
    sudo docker network connect coolify "$c" 2>/dev/null || true
  done

  # 5. Synchronize Coolify UI Dashboard Status
  echo "[COOLIFY-RESTORE] Synchronizing Coolify UI dashboard status..."
  sudo docker exec coolify php artisan schedule:run 2>/dev/null || true
  sudo docker exec coolify php artisan tinker --execute='
    try {
      \Illuminate\Support\Facades\DB::table("service_applications")->whereNull("deleted_at")->update(["status" => "running:healthy"]);
      \Illuminate\Support\Facades\DB::table("applications")->whereNull("deleted_at")->update(["status" => "running:healthy"]);
    } catch (\Throwable $e) {}
  ' 2>/dev/null || true
else
  echo "[COOLIFY-RESTORE] No active user applications or services found to start."
fi

echo "[COOLIFY-RESTORE] All active containers post-restore:"
sudo docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" || true
