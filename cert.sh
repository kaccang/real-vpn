#!/bin/bash
set -e

# ========== 1. minta input ==========

echo "==============================="
echo "   Xray SSL Issuer (acme.sh)"
echo "==============================="

read -rp "Nama (mis: user1): " NAME
[ -z "$NAME" ] && { echo "nama gak boleh kosong"; exit 1; }

read -rp "Domain (mis: user1.example.com): " DOMAIN
[ -z "$DOMAIN" ] && { echo "domain gak boleh kosong"; exit 1; }

BASE_DIR="/opt/xray/${NAME}"
KEY_FILE="${BASE_DIR}/xray.key"
CRT_FILE="${BASE_DIR}/xray.crt"

echo
echo "[i] nama   : $NAME"
echo "[i] domain : $DOMAIN"
echo "[i] target : $KEY_FILE / $CRT_FILE"
echo

# ========== 2. siapkan folder ==========

mkdir -p "$BASE_DIR"

# ========== 3. pastikan dependensi ada ==========

# ini di-host, bukan di container
echo "[+] install dependen (curl, socat) ..."
apt-get update -y >/dev/null 2>&1 || true
apt-get install -y curl socat >/dev/null 2>&1 || true

# ========== 4. install acme.sh kalau belum ada ==========
if ! command -v acme.sh >/dev/null 2>&1; then
  echo "[+] acme.sh belum ada, install ..."
  curl https://get.acme.sh | sh
  # shell init
  if [ -f "$HOME/.bashrc" ]; then
    # biar acme.sh ke-export
    . "$HOME/.bashrc"
  fi
fi

# setelah install, binary-nya biasanya di ~/.acme.sh/acme.sh
ACME="$HOME/.acme.sh/acme.sh"
if [ ! -x "$ACME" ]; then
  echo "❌ gak ketemu acme.sh setelah install. cek manual ya."
  exit 1
fi

# set ke Let's Encrypt
$ACME --set-default-ca --server letsencrypt >/dev/null 2>&1 || true

# ========== 5. stop nginx dulu ==========
NGINX_WAS_RUNNING=0
if systemctl is-active --quiet nginx; then
  echo "[+] nginx lagi jalan → stop dulu..."
  NGINX_WAS_RUNNING=1
  systemctl stop nginx
else
  echo "[i] nginx lagi MATI, lanjut issue..."
fi

# ========== 6. issue cert ==========
echo "[+] issue cert untuk $DOMAIN ..."
# pakai --standalone: listen 80 sendiri
if ! $ACME --issue --standalone -d "$DOMAIN" --force; then
  echo "❌ gagal issue. nyalain lagi nginx (kalau tadinya hidup)..."
  if [ "$NGINX_WAS_RUNNING" -eq 1 ]; then
    systemctl start nginx || true
  fi
  exit 1
fi

# ========== 7. install ke /opt/xray/<name>/xray.key|crt ==========
echo "[+] install cert ke $BASE_DIR ..."
$ACME --install-cert -d "$DOMAIN" \
  --key-file       "$KEY_FILE" \
  --fullchain-file "$CRT_FILE" \
  --reloadcmd      "echo reload xray placeholder" \
  >/dev/null 2>&1

chmod 600 "$KEY_FILE"
chmod 644 "$CRT_FILE"
chown root:root "$KEY_FILE" "$CRT_FILE"

# ========== 8. hidupkan lagi nginx kalau tadinya hidup ==========
if [ "$NGINX_WAS_RUNNING" -eq 1 ]; then
  echo "[+] start nginx lagi ..."
  systemctl start nginx
fi

echo
echo "✅ Selesai."
echo "Nama    : $NAME"
echo "Domain  : $DOMAIN"
echo "Key     : $KEY_FILE"
echo "Cert    : $CRT_FILE"
echo
echo "Catatan: nginx tadi $( [ "$NGINX_WAS_RUNNING" -eq 1 ] && echo 'dihidupkan lagi.' || echo 'memang mati dari awal.' )"
