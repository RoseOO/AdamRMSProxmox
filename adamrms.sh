#!/usr/bin/env bash

# Copyright (c) 2026
# Author: Rose
# License: MIT
# Source: https://adam-rms.com/ | Github: https://github.com/adam-rms/adam-rms

set -e
trap 'echo -e "\e[31m[ERROR]\e[0m Script failed at line $LINENO"' ERR

GEN="\033[0;32m"
YW="\033[1;33m"
BL="\033[0;34m"
RD="\033[0;31m"
CL="\033[0m"
GN="\033[1;32m"
BGN="\033[4;32m"

msg_info()   { echo -e "${GN}[INFO]${CL}  $*"; }
msg_ok()     { echo -e "${GEN}[ OK ]${CL}  $*"; }
msg_warn()   { echo -e "${YW}[WARN]${CL}  $*"; }
msg_error()  { echo -e "${RD}[ERROR]${CL} $*"; }

echo -e "\n${BGN}AdamRMS Proxmox Installer${CL}\n"

# ── Check we're on Proxmox ──────────────────────────────────────────
if ! command -v pct &>/dev/null; then
  msg_error "This script must be run on a Proxmox VE host."
  exit 1
fi

# ── Config defaults ─────────────────────────────────────────────────
CT_ID="${1:-}"
while [[ -z "$CT_ID" ]] || ! [[ "$CT_ID" =~ ^[0-9]+$ ]]; do
  NEXT_ID=$(pvesh get /cluster/nextid 2>/dev/null || echo "")
  if [[ -n "$NEXT_ID" ]]; then
    read -r -p "Container ID [${NEXT_ID}]: " CT_ID
  else
    read -r -p "Container ID: " CT_ID
  fi
  CT_ID="${CT_ID:-$NEXT_ID}"
done

STORAGE=$(pvesm status -content rootdir 2>/dev/null | awk 'NR>1{print $1; exit}')
if [[ -z "$STORAGE" ]]; then
  msg_error "No storage pool found for rootdir."
  exit 1
fi

read -r -p "Hostname [adamrms]: " HN
HN="${HN:-adamrms}"
HN=$(echo "${HN,,}" | tr -d ' ')

DEFAULT_CPU=2
DEFAULT_RAM=2048
DEFAULT_DISK=10

read -r -p "CPU cores [${DEFAULT_CPU}]: " CPU
CPU="${CPU:-$DEFAULT_CPU}"

read -r -p "RAM in MB [${DEFAULT_RAM}]: " RAM
RAM="${RAM:-$DEFAULT_RAM}"

read -r -p "Disk in GB [${DEFAULT_DISK}]: " DISK
DISK="${DISK:-$DEFAULT_DISK}"

read -r -p "Bridge [vmbr0]: " BRIDGE
BRIDGE="${BRIDGE:-vmbr0}"

echo ""
echo -e "${YW}DHCP or static IP?${CL}"
read -r -p "Use DHCP? [Y/n]: " USE_DHCP
USE_DHCP="${USE_DHCP:-y}"

if [[ "${USE_DHCP,,}" =~ ^(y|yes)$ ]]; then
  IP_CONFIG="ip=dhcp"
else
  read -r -p "IP address with CIDR (e.g. 192.168.1.100/24): " STATIC_IP
  read -r -p "Gateway (e.g. 192.168.1.1): " GATEWAY
  IP_CONFIG="ip=${STATIC_IP},gw=${GATEWAY}"
fi

# ── Database choice ─────────────────────────────────────────────────
echo ""
echo -e "${YW}Which database backend?${CL}"
echo "1) MariaDB (recommended)"
echo "2) MySQL"
while true; do
  read -r -p "Choice [1]: " DB_CHOICE
  DB_CHOICE="${DB_CHOICE:-1}"
  case "$DB_CHOICE" in
    1) DB_BACKEND="mariadb"; break ;;
    2) DB_BACKEND="mysql"; break ;;
    *) msg_warn "Enter 1 or 2" ;;
  esac
done

# ── Generate passwords ──────────────────────────────────────────────
DB_NAME="adamrms"
DB_USER="adamrms"
DB_PASS=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 20)
DB_ROOT_PASS=""
if [[ "$DB_BACKEND" == "mysql" ]]; then
  DB_ROOT_PASS=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 24)
fi

# ── Find Debian 13 template ─────────────────────────────────────────
msg_info "Locating Debian 13 template"
TEMPLATE=$(pveam available 2>/dev/null | grep -i "debian-13" | awk '{print $2}' | head -1)
if [[ -z "$TEMPLATE" ]]; then
  TEMPLATE=$(pveam available 2>/dev/null | grep -i "debian" | awk '{print $2}' | head -1)
fi
if [[ -z "$TEMPLATE" ]]; then
  msg_error "No Debian template found. Run: pveam update"
  exit 1
