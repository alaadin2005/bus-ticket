#!/usr/bin/env bash
set -Eeuo pipefail

# Run as root on db01 (CentOS Stream 9).
DB_NAME="ticketing_system"
DB_USER="ticketapp"
APP_SOURCE_IP="192.168.3.21"
REPO_URL="https://github.com/alaadin2005/bus-ticket.git"
PROJECT_DIR="/opt/bus-ticket"

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash $0"; exit 1; }

echo "== 1/7 Install required packages =="
dnf -y install git firewalld
if ! rpm -q mysql-server >/dev/null 2>&1; then
  dnf -y install mysql-server
fi

echo "== 2/7 Start MySQL and firewalld =="
systemctl enable --now mysqld
systemctl enable --now firewalld

echo "== 3/7 Get project SQL file =="
if [[ ! -d "$PROJECT_DIR/.git" ]]; then
  git clone "$REPO_URL" "$PROJECT_DIR"
else
  echo "Repository already exists at $PROJECT_DIR; not overwriting it."
fi
[[ -s "$PROJECT_DIR/database.sql" ]] || { echo "Missing $PROJECT_DIR/database.sql"; exit 1; }

echo "== 4/7 Import sample schema/data only if database has no tables =="
DB_TABLE_COUNT="$(mysql -NBe "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}'" 2>/dev/null || echo 0)"
if [[ "${DB_TABLE_COUNT}" == "0" ]]; then
  # The repository dump creates ticketing_system with the original latin1 schema.
  mysql < "$PROJECT_DIR/database.sql"
  echo "Imported schema and sample rows from database.sql."
else
  echo "Database $DB_NAME already has ${DB_TABLE_COUNT} table(s); import skipped to avoid duplicate/overwriting data."
fi

echo "== 5/7 Create/update application DB account =="
echo "Enter a DB password using only letters, numbers, dot, underscore, or hyphen."
read -rsp "Password for ${DB_USER}: " DB_PASSWORD
echo
[[ "$DB_PASSWORD" =~ ^[A-Za-z0-9._-]{12,128}$ ]] || {
  echo "Password must be 12-128 characters and contain only A-Z a-z 0-9 . _ -"; exit 1;
}
# SQL-escape is unnecessary for this deliberately restricted character set.
mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET latin1 COLLATE latin1_swedish_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'${APP_SOURCE_IP}' IDENTIFIED BY '${DB_PASSWORD}';
ALTER USER '${DB_USER}'@'${APP_SOURCE_IP}' IDENTIFIED BY '${DB_PASSWORD}';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, DROP ON \`${DB_NAME}\`.* TO '${DB_USER}'@'${APP_SOURCE_IP}';
FLUSH PRIVILEGES;
SQL
unset DB_PASSWORD

echo "== 6/7 Allow MySQL only from app01 source IP ${APP_SOURCE_IP} =="
firewall-cmd --permanent --zone=public \
  --add-rich-rule="rule family=\"ipv4\" source address=\"${APP_SOURCE_IP}/32\" port port=\"3306\" protocol=\"tcp\" accept" || true
firewall-cmd --reload

echo "== 7/7 Verify =="
mysql -e "SELECT VERSION() AS mysql_version; SHOW DATABASES LIKE '${DB_NAME}';"
firewall-cmd --zone=public --list-rich-rules
echo
echo "db01 setup finished. Keep the DB password safe; enter the same password when running 02-app01-setup.sh."
