#!/bin/bash
# lib/rootfs_inner.sh — 在 chroot 内执行的系统配置脚本
# 兼容 Ubuntu 20.04/22.04/24.04、Debian bookworm/trixie、Armbian bookworm
#
# 三发行版兼容：
#   [D1] APT 源按 DISTRO 分支（ubuntu/debian/armbian）
#   [D2] 软件包列表按 DISTRO 微调（rsyslog 仅 Ubuntu、systemd-timesyncd 仅 Debian/Armbian）
#   [D3] systemd-resolved 仅 Ubuntu 启用；Debian/Armbian 用传统 resolv.conf
#
# 移植自 hi3798 项目，针对 rk3188 + Linux 6.12 适配：
#   [P1-P4]  firstboot-password 正向判据 + chpasswd 管道
#   [P5]  ❌ 已删除（6.12 有 =m 模块，modules-load.d 必须保留）
#   [P6]  system.conf.d/99-old-kernel.conf 消除 hidepid 警告
#   [P7]  保留 apt lists + 99-no-translations
#   [P8]  A 级精简 consolefonts/keymaps/hwdb.bin
#   [P9]  精简不做 apt 操作
#   [P10] eth0 由 NetworkManager 管理
#   [P11] 删除 Ubuntu 默认 10-globally-managed-devices.conf
#   [P12] 预装 iptables 并切换 legacy 后端
#   [R1]  enable serial-getty@ttyS2
#   [R2]  /etc/fstab 用 LABEL=rootfs 兜底
#   [R3]  depmod -a
#   [R4]  MINIMAL_MODE=yes 时 C 级精简
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C LANG=C
export SYSTEMD_OFFLINE=1

DISTRO="${DISTRO:-ubuntu}"

echo "==> [${MODE} 模式 / ${DISTRO}] 挂载 tmpfs"
mount -t tmpfs tmpfs /tmp 2>/dev/null || true
mkdir -p /var/cache/apt/archives
mount -t tmpfs tmpfs /var/cache/apt/archives 2>/dev/null || true

# ========== APT 最小化 ==========
cat > /etc/apt/apt.conf.d/99minimize << 'APTCONF'
APT::Install-Recommends "false";
APT::Install-Suggests "false";
APT::Get::Install-Recommends "false";
APT::Get::Install-Suggests "false";
DPkg::Options:: "--path-exclude=/usr/share/doc/*";
DPkg::Options:: "--path-exclude=/usr/share/man/*";
DPkg::Options:: "--path-exclude=/usr/share/info/*";
DPkg::Options:: "--path-exclude=/usr/share/lintian/*";
DPkg::Options:: "--path-exclude=/usr/share/groff/*";
APTCONF

cat > /etc/apt/apt.conf.d/99locale-keep << 'LOCCONF'
DPkg::Options:: "--path-exclude=/usr/share/locale/*";
DPkg::Options:: "--path-include=/usr/share/locale/en/*";
DPkg::Options:: "--path-include=/usr/share/locale/zh_CN/*";
LOCCONF

cat > /etc/apt/apt.conf.d/99-no-translations << 'APTCONF'
Acquire::IndexTargets::deb::DEP-11::DefaultEnabled "false";
Acquire::IndexTargets::deb::DEP-11-icons::DefaultEnabled "false";
Acquire::IndexTargets::deb::DEP-11-icons-small::DefaultEnabled "false";
Acquire::IndexTargets::deb::DEP-11-icons-large::DefaultEnabled "false";
Acquire::Languages "none";
APTCONF

CODENAME="${UBUNTU_CODENAME:-jammy}"
echo "==> 发行版: $DISTRO  代号: $CODENAME"

# ============================================================
# [D1] APT 源按 DISTRO 分支
# ============================================================
case "${DISTRO}" in
  debian)
    echo "==> 配置 Debian 软件源: ${DEBIAN_MIRROR}"
    cat > /etc/apt/sources.list << SOURCES
