#!/bin/bash
set -e

# usage:
#   ./issue-ssl.sh           → interaktif
#   ./issue-ssl.sh name dom  → langsung

NAME="$1"
DOMAIN="$2"

if [ -z "$NAME" ]; then
  echo "==============================="
  echo "   Xray SSL Issuer (acme.sh)"
  echo "==============================="
  read -rp "Nama (mis: user1): " NAME
fi

if [ -z "$DOMAIN" ]; then
  read -rp "Domain (mis: user1.example.com): " DOMAIN
fi

if [ -z "$NAME" ] || [ -z "$DOMAIN" ]; then
  echo "❌ nama / domain gak boleh kosong"
  exit 1
fi

BASE_DIR="/opt/xray/${NAME}"
KEY_FILE="${BASE_DIR}/xray.key"
CRT_FILE="${BASE_DIR}/xray.crt"

mkdir -p "$BASE_DIR"

echo "[+] install dependen (curl, socat) kalau belum..."
apt-get update -y >/dev/null 2>&1 || true
apt-get install -y curl socat >/dev/null 2>&1 || true

if ! command -v acme.sh >/dev/null 2>&1; then
  echo "[+] acme.sh belum ada, install ..."
  curl https://get.acme.sh | sh
  [ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"
fi

ACME="$HOME/.acme.sh/acme.sh"
if [ ! -x "$ACME" ]; then
  echo "❌ gak ketemu acme.sh"
  exit 1
fi

$ACME --set-default-ca --server letsencrypt >/dev/null 2>&1 || true

NGINX_WAS_RUNNING=0
if systemctl is-active --quiet nginx; then
  NGINX_WAS_RUNNING=1
  echo "[+] stop nginx dulu..."
  systemctl stop nginx
fi

echo "[+] issue cert untuk $DOMAIN ..."
if ! $ACME --issue --standalone -d "$DOMAIN" --force; then
  echo "❌ issue gagal"
  [ "$NGINX_WAS_RUNNING" -eq 1 ] && systemctl start nginx || true
  exit 1
fi

echo "[+] install cert ke $BASE_DIR ..."
$ACME --install-cert -d "$DOMAIN" \
  --key-file       "$KEY_FILE" \
  --fullchain-file "$CRT_FILE" \
  --reloadcmd      "echo ok" \
  >/dev/null 2>&1

chmod 600 "$KEY_FILE"
chmod 644 "$CRT_FILE"
chown root:root "$KEY_FILE" "$CRT_FILE"

if [ "$NGINX_WAS_RUNNING" -eq 1 ]; then
  echo "[+] start nginx lagi ..."
  systemctl start nginx
fi

echo "✅ SSL selesai:"
echo "  name   : $NAME"
echo "  domain : $DOMAIN"
echo "  key    : $KEY_FILE"
echo "  cert   : $CRT_FILE"
