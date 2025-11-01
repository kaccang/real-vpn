#!/bin/bash
set -e

# ====== ENV default ======
: "${DOKODEMO_PORT:=10000}"
: "${VLESS_PORT:=10001}"
: "${VMESS_PORT:=10002}"
: "${TROJAN_PORT:=10003}"
: "${SSH_PORT:=2201}"

: "${VLESS_PATH:=/vless}"
: "${VMESS_PATH:=/vmess}"
: "${TROJAN_PATH:=/trojan}"

: "${XRAY_DOMAIN:=example.com}"
: "${ROOT_PASSWORD:=root123}"
: "${XRAY_HOSTNAME:=}"   # hostname dari luar (opsional)

mkdir -p /var/run/sshd /var/log/xray /var/log/supervisor /etc/xray

# simpan domain buat script add-vless, add-vmess, dll
echo "${XRAY_DOMAIN}" > /etc/xray/domain
curl -s ipinfo.io/org | cut -d ' ' -f 2- > /etc/xray/isp
curl -s ipinfo.io/city > /etc/xray/city

# install rclone
curl -fsSL https://rclone.org/install.sh | bash


# SSH allow password + root
sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config || true
sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config || true
sed -i 's/^#PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config || true
sed -i 's/^PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config || true
echo "root:${ROOT_PASSWORD}" | chpasswd

# ====== hostname (dibikin NON-FATAL) ======
if [ -n "$XRAY_HOSTNAME" ]; then
  # ini cuma supaya prompt keliatan cakep, tapi jangan sampai bikin container mati
  echo "$XRAY_HOSTNAME" > /etc/hostname || true
  hostname "$XRAY_HOSTNAME" 2>/dev/null || true
  if ! grep -q "$XRAY_HOSTNAME" /etc/hosts; then
    echo "127.0.1.1   $XRAY_HOSTNAME" >> /etc/hosts || true
  fi
fi

# ====== VNSTAT (disederhanakan, cocok vnstat 2.12) ======
# kalau user gak set VNSTAT_IFACE, coba deteksi otomatis
if [ -z "$VNSTAT_IFACE" ]; then
  echo "[vnstat] VNSTAT_IFACE belum di-set, deteksi otomatis..."
  VNSTAT_IFACE="$(
    ip -o link show 2>/dev/null \
      | awk -F': ' '{print $2}' \
      | grep -v '^lo$' \
      | grep -v '^docker0$' \
      | grep -v '^veth' \
      | grep -v '^br-' \
      | head -n1
  )"
  [ -z "$VNSTAT_IFACE" ] && VNSTAT_IFACE="eth0"
  echo "[vnstat] pakai interface: ${VNSTAT_IFACE}"
else
  echo "[vnstat] VNSTAT_IFACE dari ENV: ${VNSTAT_IFACE}"
fi

mkdir -p /var/lib/vnstat

# bagian vnstat ini jangan bikin entrypoint mati
set +e
echo "[vnstat] init database (vnstatd --initdb)..."
/usr/sbin/vnstatd --initdb 2>/dev/null

echo "[vnstat] tambah interface ${VNSTAT_IFACE} ..."
# vnstat 2.12 gak punya --create tapi punya --add / -u
vnstat --add -i "${VNSTAT_IFACE}" 2>/dev/null
ADD_RC=$?

if [ $ADD_RC -ne 0 ]; then
  echo "[vnstat] --add gagal / gak ada, coba gaya lama: vnstat -u -i ${VNSTAT_IFACE}"
  vnstat -u -i "${VNSTAT_IFACE}" 2>/dev/null
fi
# balik ke strict lagi
set -e

