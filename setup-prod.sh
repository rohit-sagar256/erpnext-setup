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

echo "[+] Checking Python dependencies..."

# Detect correct Python package for distutils / stdlib extensions
if ! apt-cache show python3-distutils >/dev/null 2>&1; then
  echo "[!] python3-distutils not found, using python3-stdlib-extensions instead..."
  PY_PKG="python3-stdlib-extensions"
else
  PY_PKG="python3-distutils"
fi

echo "[+] Installing production dependencies..."
sudo apt install -y \
  python3-dev python3-setuptools python3-pip python3-venv $PY_PKG \
  mariadb-server mariadb-client redis-server \
  curl wget git xvfb libfontconfig wkhtmltopdf \
  nodejs npm yarn supervisor nginx acl

echo "[+] Configuring MariaDB..."
sudo systemctl enable mariadb
sudo systemctl start mariadb

sudo mysql -uroot <<MYSQL_SCRIPT
ALTER USER 'root'@'localhost' IDENTIFIED BY '$DB_PASS';
FLUSH PRIVILEGES;
MYSQL_SCRIPT

echo "[+] Verifying user: $USER..."
if ! id -u $USER >/dev/null 2>&1; then
  echo "[+] Creating user $USER..."
  sudo adduser --disabled-password --gecos "" $USER
  sudo usermod -aG sudo $USER
else
  echo "[+] User $USER already exists."
fi

echo "[+] Setting up Frappe Bench as $USER..."
sudo -i -u $USER bash <<EOF
cd ~

# Install frappe-bench if not already installed
if ! command -v bench &> /dev/null; then
  echo "[+] Installing frappe-bench..."
  pip3 install --user frappe-bench
fi

echo "[+] Initializing Frappe Bench..."
bench init --frappe-path https://github.com/frappe/frappe --frappe-branch $FRAPPE_BRANCH $BENCH_DIR

cd $BENCH_DIR
echo "[+] Creating new site..."
bench new-site prod.localhost --admin-password $ADMIN_PASS --mariadb-root-password $DB_PASS

echo "[+] Getting ERPNext app..."
bench get-app --branch $ERP_BRANCH erpnext https://github.com/frappe/erpnext

echo "[+] Installing ERPNext on site..."
bench --site prod.localhost install-app erpnext

echo "[+] Building assets..."
bench build
EOF

echo "[+] Configuring Supervisor & Nginx..."
sudo -i -u $USER bash <<EOF
cd $BENCH_DIR
bench setup supervisor
bench setup nginx
EOF

sudo ln -sf $BENCH_DIR/config/supervisor.conf /etc/supervisor/conf.d/frappe-bench.conf
sudo ln -sf $BENCH_DIR/config/nginx.conf /etc/nginx/sites-enabled/frappe-bench.conf
sudo rm -f /etc/nginx/sites-enabled/default

sudo setfacl -R -m u:www-data:rx /home/$USER/frappe-bench/sites
sudo setfacl -R -d -m u:www-data:rx /home/$USER/frappe-bench/sites

echo "[+] Restarting Supervisor and Nginx..."
sudo supervisorctl reread
sudo supervisorctl update
sudo systemctl restart supervisor
sudo systemctl restart nginx

echo "[+] Enabling Scheduler and Workers..."
sudo -i -u $USER bash <<EOF
cd $BENCH_DIR
bench --site prod.localhost enable-scheduler
EOF

echo "[+] Setting up Daily Auto Backup via cron..."
CRON_JOB="0 2 * * * cd $BENCH_DIR && bench --site prod.localhost backup"
( sudo crontab -l 2>/dev/null | grep -v "$BENCH_DIR" ; echo "$CRON_JOB" ) | sudo crontab -

echo
echo "=========================================================="
echo "[✔] Production setup complete!"
echo "[+] ERPNext URL: http://<your-server-ip>"
echo "[+] Login with admin / $ADMIN_PASS"
echo "=========================================================="