deb ${DEBIAN_MIRROR:-https://mirrors.aliyun.com/debian} ${CODENAME} main
deb ${DEBIAN_MIRROR:-https://mirrors.aliyun.com/debian} ${CODENAME}-updates main
deb ${DEBIAN_MIRROR:-https://mirrors.aliyun.com/debian-security} ${CODENAME}-security main
SOURCES
    ;;
  armbian)
    echo "==> 配置 Armbian 软件源（改用 Debian 镜像）: ${DEBIAN_MIRROR}"
    # Armbian bookworm 基于 Debian 12，直接用 Debian 源
    cat > /etc/apt/sources.list << SOURCES
deb ${DEBIAN_MIRROR:-https://mirrors.aliyun.com/debian} ${CODENAME} main contrib non-free non-free-firmware
deb ${DEBIAN_MIRROR:-https://mirrors.aliyun.com/debian} ${CODENAME}-updates main contrib non-free non-free-firmware
deb ${DEBIAN_MIRROR:-https://mirrors.aliyun.com/debian-security} ${CODENAME}-security main contrib non-free non-free-firmware
SOURCES
    # 清理 Armbian 自有源
    rm -f /etc/apt/sources.list.d/armbian.list 2>/dev/null || true
    rm -f /etc/apt/sources.list.d/armbian*.list 2>/dev/null || true
    ;;
  ubuntu|*)
    echo "==> 配置 Ubuntu 软件源: ${MIRROR}"
    if [ "$CODENAME" = "noble" ]; then
        echo "==> DEB822 格式 (24.04+)"
        mkdir -p /etc/apt/sources.list.d
        cat > /etc/apt/sources.list.d/ubuntu.sources << SOURCES
Types: deb
URIs: ${MIRROR}
Suites: ${CODENAME} ${CODENAME}-updates ${CODENAME}-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: ${MIRROR}
Suites: ${CODENAME}-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
SOURCES
        : > /etc/apt/sources.list
    else
        cat > /etc/apt/sources.list << SOURCES
deb ${MIRROR} ${CODENAME} main restricted universe multiverse
deb ${MIRROR} ${CODENAME}-updates main restricted universe multiverse
deb ${MIRROR} ${CODENAME}-security main restricted universe multiverse
deb ${MIRROR} ${CODENAME}-backports main restricted universe multiverse
SOURCES
    fi
    ;;
esac

apt-get update -qq
apt-get -f install -y -qq 2>&1 || true

# ============================================================
# [D2] 软件包列表按 DISTRO 微调
# ============================================================
echo "==> 安装核心软件包"
PKGS="systemd systemd-sysv dbus udev \
  ifupdown isc-dhcp-client iproute2 iputils-ping iputils-arping procps \
  openssh-server ssh sudo e2fsprogs ca-certificates \
  vim-tiny less wget curl cron locales tzdata \
  file network-manager wpasupplicant iw rfkill iptables"

# rsyslog + bash-completion 仅 Ubuntu（Debian/Armbian 用 journald）
if [ "${DISTRO}" = "ubuntu" ]; then
  PKGS="$PKGS rsyslog bash-completion systemd-timesyncd"
else
  PKGS="$PKGS systemd-timesyncd"
fi

apt-get install -y -qq --no-install-recommends $PKGS

# ============================================================
# [P12] iptables 切换到 legacy 后端
# ============================================================
echo "==> 配置 iptables 使用 legacy 后端"
if [ -x /usr/sbin/iptables-legacy ]; then
    update-alternatives --set iptables /usr/sbin/iptables-legacy 2>/dev/null || true
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy 2>/dev/null || true
    echo "✅ iptables 已切换至 legacy 模式"
    iptables --version 2>/dev/null || true
else
    echo "⚠️ 未找到 iptables-legacy，跳过切换"
fi

# ========== USB 存储支持 ==========
echo "==> USB 存储支持"
apt-get install -y -qq --no-install-recommends \
  util-linux usbutils dosfstools ntfs-3g exfat-fuse eject

cat > /etc/udev/rules.d/99-usb-storage-mount.rules << 'UDEV'
ACTION=="add", SUBSYSTEM=="block", KERNEL=="sd[a-z][0-9]", ENV{SYSTEMD_WANTS}+="usb-mount@%k.service"
ACTION=="remove", SUBSYSTEM=="block", KERNEL=="sd[a-z][0-9]", ENV{SYSTEMD_WANTS}+="usb-umount@%k.service"
UDEV

cat > /etc/systemd/system/usb-mount@.service << 'SVC'
[Unit]
Description=Auto-mount USB block device /dev/%i
After=dev-%i.device

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/usb-mount.sh add %i
ExecStop=/usr/local/sbin/usb-mount.sh remove %i
SVC

cat > /etc/systemd/system/usb-umount@.service << 'SVC'
[Unit]
Description=Auto-unmount USB block device /dev/%i

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/usb-mount.sh remove %i
SVC

mkdir -p /usr/local/sbin
cat > /usr/local/sbin/usb-mount.sh << 'SCRIPT'
#!/bin/bash
set -euo pipefail
ACTION="$1"; DEV="$2"
DEV_PATH="/dev/$DEV"; MOUNT_POINT="/media/$DEV"
case "$ACTION" in
  add)
    [ -b "$DEV_PATH" ] || exit 0
    sleep 0.5
    FSTYPE=$(blkid -o value -s TYPE "$DEV_PATH" 2>/dev/null || true)
    [ -z "$FSTYPE" ] && exit 0
    mkdir -p "$MOUNT_POINT"
    case "$FSTYPE" in
      vfat|fat|msdos) mount -t vfat -o rw,uid=0,gid=0,umask=000 "$DEV_PATH" "$MOUNT_POINT" || true ;;
      exfat) mount.exfat-fuse -o rw,uid=0,gid=0,umask=000 "$DEV_PATH" "$MOUNT_POINT" 2>/dev/null \
               || mount -t exfat -o rw,uid=0,gid=0,umask=000 "$DEV_PATH" "$MOUNT_POINT" 2>/dev/null || true ;;
      ntfs) mount -t ntfs-3g -o rw,uid=0,gid=0,umask=000 "$DEV_PATH" "$MOUNT_POINT" || true ;;
      ext4|ext3|ext2) mount -t "$FSTYPE" -o rw "$DEV_PATH" "$MOUNT_POINT" || true ;;
      *) mount -o rw "$DEV_PATH" "$MOUNT_POINT" 2>/dev/null || true ;;
    esac ;;
  remove)
    umount "$MOUNT_POINT" 2>/dev/null || umount -l "$MOUNT_POINT" 2>/dev/null || true
    rmdir "$MOUNT_POINT" 2>/dev/null || true ;;
