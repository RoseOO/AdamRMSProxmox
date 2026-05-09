#!/usr/bin/env bash

# Copyright (c) 2026 community-scripts ORG
# Author: Rose
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://adam-rms.com/ | Github: https://github.com/adam-rms/adam-rms

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt-get install -y \
  curl \
  ca-certificates \
  gnupg \
  lsb-release \
  openssl
msg_ok "Installed Dependencies"

msg_info "Choosing Database Backend"
if [[ -z "${DB_BACKEND:-}" ]]; then
  echo ""
  echo -e "${TAB}${YW}Which database backend would you like to use?${CL}"
  echo -e "${TAB}${TAB}1) MariaDB"
  echo -e "${TAB}${TAB}2) MySQL"
  echo ""
  while true; do
    read -r -p "${TAB}Enter choice (1 or 2): " DB_CHOICE
    case "$DB_CHOICE" in
      1|mariadb|MariaDB) DB_BACKEND="mariadb"; break ;;
      2|mysql|MySQL) DB_BACKEND="mysql"; break ;;
      *) msg_warn "Please enter 1 for MariaDB or 2 for MySQL" ;;
    esac
  done
fi
msg_ok "Selected ${DB_BACKEND}"

msg_info "Generating Credentials"
DB_USER="${DB_USER:-adamrms}"
DB_NAME="${DB_NAME:-adamrms}"
DB_PASS=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 20)
if [[ "$DB_BACKEND" == "mysql" ]]; then
  DB_ROOT_PASS=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 24)
fi
msg_ok "Generated Credentials"

msg_info "Installing Docker"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" >/etc/apt/sources.list.d/docker.list
$STD apt-get update
$STD apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
msg_ok "Installed Docker"

msg_info "Setting up AdamRMS Directory"
mkdir -p /opt/adamrms
msg_ok "Set up Directory"

msg_info "Creating docker-compose.yml"
if [[ "$DB_BACKEND" == "mariadb" ]]; then
  cat <<COMPOSE >/opt/adamrms/docker-compose.yml
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
  cat <<COMPOSE >/opt/adamrms/docker-compose.yml
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
msg_ok "Created docker-compose.yml"

msg_info "Starting AdamRMS (this may take a few minutes on first run)"
cd /opt/adamrms
$STD docker compose up -d
msg_ok "Started AdamRMS"

msg_info "Waiting for AdamRMS to initialize"
SECONDS=0
while ! curl -fsSL -o /dev/null http://localhost 2>/dev/null; do
  if ((SECONDS > 300)); then
    msg_warn "AdamRMS is taking longer than expected to start"
    break
  fi
  sleep 5
done
msg_ok "AdamRMS is responding"

{
  echo ""
  echo "AdamRMS Credentials"
  echo "==================="
  echo "Database Backend: ${DB_BACKEND}"
  echo "Database Name: ${DB_NAME}"
  echo "Database User: ${DB_USER}"
  echo "Database Password: ${DB_PASS}"
  if [[ "$DB_BACKEND" == "mysql" ]]; then
    echo "MySQL Root Password: ${DB_ROOT_PASS}"
  fi
  echo ""
  echo "AdamRMS Default Login"
  echo "====================="
  echo "Username: username"
  echo "Password: password!"
  echo ""
  echo "IMPORTANT: Login and change the default password immediately!"
} >>~/adamrms.creds

motd_ssh
customize
cleanup_lxc
