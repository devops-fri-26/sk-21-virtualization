
#!/usr/bin/env bash
set -euo pipefail

echo "================================"
echo " Namestitev BookStack okolja"
echo "================================"

# Posodobitev paketov
apt-get update

# Namestitev osnovnih paketov
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    nginx \
    mariadb-server \
    git \
    curl \
    unzip \
    composer \
    openssl \
    php8.3-fpm \
    php8.3-cli \
    php8.3-mysql \
    php8.3-mbstring \
    php8.3-xml \
    php8.3-curl \
    php8.3-zip \
    php8.3-gd \
    php8.3-intl \
    php8.3-bcmath

systemctl enable --now nginx
systemctl enable --now mariadb
systemctl enable --now php8.3-fpm

echo "Osnovni paketi so namesceni!"

# ========================================
# MariaDB
# ========================================

echo "Konfiguriram podatkovno bazo..."

# Geslo podatkovne baze hranimo samo znotraj VM
install -d -m 700 /etc/bookstack

DB_PASSWORD_FILE="/etc/bookstack/db-password"

if [ -f "$DB_PASSWORD_FILE" ]; then
    # Pri ponovni namestitvi uporabi obstojece geslo
    DB_PASSWORD="$(cat "$DB_PASSWORD_FILE")"
else
    # Ob prvi namestitvi ustvari nakljucno geslo
    DB_PASSWORD="${BOOKSTACK_DB_PASSWORD:-$(openssl rand -hex 24)}"

    printf '%s\n' "$DB_PASSWORD" > "$DB_PASSWORD_FILE"
    chmod 600 "$DB_PASSWORD_FILE"
fi

mariadb <<SQL
CREATE DATABASE IF NOT EXISTS bookstack
CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS 'bookstack'@'localhost'
IDENTIFIED BY '${DB_PASSWORD}';

ALTER USER 'bookstack'@'localhost'
IDENTIFIED BY '${DB_PASSWORD}';

GRANT ALL PRIVILEGES ON bookstack.*
TO 'bookstack'@'localhost';
SQL

echo "Podatkovna baza je pripravljena!"

# ========================================
# BookStack
# ========================================

echo "Namescam BookStack..."

if [ ! -d /var/www/bookstack/.git ]; then
    git clone --branch release \
        https://github.com/BookStackApp/BookStack.git \
        /var/www/bookstack
fi

cd /var/www/bookstack

COMPOSER_ALLOW_SUPERUSER=1 composer install \
    --no-dev \
    --no-interaction \
    --prefer-dist \
    --optimize-autoloader \
    --no-scripts

chown -R www-data:www-data /var/www/bookstack
chmod -R 775 storage bootstrap/cache

if [ ! -f .env ]; then
    cp .env.example .env
fi

# URL aplikacije prek HTTPS
sed -i 's|^APP_URL=.*|APP_URL=https://localhost:8443|' .env

# Podatkovna baza
sed -i 's|^DB_HOST=.*|DB_HOST=localhost|' .env
sed -i 's|^DB_DATABASE=.*|DB_DATABASE=bookstack|' .env
sed -i 's|^DB_USERNAME=.*|DB_USERNAME=bookstack|' .env
sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${DB_PASSWORD}|" .env

if ! grep -Eq '^APP_KEY=base64:.+' .env; then
    php artisan key:generate --force
fi

php artisan migrate --force

chown -R www-data:www-data /var/www/bookstack
chmod -R 775 storage bootstrap/cache

echo "BookStack je pripravljen!"

# ========================================
# HTTPS CERTIFIKAT
# ========================================

echo "Ustvarjam HTTPS certifikat..."

mkdir -p /etc/nginx/ssl

if [ ! -f /etc/nginx/ssl/bookstack.crt ] || \
   [ ! -f /etc/nginx/ssl/bookstack.key ]; then

    openssl req -x509 -nodes -days 365 \
        -newkey rsa:2048 \
        -keyout /etc/nginx/ssl/bookstack.key \
        -out /etc/nginx/ssl/bookstack.crt \
        -subj "/CN=localhost" \
        -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
fi

chmod 600 /etc/nginx/ssl/bookstack.key

echo "HTTPS certifikat je pripravljen!"

# ========================================
# NGINX
# ========================================

echo "Konfiguriram Nginx..."

cat > /etc/nginx/sites-available/bookstack <<'EOF'
server {
    listen 80;
    server_name _;

    root /var/www/bookstack/public;
    index index.php index.html;

    client_max_body_size 100M;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}

server {
    listen 443 ssl;
    server_name localhost;

    ssl_certificate /etc/nginx/ssl/bookstack.crt;
    ssl_certificate_key /etc/nginx/ssl/bookstack.key;

    root /var/www/bookstack/public;
    index index.php index.html;

    client_max_body_size 100M;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF

ln -sfn /etc/nginx/sites-available/bookstack \
    /etc/nginx/sites-enabled/bookstack

rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl reload nginx

echo "Nginx in HTTPS sta pripravljena!"

# ========================================
# REDIS
# ========================================

echo "Namescam Redis..."

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    redis-server \
    php8.3-redis

systemctl enable --now redis-server

sed -i 's/^bind .*/bind 127.0.0.1 -::1/' \
    /etc/redis/redis.conf

systemctl restart redis-server

cd /var/www/bookstack

# Odstrani morebitne stare Redis nastavitve
sed -i '/^CACHE_DRIVER=/d' .env
sed -i '/^CACHE_STORE=/d' .env
sed -i '/^CACHE_SESSION_DRIVER=/d' .env
sed -i '/^SESSION_DRIVER=/d' .env
sed -i '/^REDIS_HOST=/d' .env
sed -i '/^REDIS_PORT=/d' .env
sed -i '/^REDIS_PASSWORD=/d' .env
sed -i '/^REDIS_SERVERS=/d' .env

cat >> .env <<'EOF'

CACHE_DRIVER=redis
SESSION_DRIVER=file
REDIS_SERVERS=127.0.0.1:6379:0
EOF

php artisan config:clear
php artisan cache:clear

chown www-data:www-data .env

systemctl restart php8.3-fpm

echo "Redis je pripravljen!"

# ========================================
# UFW IN FAIL2BAN
# ========================================

echo "Namescam varnostna orodja..."

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ufw \
    fail2ban

ufw default deny incoming
ufw default allow outgoing

# SSH
ufw allow 22/tcp

# HTTP in HTTPS
ufw allow 80/tcp
ufw allow 443/tcp

# Netdata samo prek VirtualBox NAT prehoda
ufw allow from 10.0.2.2 to any port 19999 proto tcp

ufw --force enable

echo "UFW je konfiguriran!"

# Fail2ban
cat > /etc/fail2ban/jail.d/sshd.local <<'EOF'
[sshd]
enabled = true
port = ssh
filter = sshd
backend = systemd
maxretry = 5
findtime = 600
bantime = 600
banaction = ufw
EOF

systemctl enable --now fail2ban
systemctl restart fail2ban

echo "Fail2ban je konfiguriran!"

# ========================================
# NETDATA
# ========================================

echo "Namescam Netdata..."

DEBIAN_FRONTEND=noninteractive apt-get install -y netdata

systemctl enable --now netdata

mkdir -p /etc/netdata

cat > /etc/netdata/netdata.conf <<'EOF'
[web]
    bind to = 0.0.0.0
EOF

systemctl restart netdata

echo "================================"
echo " Namestitev BookStack je koncana!"
echo " HTTPS: https://localhost:8443"
echo " Netdata: http://localhost:19999"
echo "================================"
