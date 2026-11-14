#!/bin/bash
# ============================================================
# lib/common.sh — RK3188 纯净 rootfs 构建核心（三发行版）
#
# 修复记录（本轮）：
#   [R1] Ubuntu CODENAME 修正：22.04.5 → jammy（apt 源只能用代号）
#   [R2] Debian：mmdebstrap 前确保 debian-archive-keyring 已安装且路径正确
#   [R3] Armbian：通配符改为同时匹配 legacy/current/vendor 分支，
#        不再依赖 branch 字段精确匹配（镜像站实际只有 legacy 的 bookworm）
# ============================================================
set -euo pipefail

MODE="${MODE:?请通过 build_rootfs.sh (ttl) 或 build_usb_rootfs.sh (usb) 调用}"
DISTRO="${DISTRO:-ubuntu}"
UBUNTU_VERSION="${UBUNTU_VERSION:-22.04.5}"
UBUNTU_ARCH="${UBUNTU_ARCH:-armhf}"
_UBUNTU_SERIES=$(echo "$UBUNTU_VERSION" | cut -d. -f1,2)

DEBIAN_SUITE="${DEBIAN_SUITE:-bookworm}"
DEBIAN_MIRROR="${DEBIAN_MIRROR:-https://mirrors.aliyun.com/debian}"
DEBIAN_ARCH="${DEBIAN_ARCH:-armhf}"

ARMBIAN_BOARD="${ARMBIAN_BOARD:-rock-5b}"
ARMBIAN_RELEASE="${ARMBIAN_RELEASE:-bookworm}"
ARMBIAN_BRANCH="${ARMBIAN_BRANCH:-legacy}"

MIRROR="${MIRROR:-http://repo.huaweicloud.com/ubuntu-ports}"

TARGET_HOSTNAME="${TARGET_HOSTNAME:-rk3188}"
CUSTOM_MAC="${CUSTOM_MAC:-}"
MINIMAL_MODE="${MINIMAL_MODE:-no}"
ROOT_PASSWORD="${ROOT_PASSWORD:-root123}"
TIMEZONE="${TIMEZONE:-Asia/Shanghai}"
LOCALES="${LOCALES:-en_US.UTF-8 zh_CN.UTF-8}"

# [R1] CODENAME：Ubuntu 必须用代号（jammy），不能用版本号（22.04.5）
if [ -z "${UBUNTU_CODENAME:-}" ]; then
  case "$DISTRO" in
    debian)  UBUNTU_CODENAME="${DEBIAN_SUITE}" ;;
    armbian) UBUNTU_CODENAME="${ARMBIAN_RELEASE}" ;;
    *)
      case "$_UBUNTU_SERIES" in
        20.04) UBUNTU_CODENAME="focal" ;;
        22.04) UBUNTU_CODENAME="jammy" ;;
        24.04) UBUNTU_CODENAME="noble" ;;
        *)     echo "⚠️  未知版本 $UBUNTU_VERSION，默认 jammy" >&2; UBUNTU_CODENAME="jammy" ;;
      esac
      ;;
  esac
fi
export UBUNTU_CODENAME

# Ubuntu Base URL：用代号拼完整路径
BASE_URL="${BASE_URL:-}"
if [ "$DISTRO" = "ubuntu" ]; then
  if [ -z "$BASE_URL" ] || ! echo "$BASE_URL" | grep -qE "/${UBUNTU_CODENAME}/release/?$"; then
    BASE_URL="https://cdimage.ubuntu.com/ubuntu-base/releases/${UBUNTU_CODENAME}/release"
  fi
fi

echo "==> [common.sh] DISTRO=$DISTRO  CODENAME=$UBUNTU_CODENAME  ARCH=$UBUNTU_ARCH"
echo "==> [common.sh] TARGET_HOSTNAME=$TARGET_HOSTNAME"
echo "==> [common.sh] CUSTOM_MAC=${CUSTOM_MAC:-(未设置)}"
echo "==> [common.sh] MINIMAL_MODE=$MINIMAL_MODE"
[ "$DISTRO" = "ubuntu" ] && echo "==> [common.sh] BASE_URL=$BASE_URL  MIRROR=$MIRROR"
[ "$DISTRO" = "debian" ] && echo "==> [common.sh] DEBIAN_MIRROR=$DEBIAN_MIRROR"
[ "$DISTRO" = "armbian" ] && echo "==> [common.sh] ARMBIAN_BOARD=$ARMBIAN_BOARD RELEASE=$ARMBIAN_RELEASE BRANCH=$ARMBIAN_BRANCH"

