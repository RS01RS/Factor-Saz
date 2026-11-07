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
IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src")print $(i+1)}' | head -1); [ -n "$IP" ] || IP=$(hostname -I | awk '{print $1}')
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
# اگر نسخهٔ مشخصی داده شده (TZ_REF)، از آینهٔ jsDelivr همان نسخه گرفته می‌شود (سریع و بدون کش قدیمی)
URLS=()
GHT=$(cat "$APP/tazmin_app/.gh_token" 2>/dev/null || true)
if [ -n "$GHT" ]; then   # مخزن خصوصی: با توکن فقط‌خواندنی که روی خود سرور ذخیره شده
  curl -fsSL --retry 4 --connect-timeout 20 --max-time 400 -H "Authorization: Bearer $GHT" -H "Accept: application/vnd.github.raw" \
    -o "$T/s.enc" "https://api.github.com/repos/RS01RS/Factor-Saz/contents/server.enc?ref=${TZ_REF:-main}" || rm -f "$T/s.enc"
fi
[ -n "${TZ_REF:-}" ] && URLS+=("https://cdn.jsdelivr.net/gh/RS01RS/Factor-Saz@${TZ_REF}/server.enc")
URLS+=("https://raw.githubusercontent.com/RS01RS/Factor-Saz/main/server.enc?t=$(date +%s)" "https://cdn.jsdelivr.net/gh/RS01RS/Factor-Saz@main/server.enc")
for u in "${URLS[@]}"; do
  [ -s "$T/s.enc" ] && break
  rm -f "$T/s.enc"
  curl -fsSL --retry 4 --retry-delay 3 --connect-timeout 20 --max-time 400 -o "$T/s.enc" "$u" && [ -s "$T/s.enc" ] && break || warn "دانلود از یک آینه نشد، آینهٔ بعدی…"
done
if [ ! -s "$T/s.enc" ] && [ -s "$APP/tazmin_app/storage/push/server.enc" ]; then cp "$APP/tazmin_app/storage/push/server.enc" "$T/s.enc"; warn "گیت‌هاب در دسترس نبود؛ کد سرور از نسخهٔ ارسال‌شده به خود سرور برداشته شد"; fi
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
[ -d "$APP/tazmin_app/keys" ] && chmod 700 "$APP/tazmin_app/keys" && chmod 600 "$APP/tazmin_app/keys/"*
runuser -u www-data -- php "$APP/tazmin_app/install.php" migrate

say "۵/۸ وب‌سرور"
# تنظیمات قدیمی که به گواهی حذف‌شده اشاره می‌کنند، از نو ساخته می‌شوند
[ -n "${EXTRA_KEEP:-}" ] || rm -f /etc/nginx/sites-enabled/tazmin-extra
# بدنهٔ مشترک (برای دامنهٔ اصلی و دامنه‌های اضافه)
cat > /etc/nginx/snippets/tazmin-body.conf <<NG
    root $APP/public_api; index index.php;
    client_max_body_size 30m;
    server_tokens off;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options DENY always;
    location ~ /\. { deny all; }
    location /$PANEL/ { try_files \$uri /$PANEL/index.php\$is_args\$args; }
    location /app/ { index index.html; try_files \$uri \$uri/ /index.php\$is_args\$args; add_header Cache-Control "no-cache" always; add_header X-Content-Type-Options nosniff always; add_header X-Frame-Options DENY always; }
    location / { try_files \$uri /index.php\$is_args\$args; }
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$SOCK;
        fastcgi_param HTTP_AUTHORIZATION \$http_authorization;
        fastcgi_read_timeout 120;
    }
