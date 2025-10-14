#!/bin/bash
set -euo pipefail

# -------------------------
# Configuration (edit these)
# -------------------------
USER=frappe
BENCH_DIR=/home/$USER/frappe-bench
FRAPPE_BRANCH=version-15
ERP_BRANCH=version-15
DB_PASS="root"              # MariaDB root password (change if you want)
ADMIN_PASS="admin"          # ERPNext admin password (change)
SITE_NAME="prod.localhost"  # site name used by bench (prod.localhost by default)
WEB_PORTS="80 443 8000"     # ports to open in firewall (8000 optional for dev)

# -------------------------
# Helpers
# -------------------------
echo_prefix() { echo -e "\n[+] $1"; }

# -------------------------
# 1) Ensure swap (2GB)
# -------------------------
echo_prefix "Ensuring 2GB swap (helps yarn and pip builds on small instances)..."
if ! swapon --show | grep -q swapfile; then
  sudo fallocate -l 2G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab > /dev/null
else
  echo "Swap already present."
fi
free -h

# -------------------------
# 2) System update & base packages
# -------------------------
echo_prefix "Updating apt and installing base packages..."
sudo apt update && sudo apt upgrade -y
# Add packages needed by Frappe, w/ $PY_PKG placeholder resolved next
sudo apt install -y apt-transport-https ca-certificates curl gnupg lsb-release software-properties-common

# -------------------------
# 3) Python distutils detection (robust)
# -------------------------
echo_prefix "Detecting Python distutils/stdlib package..."
DISTUTILS_CANDIDATE=$(apt-cache policy python3-distutils 2>/dev/null | awk '/Candidate:/ {print $2}' || true)
if [ -n "$DISTUTILS_CANDIDATE" ] && [ "$DISTUTILS_CANDIDATE" != "(none)" ]; then
  PY_PKG="python3-distutils"
elif apt-cache show python3-stdlib-extensions >/dev/null 2>&1; then
  PY_PKG="python3-stdlib-extensions"
else
  PY_PKG="python3-setuptools"
fi
echo "Selected Python helper package: $PY_PKG"

# -------------------------
# 4) Install production dependencies
# -------------------------
echo_prefix "Installing production dependencies (may take a while)..."
sudo apt install -y \
  python3-dev python3-setuptools python3-pip python3-venv $PY_PKG \
  mariadb-server mariadb-client redis-server \
  curl wget git xvfb libfontconfig wkhtmltopdf \
  build-essential supervisor nginx acl unzip

# (Optional) install recommended yarn/node prereqs via upstream repo if you want latest node packages
# We'll install Node via `n` to ensure Node v18 LTS.
echo_prefix "Installing Node 18 (LTS) and Yarn..."
# ensure npm exists
sudo apt install -y npm
sudo npm cache clean -f || true
sudo npm install -g n
sudo n 18.19.0
# install Yarn (core)
sudo npm install -g yarn
# ensure /usr/local/bin is in PATH for subsequent commands
export PATH="$PATH:/usr/local/bin"
node -v || true
yarn -v || true

# -------------------------
# 5) MariaDB configuration (EC2-safe)
# -------------------------
echo_prefix "Configuring MariaDB (EC2-safe socket -> password conversion)..."
sudo systemctl enable mariadb
sudo systemctl start mariadb

PLUGIN=$(sudo mariadb -N -e "SELECT plugin FROM mysql.user WHERE user='root' AND host='localhost';" || echo "unknown")
if [ "$PLUGIN" = "unix_socket" ]; then
  echo_prefix "Root uses unix_socket; switching to mysql_native_password..."
  sudo mariadb -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$DB_PASS'; FLUSH PRIVILEGES;"
else
  echo "Root plugin is $PLUGIN (no change required)."
fi

# verify login
if mysql -u root -p"$DB_PASS" -e "SELECT VERSION();" >/dev/null 2>&1; then
  echo "MariaDB password auth OK."
else
  echo "Retrying MariaDB password setup via socket..."
  sudo mariadb -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$DB_PASS'; FLUSH PRIVILEGES;"
  mysql -u root -p"$DB_PASS" -e "SELECT VERSION();" || { echo "MariaDB setup failed"; exit 1; }
fi

# -------------------------
# 6) Create frappe system user & groups
# -------------------------
echo_prefix "Creating system user '$USER' (if missing) and setting permissions..."
if ! id -u $USER >/dev/null 2>&1; then
  sudo adduser --disabled-password --gecos "" $USER
  sudo usermod -aG sudo $USER
  echo "Created user $USER and added to sudo group."
else
  echo "User $USER already exists."
fi
# Ensure home ownership and safe permission
sudo mkdir -p /home/$USER
sudo chown -R $USER:$USER /home/$USER
sudo chmod 750 /home/$USER

# -------------------------
# 7) Ensure Redis and Supervisor running
# -------------------------
echo_prefix "Enabling & starting redis-server and supervisor..."
sudo systemctl enable redis-server
sudo systemctl start redis-server
sudo systemctl enable supervisor
sudo systemctl start supervisor

