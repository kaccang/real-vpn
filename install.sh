#!/bin/bash
apt update
apt install -y git
mkdir -p /opt/xray
chown $USER:$USER /opt/xray
git clone https://github.com/kaccang/real-vpn.git /opt/xray
## Vps utama

# install dependensi
apt update 
apt install ca-certificates curl gnupg lsb-release -y
apt upgrade -y

# install docker
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) \
  signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
apt update
apt install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y
apt install wget curl zip vnstat socat gzip neofetch htop nginx -y 
docker --version

sudo -v ; curl https://rclone.org/install.sh | sudo bash
#
mkdir -p /opt/xray

chmod +x /opt/xray/menu.sh
chmod +x /opt/xray/cert.sh
chmod +x /opt/xray/issue-ssl.sh
chmod +x /opt/xray/backup-restore.sh

cp /opt/xray/menu.sh /usr/bin/
cp /opt/xray/cert.sh /usr/bin/
cp /opt/xray/issue-ssl.sh /usr/bin/
cp /opt/xray/backup-restore.sh /usr/bin/

if ! grep -q "/usr/bin/menu" ~/.bashrc; then
    echo "/usr/bin/menu" >> ~/.bashrc
fi

IMAGE_NAME="xray-base:24.04"
docker build -t "$IMAGE_NAME" -f /opt/xray/Dockerfile /opt/xray