esac
SCRIPT
chmod +x /usr/local/sbin/usb-mount.sh
echo "✅ USB 存储支持已配置"

# ========== 基础系统配置 ==========
echo "==> 基础系统配置"
echo "$HOSTNAME" > /etc/hostname
hostname "$HOSTNAME" 2>/dev/null || true
cat > /etc/hosts << HOSTS
127.0.0.1 localhost
127.0.1.1 $HOSTNAME
HOSTS
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
echo "$TIMEZONE" > /etc/timezone
dpkg-reconfigure -f noninteractive tzdata >/dev/null 2>&1 || true

# ========== [R2] fstab ==========
cat > /etc/fstab << 'FSTAB'
# <file system>  <mount point>  <type>     <options>                         <dump> <pass>
LABEL=rootfs     /              ext4       defaults,noatime,errors=remount-ro 0     1
proc             /proc          proc       defaults                          0     0
sysfs            /sys           sysfs      defaults                          0     0
devtmpfs         /dev           devtmpfs   mode=0755,nosuid                  0     0
tmpfs            /tmp           tmpfs      defaults,nosuid,size=64M          0     0
FSTAB

# ========== root 密码 ==========
echo "==> 设置 root 密码（长度 ${#ROOT_PASSWORD} 字符）"
echo "root:$ROOT_PASSWORD" | chpasswd
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config 2>/dev/null || true

# ========== [P1-P4] firstboot-password ==========
printf '%s\n' "$ROOT_PASSWORD" > /etc/firstboot-pwd.txt
chmod 600 /etc/firstboot-pwd.txt
chown root:root /etc/firstboot-pwd.txt