# -------------------------
# 8) Install frappe-bench globally (system pip), bench CLI
# -------------------------
echo_prefix "Installing bench CLI (frappe-bench) globally..."
if ! command -v bench >/dev/null 2>&1; then
  # Ubuntu upstream blocks system pip installs; we allow override for single-server installs
  sudo pip3 install frappe-bench --break-system-packages
fi
export PATH="$PATH:/usr/local/bin"
bench --version || true

# -------------------------
# 9) Pre-check: ensure supervisor active (bench uses it)
# -------------------------
echo_prefix "Verifying Supervisor is active..."
if ! sudo systemctl is-active --quiet supervisor; then
  echo "Supervisor is not active; attempting start..."
  sudo systemctl start supervisor
  sleep 2
fi
sudo systemctl status supervisor --no-pager || true

# -------------------------
# 10) Initialize bench as $USER, install ERPNext (idempotent)
# -------------------------
echo_prefix "Initializing bench and installing ERPNext as $USER..."
sudo -i -u $USER bash <<EOF
set -euo pipefail
export PATH="\$PATH:/usr/local/bin:\$HOME/.local/bin"

# move to home
cd ~

# If bench dir exists but is broken, you may want to remove it manually.
if [ ! -d "$BENCH_DIR" ]; then
  echo "[inside user] bench init..."
  bench init --frappe-branch $FRAPPE_BRANCH $BENCH_DIR
else
  echo "[inside user] bench directory already exists; skipping bench init."
fi

cd $BENCH_DIR

# create site if missing
if [ ! -d "sites/$SITE_NAME" ]; then
  echo "[inside user] Creating new site $SITE_NAME"
  bench new-site $SITE_NAME --admin-password $ADMIN_PASS --mariadb-root-password $DB_PASS --install-app --quiet || true
else
  echo "[inside user] site $SITE_NAME already exists."
fi

# fetch ERPNext app if missing
if [ ! -d "apps/erpnext" ]; then
  echo "[inside user] Getting erpnext app..."
  bench get-app --branch $ERP_BRANCH https://github.com/frappe/erpnext
else
  echo "[inside user] apps/erpnext already present."
fi

# install erpnext on site (idempotent)
echo "[inside user] Installing ERPNext on site (may take time)..."
bench --site $SITE_NAME install-app erpnext || true

# build assets (yarn+webpack) — verbose to help debugging
echo "[inside user] Building assets..."
bench build --verbose || true

EOF

# -------------------------
# 11) Supervisor and Nginx configuration from bench
# -------------------------
echo_prefix "Setting up Supervisor and Nginx from bench config..."
sudo -i -u $USER bash <<EOF
set -euo pipefail
cd $BENCH_DIR
bench setup supervisor
bench setup nginx
EOF

# link generated configs
sudo ln -sf $BENCH_DIR/config/supervisor.conf /etc/supervisor/conf.d/frappe-bench.conf
sudo ln -sf $BENCH_DIR/config/nginx.conf /etc/nginx/sites-enabled/frappe-bench.conf
# remove default nginx site to avoid conflicts
sudo rm -f /etc/nginx/sites-enabled/default

# set file permissions for web user
sudo setfacl -R -m u:www-data:rx $BENCH_DIR/sites || true
sudo setfacl -R -d -m u:www-data:rx $BENCH_DIR/sites || true

# -------------------------
# 12) Reload supervisor & restart services
# -------------------------
echo_prefix "Reloading supervisor configs and restarting services..."
sudo supervisorctl reread || true
sudo supervisorctl update || true
sudo systemctl restart supervisor || true
# test nginx config and restart
sudo nginx -t || true
sudo systemctl restart nginx || true

# -------------------------
# 13) Enable scheduler and workers
# -------------------------
echo_prefix "Enabling scheduler for site..."
sudo -i -u $USER bash <<EOF
cd $BENCH_DIR
bench --site $SITE_NAME enable-scheduler || true
EOF

# -------------------------
# 14) Cron backup
# -------------------------
echo_prefix "Installing daily backup cron job (02:00)..."
CRON_JOB="0 2 * * * cd $BENCH_DIR && bench --site $SITE_NAME backup >> $HOME/bench-backup.log 2>&1"
( sudo crontab -l 2>/dev/null | grep -v "$BENCH_DIR" || true ; echo "$CRON_JOB" ) | sudo crontab -

# -------------------------
# 15) UFW firewall (optional - only if ufw is active)
# -------------------------
echo_prefix "Opening ports in UFW if UFW active..."
if sudo ufw status | grep -q "Status: active"; then
  for p in $WEB_PORTS; do
    sudo ufw allow $p/tcp || true
  done
  sudo ufw reload || true
fi

# -------------------------
# 16) Final checks & status
# -------------------------
echo_prefix "Final service status checks..."
echo "Nginx status:"
sudo systemctl status nginx --no-pager
echo "Supervisor status:"
sudo systemctl status supervisor --no-pager
echo "Redis status:"
sudo systemctl status redis-server --no-pager

echo
echo "=========================================================="
echo "[✔] Production setup (script) completed!"
echo "Visit: http://<your-server-ip>"
echo "Login: admin / $ADMIN_PASS"
echo "MariaDB root password: $DB_PASS"
echo "Bench dir: $BENCH_DIR (owned by $USER)"
echo "=========================================================="