case "$MODE" in
  ttl) DEFAULT_ROOTFS_DIR="$(pwd)/pure_rootfs" ;;
  usb) DEFAULT_ROOTFS_DIR="$(pwd)/usb_pure_rootfs" ;;
  *)   echo "❌ 未知 MODE: $MODE" >&2; exit 1 ;;
esac
ROOTFS_DIR="${ROOTFS_DIR:-$DEFAULT_ROOTFS_DIR}"
BASE_TARBALL=""
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; $SUDO -v 2>/dev/null || exit 1; fi
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

log() { echo "==> $*"; }

cleanup_mounts() {
  for m in tmp var/cache/apt/archives dev/pts dev sys proc; do
    $SUDO umount -lf "$ROOTFS_DIR/$m" 2>/dev/null || true
  done
  $SUDO umount -lf "$(pwd)/mnt_armbian_tmp" 2>/dev/null || true
}
trap cleanup_mounts EXIT INT TERM

# ============================================================
# Ubuntu
# ============================================================
resolve_base_tarball() {
  local sums="cache/SHA256SUMS"
  local probe=""
  if [ -f "$sums" ]; then
    probe=$(grep -oE "ubuntu-base-[0-9.]+-base-${UBUNTU_ARCH}\.tar\.gz" "$sums" 2>/dev/null | head -1 || true)
  fi
  if [ -n "$probe" ]; then BASE_TARBALL="$probe"; else
    BASE_TARBALL="ubuntu-base-${UBUNTU_VERSION}-base-${UBUNTU_ARCH}.tar.gz"
  fi
}

fetch_ubuntu_base() {
  if ! echo "$BASE_URL" | grep -qE "/${UBUNTU_CODENAME}/release/?$"; then
    BASE_URL="https://cdimage.ubuntu.com/ubuntu-base/releases/${UBUNTU_CODENAME}/release"
  fi
  log "下载 Ubuntu Base $UBUNTU_VERSION ($UBUNTU_ARCH)..."
  mkdir -p cache
  wget -q --tries=3 --timeout=30 -O cache/SHA256SUMS "$BASE_URL/SHA256SUMS" 2>/dev/null || true
  resolve_base_tarball
  log "目标文件: $BASE_TARBALL"
  log "来源: $BASE_URL/$BASE_TARBALL"
  (cd cache
   [ -f "$BASE_TARBALL" ] && ! tar -tzf "$BASE_TARBALL" >/dev/null 2>&1 && rm -f "$BASE_TARBALL"
   wget -q -c --tries=5 --timeout=60 "$BASE_URL/$BASE_TARBALL" || exit 1
   if [ -f SHA256SUMS ] && grep -qF "$BASE_TARBALL" SHA256SUMS; then
     grep -F "$BASE_TARBALL" SHA256SUMS | sha256sum -c - || exit 1
   fi)
}

prepare_ubuntu_rootfs() {
  log "准备目录: $ROOTFS_DIR"
  $SUDO rm -rf "$ROOTFS_DIR"; mkdir -p "$ROOTFS_DIR"
  $SUDO tar --numeric-owner -xpf "cache/$BASE_TARBALL" -C "$ROOTFS_DIR"
  $SUDO chown root:root "$ROOTFS_DIR"
}

