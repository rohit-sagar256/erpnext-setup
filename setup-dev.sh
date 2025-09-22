#!/bin/bash
set -e

USER=frappe
BENCH_DIR=/home/$USER/frappe-bench
FRAPPE_BRANCH=version-15
ERP_BRANCH=version-15
DB_PASS="root"   # change as needed
ADMIN_PASS="admin"

echo "[+] Updating system..."
sudo apt update && sudo apt upgrade -y

echo "[+] Installing core dependencies..."
sudo apt install -y \
  python3-dev python3-setuptools python3-pip python3-venv python3-distutils \
  mariadb-server mariadb-client redis-server \
  curl wget git \
  xvfb libfontconfig wkhtmltopdf \
  nodejs npm yarn

# Setup MariaDB for ERPNext
echo "[+] Configuring MariaDB..."
sudo mysql -uroot <<MYSQL_SCRIPT
ALTER USER 'root'@'localhost' IDENTIFIED BY '$DB_PASS';
FLUSH PRIVILEGES;
MYSQL_SCRIPT

# Create frappe user
if ! id -u $USER >/dev/null 2>&1; then
  echo "[+] Creating user $USER..."
  sudo adduser --disabled-password --gecos "" $USER
  sudo usermod -aG sudo $USER
fi

echo "[+] Switching to $USER..."
sudo -i -u $USER bash <<EOF
cd ~

pip3 install --user frappe-bench

bench init --frappe-path https://github.com/frappe/frappe --frappe-branch $FRAPPE_BRANCH $BENCH_DIR

cd $BENCH_DIR
bench new-site dev.localhost --admin-password $ADMIN_PASS --mariadb-root-password $DB_PASS

bench get-app --branch $ERP_BRANCH erpnext https://github.com/frappe/erpnext
bench --site dev.localhost install-app erpnext

bench build

echo "[+] Development setup done. Run: cd $BENCH_DIR && bench start"
EOF
