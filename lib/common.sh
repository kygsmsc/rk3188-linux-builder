#!/bin/bash
# ============================================================
# lib/common.sh — hi3798mv100 纯净 Ubuntu rootfs 构建核心
# TTL 版与 USB 版共用，由 build_rootfs.sh / build_usb_rootfs.sh 调用
#
# 可配置环境变量（均有默认值）：
#   MODE            ttl | usb                    （由包装脚本设置）
#   UBUNTU_VERSION  Ubuntu Base 版本号           （默认 20.04.5）
#   BASE_URL        Ubuntu Base 下载目录         （默认 cdimage.ubuntu.com 官方）
#   MIRROR          apt 软件源镜像               （默认华为云）
#   HOSTNAME        主机名                        （默认 hi3798mv100）
#   ROOT_PASSWORD   root 密码                     （默认 root123，生产请改!）
#   TIMEZONE        时区                          （默认 Asia/Shanghai）
#   LOCALES         生成的 locale（空格分隔）     （默认 en_US.UTF-8 zh_CN.UTF-8）
#   ROOTFS_DIR      输出目录                      （默认 ./pure_rootfs 或 ./usb_pure_rootfs）
# ============================================================
set -euo pipefail

MODE="${MODE:?请通过 build_rootfs.sh (ttl) 或 build_usb_rootfs.sh (usb) 调用}"
UBUNTU_VERSION="${UBUNTU_VERSION:-20.04.5}"
_UBUNTU_SERIES=$(echo "$UBUNTU_VERSION" | cut -d. -f1,2)
BASE_URL="${BASE_URL:-https://cdimage.ubuntu.com/ubuntu-base/releases/${_UBUNTU_SERIES}/release}"
MIRROR="${MIRROR:-http://repo.huaweicloud.com/ubuntu-ports}"

TARGET_HOSTNAME="${TARGET_HOSTNAME:-hi3798mv100}"
CUSTOM_MAC="${CUSTOM_MAC:-}"
MINIMAL_MODE="${MINIMAL_MODE:-no}"
ROOT_PASSWORD="${ROOT_PASSWORD:-root123}"
TIMEZONE="${TIMEZONE:-Asia/Shanghai}"
LOCALES="${LOCALES:-en_US.UTF-8 zh_CN.UTF-8}"

case "$_UBUNTU_SERIES" in
  20.04) UBUNTU_CODENAME="focal" ;;
  22.04) UBUNTU_CODENAME="jammy" ;;
  24.04) UBUNTU_CODENAME="noble" ;;
  *)     echo "⚠️  未知版本 $UBUNTU_VERSION，默认 focal" >&2; UBUNTU_CODENAME="focal" ;;
esac
export UBUNTU_CODENAME

echo "==> [common.sh] UBUNTU_VERSION=$UBUNTU_VERSION  =>  CODENAME=$UBUNTU_CODENAME"
echo "==> [common.sh] TARGET_HOSTNAME=$TARGET_HOSTNAME"
echo "==> [common.sh] CUSTOM_MAC=${CUSTOM_MAC:-(未设置，用设备原生 MAC)}"
echo "==> [common.sh] MINIMAL_MODE=$MINIMAL_MODE"
echo "==> [common.sh] BASE_URL=$BASE_URL"
echo "==> [common.sh] MIRROR=$MIRROR"

case "$MODE" in
  ttl) DEFAULT_ROOTFS_DIR="$(pwd)/pure_rootfs" ;;
  usb) DEFAULT_ROOTFS_DIR="$(pwd)/usb_pure_rootfs" ;;
  *)   echo "❌ 未知 MODE: $MODE" >&2; exit 1 ;;
esac
ROOTFS_DIR="${ROOTFS_DIR:-$DEFAULT_ROOTFS_DIR}"
BASE_TARBALL="ubuntu-base-${UBUNTU_VERSION}-base-armhf.tar.gz"
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
  $SUDO -v 2>/dev/null || { echo "❌ 需要 root 权限或 sudo" >&2; exit 1; }
fi

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

log() { echo "==> $*"; }

cleanup_mounts() {
  for m in tmp var/cache/apt/archives dev/pts dev sys proc; do
    $SUDO umount -lf "$ROOTFS_DIR/$m" 2>/dev/null || true
  done
}
trap cleanup_mounts EXIT INT TERM

fetch_base() {
  log "下载 Ubuntu Base $UBUNTU_VERSION (armhf)..."
  log "目标: cache/$BASE_TARBALL"
  log "来源: $BASE_URL/$BASE_TARBALL"
  mkdir -p cache
  (
    cd cache
    if [ -f "$BASE_TARBALL" ] && ! tar -tzf "$BASE_TARBALL" >/dev/null 2>&1; then
      echo "⚠️  缓存损坏，重新下载"
      rm -f "$BASE_TARBALL"
    fi
    wget -q -c --tries=5 --timeout=60 "$BASE_URL/$BASE_TARBALL" || exit 1
    if wget -q --tries=3 --timeout=30 -O SHA256SUMS "$BASE_URL/SHA256SUMS" 2>/dev/null; then
      if grep -F "$BASE_TARBALL" SHA256SUMS | sha256sum -c - >/dev/null 2>&1; then
        echo "✅ SHA256 校验通过"
      else
        echo "❌ SHA256 校验失败" >&2
        exit 1
      fi
    else
      echo "⚠️  未获取 SHA256SUMS，跳过校验"
    fi
  )
}