cat > /usr/local/sbin/firstboot-password.sh << 'SH'
#!/bin/bash
PWDFILE=/etc/firstboot-pwd.txt
[ -f "$PWDFILE" ] || exit 0
if { printf 'root:'; cat "$PWDFILE"; } | chpasswd; then
    chage -d "$(date +%Y-%m-%d)" root 2>/dev/null || true
    rm -f "$PWDFILE"
    touch /var/lib/firstboot-password.done
    echo "firstboot-password: reset done at $(date)" | systemd-cat -t firstboot-password 2>/dev/null || true
else
    echo "firstboot-password: chpasswd FAILED, keeping $PWDFILE for retry" \
        | systemd-cat -t firstboot-password 2>/dev/null || true
    exit 1
fi
SH
chmod +x /usr/local/sbin/firstboot-password.sh

cat > /etc/systemd/system/firstboot-password.service << 'SVC'
[Unit]
Description=First boot: force reset root password
ConditionPathExists=/etc/firstboot-pwd.txt
After=local-fs.target
Before=ssh.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/firstboot-password.sh
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
SVC
systemctl enable firstboot-password.service 2>/dev/null || true

# ========== firstboot-apt-update ==========
cat > /etc/systemd/system/firstboot-apt-update.service << 'SVC'
[Unit]
Description=First boot: refresh apt package lists in background
ConditionPathExists=!/var/lib/firstboot-apt-update.done
After=network-online.target networking.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'for i in $(seq 1 90); do if ping -c 1 -W 1 223.5.5.5 >/dev/null 2>&1; then break; fi; sleep 1; done; /usr/bin/apt-get update -qq && /bin/touch /var/lib/firstboot-apt-update.done'
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
SVC
systemctl enable firstboot-apt-update.service 2>/dev/null || true

# ============================================================
# [P10/P11] 网络：eth0 + wlan0 全由 NetworkManager 管理
# ============================================================
echo "==> 网络配置（eth0 + wlan0 全部由 NetworkManager 管理）"
rm -f /etc/network/interfaces.d/eth0
mkdir -p /etc/network/interfaces.d

cat > /etc/network/interfaces << 'NETIF'
# Loopback
auto lo
iface lo inet loopback

# eth0 / wlan0 全部由 NetworkManager 管理
NETIF

# [P11] 删除 Ubuntu 默认 unmanaged-devices
rm -f /usr/lib/NetworkManager/conf.d/10-globally-managed-devices.conf

mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/10-globally-managed-devices.conf << 'NMOVERRIDE'
[keyfile]
unmanaged-devices=
NMOVERRIDE

cat > /etc/NetworkManager/conf.d/99-rk3188.conf << 'NMCONF'
[device]
wifi.scan-rand-mac-address=no

[connection]
wifi.powersave = 2
NMCONF

mkdir -p /etc/NetworkManager/system-connections
ETH_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null \
           || uuidgen 2>/dev/null \
           || echo "8a8b4b7a-1e6d-4a6c-9b1a-1a2b3c4d5e6f")

if [ -n "${CUSTOM_MAC:-}" ]; then
  cat > /etc/NetworkManager/system-connections/eth0.nmconnection << NMETH0
[connection]
id=eth0
uuid=$ETH_UUID
type=ethernet
interface-name=eth0
autoconnect=true

[ethernet]
cloned-mac-address=$CUSTOM_MAC

[ipv4]
method=auto

[ipv6]
method=auto
NMETH0
else
  cat > /etc/NetworkManager/system-connections/eth0.nmconnection << NMETH0
[connection]
id=eth0
uuid=$ETH_UUID
type=ethernet
interface-name=eth0
autoconnect=true

[ipv4]
method=auto

[ipv6]
method=auto
NMETH0
fi
chmod 600 /etc/NetworkManager/system-connections/eth0.nmconnection
chown root:root /etc/NetworkManager/system-connections/eth0.nmconnection

# ========== locale ==========
echo "==> 生成 locale: $LOCALES"
cat > /etc/locale.gen << 'LGEN'
en_US.UTF-8 UTF-8
zh_CN.UTF-8 UTF-8
LGEN

if ! locale-gen; then
  echo "⚠️  locale-gen 返回非 0"