# ============================================================
# Debian — [R2] 确保 keyring 就绪
# ============================================================
build_debian_rootfs() {
  log "构建 Debian $DEBIAN_SUITE ($DEBIAN_ARCH) rootfs via mmdebstrap..."

  if ! command -v mmdebstrap >/dev/null 2>&1; then
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq mmdebstrap qemu-user-static binfmt-support
  fi

  # [R2] 强制安装 keyring，并校验文件存在
  $SUDO apt-get install -y -qq debian-archive-keyring
  local KEYRING="/usr/share/keyrings/debian-archive-keyring.gpg"
  if [ ! -f "$KEYRING" ]; then
    # 某些 Ubuntu 版本路径可能是 debian-archive-bookworm-stable.gpg
    KEYRING=$(ls /usr/share/keyrings/debian-archive-*.gpg 2>/dev/null | head -1)
  fi
  if [ -z "$KEYRING" ] || [ ! -f "$KEYRING" ]; then
    echo "❌ 找不到 Debian GPG keyring"
    ls -la /usr/share/keyrings/ | grep -i debian || true
    exit 1
  fi
  log "使用 keyring: $KEYRING"

  $SUDO rm -rf "$ROOTFS_DIR"; mkdir -p "$ROOTFS_DIR"

  $SUDO mmdebstrap \
    --architectures="$DEBIAN_ARCH" \
    --variant=minbase \
    --components="main" \
    --keyring="$KEYRING" \
    --include="apt-utils,ca-certificates,locales,tzdata,systemd,systemd-sysv,dbus,udev,e2fsprogs,openssh-server,sudo,iproute2,ifupdown,isc-dhcp-client,network-manager,wpasupplicant,iw,rfkill,iptables,file,procps" \
    "$DEBIAN_SUITE" \
    "$ROOTFS_DIR" \
    "$DEBIAN_MIRROR"

  $SUDO chown root:root "$ROOTFS_DIR"
  log "Debian rootfs 基础包安装完成"
}