# ====== Xray config (PAKE PUNYAMU, komentar dibiarkan) ======
# HANYA ditulis jika belum ada, supaya tidak overwrite file yang sudah ada/di-mount
if [ ! -s /etc/xray/config.json ]; then
cat >/etc/xray/config.json <<'EOF'
{
  "log": {
    "loglevel": "warning",
    "error": "/var/log/xray/error.log",
    "access": "/var/log/xray/access.log"
   },
   "api": {
    "services": [
      "HandlerService",
      "LoggerService",
      "StatsService"
     ],
    "tag": "api"
    },
    "stats": {},
    "policy": {
    "levels": {
      "0": {
        "handshake": 2,
        "connIdle": 128,
        "statsUserUplink": true,
        "statsUserDownlink": true
        }
       }
      },
      "inbounds": [
      {
      "listen": "127.0.0.1",
      "port": ${DOKODEMO_PORT},
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1"
      },
      "tag": "api"
      },
      {
     "listen": "127.0.0.1",
     "port": ${VLESS_PORT},
     "protocol": "vless",
      "settings": {
          "decryption":"none",
            "clients": [
               {
                 "id": "1d1c1d94-6987-4658-a4dc-8821a30fe7e0"
#vless
#& vless02 2025-10-28
},{"id": "0ee3c8ec-e76b-45e7-b721-a6dfbb5435ac","email": "vless02"
             }
          ]
       },
       "streamSettings":{
         "network": "ws",
            "wsSettings": {
                "path": "${VLESS_PATH}"
          }
        }
     },
     {
     "listen": "127.0.0.1",
     "port": ${VMESS_PORT},
     "protocol": "vmess",
      "settings": {
            "clients": [
               {
                 "id": "1d1c1d94-6987-4658-a4dc-8821a30fe7e0",
                 "alterId": 0
#vmess
### vmess02 2025-10-28
},{"id": "8349249d-5ff1-42f1-9e15-77fb4e609153","alterId": 0,"email": "vmess02"
             }
          ]
       },
       "streamSettings":{
         "network": "ws",
            "wsSettings": {
                "path": "${VMESS_PATH}"
           }
         }
       },
       {
      "listen": "127.0.0.1",
      "port": ${TROJAN_PORT},
      "protocol": "trojan",
      "settings": {
          "decryption":"none",
           "clients": [
              {
                 "password": "1d1c1d94-6987-4658-a4dc-8821a30fe7e0"
#trojanws
#! trojan02 2025-10-28
},{"password": "50a95b46-8c40-4d50-96c3-50775bdccf21","email": "trojan02"
              }
          ],
         "udp": true
       },
       "streamSettings":{
           "network": "ws",
           "wsSettings": {
               "path": "${TROJAN_PATH}"
            }
       }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": { "domainStrategy": "UseIP" },
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "settings": {},
      "tag": "blocked"
    }
  ],
  "routing": {
  "domainStrategy": "ipIfNotMatch",
  "rules": [
    {
      "type": "field",
      "inboundTag": ["api"],
      "outboundTag": "api"
    },
    {
      "type": "field",
      "outboundTag": "direct",
      "network": "tcp,udp"
      }
    ]
  },
  "dns": {
    "servers": [
      "https://1.1.1.1/dns-query",
      "https://dns.google/dns-query",
      "8.8.8.8",
      "1.1.1.1"
    ]
  }
}
EOF
fi

# ====== supervisor ======
cat >/etc/supervisor/supervisord.conf <<EOF
[supervisord]
nodaemon=true
logfile=/var/log/supervisor/supervisord.log

[unix_http_server]
file=/var/run/supervisor.sock
chmod=0700

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix:///var/run/supervisor.sock

[program:xray]
command=/usr/local/bin/xray -config /etc/xray/config.json
autorestart=true
stdout_logfile=/var/log/xray/xray-out.log
stderr_logfile=/var/log/xray/xray-err.log

[program:sshd]
command=/usr/sbin/sshd -D -p ${SSH_PORT}
autorestart=true
stdout_logfile=/var/log/xray/ssh-out.log
stderr_logfile=/var/log/xray/ssh-err.log

[program:vnstatd]
command=/usr/sbin/vnstatd --nodaemon --startempty
autostart=true
autorestart=true
stdout_logfile=/var/log/supervisor/vnstatd.log
stderr_logfile=/var/log/supervisor/vnstatd.err.log

[program:cron]
command=/usr/sbin/cron -f
autostart=true
autorestart=true
stdout_logfile=/var/log/supervisor/cron.log
stderr_logfile=/var/log/supervisor/cron.err
EOF

exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
