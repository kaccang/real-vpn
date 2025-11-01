#!/bin/bash
set -euo pipefail

BASE_DIR="/opt/xray"
BACKUP_DIR="$BASE_DIR/backups"
NGINX_CONF_DIR="/etc/nginx/conf.d"
REMOTE_DEFAULT="proton"
REMOTE_SUBDIR="/backup/vps/real-vpn"

mkdir -p "$BACKUP_DIR"

# --- helper: timestamp & pick latest file
ts() { date +%Y%m%d-%H%M%S; }

latest_backup() {
  ls -1t "$BACKUP_DIR"/real-vpn-*.tar.gz 2>/dev/null | head -n1
}

# --- helper: token & rclone config
# /opt/xray/.token (opsional):
#   RCLONE_REMOTE=proton
load_token() {
  local token="$BASE_DIR/.token"
  if [ -f "$token" ]; then
    # shellcheck disable=SC1090
    . "$token"
  fi
}

# rclone config path:
# 1) default: /root/.config/rclone/rclone.conf
# 2) override: jika /opt/xray/.rclone.conf ada dan tidak kosong -> RCLONE_CONFIG env dipakai
setup_rclone_env() {
  if [ -s "$BASE_DIR/.rclone.conf" ]; then
    export RCLONE_CONFIG="$BASE_DIR/.rclone.conf"
  else
    export RCLONE_CONFIG="/root/.config/rclone/rclone.conf"
  fi
}

# --- helper: list containers (untuk metadata)
list_containers() {
  docker ps -a --format '{{.Names}}' | grep '^xray-' || true
}

# --- helper: write manifest ke backups/ (tidak masuk arsip & tidak di root repo)
write_manifest() {
  local stamp="$1"; shift
  local outfile="$BACKUP_DIR/backup.MANIFEST.${stamp}.txt"

  local pubip host
  host="$(hostname -f 2>/dev/null || hostname)"
  pubip="$(curl -4 -s https://icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)"
  local containers
  containers="$(list_containers | tr '\n' ',' | sed 's/,$//')"

  {
    echo "backup_time=${stamp}"
    echo "docker_host=${host}"
    [ -n "$pubip" ] && echo "public_ip=${pubip}" || true
    echo "containers=${containers}"
  } > "$outfile"

  echo "[info] Manifest ditulis: $outfile"
}

# --- BACKUP: buat arsip tar.gz
do_backup() {
  local stamp fname
  stamp="$(ts)"
  fname="real-vpn-${stamp}.tar.gz"
  local target="$BACKUP_DIR/$fname"

  echo "== Backup mulai → $target"

  # Pastikan nginx conf pattern tidak bikin tar error saat no-match.
  shopt -s nullglob

  # Kumpulkan daftar xray-*.conf (boleh kosong)
  mapfile -t nginx_files < <(ls -1 ${NGINX_CONF_DIR}/xray-*.conf 2>/dev/null || true)

  # Tulis manifest (tidak masuk ke arsip)
  write_manifest "$stamp"

  # Buat arsip:
  # -C / : simpan path relatif dari root (opt/xray/..., etc/nginx/conf.d/...)
  # exclude backups agar arsip tidak memuat dirinya sendiri
  # shellcheck disable=SC2086
  tar -C / \
      --exclude="opt/xray/backups" \
      -czf "$target" \
      opt/xray \
      ${nginx_files[@]:+"${nginx_files[@]/#//}"} \
      2>/dev/null || true

  echo "✅ Backup selesai: $target"
}