fi

TEMPLATE_STORAGE=$(pvesm status -content vztmpl 2>/dev/null | awk 'NR>1{print $1; exit}')
if [[ -z "$TEMPLATE_STORAGE" ]]; then
  msg_error "No template storage found."
  exit 1
fi

if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$TEMPLATE"; then
  msg_info "Downloading template $TEMPLATE"
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
fi
msg_ok "Template ready"

# ── Create container ────────────────────────────────────────────────
msg_info "Creating LXC container $CT_ID ($HN)"
pct create "$CT_ID" \
  "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
  --hostname "$HN" \
  --storage "$STORAGE" \
  --rootfs "${STORAGE}:${DISK}" \
  --cores "$CPU" \
  --memory "$RAM" \
  --swap 0 \
  --net0 "name=eth0,bridge=${BRIDGE},${IP_CONFIG}" \
  --ostype debian \
  --unprivileged 1 \
  --features nesting=1,keyctl=1 \
  --onboot 1 \
  --start 0 \
  --timezone host
msg_ok "Container created"

msg_info "Starting container"
pct start "$CT_ID"
# Wait for networking
sleep 5
for i in $(seq 1 30); do
  if pct exec "$CT_ID" -- ping -c 1 -W 1 8.8.8.8 &>/dev/null; then
    break
  fi
  sleep 2
done
msg_ok "Container started"

# ── Get container IP ────────────────────────────────────────────────
CT_IP=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}')
if [[ -z "$CT_IP" ]]; then
  CT_IP="<container-ip>"
fi

# ── Build and inject install script ─────────────────────────────────
msg_info "Injecting install script"
INSTALL_SCRIPT="/tmp/adamrms-install-inner.sh"

cat >"$INSTALL_SCRIPT" <<'INNER_EOF'
#!/usr/bin/env bash
set -e

GEN="\033[0;32m"; YW="\033[1;33m"; RD="\033[0;31m"; CL="\033[0m"; GN="\033[1;32m"
msg_info()  { echo -e "${GN}[INFO]${CL}  $*"; }
msg_ok()    { echo -e "${GEN}[ OK ]${CL}  $*"; }
msg_warn()  { echo -e "${YW}[WARN]${CL}  $*"; }
msg_error() { echo -e "${RD}[ERROR]${CL} $*"; }

INNER_EOF

# Inject variables into the script
cat >>"$INSTALL_SCRIPT" <<INNER_VARS
DB_BACKEND="$DB_BACKEND"
DB_NAME="$DB_NAME"
DB_USER="$DB_USER"
DB_PASS="$DB_PASS"
DB_ROOT_PASS="$DB_ROOT_PASS"
INNER_VARS

cat >>"$INSTALL_SCRIPT" <<'INNER_BODY'

msg_info "Updating system"
apt-get update -qq && apt-get upgrade -y -qq
msg_ok "System updated"

msg_info "Setting up root auto-login"
mkdir -p /etc/systemd/system/container-getty@.service.d
cat > /etc/systemd/system/container-getty@.service.d/override.conf <<'AUTOLOGIN'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
AUTOLOGIN
systemctl daemon-reload
msg_ok "Root auto-login configured"

