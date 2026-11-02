#!/usr/bin/env bash
set -Eeuo pipefail

# Run as root on web01 (Ubuntu 22.04).
APP_HOST="192.168.3.12"
APP_PORT="8080"
SERVER_NAME="_"

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash $0"; exit 1; }

echo "== 1/5 Install Nginx and curl =="
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx curl

echo "== 2/5 Configure reverse proxy to app01 =="
cat > /etc/nginx/sites-available/bus-ticket <<'NGINX'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    access_log /var/log/nginx/bus-ticket-access.log;
    error_log  /var/log/nginx/bus-ticket-error.log;

    location / {
        proxy_pass http://192.168.3.12:8080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 10s;
        proxy_read_timeout 120s;
    }
}
NGINX

echo "== 3/5 Enable this site and remove default site =="
rm -f /etc/nginx/sites-enabled/default
ln -sfn /etc/nginx/sites-available/bus-ticket /etc/nginx/sites-enabled/bus-ticket
nginx -t

echo "== 4/5 Start Nginx =="
systemctl enable --now nginx
systemctl reload nginx

echo "== 5/5 Verify =="
systemctl --no-pager --full status nginx || true
echo
curl -sS -o /dev/null -w 'Nginx HTTP %{http_code}\n' http://127.0.0.1/ || true
echo
echo "web01 setup finished. Open http://192.168.3.11/ from a client on the network."
