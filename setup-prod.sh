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

echo "[+] Installing production dependencies..."
sudo apt install -y   python3-dev python3-setuptools python3-pip python3-venv python3-distutils   mariadb-server mariadb-client redis-server   curl wget git   xvfb libfontconfig wkhtmltopdf   nodejs npm yarn supervisor nginx acl

echo "[+] Configuring MariaDB..."
sudo mysql -uroot <<MYSQL_SCRIPT
ALTER USER 'root'@'localhost' IDENTIFIED BY '$DB_PASS';
FLUSH PRIVILEGES;
MYSQL_SCRIPT

if ! id -u $USER >/dev/null 2>&1; then
  echo "[+] Creating user $USER..."
  sudo adduser --disabled-password --gecos "" $USER
  sudo usermod -aG sudo $USER
fi

echo "[+] Setting up Frappe Bench as $USER..."
sudo -i -u $USER bash <<EOF
cd ~

pip3 install --user frappe-bench

bench init --frappe-path https://github.com/frappe/frappe --frappe-branch $FRAPPE_BRANCH $BENCH_DIR

cd $BENCH_DIR
bench new-site prod.localhost --admin-password $ADMIN_PASS --mariadb-root-password $DB_PASS

bench get-app --branch $ERP_BRANCH erpnext https://github.com/frappe/erpnext
bench --site prod.localhost install-app erpnext

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

echo "[+] Production setup complete with workers, scheduler, and daily backups."
echo "Access ERPNext at: http://<server-ip>"
