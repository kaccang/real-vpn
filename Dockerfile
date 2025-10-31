FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

# 1. paket dasar
RUN apt-get update && \
apt-get install -y \
curl \
unzip \
ca-certificates \
supervisor \
openssh-server \
nano \
grep \
cron \
vnstat \
iproute2 \
net-tools && \
mkdir -p /var/run/sshd /var/log/supervisor && \
rm -rf /var/lib/apt/lists/*

# 2. download xray (boleh kamu kunci ke v25.10.15)
ARG XRAY_VER=v25.10.15
RUN set -eux; \
arch="$(uname -m)"; \
if [ "$arch" = "x86_64" ]; then xarch=64; \
elif [ "$arch" = "aarch64" ]; then xarch=arm64-v8a; \
else echo "arch $arch belum ditangani"; exit 1; \
fi; \
curl -L -o /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/Xray-linux-${xarch}.zip"; \
unzip /tmp/xray.zip -d /tmp/xray; \
install -m 755 /tmp/xray/xray /usr/local/bin/xray; \
mkdir -p /usr/local/share/xray; \
install -m 644 /tmp/xray/geoip.dat /usr/local/share/xray/geoip.dat; \
install -m 644 /tmp/xray/geosite.dat /usr/local/share/xray/geosite.dat; \
rm -rf /tmp/xray /tmp/xray.zip

# 3. folder xray
RUN mkdir -p /etc/xray /var/log/xray /etc/supervisor && \
chmod 777 /var/log/xray

# 4. copy script CLI kamu ke dalam container
# (pastikan folder /opt/xray/container/ ada di host)
COPY container/* /usr/bin/
RUN chmod +x /usr/bin/*

# Auto-jalankan menu saat login (test doang, tulis ke /root/.bashrc)
RUN bash -lc 'if ! grep -q "/usr/bin/menu" /root/.bashrc 2>/dev/null; then echo "/usr/bin/menu" >> /root/.bashrc; fi'

# Cron system-wide (butuh kolom user = root)
RUN printf '%s\n' \
"0 1 * * * root /usr/bin/menu" \
"0 2 * * * root /usr/bin/backup" \
"0 */12 * * * root /usr/bin/bw-tele" \
> /etc/cron.d/container-jobs && \
chmod 644 /etc/cron.d/container-jobs

# install rclone di DALAM image
RUN curl -fsSL https://rclone.org/install.sh | bash

# siapkan folder conf
RUN mkdir -p /root/.config/rclone /etc/rclone /tmp/restore

# kalau file ini ada di build context → akan ke-copy
RUN set -eux; \
    # rclone.conf
    if [ -f /tmp/rclone.conf ]; then \
        cp /tmp/rclone.conf /root/.config/rclone/rclone.conf; \
    else \
        touch /root/.config/rclone/rclone.conf; \
    fi; \
    # token
    if [ -f /tmp/.token ]; then \
        cp /tmp/.token /etc/.token; \
    else \
        touch /etc/.token; \
    fi


# 5. copy entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

CMD ["/entrypoint.sh"]
