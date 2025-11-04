#!/bin/bash

IMAGE_NAME="xray-base:24.04"
BASE_DIR="/opt/xray"
STEP=10
STATE_FILE="$BASE_DIR/.ports"
PROFILE_FILE="$BASE_DIR/profiles.json"
NGINX_CONF_DIR="/etc/nginx/conf.d"

# base dir
mkdir -p "$BASE_DIR"

# ====== ensure token & rclone.conf (nama konsisten) ======
[ -f "$BASE_DIR/.token" ] || touch "$BASE_DIR/.token"
[ -f "$BASE_DIR/rclone.conf" ] || touch "$BASE_DIR/rclone.conf"

# ==============================
# helper kecil
# ==============================
json_escape() { echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

get_acme_bin() {
  if command -v acme.sh >/dev/null 2>&1; then echo "acme.sh"; return; fi
  if [ -x "/root/.acme.sh/acme.sh" ]; then echo "/root/.acme.sh/acme.sh"; return; fi
  echo ""
}

get_public_ip() {
  ip="$(curl -4 -s https://icanhazip.com 2>/dev/null | tr -d '[:space:]')"
  if [ -z "$ip" ]; then ip="$(hostname -I 2>/dev/null | awk '{print $1}')"; fi
  echo "$ip"
}

# ==============================
# load / save port
# ==============================
load_state() {
  if [ -f "$STATE_FILE" ]; then
    . "$STATE_FILE"
  else
    DOKO=10000
    SSH=2201
  fi
}

save_state() {
  cat > "$STATE_FILE" <<EOF
DOKO=${DOKO}
SSH=${SSH}
EOF
}

# ==============================
# cek image
# ==============================
check_image() {
  if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    echo "❌ Image $IMAGE_NAME belum ada."
    echo "   cd /opt/xray && docker build -t $IMAGE_NAME ."
    exit 1
  fi
}

# ==============================
# nginx
# ==============================
ensure_nginx() {
  if ! command -v nginx >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y nginx
    systemctl enable nginx 2>/dev/null || true
  fi
}

write_nginx_block() {
  local name="$1"
  local domain="$2"
  local vless="$3"
  local vmess="$4"
  local trojan="$5"

  ensure_nginx

  if [ ! -f "/opt/xray/${name}/xray.crt" ] || [ ! -f "/opt/xray/${name}/xray.key" ]; then
    echo "⚠️ cert untuk ${name} belum ada, skip tulis nginx."
    return 0
  fi

  mkdir -p "$NGINX_CONF_DIR"
  local target="$NGINX_CONF_DIR/xray-${name}.conf"
  local tmp; tmp="$(mktemp)"

  cat > "$tmp" <<EOF
# auto-generated for ${name}
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${domain};

    ssl_certificate     /opt/xray/${name}/xray.crt;
    ssl_certificate_key /opt/xray/${name}/xray.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256:ECDHE+AESGCM:ECDHE+CHACHA20';
    ssl_prefer_server_ciphers off;

    # ==== VLESS: /vless dan turunannya ====
    location ~ ^/vless(?:/.*)?$ {
        # kalau bukan websocket, rewrite ke /vless
        if (\$http_upgrade != "websocket") {
            rewrite ^/vless(?:/.*)?$ /vless break;
        }
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_buffering off;
        proxy_pass http://127.0.0.1:${vless};
    }

    # ==== VMESS: /vmess dan turunannya ====
    location ~ ^/vmess(?:/.*)?$ {
        if (\$http_upgrade != "websocket") {
            rewrite ^/vmess(?:/.*)?$ /vmess break;
        }
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_buffering off;
        proxy_pass http://127.0.0.1:${vmess};
    }

    # ==== TROJAN: /trojan dan turunannya ====
    location ~ ^/trojan(?:/.*)?$ {
        if (\$http_upgrade != "websocket") {
            rewrite ^/trojan(?:/.*)?$ /trojan break;
        }
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_buffering off;
        proxy_pass http://127.0.0.1:${trojan};
    }
}
EOF

  if nginx -t >/dev/null 2>&1; then
    mv "$tmp" "$target"
    nginx -t && (systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true)
    echo "✅ nginx untuk ${name} ditulis."
  else
    echo "❌ nginx.conf error, block ${name} gak ditulis"
    rm -f "$tmp"
  fi
}