NG
cat > /etc/nginx/sites-available/tazmin <<NG
server {
    listen 80; listen [::]:80;
    server_name ${DOMAIN:-_} $IP;
    include snippets/tazmin-body.conf;
}
NG
EXTRA=$( { cat "$APP/tazmin_app/.domains" 2>/dev/null || true; } | tr -s ' \n' '\n' | grep -vx "${DOMAIN:-__none__}" | tr '\n' ' ' | sed 's/^ *//;s/ *$//' || true)
if [ -n "$EXTRA" ]; then
cat > /etc/nginx/sites-available/tazmin-extra <<NG
server {
    listen 80; listen [::]:80;
    server_name $EXTRA;
    include snippets/tazmin-body.conf;
}
NG
ln -sf /etc/nginx/sites-available/tazmin-extra /etc/nginx/sites-enabled/tazmin-extra
fi
ln -sf /etc/nginx/sites-available/tazmin /etc/nginx/sites-enabled/tazmin
rm -f /etc/nginx/sites-enabled/default
# گواهی SSL قبلی را دوباره روی تنظیمات تازه می‌نشاند (به‌روزرسانی نباید HTTPS را خراب کند)
if [ -n "${DOMAIN:-}" ] && [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then
  certbot install --nginx --cert-name "$DOMAIN" --redirect --non-interactive >/dev/null 2>&1 && ok "SSL حفظ شد" || warn "نصب دوبارهٔ SSL انجام نشد؛ بزن: sudo tazmin-ssl $DOMAIN"
fi
if [ -n "${EXTRA:-}" ] && [ -d /etc/letsencrypt/live/tazmin-extra ]; then
  certbot install --nginx --cert-name tazmin-extra --redirect --non-interactive >/dev/null 2>&1 && ok "SSL دامنه‌های اضافه حفظ شد" || warn "SSL دامنه‌های اضافه: بزن sudo tazmin-domains"
fi
nginx -t -q && systemctl reload nginx
ok "nginx"

say "۶/۸ کارهای زمان‌دار (پیامک‌های یادآوری و پشتیبان شبانه)"
cat > /etc/cron.d/tazmin <<CR
*/5 * * * * www-data php $APP/tazmin_app/cron.php sms >/dev/null 2>&1
17 * * * * www-data php $APP/tazmin_app/cron.php cleanup >/dev/null 2>&1
30 3 * * * www-data php $APP/tazmin_app/cron.php nightly >/dev/null 2>&1
41 * * * * www-data php $APP/tazmin_app/cron.php apk >/dev/null 2>&1
CR
chmod 644 /etc/cron.d/tazmin
ok "cron"
( runuser -u www-data -- php "$APP/tazmin_app/cron.php" apk >/dev/null 2>&1 & )   # فایل نصبی برنامه روی سرور (پس‌زمینه)

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
echo "$D" | grep -Eq '^[a-z0-9.-]+\.[a-z]{2,}$' || { echo "✗ نام دامنه نامعتبر: $D"; exit 1; }
IP=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++)if($i=="src")print $(i+1)}' | head -1); PUB=$(curl -fsS4 --max-time 8 https://api.ipify.org 2>/dev/null); R=$(dig +short A "$D" | tail -1)
[ "$R" = "$IP" ] || [ "$R" = "$PUB" ] || [ -d "/etc/letsencrypt/live/$D" ] || { echo "✗ $D هنوز به $IP اشاره نمی‌کند (الان: ${R:-هیچ}). رکورد A را بساز و چند دقیقه بعد دوباره بزن."; exit 1; }
sed -i "s/server_name [^;]*;/server_name $D $IP;/" /etc/nginx/sites-available/tazmin && nginx -t -q && systemctl reload nginx
certbot --nginx -d "$D" --non-interactive --agree-tos --register-unsafely-without-email --redirect && echo "$D" > /var/www/tazmin/tazmin_app/.domain && echo "✓ SSL فعال شد: https://$D/v1/ping"
SS
chmod 755 /usr/local/bin/tazmin-ssl
cat > /usr/local/bin/tazmin-domains <<'DM'
#!/usr/bin/env bash
# دامنه‌های اضافه (مثلاً دامنهٔ جدید برند) کنار دامنهٔ فعلی؛ هر دو همزمان کار می‌کنند
# استفاده: sudo tazmin-domains api.tazmintaraz.ir app.tazmintaraz.ir tazmintaraz.ir www.tazmintaraz.ir
F=/var/www/tazmin/tazmin_app/.domains
IP=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++)if($i=="src")print $(i+1)}' | head -1); PUB=$(curl -fsS4 --max-time 8 https://api.ipify.org 2>/dev/null)
L=$(cat "$F" 2>/dev/null || true)
for d in "$@"; do d=$(echo "$d" | tr 'A-Z' 'a-z'); echo "$d" | grep -Eq '^[a-z0-9.-]+\.[a-z]{2,}$' || { echo "✗ نامعتبر: $d"; continue; }; L="$L $d"; done
MAIN=$(cat /var/www/tazmin/tazmin_app/.domain 2>/dev/null || true)
OK=""; for d in $(echo $L | tr ' ' '\n' | sort -u); do [ "$d" = "$MAIN" ] && continue; R=$(dig +short A "$d" | tail -1)
  if [ "$R" = "$IP" ] || [ "$R" = "$PUB" ]; then OK="$OK $d"; echo "✓ $d"; else echo "✗ $d هنوز به این سرور اشاره نمی‌کند (الان: ${R:-هیچ})"; fi; done