# ============================================================
# Armbian — [R3] 通配符放宽，匹配 legacy/current/vendor
# 镜像站实际文件名：Armbian_23.2.1_Rock-5b_bookworm_legacy_5.10.160_minimal.img.xz
# ============================================================
build_armbian_rootfs() {
  log "构建 Armbian ${ARMBIAN_BOARD} ${ARMBIAN_RELEASE} (${ARMBIAN_BRANCH}) rootfs..."

  for t in losetup mount xz rsync wget; do
    command -v "$t" >/dev/null 2>&1 || {
      $SUDO apt-get update -qq
      $SUDO apt-get install -y -qq util-linux mount xz-utils rsync wget
    }
  done

  mkdir -p cache
  local tag="${ARMBIAN_BOARD}-${ARMBIAN_RELEASE}-${ARMBIAN_BRANCH}"
  local img_xz="cache/armbian-${tag}.img.xz"
  local img="cache/armbian-${tag}.img"

  if [ ! -f "$img_xz" ]; then
    local board_cap
    board_cap=$(echo "${ARMBIAN_BOARD}" | sed 's/./\U&/')
    local mirrors=(
      "https://mirrors.tuna.tsinghua.edu.cn/armbian-releases/${ARMBIAN_BOARD}/archive"
      "https://mirrors.bfsu.edu.cn/armbian-releases/${ARMBIAN_BOARD}/archive"
      "https://mirrors.ustc.edu.cn/armbian-releases/${ARMBIAN_BOARD}/archive"
      "https://mirrors.nju.edu.cn/armbian-releases/${ARMBIAN_BOARD}/archive"
    )

    local filename=""
    local url=""
    local base=""
    for base in "${mirrors[@]}"; do
      log "从镜像站查找: ${base}/"
      # [R3] 不限制 branch，匹配任意 *_minimal.img.xz
      # 格式: Armbian_<ver>_<Board>_<release>_<branch>_<kernel>_minimal.img.xz
      filename=$(wget -q -O - "$base/" 2>/dev/null \
        | grep -oE "Armbian_[^\"'<>[:space:]]*_${board_cap}_${ARMBIAN_RELEASE}_[^\"'<>[:space:]]*_minimal\.img\.xz" \
        | sort -V | tail -1 || true)
      if [ -n "$filename" ]; then
        url="${base}/${filename}"
        log "找到: $filename"
        break
      fi
    done

    if [ -z "$url" ]; then
      echo "❌ 找不到 Armbian 镜像"
      echo "   板型: ${ARMBIAN_BOARD}  release: ${ARMBIAN_RELEASE}"
      echo "   尝试过:"
      for b in "${mirrors[@]}"; do echo "     - ${b}/"; done
      echo "   请访问上述 URL 确认实际存在的 release（bookworm/trixie/resolute）"
      exit 1
    fi

    log "下载 Armbian 镜像: $url"
    wget -q -c --tries=5 --timeout=600 "$url" -O "$img_xz" || { echo "❌ 下载失败"; exit 1; }
  fi

  if [ ! -f "$img" ] || [ "$img_xz" -nt "$img" ]; then
    log "解压 Armbian 镜像..."
    xz -dkc "$img_xz" > "$img"
  fi

  log "挂载 Armbian 镜像提取 rootfs..."
  local loop_dev
  loop_dev=$($SUDO losetup -fP --show "$img") || { echo "❌ losetup 失败"; exit 1; }
  sleep 2

  local root_part
  root_part=$($SUDO lsblk -lnpo NAME,SIZE "$loop_dev" | sort -k2 -n | tail -1 | awk '{print $1}')
  if [ -z "$root_part" ]; then
    echo "❌ 找不到 rootfs 分区"; $SUDO losetup -d "$loop_dev"; exit 1
  fi

  $SUDO rm -rf "$ROOTFS_DIR"; mkdir -p "$ROOTFS_DIR"
  local mnt_tmp="mnt_armbian_tmp"
  rm -rf "$mnt_tmp"; mkdir -p "$mnt_tmp"

  $SUDO mount -o ro "$root_part" "$mnt_tmp" || {
    echo "❌ 挂载失败"; $SUDO losetup -d "$loop_dev"; exit 1
  }

  $SUDO rsync -aHAX \
    --exclude=/proc/* --exclude=/sys/* --exclude=/dev/* \
    --exclude=/run/* --exclude=/tmp/* \
    --exclude=/var/cache/apt/archives/* \
    --exclude=/lib/modules/* \
    --exclude=/etc/armbian \
    --exclude=/etc/firstboot.d \
    --exclude=/etc/armbian-firstlogin \
    --exclude=/var/log/* \
    "$mnt_tmp/" "$ROOTFS_DIR/"

  $SUDO umount "$mnt_tmp"; rmdir "$mnt_tmp"
  $SUDO losetup -d "$loop_dev"
  $SUDO chown root:root "$ROOTFS_DIR"
  log "Armbian rootfs 提取完成"
}

# ============================================================
# Chroot 环境（共用）
# ============================================================
setup_chroot_env() {
  log "准备 Chroot 环境..."
  if [ ! -f /usr/bin/qemu-arm-static ]; then
    echo "❌ 未找到 /usr/bin/qemu-arm-static"; exit 1
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
  log "在 Chroot 中执行安装配置..."
  $SUDO chroot "$ROOTFS_DIR" /usr/bin/env \
    MODE="$MODE" DISTRO="$DISTRO" MIRROR="$MIRROR" HOSTNAME="$TARGET_HOSTNAME" \
    ROOT_PASSWORD="$ROOT_PASSWORD" TIMEZONE="$TIMEZONE" LOCALES="$LOCALES" \
    UBUNTU_CODENAME="$UBUNTU_CODENAME" CUSTOM_MAC="$CUSTOM_MAC" \
    MINIMAL_MODE="$MINIMAL_MODE" \
    DEBIAN_MIRROR="$DEBIAN_MIRROR" DEBIAN_SUITE="$DEBIAN_SUITE" \
    ARMBIAN_RELEASE="$ARMBIAN_RELEASE" \
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
    [ -e "$ROOTFS_DIR/$s" ] && { echo "❌ 可疑: $s"; FAIL=1; }
  done
  local BAD_ROOT
  BAD_ROOT=$($SUDO find "$ROOTFS_DIR/root" -mindepth 1 -maxdepth 1 \
      ! -name '.bashrc' ! -name '.profile' ! -name '.bash_logout' \
      ! -name '.cache' ! -name '.local' 2>/dev/null)
  [ -n "$BAD_ROOT" ] && { echo "❌ /root 非标准:"; echo "$BAD_ROOT"; FAIL=1; }
  local TMP_COUNT
  TMP_COUNT=$($SUDO find "$ROOTFS_DIR/tmp" -mindepth 1 2>/dev/null | wc -l)
  [ "$TMP_COUNT" -ne 0 ] && { echo "❌ /tmp 非空"; FAIL=1; }
  if [ "$FAIL" -ne 0 ]; then exit 1; fi
  echo "✅ 审计通过"
  local SIZE
  SIZE="$($SUDO du -sh "$ROOTFS_DIR" | cut -f1)"
  echo "✅ ${MODE} 版 ${DISTRO} 构建完成: $ROOTFS_DIR ($SIZE)"
}

main() {
  log "开始构建 ${MODE} 版 ${DISTRO} 纯净根文件系统"
  case "${DISTRO}" in
    debian)  build_debian_rootfs ;;
    armbian) build_armbian_rootfs ;;
    ubuntu|*) fetch_ubuntu_base; prepare_ubuntu_rootfs ;;
  esac
  setup_chroot_env
  write_inner_script
  run_inner
  finish
}
