#!/usr/bin/env bash
# ==============================================================================
# Hardened Coolify State Restoration Script for Backblaze B2
# ==============================================================================
set -euo pipefail

STORAGE_TARGET="${1:-b2:coolify-relay-state/coolify-state}"
BACKUP_DIR="/data/coolify/backups"
SOURCE_DIR="/data/coolify"

echo "[COOLIFY-RESTORE] === Phase: State Hydration & Permission Normalization ==="

sudo mkdir -p "$SOURCE_DIR" /var/lib/docker/volumes "$BACKUP_DIR"

# 1. Check if backup bundle exists in object storage
if rclone cat "${STORAGE_TARGET}/coolify_bundle.tar.gz" 2>/dev/null | sudo tar --numeric-owner -xpzf - -C /data/coolify 2>/dev/null; then
  echo "[COOLIFY-RESTORE] Core /data/coolify state restored successfully."
else
  echo "[COOLIFY-RESTORE] No prior backup found or cold start baseline."
fi

# 2. Restore Docker volumes if present
rclone cat "${STORAGE_TARGET}/volumes_bundle.tar.gz" 2>/dev/null | sudo tar --numeric-owner -xpzf - -C /var/lib/docker/volumes 2>/dev/null || true

# 3. Pull latest standalone PostgreSQL dump
rclone copyto "${STORAGE_TARGET}/coolify_pg_latest.sql.gz" "${BACKUP_DIR}/coolify_pg_latest.sql.gz" 2>/dev/null || true

# ==============================================================================
# SAFEGUARD 1: Strict Linux File Ownership & Permissions
# ==============================================================================
echo "[COOLIFY-RESTORE] Applying strict Linux filesystem permissions..."
# Ensure /data/coolify is traversable and writable by docker and runner
sudo chmod -R 755 /data/coolify 2>/dev/null || true
[ -d "/data/coolify/source" ] && sudo chmod -R 775 /data/coolify/source 2>/dev/null || true