OK=$(echo $OK); [ -n "$OK" ] || { echo "هیچ دامنهٔ آماده‌ای نیست. رکورد A بساز و چند دقیقه بعد دوباره بزن."; exit 1; }
echo "$OK" > "$F"
printf 'server {\n    listen 80; listen [::]:80;\n    server_name %s;\n    include snippets/tazmin-body.conf;\n}\n' "$OK" > /etc/nginx/sites-available/tazmin-extra
ln -sf /etc/nginx/sites-available/tazmin-extra /etc/nginx/sites-enabled/tazmin-extra
nginx -t -q && systemctl reload nginx || { echo "✗ خطای nginx"; exit 1; }
A=(); for d in $OK; do A+=(-d "$d"); done
certbot --nginx --cert-name tazmin-extra --expand "${A[@]}" --non-interactive --agree-tos --register-unsafely-without-email --redirect >/dev/null 2>&1 \
  && { echo "✓ SSL فعال شد:"; for d in $OK; do echo "   https://$d"; done; } || echo "✗ گرفتن SSL نشد. چند دقیقه بعد دوباره بزن: sudo tazmin-domains"
DM
chmod 755 /usr/local/bin/tazmin-domains
cat > /usr/local/bin/tazmin-update <<'UP'
#!/usr/bin/env bash
# به‌روزرسانی سرور: اول از گیت‌هاب؛ اگر نشد، از نسخه‌ای که GitHub Actions مستقیم به خود سرور فرستاده (storage/push)
PUSH=/var/www/tazmin/tazmin_app/storage/push
GHT=$(sudo cat /var/www/tazmin/tazmin_app/.gh_token 2>/dev/null); H=(); [ -n "$GHT" ] && H=(-H "Authorization: Bearer $GHT")
R=$(curl -fsS --max-time 30 "${H[@]}" https://api.github.com/repos/RS01RS/Factor-Saz/commits/main 2>/dev/null | grep -m1 '"sha"' | cut -d'"' -f4)
T=$(mktemp)
if [ -n "$GHT" ]; then curl -fsSL --retry 4 --max-time 300 "${H[@]}" -H "Accept: application/vnd.github.raw" -o "$T" "https://api.github.com/repos/RS01RS/Factor-Saz/contents/setup.sh?ref=${R:-main}" || : > "$T"; fi
[ -s "$T" ] || curl -fsSL --retry 3 --max-time 300 -o "$T" "https://cdn.jsdelivr.net/gh/RS01RS/Factor-Saz@${R:-main}/setup.sh" || : > "$T"
if ! head -1 "$T" | grep -q '^#!'; then
  if sudo test -s "$PUSH/setup.sh"; then echo "↪ گیت‌هاب در دسترس نبود؛ از نسخهٔ ارسال‌شده به خود سرور استفاده می‌شود"; sudo cp "$PUSH/setup.sh" "$T"; R=""
  else echo "دانلود نصب‌کننده نشد (اینترنت بین‌المللی سرور). چند دقیقه بعد دوباره بزن."; rm -f "$T"; exit 1; fi
fi
sudo TZ_REF="$R" bash "$T"; rc=$?; rm -f "$T"; exit $rc
UP
cat > /usr/local/bin/tazmin-github-token <<'GT'
#!/usr/bin/env bash
# توکن فقط‌خواندنی گیت‌هاب (برای وقتی مخزن خصوصی است). روی خود سرور می‌ماند و جایی فرستاده نمی‌شود.
read -rsp "توکن گیت‌هاب را بچسبان و Enter بزن: " TK; echo
[ -n "$TK" ] || { echo "خالی بود"; exit 1; }
F=/var/www/tazmin/tazmin_app/.gh_token; printf '%s' "$TK" | sudo tee "$F" >/dev/null; sudo chown www-data:www-data "$F"; sudo chmod 600 "$F"
C=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TK" https://api.github.com/repos/RS01RS/Factor-Saz)
[ "$C" = 200 ] && echo "✓ توکن کار می‌کند" || echo "✗ گیت‌هاب توکن را قبول نکرد (کد $C)"
GT
cat > /usr/local/bin/tazmin-apk <<'AP'
#!/usr/bin/env bash
# همین حالا آخرین نسخهٔ برنامه را از گیت‌هاب روی سرور بگذار
runuser -u www-data -- php /var/www/tazmin/tazmin_app/cron.php apk force
AP
cat > /usr/local/bin/tazmin-sms-template <<'ST'
#!/usr/bin/env bash
# نام قالب (الگوی) پیامک یادآوری مشتری در کاوه‌نگار را روی سرور ثبت می‌کند
CF=/var/www/tazmin/tazmin_app/config.php
[ -f "$CF" ] || { echo "config.php پیدا نشد"; exit 1; }
CUR=$(sudo php -r '$c=require "'"$CF"'"; echo $c["sms"]["reminder_template"]??"";' 2>/dev/null)
echo "قالب فعلی یادآوری: ${CUR:-(خالی)}"
read -rp "نام قالب یادآوری در کاوه‌نگار را بنویس و Enter بزن: " T
T=$(printf '%s' "$T" | tr -cd 'A-Za-z0-9_-')
[ -n "$T" ] || { echo "خالی بود؛ چیزی عوض نشد"; exit 1; }
sudo python3 - "$CF" "$T" <<'PY'
import re,sys
p,t=sys.argv[1],sys.argv[2];s=open(p,encoding='utf-8').read()
s2,n=re.subn(r"('reminder_template'\s*=>\s*)'[^']*'",lambda m:m.group(1)+"'"+t+"'",s,count=1)
if not n:
    s2,n=re.subn(r"('template'\s*=>\s*'[^']*',)",lambda m:m.group(1)+"\n        'reminder_template' => '"+t+"',",s,count=1)
open(p,'w',encoding='utf-8').write(s2);print('✓ ذخیره شد' if n else '✗ جای قالب در config.php پیدا نشد')
PY
echo "حالا در پنل مدیریت ← پیامک‌ها ← «ارسال یادآوری آزمایشی» را بزن."
ST
chmod 755 /usr/local/bin/tazmin-sms-template
cat > /usr/local/bin/tazmin-admin-pass <<'APW'
#!/usr/bin/env bash
# عوض کردن رمز، نام کاربری یا شمارهٔ مدیر پنل (روی خود سرور)
CF=/var/www/tazmin/tazmin_app/config.php
[ -f "$CF" ] || { echo "config.php پیدا نشد"; exit 1; }
U=$(sudo php -r '$c=require "'"$CF"'"; echo $c["admin"]["user"]??"admin";'); PH=$(sudo php -r '$c=require "'"$CF"'"; echo $c["admin"]["phone"]??"";')
echo "نام کاربری فعلی: $U   ·   شمارهٔ مدیر: $PH"
read -rp "نام کاربری جدید (Enter = بدون تغییر): " NU
read -rp "شمارهٔ موبایل مدیر جدید (Enter = بدون تغییر): " NP
while :; do read -rsp "رمز جدید پنل (حداقل ۱۲ کاراکتر؛ Enter = بدون تغییر): " P1; echo; [ -z "$P1" ] && break; read -rsp "تکرار رمز: " P2; echo; [ "$P1" = "$P2" ] && [ ${#P1} -ge 12 ] && break; echo "یکسان نبود یا کوتاه بود؛ دوباره."; done
H=""; [ -n "$P1" ] && H=$(P="$P1" php -r 'echo password_hash(getenv("P"), defined("PASSWORD_ARGON2ID")?PASSWORD_ARGON2ID:PASSWORD_BCRYPT);')
sudo NU="$NU" NP="$NP" H="$H" python3 - "$CF" <<'PY'
import os,re,sys
p=sys.argv[1];s=open(p,encoding='utf-8').read()
def setk(s,k,v):
    return re.sub(r"('"+k+r"'\s*=>\s*)'[^']*'",lambda m:m.group(1)+"'"+v.replace("'","")+"'",s,count=1)
a=s.find("'admin'");head,tail=s[:a],s[a:]
if os.environ.get('NU'):tail=setk(tail,'user',os.environ['NU'])
if os.environ.get('NP'):tail=setk(tail,'phone',os.environ['NP'])
if os.environ.get('H'):tail=setk(tail,'pass_hash',os.environ['H'])
open(p,'w',encoding='utf-8').write(head+tail);print('✓ ذخیره شد')
PY
unset P1 P2 H
APW
cat > /usr/local/bin/tazmin-info <<'INF'
#!/usr/bin/env bash
# خلاصهٔ وضعیت سرور؛ با --secrets رمزها و کلیدها را هم (فقط روی همین سرور) نشان می‌دهد
APP=/var/www/tazmin; CF=$APP/tazmin_app/config.php
D=$(cat $APP/tazmin_app/.domain 2>/dev/null); P=$(sudo cat $APP/tazmin_app/.panel 2>/dev/null)
echo "================ تضمین تراز ================"
echo "دامنهٔ اصلی:        ${D:-—}"
echo "دامنه‌های اضافه:    $(cat $APP/tazmin_app/.domains 2>/dev/null | tr '\n' ' ')"
echo "آدرس پنل مدیریت:    https://${D}/${P}/"
sudo php -r '$c=require "'"$CF"'";
 echo "نام کاربری پنل:     ".($c["admin"]["user"]??"")."\n";
 echo "شمارهٔ مدیر:         ".($c["admin"]["phone"]??"")."\n";
 echo "دیتابیس:            ".($c["db"]["dsn"]??"")."  کاربر: ".($c["db"]["user"]??"")."\n";
 echo "سامانهٔ پیامک:       ".($c["sms"]["provider"]??"")."  الگوی ورود: ".($c["sms"]["template"]??"")."  الگوی یادآوری: ".(($c["sms"]["reminder_template"]??"")?:"(خالی)")."\n";
 echo "اجرای پلن‌ها:        ".(!empty($c["enforce_plans"])?"روشن":"خاموش (همه چیز باز)")."\n";
 if (in_array("--secrets",$argv)) { echo "\n------ محرمانه (در چت یا جای عمومی نفرست) ------\n";
   echo "رمز دیتابیس:        ".($c["db"]["pass"]??"")."\n"; echo "کلید API پیامک:     ".($c["sms"]["api_key"]??"")."\n";
   echo "secret:             ".($c["secret"]??"")."\nmaster_key:         ".($c["master_key"]??"")."\n";
   echo "offsite key:        ".($c["offsite"]["key"]??"")."\noffsite token:      ".($c["offsite"]["token"]??"")."\n";
   echo "(رمز پنل به‌صورت هش ذخیره است و قابل نمایش نیست؛ برای عوض کردنش: sudo tazmin-admin-pass)\n"; }' -- "$@"
echo "--------------------------------------------"
echo "نسخهٔ برنامه روی سرور: $(curl -s -m 8 https://${D}/v1/app/latest | grep -o '"tag":"[^"]*"' | head -1)"
CL=$(cat $APP/tazmin_app/storage/sms_cron 2>/dev/null); [ -n "$CL" ] && echo "آخرین اجرای ارسال پیامک: $(( ( $(date +%s) - CL ) / 60 )) دقیقه پیش" || echo "آخرین اجرای ارسال پیامک: هرگز"
echo "nginx: $(systemctl is-active nginx)   php-fpm: $(systemctl is-active 'php*-fpm' 2>/dev/null | head -1)   mysql: $(systemctl is-active mysql 2>/dev/null || systemctl is-active mariadb)"
echo "فضای دیسک: $(df -h / | awk 'NR==2{print $4" آزاد از "$2}')"
INF
cat > /usr/local/bin/tazmin-check <<'CHK'
#!/usr/bin/env bash
# عیب‌یابی سریع همهٔ بخش‌ها
APP=/var/www/tazmin; D=$(cat $APP/tazmin_app/.domain 2>/dev/null); P=$(sudo cat $APP/tazmin_app/.panel 2>/dev/null)
echo "== بررسی تنظیمات برنامه =="; sudo runuser -u www-data -- php $APP/tazmin_app/install.php check
echo "== وب‌سرور =="; sudo nginx -t 2>&1 | tail -1
for s in nginx mysql mariadb; do systemctl list-unit-files | grep -q "^$s" && echo "$s: $(systemctl is-active $s)"; done
echo "php-fpm: $(systemctl is-active $(systemctl list-units --type=service --all | grep -o 'php[0-9.]*-fpm' | head -1))"
echo "== آزمایش آدرس‌ها =="
for u in "https://$D/v1/ping" "https://$D/v1/app/latest" "https://$D/app/" "https://$D/$P/"; do printf '%s  ' "$(curl -s -o /dev/null -m 12 -w '%{http_code}' "$u")"; echo "$u" | sed "s#$P#<پنل>#"; done
echo "== گواهی SSL =="; echo | openssl s_client -servername "$D" -connect "$D:443" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null || echo "خوانده نشد"
echo "== دسترسی به گیت‌هاب (برای به‌روزرسانی) =="; for u in https://api.github.com https://raw.githubusercontent.com https://cdn.jsdelivr.net; do echo "$(curl -s -o /dev/null -m 12 -w '%{http_code}' $u)  $u"; done
echo "== آخرین خطاهای وب‌سرور و PHP =="; sudo tail -n 8 /var/log/nginx/error.log 2>/dev/null; sudo sh -c 'tail -n 8 /var/log/php*-fpm.log' 2>/dev/null
CHK
cat > /usr/local/bin/tazmin-logs <<'LG'
#!/usr/bin/env bash
# نمایش زندهٔ خطاها (Ctrl+C برای خروج)
sudo sh -c 'tail -f /var/log/nginx/error.log /var/log/php*-fpm.log'
LG
chmod 755 /usr/local/bin/tazmin-admin-pass /usr/local/bin/tazmin-info /usr/local/bin/tazmin-check /usr/local/bin/tazmin-logs
cat > /usr/local/bin/tazmin-deploy-key <<'DK'
#!/usr/bin/env bash
# کلید «مسیر دوم به‌روزرسانی»: GitHub Actions فایل‌ها را مستقیم به همین سرور می‌فرستد (وقتی سرور به گیت‌هاب نمی‌رسد)
K=$(sudo runuser -u www-data -- php -r 'require "/var/www/tazmin/tazmin_app/bootstrap.php"; $k=bin2hex(random_bytes(32)); setting_set("deploy_key",$k); echo $k;')
[ ${#K} -eq 64 ] || { echo "ساخت کلید نشد"; exit 1; }
echo
echo "کلید ساخته شد. حالا در گیت‌هاب:"
echo "  مخزن Factor-Saz ← Settings ← Secrets and variables ← Actions ← New repository secret"
echo "  Name:   DEPLOY_KEY"
echo "  Secret: (خط زیر را کامل کپی کن)"
echo
echo "$K"
echo
echo "این کلید را در چت یا جای دیگری نفرست؛ فقط در گیت‌هاب بگذار. با اجرای دوبارهٔ همین دستور، کلید قبلی باطل می‌شود."
DK
chmod 755 /usr/local/bin/tazmin-deploy-key
chmod 755 /usr/local/bin/tazmin-github-token /usr/local/bin/tazmin-apk
chmod 755 /usr/local/bin/tazmin-update
say "۸/۸ گواهی SSL"
if [ -n "${DOMAIN:-}" ] && [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then
  ok "SSL از قبل فعال است"
elif [ -n "${DOMAIN:-}" ] && [ "$(dig +short A "$DOMAIN" | tail -1)" = "$IP" ]; then
  if [ -n "${EMAIL:-}" ]; then certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --redirect >/dev/null && ok "SSL فعال شد"
  else tazmin-ssl "$DOMAIN"; fi
else
  warn "دامنه هنوز به این سرور وصل نیست. بعد از ساختن رکورد A بزن:  sudo tazmin-ssl ${DOMAIN:-api.tazmintaraz.ir}"
fi

echo; echo "================ بررسی نهایی ================"
runuser -u www-data -- php "$APP/tazmin_app/install.php" check || true
echo
if [ -n "${DOMAIN:-}" ] && [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then P=$(curl -fsS --max-time 8 --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/v1/ping" || echo "جواب نداد"); else P=$(curl -fsS --max-time 5 "http://127.0.0.1/v1/ping" -H "Host: ${DOMAIN:-localhost}" || echo "جواب نداد"); fi
echo "آزمایش API: $P"
echo "=============================================="
ok "نصب تمام شد"
echo "آدرس API:          https://${DOMAIN:-دامنه}/v1/ping"
if [ "$UPDATE" = 0 ]; then echo "پنل مدیریت (مخفی): https://${DOMAIN:-دامنه}/$PANEL/"; echo "این آدرس پنل را جایی امن یادداشت کن و در چت نفرست."; else echo "آدرس پنل مدیریت عوض نشده (برای دیدنش: cat $APP/tazmin_app/.panel)"; fi
echo "مورد «پشتیبان هاست دوم» در بررسی بالا فعلاً ✗ است؛ بعداً تنظیمش می‌کنیم."
