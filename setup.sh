#!/usr/bin/env bash
# نصب خودکار سرور «تضمین تراز» روی Ubuntu 22.04 / 24.04
# اجرا:  curl -fsSL https://cdn.jsdelivr.net/gh/RS01RS/Factor-Saz@main/setup.sh | sudo bash
# هیچ رمز یا کلیدی داخل این فایل نیست؛ همه‌چیز موقع اجرا پرسیده می‌شود و فقط روی خود سرور می‌ماند.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
TTY=/dev/tty
say(){ printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
ok(){ printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
warn(){ printf '\033[1;33m! %s\033[0m\n' "$*"; }
ask(){ local v; read -r -p "$1: " v < "$TTY"; printf '%s' "${v:-$2}"; }
asks(){ local v; read -r -s -p "$1: " v < "$TTY"; echo > "$TTY"; printf '%s' "$v"; }

[ "$(id -u)" = 0 ] || { echo "با sudo اجرا کن"; exit 1; }
grep -qi ubuntu /etc/os-release || warn "این اسکریپت برای Ubuntu نوشته شده"

APP=/var/www/tazmin
IP=$(curl -fsS4 --max-time 8 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
echo "=============================================="
echo "   نصب سرور تضمین تراز   ·   IP این سرور: $IP"
echo "=============================================="

if [ -f "$APP/tazmin_app/config.php" ]; then
  warn "تضمین تراز قبلاً روی این سرور نصب شده. فقط کد به‌روز می‌شود؛ تنظیمات و اطلاعات دست نمی‌خورد."
  UPDATE=1
else UPDATE=0; fi

if [ "$UPDATE" = 0 ]; then
  DOMAIN=$(ask "آدرس API (مثلاً api.tazmintaraz.ir)" "")
  EMAIL=$(ask "ایمیل برای گواهی SSL (اختیاری)" "")
  ADMIN_PHONE=$(ask "شمارهٔ موبایل مدیر (09…)" "")
  KAVE_KEY=$(asks "کلید API کاوه‌نگار (دیده نمی‌شود)")
  OTP_TPL=$(ask "اسم الگوی کد تأیید در کاوه‌نگار" "tazmintaraz-otp")
  REM_TPL=$(ask "اسم الگوی یادآوری در کاوه‌نگار" "tazmintaraz-remind")
  while :; do ADMIN_PASS=$(asks "رمز پنل مدیریت (حداقل ۱۲ کاراکتر)"); [ ${#ADMIN_PASS} -ge 12 ] && break; warn "کوتاه است"; done
fi
SRC_PASS=$(asks "رمز سورس (همان SRC_PASS گیت‌هاب)")

say "۱/۸ نصب بسته‌ها (چند دقیقه)"
apt-get update -qq
apt-get install -y -qq nginx mariadb-server php-fpm php-cli php-mysql php-curl php-mbstring php-xml php-zip \
  certbot python3-certbot-nginx ufw fail2ban unzip curl openssl cron unattended-upgrades dnsutils >/dev/null
PHPV=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
SOCK=/run/php/php${PHPV}-fpm.sock
ok "PHP $PHPV"

say "۲/۸ دریافت و باز کردن کد سرور"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
for u in "https://cdn.jsdelivr.net/gh/RS01RS/Factor-Saz@main/server.enc" "https://raw.githubusercontent.com/RS01RS/Factor-Saz/main/server.enc"; do
  curl -fsSL --max-time 120 -o "$T/s.enc" "$u" && break || true
done
[ -s "$T/s.enc" ] || { echo "دانلود کد سرور انجام نشد (اینترنت سرور را چک کن)"; exit 1; }
printf '%s' "$SRC_PASS" > "$T/p"; chmod 600 "$T/p"
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -in "$T/s.enc" -out "$T/s.zip" -pass file:"$T/p" 2>/dev/null || { echo "رمز سورس اشتباه است"; exit 1; }
rm -f "$T/p"; unzip -q "$T/s.zip" -d "$T/x"
mkdir -p "$APP/tazmin_app" "$APP/public_api"
cp -a "$T/x/app/." "$APP/tazmin_app/"
if [ "$UPDATE" = 0 ]; then
  PANEL="panel-$(openssl rand -hex 4)"
  mkdir -p "$APP/public_api/$PANEL"
  cp "$T/x/public_api/index.php" "$APP/public_api/index.php"
  cp "$T/x/public_api/admin/index.php" "$APP/public_api/$PANEL/index.php"
  echo "$PANEL" > "$APP/tazmin_app/.panel"
else
  PANEL=$(cat "$APP/tazmin_app/.panel"); DOMAIN=$(cat "$APP/tazmin_app/.domain" 2>/dev/null || echo "")
fi
ok "کد در $APP"

if [ "$UPDATE" = 0 ]; then
  say "۳/۸ دیتابیس"
  DBP=$(openssl rand -hex 20)
  mysql -e "CREATE DATABASE IF NOT EXISTS tazmin CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
            CREATE USER IF NOT EXISTS 'tazmin'@'localhost' IDENTIFIED BY '$DBP';
            ALTER USER 'tazmin'@'localhost' IDENTIFIED BY '$DBP';
            GRANT ALL ON tazmin.* TO 'tazmin'@'localhost'; FLUSH PRIVILEGES;"
  ok "دیتابیس tazmin"

  say "۴/۸ تنظیمات و کلیدها"
  HASH=$(ADMIN_PASS="$ADMIN_PASS" php -r 'echo password_hash(getenv("ADMIN_PASS"), defined("PASSWORD_ARGON2ID")?PASSWORD_ARGON2ID:PASSWORD_BCRYPT);')
  C_DBP="$DBP" C_KEY="$KAVE_KEY" C_OTP="$OTP_TPL" C_REM="$REM_TPL" C_HASH="$HASH" C_PHONE="$ADMIN_PHONE" \
  C_S1=$(openssl rand -hex 32) C_S2=$(openssl rand -hex 32) C_S3=$(openssl rand -hex 32) C_S4=$(openssl rand -hex 32) \
  python3 - "$APP/tazmin_app/config.sample.php" "$APP/tazmin_app/config.php" <<'PY'
import sys,re,os
E=os.environ
s=open(sys.argv[1],encoding='utf-8').read()
def put(key,val):
    global s
    val=val.replace('\\','\\\\').replace("'","\\'")
    s=re.compile(r"('"+re.escape(key)+r"'\s*=>\s*)'[^']*'").sub(lambda m:m.group(1)+"'"+val+"'",s,count=1)
put('dsn','mysql:host=localhost;dbname=tazmin;charset=utf8mb4'); put('user','tazmin'); put('pass',E['C_DBP'])
put('secret',E['C_S1']); put('master_key',E['C_S2'])
put('provider','kavenegar'); put('api_key',E['C_KEY']); put('template',E['C_OTP']); put('reminder_template',E['C_REM'])
put('pass_hash',E['C_HASH']); put('phone',E['C_PHONE'])
put('url',''); put('token',E['C_S3']); put('key',E['C_S4'])
open(sys.argv[2],'w',encoding='utf-8').write(s)
PY
  unset KAVE_KEY ADMIN_PASS HASH DBP
  echo "$DOMAIN" > "$APP/tazmin_app/.domain"
  ok "config.php ساخته شد"
fi
chown -R www-data:www-data "$APP"; chmod 750 "$APP/tazmin_app"; chmod 600 "$APP/tazmin_app/config.php"
runuser -u www-data -- php "$APP/tazmin_app/install.php" migrate

say "۵/۸ وب‌سرور"
cat > /etc/nginx/sites-available/tazmin <<NG
server {
    listen 80; listen [::]:80;
    server_name ${DOMAIN:-_} $IP;
    root $APP/public_api; index index.php;
    client_max_body_size 30m;
    server_tokens off;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options DENY always;
    location ~ /\. { deny all; }
    location /$PANEL/ { try_files \$uri /$PANEL/index.php\$is_args\$args; }
    location / { try_files \$uri /index.php\$is_args\$args; }
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$SOCK;
        fastcgi_param HTTP_AUTHORIZATION \$http_authorization;
        fastcgi_read_timeout 120;
    }
}
NG
ln -sf /etc/nginx/sites-available/tazmin /etc/nginx/sites-enabled/tazmin
rm -f /etc/nginx/sites-enabled/default
nginx -t -q && systemctl reload nginx
ok "nginx"

say "۶/۸ کارهای زمان‌دار (پیامک‌های یادآوری و پشتیبان شبانه)"
cat > /etc/cron.d/tazmin <<CR
*/5 * * * * www-data php $APP/tazmin_app/cron.php sms >/dev/null 2>&1
17 * * * * www-data php $APP/tazmin_app/cron.php cleanup >/dev/null 2>&1
30 3 * * * www-data php $APP/tazmin_app/cron.php nightly >/dev/null 2>&1
CR
chmod 644 /etc/cron.d/tazmin
ok "cron"

say "۷/۸ امنیت (فایروال، ضد حدس رمز، به‌روزرسانی خودکار امنیتی)"
ufw allow OpenSSH >/dev/null; ufw allow 'Nginx Full' >/dev/null; ufw --force enable >/dev/null
systemctl enable --now fail2ban >/dev/null 2>&1 || true
dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true
ok "ufw + fail2ban"

# گواهی SSL: اگر دامنه به همین سرور اشاره کند همین حالا، وگرنه بعداً با دستور tazmin-ssl
cat > /usr/local/bin/tazmin-ssl <<'SS'
#!/usr/bin/env bash
D=$(cat /var/www/tazmin/tazmin_app/.domain 2>/dev/null); [ -n "$1" ] && D="$1"
[ -n "$D" ] || { echo "استفاده: tazmin-ssl api.tazmintaraz.ir"; exit 1; }
echo "$D" > /var/www/tazmin/tazmin_app/.domain
IP=$(curl -fsS4 --max-time 8 https://api.ipify.org); R=$(dig +short A "$D" | tail -1)
[ "$R" = "$IP" ] || { echo "✗ $D هنوز به $IP اشاره نمی‌کند (الان: ${R:-هیچ}). رکورد A را بساز و چند دقیقه بعد دوباره بزن."; exit 1; }
sed -i "s/server_name [^;]*;/server_name $D $IP;/" /etc/nginx/sites-available/tazmin && nginx -t -q && systemctl reload nginx
certbot --nginx -d "$D" --non-interactive --agree-tos --register-unsafely-without-email --redirect && echo "✓ SSL فعال شد: https://$D/v1/ping"
SS
chmod 755 /usr/local/bin/tazmin-ssl
say "۸/۸ گواهی SSL"
if [ -n "${DOMAIN:-}" ] && [ "$(dig +short A "$DOMAIN" | tail -1)" = "$IP" ]; then
  if [ -n "${EMAIL:-}" ]; then certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --redirect >/dev/null && ok "SSL فعال شد"
  else tazmin-ssl "$DOMAIN"; fi
else
  warn "دامنه هنوز به این سرور وصل نیست. بعد از ساختن رکورد A بزن:  sudo tazmin-ssl ${DOMAIN:-api.tazmintaraz.ir}"
fi

echo; echo "================ بررسی نهایی ================"
runuser -u www-data -- php "$APP/tazmin_app/install.php" check || true
echo
P=$(curl -fsS --max-time 5 "http://127.0.0.1/v1/ping" -H "Host: ${DOMAIN:-localhost}" || echo "جواب نداد")
echo "آزمایش API: $P"
echo "=============================================="
ok "نصب تمام شد"
echo "آدرس API:          https://${DOMAIN:-دامنه}/v1/ping"
echo "پنل مدیریت (مخفی): https://${DOMAIN:-دامنه}/$PANEL/"
echo "این آدرس پنل را جایی امن یادداشت کن و در چت نفرست."
echo "مورد «پشتیبان هاست دوم» در بررسی بالا فعلاً ✗ است؛ بعداً تنظیمش می‌کنیم."