msg_info "Setting up MOTD"
cat > /etc/motd <<'MOTD'
\033[1;32m
   █████╗ ██████╗  █████╗ ███╗   ███╗██████╗ ███╗   ███╗███████╗
  ██╔══██╗██╔══██╗██╔══██╗████╗ ████║██╔══██╗████╗ ████║██╔════╝
  ███████║██║  ██║███████║██╔████╔██║██████╔╝██╔████╔██║███████╗
  ██╔══██║██║  ██║██╔══██║██║╚██╔╝██║██╔══██╗██║╚██╔╝██║╚════██║
  ██║  ██║██████╔╝██║  ██║██║ ╚═╝ ██║██║  ██║██║ ╚═╝ ██║███████║
  ╚═╝  ╚═╝╚═════╝ ╚═╝  ╚═╝╚═╝     ╚═╝╚═╝  ╚═╝╚═╝     ╚═╝╚══════╝
\033[0m

  Asset & Rental Management System

  \033[1;33mType 'update_adamrms' to update AdamRMS\033[0m
  \033[1;33mCredentials saved to ~/adamrms.creds\033[0m
MOTD
touch /root/.hushlogin
msg_ok "MOTD configured"

msg_info "Creating update command"
cat > /usr/local/bin/update_adamrms <<'UPDATE'
#!/usr/bin/env bash
set -e
echo -e "\033[1;32m[INFO]\033[0m  Updating AdamRMS..."
cd /opt/adamrms
docker compose down
docker compose pull
docker compose up -d
echo -e "\033[0;32m[ OK ]\033[0m  AdamRMS updated successfully!"
UPDATE
chmod +x /usr/local/bin/update_adamrms
ln -sf /usr/local/bin/update_adamrms /usr/local/bin/update 2>/dev/null || true
msg_ok "Update command created"

msg_info "Installing Docker"
apt-get install -y -qq curl ca-certificates gnupg lsb-release openssl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" >/etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
msg_ok "Docker installed"

msg_info "Setting up AdamRMS"
mkdir -p /opt/adamrms
cd /opt/adamrms

if [[ "$DB_BACKEND" == "mariadb" ]]; then
  cat >docker-compose.yml <<COMPOSE
services:
  db:
    image: mariadb:lts
    container_name: adamrms-db
    restart: always
    volumes:
      - adamrms_db_data:/var/lib/mysql
      - /etc/localtime:/etc/localtime:ro
    environment:
      - MARIADB_DATABASE=${DB_NAME}
      - MARIADB_USER=${DB_USER}
      - MARIADB_PASSWORD=${DB_PASS}
      - MARIADB_ROOT_PASSWORD=${DB_PASS}
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 10

  adamrms:
    image: ghcr.io/adam-rms/adam-rms:latest
    container_name: adamrms
    restart: always
    ports:
      - 80:80
    depends_on:
      db:
        condition: service_healthy
    environment:
      - DB_HOSTNAME=adamrms-db
      - DB_DATABASE=${DB_NAME}
      - DB_USERNAME=${DB_USER}
      - DB_PASSWORD=${DB_PASS}
      - DB_PORT=3306

volumes:
  adamrms_db_data:
COMPOSE
else
  cat >docker-compose.yml <<COMPOSE
services:
  db:
    image: mysql:8.0
    container_name: adamrms-db
    restart: always
    command: --default-authentication-plugin=mysql_native_password
    volumes:
      - adamrms_db_data:/var/lib/mysql
      - /etc/localtime:/etc/localtime:ro
    environment:
      - MYSQL_DATABASE=${DB_NAME}
      - MYSQL_USER=${DB_USER}
      - MYSQL_PASSWORD=${DB_PASS}
      - MYSQL_ROOT_PASSWORD=${DB_ROOT_PASS}
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-u", "root", "-p${DB_ROOT_PASS}"]
      interval: 10s
      timeout: 5s
      retries: 10

  adamrms:
    image: ghcr.io/adam-rms/adam-rms:latest
    container_name: adamrms
    restart: always
    ports:
      - 80:80
    depends_on:
      db:
        condition: service_healthy
    environment:
      - DB_HOSTNAME=adamrms-db
      - DB_DATABASE=${DB_NAME}
      - DB_USERNAME=${DB_USER}
      - DB_PASSWORD=${DB_PASS}
      - DB_PORT=3306

volumes:
  adamrms_db_data:
COMPOSE
fi
msg_ok "docker-compose.yml created"

msg_info "Pulling images and starting services (this may take a few minutes)"
docker compose pull -q
docker compose up -d
msg_ok "Services started"

msg_info "Waiting for AdamRMS to become ready"
for i in $(seq 1 60); do
  if curl -fsSL -o /dev/null http://localhost 2>/dev/null; then
    break
  fi
  sleep 5
done
msg_ok "AdamRMS is running"

cat >>~/adamrms.creds <<CREDS

AdamRMS Credentials
===================
Database Backend: ${DB_BACKEND}
Database Name:     ${DB_NAME}
Database User:     ${DB_USER}
Database Password: ${DB_PASS}
$([[ -n "$DB_ROOT_PASS" ]] && echo "MySQL Root Pass:   ${DB_ROOT_PASS}")

AdamRMS Default Login
=====================
URL:      http://$(hostname -I | awk '{print $1}')
Username: username
Password: password!

IMPORTANT: Login immediately and change the default password!
CREDS

cat ~/adamrms.creds
INNER_BODY

pct push "$CT_ID" "$INSTALL_SCRIPT" /tmp/install.sh
pct exec "$CT_ID" -- bash /tmp/install.sh

msg_ok "Installation complete!"
echo ""
echo -e "${GN}═══════════════════════════════════════════════${CL}"
echo -e "${BGN}  AdamRMS has been installed!${CL}"
echo -e "${GN}═══════════════════════════════════════════════${CL}"
echo -e "  Container ID : ${CT_ID}"
echo -e "  Container IP : ${CT_IP}"
echo -e "  URL           : ${BGN}http://${CT_IP}${CL}"
echo -e "  Default Login : username / password!"
echo -e "  Credentials   : ~/adamrms.creds (inside container)"
echo ""
echo -e "  ${YW}Update:${CL}  Run 'update_adamrms' inside the container, or:"
echo -e "        pct exec ${CT_ID} -- update_adamrms"
echo -e "${GN}═══════════════════════════════════════════════${CL}"

rm -f "$INSTALL_SCRIPT"