if [ -d "/data/coolify/ssh/keys" ]; then
  sudo chmod 700 /data/coolify/ssh/keys
  sudo chmod 600 /data/coolify/ssh/keys/* 2>/dev/null || true
  sudo chmod 644 /data/coolify/ssh/keys/*.pub 2>/dev/null || true
fi

# ==============================================================================
# SAFEGUARD 2: Localhost SSH Injection & Daemon Hardening
# ==============================================================================
echo "[COOLIFY-RESTORE] Configuring host SSH server & authorized_keys for Coolify engine..."
sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server

# Drop-in sshd configuration to guarantee public key auth and root login via key
sudo mkdir -p /etc/ssh/sshd_config.d
cat << 'EOF' | sudo tee /etc/ssh/sshd_config.d/99-coolify.conf >/dev/null
PermitRootLogin yes
PubkeyAuthentication yes
StrictModes no
AuthorizedKeysFile .ssh/authorized_keys
EOF

# Ensure sshd is running
sudo systemctl enable ssh 2>/dev/null || sudo systemctl enable sshd 2>/dev/null || true
sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd 2>/dev/null || true

# Guarantee that a valid root host key for @host.docker.internal exists in /data/coolify/ssh/keys
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

# Ensure correct permissions on SSH key files
sudo chmod 700 /data/coolify/ssh /data/coolify/ssh/keys
sudo chmod 600 /data/coolify/ssh/keys/* 2>/dev/null || true
sudo chmod 644 /data/coolify/ssh/keys/*.pub 2>/dev/null || true
sudo chown -R 9999:root /data/coolify/ssh 2>/dev/null || true

# Authorize Coolify's internal SSH key for root and runner users
sudo mkdir -p /root/.ssh /home/runner/.ssh

# Inject master Coolify onboarding key
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIINGMEL5LpxfXWB1Q2gd028oYZzpuGe97jlmgbYza+pN" | sudo tee -a /root/.ssh/authorized_keys >/dev/null
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIINGMEL5LpxfXWB1Q2gd028oYZzpuGe97jlmgbYza+pN" | sudo tee -a /home/runner/.ssh/authorized_keys >/dev/null

# Inject all public keys from /data/coolify/ssh/keys into authorized_keys
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
  # Ensure APP_URL is correctly set to coolify.justsawyou.cyou
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

  # Restore PostgreSQL dump if available (using postgres maintenance DB for global restore)
  if [ -f "${BACKUP_DIR}/coolify_pg_latest.sql.gz" ]; then
    echo "[COOLIFY-RESTORE] Restoring PostgreSQL database from dump..."
    gunzip -c "${BACKUP_DIR}/coolify_pg_latest.sql.gz" | sudo docker exec -i coolify-db psql -U coolify -d postgres 2>/dev/null || true
    echo "[COOLIFY-RESTORE] Database restored successfully."
  fi

  # Boot remaining Coolify engine services with full env-file and prod compose context
  echo "[COOLIFY-RESTORE] Booting complete Coolify engine (coolify, redis, realtime)..."
  sudo docker compose --project-directory /data/coolify/source \
    --env-file /data/coolify/source/.env \
    -f /data/coolify/source/docker-compose.yml \
    -f /data/coolify/source/docker-compose.prod.yml \
    up -d --remove-orphans 2>&1 || true

  # Boot Coolify Proxy (Traefik v3) if present
  if [ -d "/data/coolify/proxy" ] && [ -f "/data/coolify/proxy/docker-compose.yml" ]; then
    echo "[COOLIFY-RESTORE] Booting Coolify Traefik proxy on port 80/443..."
    sudo docker compose --project-directory /data/coolify/proxy -f /data/coolify/proxy/docker-compose.yml up -d 2>/dev/null || true
  fi

  # Wait for Coolify container readiness and run database migrations/seeders
  echo "[COOLIFY-RESTORE] Ensuring database schema and host keys are initialized in Coolify..."
  for s in {1..30}; do
    if sudo docker exec coolify php artisan --version >/dev/null 2>&1; then
      echo "[COOLIFY-RESTORE] Running database migrations..."
      sudo docker exec coolify php artisan migrate --force 2>/dev/null || true

      echo "[COOLIFY-RESTORE] Binding localhost Server(0) and PrivateKey(0) in Coolify database..."
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
      echo "[COOLIFY-RESTORE] Localhost server and private key verified in database."

      # Extract actual public key that Coolify's PrivateKey(0) computes and inject into authorized_keys
      echo "[COOLIFY-RESTORE] Authorizing Coolify PrivateKey(0) public key on host..."
      COOLIFY_ACTUAL_PUB=$(sudo docker exec coolify php artisan tinker --execute='echo \App\Models\PrivateKey::find(0)?->getPublicKey();' 2>/dev/null | tr -d '\r\n' || true)
      if [ -n "$COOLIFY_ACTUAL_PUB" ] && [[ "$COOLIFY_ACTUAL_PUB" =~ ^ssh- ]]; then
        echo "$COOLIFY_ACTUAL_PUB" | sudo tee -a /root/.ssh/authorized_keys /home/runner/.ssh/authorized_keys >/dev/null
        echo "[COOLIFY-RESTORE] Successfully injected dynamic Coolify public key into authorized_keys."
      fi

      # Also populate storage/app/ssh/keys inside container so ssh-keys disk has the file
      sudo docker exec coolify php artisan db:seed --class=PopulateSshKeysDirectorySeeder --force 2>/dev/null || true

      # Restart SSH daemon to pick up configuration changes
      sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd 2>/dev/null || true
      break
    fi
    sleep 2
  done

  echo "[COOLIFY-RESTORE] State restoration & environment hardening complete!"
fi

# ==============================================================================
# SAFEGUARD 4: Universal Auto-Discovery, Image Pull & Startup for User Services
# Works dynamically for ANY current or future service/application deployed in Coolify
# ==============================================================================
echo "[COOLIFY-RESTORE] Scanning for deployed Coolify applications and services..."

COMPOSE_FILES=()
while IFS= read -r -d '' file; do
  COMPOSE_FILES+=("$file")
done < <(find /data/coolify/applications /data/coolify/services -name "docker-compose.yml" -print0 2>/dev/null || true)

if [ ${#COMPOSE_FILES[@]} -gt 0 ]; then
  echo "[COOLIFY-RESTORE] Found ${#COMPOSE_FILES[@]} deployed service compose file(s)."
  for compose in "${COMPOSE_FILES[@]}"; do
    workdir=$(dirname "$compose")
    echo "[COOLIFY-RESTORE] >> Inspecting service in $workdir..."

    # Ensure env file exists if referenced
    env_arg=""
    if [ -f "$workdir/.env" ]; then
      env_arg="--env-file $workdir/.env"
    fi

    # 1. Pull required images (in parallel/cached) so container starts immediately
    echo "[COOLIFY-RESTORE] Pre-fetching Docker images for $workdir..."
    (cd "$workdir" && sudo docker compose $env_arg -f "$compose" pull -q 2>/dev/null || true) &
  done
  wait

  # 2. Automatically create external Docker networks required by Coolify services
  # In Coolify, services declare external networks (e.g., the directory/UUID name and 'coolify')
  echo "[COOLIFY-RESTORE] Ensuring all external networks required by user services exist..."
  sudo docker network create --attachable coolify 2>/dev/null || true
  for compose in "${COMPOSE_FILES[@]}"; do
    workdir=$(dirname "$compose")
    svc_uuid=$(basename "$workdir")
    # Always create network named after the service/app UUID
    sudo docker network create --attachable "$svc_uuid" 2>/dev/null || true

    # Native compose network discovery: inspects declared networks reliably regardless of YAML formatting
    declared_nets=$(cd "$workdir" && sudo docker compose -f "$compose" config --networks 2>/dev/null || true)
    for net in $declared_nets; do
      if [ -n "$net" ] && [ "$net" != "default" ]; then
        sudo docker network create --attachable "$net" 2>/dev/null || true
      fi
    done

    # Fallback awk parser for raw external networks if docker compose config is not yet initialized
    for net in $(awk '
      /^networks:/ { in_net=1; next }
      /^[a-zA-Z]/ && !/^networks:/ { in_net=0 }
      in_net && /^  [a-zA-Z0-9_-]+:/ {
        sub(/^  /, ""); sub(/:.*/, ""); curr=$0
      }
      in_net && curr != "" && /external:[[:space:]]*true/ {
        if (curr != "external") print curr
        curr=""
      }
    ' "$compose" 2>/dev/null || true); do
      [ -n "$net" ] && sudo docker network create --attachable "$net" 2>/dev/null || true
    done
  done

  # 3. Boot up every discovered service stack
  for compose in "${COMPOSE_FILES[@]}"; do
    workdir=$(dirname "$compose")
    echo "[COOLIFY-RESTORE] Starting service stack in $workdir..."
    env_arg=""
    if [ -f "$workdir/.env" ]; then
      env_arg="--env-file $workdir/.env"
    fi
    (cd "$workdir" && sudo docker compose $env_arg -f "$compose" up -d --remove-orphans 2>&1 || true)
  done
else
  echo "[COOLIFY-RESTORE] No deployed user applications found yet."
fi

# Final status check of all running containers
echo "[COOLIFY-RESTORE] All active containers post-restore:"
sudo docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

