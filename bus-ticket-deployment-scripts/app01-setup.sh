#!/usr/bin/env bash
set -Eeuo pipefail
 
# Run as root on app01 (CentOS Stream 9).
DB_HOST="192.168.3.15"  # 👈 تم التحديث إلى الـ IP الصحيح لماكينة قاعدة البيانات
DB_PORT="3306"
DB_NAME="ticketing_system"
DB_USER="ticketapp"
REPO_URL="https://github.com/alaadin2005/bus-ticket.git"
PROJECT_DIR="/opt/bus-ticket"
WEBROOT="/var/lib/tomcat/webapps/ROOT"

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash $0"; exit 1; }

echo "== 1/8 Install Java 17, Tomcat, and tools =="
# تم نقل أمر التثبيت هنا خارج الـ if ليعمل دائماً ويوفر حزمة tomcat و javac لـ CentOS 9
dnf -y install git firewalld java-17-openjdk-devel tomcat mysql

echo "== 2/8 Get project source =="
if [[ ! -d "$PROJECT_DIR/.git" ]]; then
  git clone "$REPO_URL" "$PROJECT_DIR"
else
  echo "Repository already exists at $PROJECT_DIR; leaving it unchanged."
fi

[[ -d "$PROJECT_DIR/WebContent" ]] || { echo "Missing WebContent directory"; exit 1; }
[[ -f "$PROJECT_DIR/WebContent/WEB-INF/lib/mysql-connector-java-8.0.12.jar" ]] || {
  echo "Missing MySQL JDBC driver in repository"; exit 1;
}

echo "== 3/8 Set DB password for the app =="
DB_PASSWORD="Admin@123456"

echo "== 4/8 Update Database.java to use environment variables =="
cat > "$PROJECT_DIR/src/com/digitalbd/Database.java" <<JAVA
package com.digitalbd;
import java.sql.*;

public class Database {
    private String hostName = System.getenv().getOrDefault(
        "DB_URL", "jdbc:mysql://${DB_HOST}:${DB_PORT}/${DB_NAME}?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC");
    private String userName = System.getenv().getOrDefault("DB_USER", "${DB_USER}");
    private String userPassword = System.getenv().getOrDefault("DB_PASSWORD", "${DB_PASSWORD}");
    public Statement statement;
    private Connection con;

    public Database() {
        this.con = null;
        this.statement = null;
        try {
            Class.forName("com.mysql.cj.jdbc.Driver");
            this.con = DriverManager.getConnection(hostName, userName, userPassword);
            this.statement = this.con.createStatement();
        } catch (SQLException e) {
            System.err.println("Database connection failed: " + e.getMessage());
        } catch (ClassNotFoundException e) {
            e.printStackTrace();
        }
    }
}
JAVA

echo "== 5/8 Compile the DB connection class =="
mkdir -p "$PROJECT_DIR/build/classes"
javac -encoding UTF-8 \
  -cp "$PROJECT_DIR/WebContent/WEB-INF/lib/mysql-connector-java-8.0.12.jar:$PROJECT_DIR/build/classes" \
  -d "$PROJECT_DIR/build/classes" \
  "$PROJECT_DIR/src/com/digitalbd/Database.java"

echo "== 6/8 Configure service environment securely =="
install -d -m 0750 /etc/bus-ticket
cat > /etc/bus-ticket/app.env <<EOF
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT}
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
DB_URL=jdbc:mysql://${DB_HOST}:${DB_PORT}/${DB_NAME}?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC
EOF
chmod 0600 /etc/bus-ticket/app.env
unset DB_PASSWORD

mkdir -p /etc/systemd/system/tomcat.service.d
cat > /etc/systemd/system/tomcat.service.d/bus-ticket.conf <<'EOF'
[Service]
EnvironmentFile=/etc/bus-ticket/app.env
EOF
systemctl daemon-reload

echo "== 7/8 Deploy JSPs, classes and JDBC driver =="
systemctl stop tomcat || true
rm -rf "$WEBROOT"
mkdir -p "$WEBROOT/WEB-INF/classes" "$WEBROOT/WEB-INF/lib"
cp -a "$PROJECT_DIR/WebContent/." "$WEBROOT/"
cp -a "$PROJECT_DIR/build/classes/." "$WEBROOT/WEB-INF/classes/"
cp -a "$PROJECT_DIR/WebContent/WEB-INF/lib/mysql-connector-java-8.0.12.jar" "$WEBROOT/WEB-INF/lib/"
chown -R tomcat:tomcat "$WEBROOT"
restorecon -RF "$WEBROOT" 2>/dev/null || true

echo "== 8/8 Start and verify Tomcat =="
systemctl enable --now tomcat
sleep 5
systemctl --no-pager --full status tomcat || true
echo
echo "Local HTTP check:"
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' http://127.0.0.1:8080 || true

sudo firewall-cmd --permanent --add-port=8080/tcp
sudo firewall-cmd --reload