# ==============================
# pastikan acme
# ==============================
ensure_acme() {
  local bin; bin="$(get_acme_bin)"
  if [ -n "$bin" ]; then . ~/.acme.sh/acme.sh.env 2>/dev/null || true; return; fi
  echo "⚠️ acme.sh belum ada, install dulu..."
  apt-get update -y && apt-get install -y curl socat
  curl https://get.acme.sh | sh -s email=admin@localhost
  . ~/.acme.sh/acme.sh.env 2>/dev/null || true
}

issue_ssl_for_user() {
  local name="$1" domain="$2"
  ensure_acme; ensure_nginx; mkdir -p "/opt/xray/${name}"
  local ACME_BIN; ACME_BIN="$(get_acme_bin)"
  if [ -z "$ACME_BIN" ]; then echo "❌ acme.sh gak ketemu"; return 1; fi

  echo "[ssl] stop nginx sementara..."; systemctl stop nginx 2>/dev/null || true
  "$ACME_BIN" --set-default-ca --server letsencrypt

  if ! "$ACME_BIN" --issue --standalone -d "$domain" --force; then
    echo "❌ issue cert gagal untuk $domain"; systemctl start nginx 2>/dev/null || true; return 1
  fi

  if ! "$ACME_BIN" --install-cert -d "$domain" \
        --key-file "/opt/xray/${name}/xray.key" \
        --fullchain-file "/opt/xray/${name}/xray.crt"; then
    echo "❌ install-cert gagal buat $domain"; systemctl start nginx 2>/dev/null || true; return 1
  fi

  chmod 600 "/opt/xray/${name}/xray.key"
  chmod 644 "/opt/xray/${name}/xray.crt"
  chown root:root "/opt/xray/${name}/xray.key" "/opt/xray/${name}/xray.crt"

  echo "[ssl] start nginx lagi..."; nginx -t && (systemctl start nginx 2>/dev/null || systemctl reload nginx 2>/dev/null || true)
  echo "✅ SSL selesai untuk $domain → /opt/xray/${name}/xray.(key|crt)"
}

# ==============================
# simpan / hapus profiles.json
# ==============================
save_profile_json() {
  local name="$1" domain="$2" pass="$3" ssh="$4" doko="$5" vless="$6" vmess="$7" trojan="$8"

  if ! command -v jq >/dev/null 2>&1; then
    echo "⚠️ jq gak ada, skip simpan JSON"; return
  fi

  [ -f "$PROFILE_FILE" ] || echo "[]" > "$PROFILE_FILE"
  local tmp; tmp="$(mktemp)"
  jq --arg n "$name" '[.[] | select(.username != $n)]' "$PROFILE_FILE" > "$tmp" && mv "$tmp" "$PROFILE_FILE"

  tmp="$(mktemp)"
  jq --arg username "$name" \
     --arg password "$pass" \
     --arg domain "$domain" \
     --argjson ssh "$ssh" \
     --argjson doko "$doko" \
     --argjson vless "$vless" \
     --argjson vmess "$vmess" \
     --argjson trojan "$trojan" \
     '. += [{
        "username": $username,
        "password": $password,
        "domain": $domain,
        "port_ssh": $ssh,
        "port_dekodemo": $doko,
        "port_vless": $vless,
        "port_vmess": $vmess,
        "port_trojan": $trojan,
        "path_dir": ("/opt/xray/" + $username),
        "active": true,
        "bandwidth_quota_gb": 4096
     }]' "$PROFILE_FILE" > "$tmp" && mv "$tmp" "$PROFILE_FILE"
}

delete_profile_json() {
  local name="$1"
  if ! command -v jq >/dev/null 2>&1; then return; fi
  [ -f "$PROFILE_FILE" ] || return
  local tmp; tmp="$(mktemp)"
  jq --arg n "$name" '[.[] | select(.username != $n)]' "$PROFILE_FILE" > "$tmp" && mv "$tmp" "$PROFILE_FILE"
}