prepare_rootfs() {
  log "准备目录: $ROOTFS_DIR"
  $SUDO rm -rf "$ROOTFS_DIR"
  mkdir -p "$ROOTFS_DIR"
  log "解压 Ubuntu Base..."
  $SUDO tar --numeric-owner -xpf "cache/$BASE_TARBALL" -C "$ROOTFS_DIR"
  $SUDO chown root:root "$ROOTFS_DIR"
}

setup_chroot_env() {
  log "准备 Chroot 环境..."
  if [ ! -f /usr/bin/qemu-arm-static ]; then
    echo "❌ 未找到 /usr/bin/qemu-arm-static，请: sudo apt-get install qemu-user-static" >&2
    exit 1
  fi
  $SUDO cp /usr/bin/qemu-arm-static "$ROOTFS_DIR/usr/bin/"
  command -v update-binfmts >/dev/null 2>&1 && $SUDO update-binfmts --enable qemu-arm 2>/dev/null || true
  $SUDO cp /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf"
  $SUDO mkdir -p "$ROOTFS_DIR"/{proc,sys,dev,dev/pts,tmp,var/cache/apt/archives}
  $SUDO mount -t proc proc "$ROOTFS_DIR/proc"
  $SUDO mount -t sysfs sysfs "$ROOTFS_DIR/sys"
  $SUDO mount -o bind /dev "$ROOTFS_DIR/dev"
  $SUDO mount -o bind /dev/pts "$ROOTFS_DIR/dev/pts"
}

write_inner_script() {
  log "生成 Chroot 内配置脚本..."
  chmod +x "$LIB_DIR/rootfs_inner.sh"
  $SUDO cp "$LIB_DIR/rootfs_inner.sh" "$ROOTFS_DIR/tmp/rootfs_inner.sh"
}

run_inner() {
  log "在 Chroot 中执行安装配置（耗时较长）..."
  $SUDO chroot "$ROOTFS_DIR" /usr/bin/env \
    MODE="$MODE" MIRROR="$MIRROR" HOSTNAME="$TARGET_HOSTNAME" \
    ROOT_PASSWORD="$ROOT_PASSWORD" TIMEZONE="$TIMEZONE" LOCALES="$LOCALES" \
    UBUNTU_CODENAME="$UBUNTU_CODENAME" CUSTOM_MAC="$CUSTOM_MAC" \
    MINIMAL_MODE="$MINIMAL_MODE" \
    /bin/bash /tmp/rootfs_inner.sh
}

finish() {
  cleanup_mounts
  $SUDO rm -f "$ROOTFS_DIR/tmp/rootfs_inner.sh" "$ROOTFS_DIR/usr/bin/qemu-arm-static" 2>/dev/null || true

  log "rootfs 发版前审计"
  local FAIL=0
  local SUSPECT=(
    "root/mv100" "root/sdat2img" "root/simg2img" "root/sparse_info"
    "root/work" "root/original_usb" "root/www_raw" "root/mv100.zip"
    "www_raw.ext4" "backup-32.gz" "sdat2img.py" "simg2img.py"
    "p9-rootfs.img" "p8-backup.img" "qemu-arm-static"
  )
  for s in "${SUSPECT[@]}"; do
    if [ -e "$ROOTFS_DIR/$s" ]; then
      echo "❌ 可疑文件: $ROOTFS_DIR/$s"
      FAIL=1
    fi
  done

  local BAD_ROOT
  BAD_ROOT=$($SUDO find "$ROOTFS_DIR/root" -mindepth 1 -maxdepth 1 \
      ! -name '.bashrc' ! -name '.profile' ! -name '.bash_logout' \
      ! -name '.cache' ! -name '.local' 2>/dev/null)
  if [ -n "$BAD_ROOT" ]; then
    echo "❌ /root 非标准:"
    echo "$BAD_ROOT"
    FAIL=1
  fi

  local TMP_COUNT
  TMP_COUNT=$($SUDO find "$ROOTFS_DIR/tmp" -mindepth 1 2>/dev/null | wc -l)
  if [ "$TMP_COUNT" -ne 0 ]; then
    echo "❌ /tmp 非空: $TMP_COUNT 条目"
    $SUDO ls -la "$ROOTFS_DIR/tmp/"
    FAIL=1
  fi

  if [ "$FAIL" -ne 0 ]; then
    echo "=============================================="
    echo "❌ 审计失败"
    echo "=============================================="
    exit 1
  fi
  echo "✅ 审计通过：rootfs 干净"

  local SIZE
  SIZE="$($SUDO du -sh "$ROOTFS_DIR" | cut -f1)"
  echo "=============================================="
  echo "✅ ${MODE} 版纯净根文件系统构建完成: $ROOTFS_DIR ($SIZE)"
  echo "=============================================="
}

main() {
  log "开始构建 ${MODE} 版纯净根文件系统"
  fetch_base
  prepare_rootfs
  setup_chroot_env
  write_inner_script
  run_inner
  finish
}