fi

for _loc in en_US.UTF-8 zh_CN.UTF-8; do
  _dir="/usr/lib/locale/$(echo "$_loc" | tr 'A-Z.' 'a-z' | sed 's/utf-8/utf8/')"
  if [ ! -d "$_dir" ] || [ -z "$(ls -A "$_dir" 2>/dev/null)" ]; then
    echo "❌ locale 生成失败: $_dir，尝试 localedef 兜底..."
    mkdir -p "$_dir"
    if ! localedef -i "$(echo "$_loc" | cut -d. -f1)" -f UTF-8 "$_loc" 2>&1; then
      echo "❌ localedef 也失败"
      ls -la /usr/share/i18n/locales/ 2>&1 | head -10
      exit 1
    fi
  fi
done

cat > /etc/default/locale << 'LOCALE'
LANG=en_US.UTF-8
LC_ALL=en_US.UTF-8
LOCALE
cat > /etc/environment << 'ENV'
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
LANG=en_US.UTF-8
LC_ALL=en_US.UTF-8
ENV
cat > /etc/profile.d/zz-locale.sh << 'LOCSH'
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
LOCSH
chmod +x /etc/profile.d/zz-locale.sh
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 >/dev/null 2>&1 || true

systemd-machine-id-setup 2>/dev/null || true

# ========== SSH 主机密钥 ==========
rm -f /etc/ssh/ssh_host_*
if command -v ssh-keygen >/dev/null 2>&1; then
  mkdir -p /etc/ssh
  for _t in rsa ecdsa ed25519; do
    ssh-keygen -t "$_t" -N '' -f "/etc/ssh/ssh_host_${_t}_key" \
      -C "root@${HOSTNAME}" -q >/dev/null 2>&1 || true
  done
fi

# ========== 服务优化 ==========
echo "==> 服务优化"
systemctl enable ssh networking 2>/dev/null || true
systemctl enable NetworkManager NetworkManager-dispatcher 2>/dev/null || true
systemctl mask motd-news.timer motd-news.service 2>/dev/null || true
systemctl mask apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl mask dpkg-db-backup.timer 2>/dev/null || true
systemctl mask networkd-dispatcher 2>/dev/null || true
systemctl set-default multi-user.target 2>/dev/null || true

# ============================================================
# [D3] systemd-resolved 仅 Ubuntu 启用
# ============================================================
if [ "${DISTRO}" = "ubuntu" ]; then
  systemctl enable systemd-resolved systemd-timesyncd 2>/dev/null || true
  mkdir -p /etc/systemd/resolved.conf.d
  cat > /etc/systemd/resolved.conf.d/99-dns.conf << 'DNS'
[Resolve]
DNS=223.5.5.5 223.6.6.6
FallbackDNS=119.29.29.29 1.1.1.1
DNSStubListener=yes
DNS
else
  # Debian/Armbian 用传统 resolv.conf
  systemctl enable systemd-timesyncd 2>/dev/null || true
  cat > /etc/resolv.conf << 'RESOLV'
nameserver 223.5.5.5
nameserver 223.6.6.6
RESOLV
fi

# ========== [R1] rk3188 console=ttyS2 ==========
systemctl enable serial-getty@ttyS2.service 2>/dev/null || true

cat > /etc/systemd/system/rfkill-unblock-wifi.service << 'SVC'
[Unit]
Description=Unblock WiFi via rfkill
Before=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/rfkill unblock wifi
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVC
systemctl enable rfkill-unblock-wifi.service 2>/dev/null || true

cat > /etc/systemd/timesyncd.conf << 'NTP'
[Time]
NTP=ntp.aliyun.com ntp.tencent.com cn.pool.ntp.org
FallbackNTP=0.cn.pool.ntp.org 1.cn.pool.ntp.org 2.cn.pool.ntp.org 3.cn.pool.ntp.org
NTP

# ========== logind + system 老内核兼容 ==========
SYSTEMD_VER=$(systemctl --version 2>/dev/null | head -1 | awk '{print $2}' | cut -d. -f1)
if [ "${SYSTEMD_VER:-0}" -ge 247 ] 2>/dev/null; then
    mkdir -p /etc/systemd/logind.conf.d
    cat > /etc/systemd/logind.conf.d/99-old-kernel.conf << 'LOGIND'
