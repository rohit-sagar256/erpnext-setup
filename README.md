# ERPNext / Frappe v15 Setup Guide

This project provides two installers:

- `setup-dev.sh` → Development setup (bench start, port 8000).
- `setup-prod.sh` → Production setup (Supervisor + Nginx, port 80).

---

## 🚀 Quickstart

### Development
```bash
bash setup-dev.sh
cd ~/frappe-bench
bench start
```
Access at: `http://<server-ip>:8000`

### Production
```bash
bash setup-prod.sh
```
Access at: `http://<server-ip>`

Default login:
- Username: `Administrator`
- Password: `admin`

---

## 📦 What the Scripts Do

- Update the server (`apt update && apt upgrade`).
- Install dependencies:
  - Python 3, pip, venv, distutils
  - MariaDB (MySQL-compatible)
  - Redis
  - Node.js + npm + Yarn
  - wkhtmltopdf (for PDF printing)
  - Git, Curl, Supervisor, Nginx
- Create `frappe` user.
- Install `frappe-bench`.
- Initialize bench in `/home/frappe/frappe-bench`.
- Create site (`dev.localhost` or `prod.localhost`).
- Install ERPNext app (v15).
- Build frontend assets.
- Configure Supervisor (production).
- Configure Nginx (production).
- Fix permissions so Nginx can serve `/assets`.

---

## ⚙️ Database (MariaDB)

ERPNext requires MariaDB properly configured.

Reset password if needed:
```bash
sudo mysql_secure_installation
```

Check status:
```bash
sudo systemctl status mariadb
```

Logs:
```bash
sudo journalctl -xeu mariadb
```

---

## 🖥️ Supervisor

Manages ERPNext workers/web in production.

Commands:
```bash
sudo supervisorctl status
sudo supervisorctl restart all
sudo journalctl -xeu supervisor
```

---

## 🌐 Nginx

Reverse proxy in production.

Config path:
```
/etc/nginx/sites-enabled/frappe-bench.conf
```

Reload:
```bash
sudo nginx -t
sudo systemctl reload nginx
```

### Example Nginx Config Snippets

#### Assets
```nginx
location /assets {
    alias /home/frappe/frappe-bench/sites/assets/;
    try_files $uri =404;
    add_header Cache-Control "max-age=31536000";
}
```

#### Public Files
```nginx
location /files {
    alias /home/frappe/frappe-bench/sites/site1.local/public/files/;
    try_files $uri =404;
}
```

#### Private Files
```nginx
location /private/files {
    internal;
    alias /home/frappe/frappe-bench/sites/site1.local/private/files/;
    try_files $uri =404;
}
```

---

## 🔒 Permissions

ERPNext often fails to serve CSS/JS because Nginx (`www-data`) can’t read assets.

### Quick way (less secure)
```bash
chmod -R o+rx /home/frappe
```

### Secure way (recommended)
```bash
sudo apt install acl -y
sudo setfacl -R -m u:www-data:rx /home/frappe/frappe-bench/sites
sudo setfacl -R -d -m u:www-data:rx /home/frappe/frappe-bench/sites
```

---

## 🛠️ Assets

Rebuild assets if UI looks broken:
```bash
cd ~/frappe-bench
bench build
bench clear-cache
bench clear-website-cache
```

On small VPS (low RAM), build may fail → add swap:
```bash
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

---

## 🐞 Troubleshooting

### Python errors
```bash
sudo python3 -m pip install --upgrade pip setuptools wheel --break-system-packages
```

### MariaDB connection refused
```bash
sudo systemctl restart mariadb
```

### Supervisor not starting
```bash
sudo apt remove --purge supervisor -y
sudo apt install supervisor -y
```

### Nginx shows default page
```bash
sudo rm /etc/nginx/sites-enabled/default
sudo systemctl reload nginx
```

### ERPNext assets broken (no CSS/JS)
```bash
cd ~/frappe-bench
bench build
```

---

## 🏗️ Multi-Site Setup

ERPNext supports multiple sites in one bench.

Create new site:
```bash
cd ~/frappe-bench
bench new-site demo.localhost --admin-password admin --mariadb-root-password root
bench --site demo.localhost install-app erpnext
```

Switch default site:
```bash
bench use demo.localhost
```

Rebuild Nginx config:
```bash
bench setup nginx
sudo systemctl reload nginx
```

---

## 🔐 Security Recommendations

- Change default MariaDB root password and ERPNext Administrator password.
- Enable HTTPS with Let’s Encrypt:
  ```bash
  bench setup lets-encrypt your-domain.com
  ```
- Regularly back up your sites:
  ```bash
  bench backup
  ```
- Avoid `chmod -R o+rx` in production, prefer ACL-based permissions.

---

## 🆘 Recovery (when everything breaks)

### Reset Python environment
```bash
sudo python3 -m pip install --upgrade pip setuptools wheel --break-system-packages
```

### Reset Supervisor
```bash
sudo apt remove --purge supervisor -y
sudo apt install supervisor -y
```

### Reset Nginx
```bash
sudo rm /etc/nginx/sites-enabled/default
sudo systemctl restart nginx
```

### Reset MariaDB
```bash
sudo mysql_secure_installation
```

### Rebuild ERPNext
```bash
cd ~/frappe-bench
bench build
bench restart
```

---

## ✅ Summary

- **Development** → Fast, simple, run with `bench start`.
- **Production** → Supervisor + Nginx, serves on port 80.
- README provides fixes for Python, Node, MariaDB, permissions, Supervisor, Nginx, and assets.
- Multi-site supported with additional `bench new-site` commands.
- Security hardened by changing defaults, enabling HTTPS, and using ACLs for permissions.
# erpnext-setup
