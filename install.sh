#!/usr/bin/env bash

# Membuat file password.txt jika belum ada
PASSWORD_FILE="password.txt"
if [ ! -f "$PASSWORD_FILE" ]; then
    echo "QUIN-BASH" > "$PASSWORD_FILE"
fi

# Membaca password dari file
PASSWORD=$(cat "$PASSWORD_FILE")

# Meminta input password dari pengguna
read -sp "Masukkan password: " INPUT_PASSWORD
echo

# Memverifikasi password
if [ "$INPUT_PASSWORD" != "$PASSWORD" ]; then
    echo "Password salah! Proses dihentikan."
    exit 1
fi

echo "Password benar! Melanjutkan proses instalasi..."

# Meminta input domain dari pengguna
read -p "Masukkan domain Anda (contoh: example.com): " DOMAIN
SCRIPT_FILE="install_script.sh"  # Ganti dengan nama file script Anda

# Memastikan bahwa domain placeholder ada di dalam file install_script.sh
if grep -q "YOUR.DOMAIN.HERE" "$SCRIPT_FILE"; then
    # Mengganti placeholder di dalam file script dengan domain yang dimasukkan
    sed -i "s/YOUR.DOMAIN.HERE/$DOMAIN/g" "$SCRIPT_FILE"
    echo "Domain telah diganti menjadi $DOMAIN dalam file $SCRIPT_FILE."
else
    echo "Domain placeholder tidak ditemukan di dalam $SCRIPT_FILE"
    exit 1
fi

# Memilih opsi depend files
echo "Pilih opsi:"
echo "1. Depend Files"
echo "0. Keluar dari Installer"
read -p "Pilih opsi (0-1): " OPTION

if [ "$OPTION" -eq 1 ]; then
    # Menjalankan perintah untuk depend files
    echo "Menginstal depend files..."
    apt update && apt -y install software-properties-common curl apt-transport-https ca-certificates gnupg || { echo "Gagal menginstal dependensi."; exit 1; }
    
    LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php || { echo "Gagal menambahkan repository PHP."; exit 1; }
    
    curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | sudo bash || { echo "Gagal menambahkan repository MariaDB."; exit 1; }
    
    apt update || { echo "Gagal memperbarui apt."; exit 1; }
    apt -y install php8.3 php8.3-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip} mariadb-server nginx git || { echo "Gagal menginstal PHP, MariaDB, Nginx, atau Git."; exit 1; }

    # Menginstal Ctrlpanel
    echo "Menginstal Ctrlpanel..."
    apt -y install php8.3-{intl,redis} || { echo "Gagal menginstal dependensi PHP."; exit 1; }
    curl -sS https://getcomposer.org/installer | sudo php -- --install-dir=/usr/local/bin --filename=composer || { echo "Gagal menginstal Composer."; exit 1; }
    
    mkdir -p /var/www/ctrlpanel && cd /var/www/ctrlpanel
    git clone https://github.com/Ctrlpanel-gg/panel.git ./ || { echo "Gagal mengunduh repository Ctrlpanel."; exit 1; }
    
    # Menambahkan user dan database ke MySQL
    echo "Membuat user dan database MySQL..."
    mysql -u root -p"$PASSWORD" <<EOF
CREATE USER 'ctrlpaneluser'@'127.0.0.1' IDENTIFIED BY 'QUIN-BASH'; 
CREATE DATABASE ctrlpanel;
GRANT ALL PRIVILEGES ON ctrlpanel.* TO 'ctrlpaneluser'@'127.0.0.1';
FLUSH PRIVILEGES;
EXIT;
EOF

    COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader || { echo "Gagal menjalankan Composer."; exit 1; }

    # Menginstal Certbot untuk SSL
    sudo apt update && sudo apt install -y certbot python3-certbot-nginx || { echo "Gagal menginstal Certbot."; exit 1; }
    
    certbot certonly --nginx -d "$DOMAIN" || { echo "Gagal mendapatkan sertifikat SSL."; exit 1; }

    # Konfigurasi Nginx
    echo "Mengonfigurasi Nginx..."
    rm /etc/nginx/sites-enabled/default
    cat <<EOL | sudo tee /etc/nginx/sites-available/ctrlpanel.conf
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    root /var/www/ctrlpanel/public;
    index index.php;

    access_log /var/log/nginx/ctrlpanel.app-access.log;
    error_log  /var/log/nginx/ctrlpanel.app-error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;

    sendfile off;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_session_cache shared:SSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384";
    ssl_prefer_server_ciphers on;

    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Robots-Tag none;
    add_header Content-Security-Policy "frame-ancestors 'self'";
    add_header X-Frame-Options DENY;
    add_header Referrer-Policy same-origin;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
        include /etc/nginx/fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOL

    sudo ln -s /etc/nginx/sites-available/ctrlpanel.conf /etc/nginx/sites-enabled/ctrlpanel.conf
    sudo nginx -t || { echo "Konfigurasi Nginx gagal."; exit 1; }
    systemctl restart nginx || { echo "Gagal merestart Nginx."; exit 1; }
    chown -R www-data:www-data /var/www/ctrlpanel/
    chmod -R 755 /var/www/ctrlpanel/storage/* /var/www/ctrlpanel/bootstrap/cache/ || { echo "Gagal mengubah permission file."; exit 1; }
    
    # Menambahkan cron job
    (crontab -l 2>/dev/null; echo "1 * * * * php /var/www/ctrlpanel/artisan schedule:run >> /dev/null 2>&1") | crontab -
    
    # Membuat service untuk Ctrlpanel Queue Worker
    cat <<EOL | sudo tee /etc/systemd/system/ctrlpanel.service
[Unit]
Description=Ctrlpanel Queue Worker

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/ctrlpanel/artisan queue:work --sleep=3 --tries=3
StartLimitBurst=0

[Install]
WantedBy=multi-user.target
EOL

    # Mengaktifkan dan memulai service
    sudo systemctl enable ctrlpanel.service || { echo "Gagal mengaktifkan service."; exit 1; }
    sudo systemctl start ctrlpanel.service || { echo "Gagal memulai service."; exit 1; }

    echo "Instalasi selesai!"
else
    echo "Keluar dari installer."
    exit 0
fi