[Login]
ProtectProc=default
ProcSubset=all
LOGIND

    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/99-old-kernel.conf << 'SYSCONF'
[Manager]
DefaultProtectProc=default
SYSCONF
fi

cat > /root/.bashrc << 'BASHRC'
[ -f /etc/bash.bashrc ] && . /etc/bash.bashrc
[ -f /etc/bash_completion ] && . /etc/bash_completion
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '
BASHRC

# ========== 深度清理 ==========
echo "==> 深度清理"
apt-get autoremove -y --purge
apt-get clean

rm -rf /var/tmp/* /tmp/* /root/.cache 2>/dev/null || true
rm -rf /usr/share/doc /usr/share/man /usr/share/info \
       /usr/share/lintian /usr/share/linda /usr/share/groff 2>/dev/null || true
rm -rf /usr/lib/systemd/catalog \
       /usr/lib/systemd/systemd-analyze \
       /usr/lib/systemd/systemd-boot* 2>/dev/null || true
find /usr/lib -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
find /usr/lib -name '*.pyc' -delete 2>/dev/null || true

if [ -d /usr/share/bash-completion/completions ]; then
  cd /usr/share/bash-completion/completions
  _KEEP="apt apt-get apt-cache dpkg ssh scp systemctl journalctl hostname ip curl wget less vim htop nmcli"
  for _f in *; do
    _keep=0
    for _k in $_KEEP; do
      [ "$_f" = "$_k" ] && _keep=1 && break
    done
    [ "$_keep" -eq 0 ] && rm -f "$_f"
  done
  cd /
fi

: > /var/log/bootstrap.log 2>/dev/null || true
: > /var/log/apt/history.log 2>/dev/null || true
: > /var/log/apt/term.log 2>/dev/null || true
: > /var/log/dpkg.log 2>/dev/null || true
: > /var/log/alternatives.log 2>/dev/null || true
rm -f /var/log/*.gz /var/log/*.old /var/log/*.1 2>/dev/null || true

rm -f /usr/bin/qemu-arm-static
rm -f /etc/apt/apt.conf.d/99minimize /etc/apt/apt.conf.d/99locale-keep

# ========== A 级精简 ==========
echo "==> 精简 A 级（零影响）"
rm -rf /usr/share/consolefonts 2>/dev/null || true
rm -rf /usr/share/keymaps 2>/dev/null || true
rm -f /etc/udev/hwdb.bin 2>/dev/null || true
echo "  ✅ 已移除 consolefonts / keymaps / hwdb.bin（~17MB）"

# ========== [R4] C 级精简 ==========
if [ "${MINIMAL_MODE:-no}" = "yes" ]; then
    echo "==> 精简 C 级"
    apt-get purge -y htop bash-completion 2>/dev/null || true
    rm -rf /usr/share/bash-completion 2>/dev/null || true
    apt-get purge -y rsyslog 2>/dev/null || true
    rm -rf /var/log/syslog /var/log/messages 2>/dev/null || true
    mkdir -p /var/log/journal
    sed -i 's/^#Storage=.*/Storage=persistent/' /etc/systemd/journald.conf 2>/dev/null || true
    grep -q '^Storage=' /etc/systemd/journald.conf 2>/dev/null \
      || echo 'Storage=persistent' >> /etc/systemd/journald.conf
    apt-get purge -y net-tools ethtool 2>/dev/null || true
    echo "  ✅ C 级精简完成"
fi

# ========== [R3] depmod ==========
if [ -d /lib/modules ] && [ -n "$(ls -A /lib/modules 2>/dev/null)" ]; then
  echo "==> depmod -a"
  depmod -a 2>/dev/null || echo "⚠️ depmod 失败"
else
  echo "⚠️ /lib/modules 为空，跳过 depmod"
fi

