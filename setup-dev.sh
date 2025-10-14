#!/bin/bash
set -e

# --- Configuration ---
USER=frappe
BENCH_DIR=/home/$USER/frappe-bench
FRAPPE_BRANCH=version-15
ERP_BRANCH=version-15
DB_PASS="root"     # MariaDB root password
ADMIN_PASS="admin" # ERPNext admin password

# --- Ensure 2GB Swap (for low-memory EC2) ---
echo "[+] Ensuring swap space..."
if ! swapon --show | grep -q swapfile; then
  sudo fallocate -l 2G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
fi
free -h

# --- System update ---
echo "[+] Updating system..."
sudo apt update && sudo apt upgrade -y

# --- Python package detection ---
echo "[+] Checking Python dependencies..."
DISTUTILS_CANDIDATE=$(apt-cache policy python3-distutils | grep Candidate | awk '{print $2}')

if [ "$DISTUTILS_CANDIDATE" != "(none)" ] && [ -n "$DISTUTILS_CANDIDATE" ]; then
  echo "[+] Using python3-distutils..."
  PY_PKG="python3-distutils"
elif apt-cache show python3-stdlib-extensions >/dev/null 2>&1; then
  echo "[+] Using python3-stdlib-extensions..."
  PY_PKG="python3-stdlib-extensions"
else
  echo "[!] Neither python3-distutils nor python3-stdlib-extensions available. Falling back to setuptools..."
  PY_PKG="python3-setuptools"
fi

# --- Install dependencies ---
echo "[+] Installing dependencies..."
sudo apt install -y \
  python3-dev python3-setuptools python3-pip python3-venv $PY_PKG \
  mariadb-server mariadb-client redis-server \
  curl wget git xvfb libfontconfig wkhtmltopdf \
  nodejs npm yarn supervisor nginx acl

# --- Node/Yarn sanity check ---
echo "[+] Installing compatible Node and Yarn versions..."
sudo npm cache clean -f
sudo npm install -g n
sudo n 18.19.0
sudo npm install -g yarn
export PATH="$PATH:/usr/local/bin"
node -v
yarn -v

# --- Configure MariaDB securely (AWS EC2–compatible) ---
echo "[+] Configuring MariaDB (AWS EC2 safe root setup)..."
sudo systemctl enable mariadb
sudo systemctl start mariadb

PLUGIN=$(sudo mariadb -N -e "SELECT plugin FROM mysql.user WHERE user='root' AND host='localhost';" || echo "unknown")

if [ "$PLUGIN" = "unix_socket" ]; then
  echo "[+] Root currently uses unix_socket, switching to mysql_native_password..."
  sudo mariadb -e "
    ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$DB_PASS';
    FLUSH PRIVILEGES;
  "
else
  echo "[+] Root already uses mysql_native_password or compatible plugin."
fi

# Verify login
if mysql -u root -p"$DB_PASS" -e "SELECT VERSION();" >/dev/null 2>&1; then
  echo "[✓] MariaDB root password configured successfully."
else
  echo "[✖] Retrying MariaDB root password configuration..."
  sudo mariadb -e "
    ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$DB_PASS';
    FLUSH PRIVILEGES;
  "
  mysql -u root -p"$DB_PASS" -e "SELECT VERSION();" || { echo "[✖] Final MariaDB configuration failed."; exit 1; }
fi

# --- Ensure Supervisor is running ---
echo "[+] Ensuring Supervisor service is active..."
sudo systemctl enable supervisor
sudo systemctl start supervisor
sudo systemctl status supervisor --no-pager || true

# --- Create frappe system user ---
if ! id -u $USER >/dev/null 2>&1; then
  echo "[+] Creating user '$USER'..."
  sudo adduser --disabled-password --gecos "" $USER
  sudo usermod -aG sudo $USER
  sudo chown -R $USER:$USER /home/$USER
else
  echo "[+] User '$USER' already exists."
fi

# --- Install Bench globally ---
echo "[+] Installing frappe-bench globally..."
if ! command -v bench >/dev/null 2>&1; then
  echo "[+] Installing frappe-bench with system override..."
  sudo pip3 install frappe-bench --break-system-packages
fi

# --- Setup Frappe Bench environment ---
echo "[+] Setting up Frappe Bench as user '$USER'..."
sudo -i -u $USER bash <<EOF
set -e
export PATH="\$PATH:/usr/local/bin:\$HOME/.local/bin"
cd ~

# Initialize bench if missing
if [ ! -d "$BENCH_DIR" ]; then
  echo "[+] Initializing bench environment..."
  bench init --frappe-branch $FRAPPE_BRANCH $BENCH_DIR
fi

cd $BENCH_DIR

# Create site if missing
if [ ! -d "sites/dev.localhost" ]; then
  echo "[+] Creating new site 'dev.localhost'..."
  bench new-site dev.localhost --admin-password $ADMIN_PASS --mariadb-root-password $DB_PASS
fi

# Get and install ERPNext
if [ ! -d "apps/erpnext" ]; then
  echo "[+] Fetching ERPNext app..."
  bench get-app --branch $ERP_BRANCH https://github.com/frappe/erpnext
fi

echo "[+] Installing ERPNext on site..."
bench --site dev.localhost install-app erpnext

echo "[+] Building front-end assets..."
bench build --verbose

echo
echo "[✔] Development setup complete!"
echo "Run: cd $BENCH_DIR && bench start"
EOF

echo
echo "=========================================================="
echo "[✔] ERPNext (Frappe v15) installation completed!"
echo "Access URL: http://<your-server-ip>:8000"
echo "Login: admin / $ADMIN_PASS"
echo "MariaDB root password: $DB_PASS"
echo "=========================================================="