# --- RESTORE: pilih arsip lokal lalu extract
do_restore() {
  echo "Daftar file backup lokal:"
  mapfile -t files < <(ls -1t "$BACKUP_DIR"/real-vpn-*.tar.gz 2>/dev/null || true)

  if [ ${#files[@]} -eq 0 ]; then
    echo "(tidak ada arsip di $BACKUP_DIR)"
    read -rp "enter..." _; return
  fi

  local i=0
  for f in "${files[@]}"; do
    i=$((i+1))
    echo " $i) $(basename "$f")"
  done

  read -rp "Pilih nomor file yang mau di-restore: " pick
  [[ "$pick" =~ ^[0-9]+$ ]] || { echo "batal"; read -rp "enter..." _; return; }
  [ "$pick" -ge 1 ] && [ "$pick" -le "${#files[@]}" ] || { echo "batal"; read -rp "enter..." _; return; }

  local chosen="${files[$((pick-1))]}"
  echo "== Restore dari: $chosen"

  # Extract ke root
  tar -C / -xzf "$chosen"

  # Reload nginx kalau konfig ada
  if nginx -t >/dev/null 2>&1; then
    (systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true)
  fi

  echo "✅ Restore selesai."
}

# --- UPLOAD: upload backup terakhir ke remote:/backup/vps/real-vpn/<file>.tar.gz
do_upload() {
  setup_rclone_env
  load_token

  local remote="${RCLONE_REMOTE:-$REMOTE_DEFAULT}"
  local last
  last="$(latest_backup)"
  if [ -z "$last" ]; then
    echo "Tidak ada arsip di $BACKUP_DIR"; read -rp "enter..." _; return
  fi

  local base
  base="$(basename "$last")"
  local dest="${remote}:${REMOTE_SUBDIR}/${base}"

  echo "[rclone] upload: $last → $dest"
  rclone copyto "$last" "$dest"
  echo "✅ Upload selesai."
}

# --- DOWNLOAD: list remote dan unduh ke backups/, tanpa bikin folder duplikat
do_download() {
  setup_rclone_env
  load_token

  local remote="${RCLONE_REMOTE:-$REMOTE_DEFAULT}"
  local prefix="${remote}:${REMOTE_SUBDIR}"

  echo "[rclone] listing di ${prefix} ..."
  mapfile -t lines < <(rclone lsf -R --files-only "$prefix" 2>/dev/null || true)

  if [ ${#lines[@]} -eq 0 ]; then
    echo "(tidak ada file di ${prefix})"; read -rp "enter..." _; return
  fi

  # Tampilkan hanya nama file (tanpa subfolder ganda)
  local files=()
  local idx=0
  for line in "${lines[@]}"; do
    # normalize & ambil basename
    f="${line%/}"
    f="$(basename "$f")"
    # filter yang match pola kita
    if [[ "$f" =~ ^real-vpn-.*\.tar\.gz$ ]]; then
      # hindari duplikat
      if ! printf '%s\n' "${files[@]}" | grep -qx "$f"; then
        files+=("$f")
      fi
    fi
  done

  if [ ${#files[@]} -eq 0 ]; then
    echo "(tidak ada file cocok pola real-vpn-*.tar.gz)"; read -rp "enter..." _; return
  fi

  echo "Pilih file yang mau diunduh:"
  for i in "${!files[@]}"; do
    printf " %d) %s\n" "$((i+1))" "${files[$i]}"
  done

  read -rp "Nomor: " pick
  [[ "$pick" =~ ^[0-9]+$ ]] || { echo "batal"; read -rp "enter..." _; return; }
  [ "$pick" -ge 1 ] && [ "$pick" -le "${#files[@]}" ] || { echo "batal"; read -rp "enter..." _; return; }

  local chosen="${files[$((pick-1))]}"
  local src="${prefix}/${chosen}"
  local dst="${BACKUP_DIR}/${chosen}"

  echo "[rclone] download: $src → $dst"
  rclone copyto "$src" "$dst"
  echo "✅ Download selesai: $dst"

  # opsional tawarkan restore
  read -rp "Langsung restore file ini? [y/N]: " go
  if [[ "$go" =~ ^[Yy]$ ]]; then
    tar -C / -xzf "$dst"
    if nginx -t >/dev/null 2>&1; then
      (systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true)
    fi
    echo "✅ Restore selesai."
  fi
}

# ==============================
# MENU
# ==============================
while true; do
  clear
  echo "============================"
  echo "  Xray Backup/Restore CLI"
  echo "============================"
  echo "1) Backup sekarang"
  echo "2) Restore dari file (pilih)"
  echo "3) Upload backup terakhir via rclone"
  echo "4) Download backup via rclone"
  echo "0) Keluar"
  read -rp "Pilih: " CH

  case "$CH" in
    1) do_backup; read -rp "enter..." _ ;;
    2) do_restore; read -rp "enter..." _ ;;
    3) do_upload;  read -rp "enter..." _ ;;
    4) do_download;read -rp "enter..." _ ;;
    0) exit 0 ;;
    *) echo "pilihan gak dikenal"; read -rp "enter..." _ ;;
  esac
done