# 重新 enable
systemctl enable firstboot-password.service 2>/dev/null || true
systemctl enable firstboot-apt-update.service 2>/dev/null || true
systemctl enable ssh networking NetworkManager systemd-timesyncd 2>/dev/null || true
systemctl enable rfkill-unblock-wifi.service 2>/dev/null || true
systemctl enable serial-getty@ttyS2.service 2>/dev/null || true
[ "${DISTRO}" = "ubuntu" ] && systemctl enable systemd-resolved 2>/dev/null || true

# ========== 防御性清理 ==========
find /root -mindepth 1 -maxdepth 1 \
    ! -name '.bashrc' ! -name '.profile' ! -name '.bash_logout' \
    ! -name '.cache' ! -name '.local' \
    -exec rm -rf {} + 2>/dev/null || true
find /tmp  -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
find /home -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true

# ============================================================
# 审计
# ============================================================
echo "========== rootfs 审计 =========="
echo "--- DISTRO / CODENAME ---"
echo "$DISTRO / $CODENAME"

echo "--- APT 源 ---"
cat /etc/apt/sources.list 2>/dev/null
[ -f /etc/apt/sources.list.d/ubuntu.sources ] && cat /etc/apt/sources.list.d/ubuntu.sources

echo "--- APT lists ---"
du -sh /var/lib/apt/lists/ 2>/dev/null || echo "(MISSING!)"

echo "--- /root /tmp /home ---"
ls -la /root/; ls -la /tmp/ 2>/dev/null || echo "(empty)"; ls -la /home/
echo "--- locale 数据 ---"
ls /usr/lib/locale/ 2>/dev/null
echo "--- 命令检查 ---"
for c in file nmcli iw rfkill wpa_supplicant; do
  printf '  %-18s ' "$c"
  command -v "$c" 2>/dev/null || echo "(MISSING!)"
done
echo "--- 内核模块 ---"
ls /lib/modules/ 2>/dev/null || echo "(无模块)"
echo "--- serial-getty@ttyS2 ---"
systemctl is-enabled serial-getty@ttyS2.service 2>/dev/null || echo "(未启用)"

echo "--- iptables 后端 ---"
IPT_VER=$(iptables --version 2>/dev/null || echo "未安装")
echo "  $IPT_VER"
case "$IPT_VER" in
  *legacy*) echo "  ✅ legacy" ;;
  *nf_tables*) echo "  ❌ nf_tables（Docker 会失败）"; exit 1 ;;
  *) echo "  ⚠️ 无法识别" ;;
esac

echo "--- 网络管理 ---"
[ -f /etc/network/interfaces.d/eth0 ] && { echo "❌ eth0 ifupdown 残留"; exit 1; } || echo "✅ eth0 无 ifupdown"
[ -f /usr/lib/NetworkManager/conf.d/10-globally-managed-devices.conf ] && { echo "❌ NM 默认排除未删"; exit 1; } || echo "✅ NM 默认排除已删"
[ -f /etc/NetworkManager/system-connections/eth0.nmconnection ] \
  && echo "✅ eth0.nmconnection 存在" || { echo "❌ eth0.nmconnection 缺失"; exit 1; }

echo "--- firstboot-password ---"
[ -f /etc/firstboot-pwd.txt ] && echo "✅ 密码文件存在" || { echo "❌ 密码文件缺失"; exit 1; }
[ -x /usr/local/sbin/firstboot-password.sh ] && echo "✅ 脚本可执行" || { echo "❌ 脚本缺失"; exit 1; }
systemctl is-enabled firstboot-password.service 2>/dev/null || { echo "❌ 未 enable"; exit 1; }

echo "--- shadow root 行 ---"
grep '^root:' /etc/shadow | cut -c1-40
grep -q '^root:\$' /etc/shadow || { echo "❌ shadow 异常"; exit 1; }

echo "--- 精简 A 级验证 ---"
for p in /usr/share/consolefonts /usr/share/keymaps /etc/udev/hwdb.bin; do
  [ -e "$p" ] && echo "  ⚠️  $p 仍存在" || echo "  ✅ $p 已清除"
done

echo "--- rootfs 总计 ---"
du -sh --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run --exclude=/tmp / 2>/dev/null | awk '{print "  " $1 "  总计"}'

echo "========== 审计结束 =========="
echo "✅ Chroot 内配置完成"