# ==============================
# MAIN
# ==============================
while true; do
  clear
  echo "========================="
  echo "  Xray Docker CLI"
  echo "========================="
  echo "1) Buat profile / container baru"
  echo "2) List container"
  echo "3) Hapus container (sekalian hapus nginx conf)"
  echo "4) Issue SSL dari profiles.json (pilih)"
  echo "0) Keluar"
  read -rp "Pilih: " CH

  case "$CH" in
    1)
      check_image
      load_state

      echo "======== Buat profile baru ========"
      read -rp "Nama profile (mis: user1): " NAME
      [ -z "$NAME" ] && { echo "nama wajib"; read -rp "enter..."; continue; }

      read -rp "Domain (opsional): " DOMAIN

      echo
      echo "Port auto sekarang:"
      echo "  dokodemo : $DOKO"
      echo "  vless    : $((DOKO+1))"
      echo "  vmess    : $((DOKO+2))"
      echo "  trojan   : $((DOKO+3))"
      echo "  ssh      : $SSH"
      echo

      read -rp "Port dokodemo [$DOKO]: " IN_D; [ -n "$IN_D" ] && DOKO="$IN_D"
      VLESS=$((DOKO+1)); VMESS=$((DOKO+2)); TROJAN=$((DOKO+3))

      read -rp "Port SSH [$SSH]: " IN_S; [ -n "$IN_S" ] && SSH="$IN_S"

      read -rp "Password SSH root [default: root123]: " ROOTPW
      [ -z "$ROOTPW" ] && ROOTPW="root123"

      mkdir -p "$BASE_DIR/$NAME/log" "$BASE_DIR/$NAME/etc-xray" "$BASE_DIR/$NAME/vnstat" "$BASE_DIR/$NAME/ssh"

      echo
      echo "== RINGKASAN =="
      echo "Nama      : $NAME"
      echo "Domain    : ${DOMAIN:-(-)}"
      echo "dokodemo  : $DOKO"
      echo "vless     : $VLESS"
      echo "vmess     : $VMESS"
      echo "trojan    : $TROJAN"
      echo "ssh       : $SSH"
      echo "password  : $ROOTPW"
      echo

      read -rp "Lanjut jalankan container? [Y/n]: " GO; GO=${GO:-Y}
      if [[ "$GO" =~ ^[Yy]$ ]]; then
        CURRENT_SSH="$SSH"
        docker rm -f "xray-$NAME" >/dev/null 2>&1 || true

        docker run -d \
          --name "xray-$NAME" \
          --hostname "$NAME" \
          --network=host \
          -e XRAY_HOSTNAME="$NAME" \
          -e XRAY_DOMAIN="$DOMAIN" \
          -e DOKODEMO_PORT="$DOKO" \
          -e VLESS_PORT="$VLESS" \
          -e VMESS_PORT="$VMESS" \
          -e TROJAN_PORT="$TROJAN" \
          -e SSH_PORT="$CURRENT_SSH" \
          -e ROOT_PASSWORD="$ROOTPW" \
          -v "$BASE_DIR/$NAME/log:/var/log/xray" \
          -v "$BASE_DIR/$NAME/etc-xray:/etc/xray" \
          -v "$BASE_DIR/$NAME/vnstat:/var/lib/vnstat" \
          -v "$BASE_DIR/$NAME/ssh:/root/.ssh" \
          "$IMAGE_NAME"

        save_profile_json "$NAME" "$DOMAIN" "$ROOTPW" "$CURRENT_SSH" "$DOKO" "$VLESS" "$VMESS" "$TROJAN"

        if [ -n "$DOMAIN" ]; then
          read -rp "Sekalian issue SSL untuk $DOMAIN ? [y/N]: " SSLGO
          if [[ "$SSLGO" =~ ^[Yy]$ ]]; then
            if issue_ssl_for_user "$NAME" "$DOMAIN"; then
              write_nginx_block "$NAME" "$DOMAIN" "$VLESS" "$VMESS" "$TROJAN"
            else
              echo "⚠️ SSL gagal → nginx gak ditulis."
            fi
          else
            echo "⚠️ SSL belum dibuat. Jalankan menu 4 nanti."
          fi
          # Jika cert SUDAH ada (misal hasil restore), tulis nginx sekarang juga
          if [ -f "/opt/xray/$NAME/xray.crt" ] && [ -f "/opt/xray/$NAME/xray.key" ]; then
            write_nginx_block "$NAME" "$DOMAIN" "$VLESS" "$VMESS" "$TROJAN"
          fi
        fi

        DOKO=$((DOKO+STEP)); SSH=$((SSH+1)); save_state

        PUBIP="$(get_public_ip)"
        echo "✅ container xray-$NAME jalan."
        if [ -n "$PUBIP" ]; then echo "   ssh: ssh root@${PUBIP} -p ${CURRENT_SSH}"; else echo "   ssh: ssh root@<server-ip> -p ${CURRENT_SSH}"; fi
      else
        echo "❎ dibatalkan."
      fi

      read -rp "enter..."
    ;;
    2)
      docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' | grep xray- || echo "(kosong)"
      read -rp "enter..."
    ;;
    3)
      MAP=(); i=0
      while IFS= read -r line; do
        i=$((i+1))
        name="$(echo "$line" | awk '{print $1}')"
        status="$(echo "$line" | awk '{print $2,$3,$4,$5,$6,$7,$8}')"
        IMAGE="$(echo "$line" | awk '{print $NF}')"
        printf " %d) %s\t%s\t%s\n" "$i" "$name" "$status" "$IMAGE"
        MAP[$i]="$name"
      done < <(docker ps -a --format '{{.Names}} {{.Status}} {{.Image}}' | grep xray-)

      [ $i -eq 0 ] && { echo "(gak ada container)"; read -rp "enter..."; continue; }

      read -rp "Hapus nomor / nama: " DEL
      if [[ "$DEL" =~ ^[0-9]+$ ]]; then DEL="${MAP[$DEL]}"; fi
      [ -z "$DEL" ] && { echo "batal"; read -rp "enter..."; continue; }

      read -rp "Yakin hapus $DEL ? [y/N]: " YA
      [[ "$YA" =~ ^[Yy]$ ]] || { echo "batal"; read -rp "enter..."; continue; }

      docker rm -f "$DEL" 2>/dev/null || true
      short="${DEL#xray-}"
      rm -f "$NGINX_CONF_DIR/xray-${short}.conf"
      delete_profile_json "$short"
      nginx -t >/dev/null 2>&1 && (systemctl reload nginx 2>/dev/null || true)

      echo "✅ $DEL dihapus (container + nginx + profiles.json)"
      read -rp "enter..."
    ;;
    4)
      if [ ! -f "$PROFILE_FILE" ]; then echo "profiles.json belum ada."; read -rp "enter..."; continue; fi
      if ! command -v jq >/dev/null 2>&1; then echo "jq gak ada. apt-get install -y jq"; read -rp "enter..."; continue; fi

      mapfile -t LINES < <(jq -r '.[] | select(.domain != null and .domain != "") | "\(.username) \(.domain) \(.port_vless) \(.port_vmess) \(.port_trojan)"' "$PROFILE_FILE")
      if [ ${#LINES[@]} -eq 0 ]; then echo "gak ada profile yang punya domain."; read -rp "enter..."; continue; fi

      echo "Pilih profile yang mau di-issue SSL:"
      idx=0; declare -A UMAP
      for line in "${LINES[@]}"; do
        idx=$((idx+1))
        user="$(echo "$line" | awk '{print $1}')"
        domain="$(echo "$line" | awk '{print $2}')"
        echo " $idx) $user  ($domain)"
        UMAP[$idx]="$line"
      done
      echo " a) issue semua"
      read -rp "Pilih: " PICK

      if [ "$PICK" = "a" ] || [ "$PICK" = "A" ]; then
        for line in "${LINES[@]}"; do
          user="$(echo "$line" | awk '{print $1}')"
          domain="$(echo "$line" | awk '{print $2}')"
          vless="$(echo "$line" | awk '{print $3}')"
          vmess="$(echo "$line" | awk '{print $4}')"
          trojan="$(echo "$line" | awk '{print $5}')"
          echo "== issue SSL untuk $user / $domain =="
          if issue_ssl_for_user "$user" "$domain"; then
            write_nginx_block "$user" "$domain" "$vless" "$vmess" "$trojan"
          else
            echo "⚠️ skip nginx buat $user karena SSL gagal"
          fi
        done
        read -rp "enter..."; continue
      fi

      if [[ "$PICK" =~ ^[0-9]+$ ]] && [ -n "${UMAP[$PICK]}" ]; then
        line="${UMAP[$PICK]}"
        user="$(echo "$line" | awk '{print $1}')"
        domain="$(echo "$line" | awk '{print $2}')"
        vless="$(echo "$line" | awk '{print $3}')"
        vmess="$(echo "$line" | awk '{print $4}')"
        trojan="$(echo "$line" | awk '{print $5}')"
        echo "== issue SSL untuk $user / $domain =="
        if issue_ssl_for_user "$user" "$domain"; then
          write_nginx_block "$user" "$domain" "$vless" "$vmess" "$trojan"
        else
          echo "⚠️ SSL gagal → nginx gak ditulis."
        fi
      else
        echo "batal."
      fi

      read -rp "enter..."
    ;;
    0) exit 0 ;;
    *) echo "pilihan gak dikenal"; read -rp "enter..." ;;
  esac
done
