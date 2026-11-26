#!/bin/bash
# lib/rootfs_inner.sh — chroot 内配置（三发行版兼容）
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C LANG=C
export SYSTEMD_OFFLINE=1

DISTRO="${DISTRO:-ubuntu}"

echo "==> [${MODE} / ${DISTRO}] 挂载 tmpfs"
mount -t tmpfs tmpfs /tmp 2>/dev/null || true
mkdir -p /var/cache/apt/archives
mount -t tmpfs tmpfs /var/cache/apt/archives 2>/dev/null || true

cat > /etc/apt/apt.conf.d/99minimize << 'APTCONF'
APT::Install-Recommends "false";
APT::Install-Suggests "false";
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

case "${DISTRO}" in
  debian)
    cat > /etc/apt/sources.list << SOURCES
deb http://deb.debian.org/debian ${CODENAME} main
deb http://deb.debian.org/debian ${CODENAME}-updates main
deb http://deb.debian.org/debian-security ${CODENAME}-security main
SOURCES
    ;;
  armbian)
    cat > /etc/apt/sources.list << SOURCES
deb http://deb.debian.org/debian ${CODENAME} main contrib non-free non-free-firmware
deb http://deb.debian.org/debian ${CODENAME}-updates main contrib non-free non-free-firmware
deb http://deb.debian.org/debian-security ${CODENAME}-security main contrib non-free non-free-firmware
SOURCES
    rm -f /etc/apt/sources.list.d/armbian*.list 2>/dev/null || true
    ;;
  ubuntu|*)
    if [ "$CODENAME" = "noble" ]; then
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

if [ "${DISTRO}" = "debian" ]; then
  if ! dpkg -l debian-archive-keyring >/dev/null 2>&1; then
    apt-get install -y -qq debian-archive-keyring 2>/dev/null || true
  fi
fi

apt-get update -qq
apt-get -f install -y -qq 2>&1 || true

# ---- 修改点 A：补 kmod（ttl-11 实证）----
# 原值（保留备查）：
# PKGS="systemd systemd-sysv dbus udev \
#   ifupdown isc-dhcp-client iproute2 iputils-ping iputils-arping procps \
#   openssh-server ssh sudo e2fsprogs ca-certificates \
#   vim-tiny less wget curl cron locales tzdata \
#   file network-manager wpasupplicant iw rfkill iptables systemd-timesyncd"
# 为什么补：缺 kmod 时 /bin/kmod、/sbin/modprobe 都不存在，导致
#   kmod-static-nodes.service 报 "Failed at step EXEC spawning /bin/kmod"，
#   modprobe@configfs/drm/fuse/efi_pstore 全部 "Executable /sbin/modprobe missing, skipping"，
#   文末的 depmod -a 也无法执行（内核模块依赖表建不出来）。
PKGS="systemd systemd-sysv dbus udev kmod python3 \
  ifupdown isc-dhcp-client iproute2 iputils-ping iputils-arping procps \
  openssh-server ssh sudo e2fsprogs ca-certificates \
  vim-tiny less wget curl cron locales tzdata \
  file network-manager wpasupplicant iw rfkill iptables systemd-timesyncd"

[ "${DISTRO}" = "ubuntu" ] && PKGS="$PKGS rsyslog bash-completion"

apt-get install -y -qq --no-install-recommends $PKGS

if [ -x /usr/sbin/iptables-legacy ]; then
    update-alternatives --set iptables /usr/sbin/iptables-legacy 2>/dev/null || true
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy 2>/dev/null || true
fi

apt-get install -y -qq --no-install-recommends \
  util-linux usbutils dosfstools ntfs-3g exfat-fuse eject

cat > /etc/udev/rules.d/99-usb-storage-mount.rules << 'UDEV'
ACTION=="add", SUBSYSTEM=="block", KERNEL=="sd[a-z][0-9]", ENV{SYSTEMD_WANTS}+="usb-mount@%k.service"
ACTION=="remove", SUBSYSTEM=="block", KERNEL=="sd[a-z][0-9]", ENV{SYSTEMD_WANTS}+="usb-umount@%k.service"
UDEV

cat > /etc/systemd/system/usb-mount@.service << 'SVC'
[Unit]
Description=Auto-mount USB /dev/%i
After=dev-%i.device
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/usb-mount.sh add %i
ExecStop=/usr/local/sbin/usb-mount.sh remove %i
SVC

cat > /etc/systemd/system/usb-umount@.service << 'SVC'
[Unit]
Description=Auto-unmount USB /dev/%i
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
      exfat) mount.exfat-fuse -o rw,uid=0,gid=0,umask=000 "$DEV_PATH" "$MOUNT_POINT" 2>/dev/null || mount -t exfat -o rw,uid=0,gid=0,umask=000 "$DEV_PATH" "$MOUNT_POINT" 2>/dev/null || true ;;
      ntfs) mount -t ntfs-3g -o rw,uid=0,gid=0,umask=000 "$DEV_PATH" "$MOUNT_POINT" || true ;;
      *) mount -o rw "$DEV_PATH" "$MOUNT_POINT" 2>/dev/null || true ;;
    esac ;;
  remove)
    umount "$MOUNT_POINT" 2>/dev/null || umount -l "$MOUNT_POINT" 2>/dev/null || true
    rmdir "$MOUNT_POINT" 2>/dev/null || true ;;
esac
SCRIPT
chmod +x /usr/local/sbin/usb-mount.sh

echo "$HOSTNAME" > /etc/hostname
hostname "$HOSTNAME" 2>/dev/null || true
cat > /etc/hosts << HOSTS
127.0.0.1 localhost
127.0.1.1 $HOSTNAME
HOSTS
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
echo "$TIMEZONE" > /etc/timezone
dpkg-reconfigure -f noninteractive tzdata >/dev/null 2>&1 || true

# ---- 修改点 C：刷机后自动把根文件系统扩满 eMMC（第二十一轮）----
# 现象：rootfs.img 是按 rootfs_size=1G 造的，刷进去后 df -h 只有 974M，
#   eMMC 剩下的 2.5G 用不上——因为分区是 blkdevparts 的 "-@24M(rootfs)"
#   （一直延伸到盘尾），但文件系统只有 1G。
# 原值（保留备查）：
# LABEL=rootfs     /              ext4       defaults,noatime,errors=remount-ro 0     1
# 改动：给根分区加 x-systemd.growfs，systemd 挂载时会自动把 ext4 扩到分区大小
#   （systemd-growfs 用 EXT4_IOC_RESIZE_FS 在线扩，不需要 resize2fs 二进制）。
cat > /etc/fstab << 'FSTAB'
LABEL=rootfs     /              ext4       defaults,noatime,errors=remount-ro,x-systemd.growfs 0     1
proc             /proc          proc       defaults                          0     0
sysfs            /sys           sysfs      defaults                          0     0
devtmpfs         /dev           devtmpfs   mode=0755,nosuid                  0     0
tmpfs            /tmp           tmpfs      defaults,nosuid,size=64M          0     0
FSTAB

# ---- 修改点 D：兜底一次性扩容服务（防止 x-systemd.growfs 在该 systemd 版本上没触发）----
R2F="$(command -v resize2fs 2>/dev/null || true)"
[ -n "$R2F" ] || R2F=/sbin/resize2fs
cat > /etc/systemd/system/rootfs-grow.service << UNIT
[Unit]
Description=First boot: grow root ext4 filesystem to fill the whole eMMC partition
Documentation=man:resize2fs(8)
ConditionPathExists=!/var/lib/.rootfs-grown
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${R2F} /dev/mmcblk1p1
ExecStartPost=/bin/sh -c 'mkdir -p /var/lib && touch /var/lib/.rootfs-grown'

[Install]
WantedBy=multi-user.target
UNIT
systemctl enable rootfs-grow.service 2>/dev/null || true

echo "root:$ROOT_PASSWORD" | chpasswd
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config 2>/dev/null || true

printf '%s\n' "$ROOT_PASSWORD" > /etc/firstboot-pwd.txt
chmod 600 /etc/firstboot-pwd.txt
cat > /usr/local/sbin/firstboot-password.sh << 'SH'
#!/bin/bash
PWDFILE=/etc/firstboot-pwd.txt
[ -f "$PWDFILE" ] || exit 0
if { printf 'root:'; cat "$PWDFILE"; } | chpasswd; then
    rm -f "$PWDFILE"; touch /var/lib/firstboot-password.done
else
    exit 1
fi
SH
chmod +x /usr/local/sbin/firstboot-password.sh

cat > /etc/systemd/system/firstboot-password.service << 'SVC'
[Unit]
Description=First boot: reset root password
ConditionPathExists=/etc/firstboot-pwd.txt
After=local-fs.target
Before=ssh.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/firstboot-password.sh
[Install]
WantedBy=multi-user.target
SVC
systemctl enable firstboot-password.service 2>/dev/null || true

rm -f /etc/network/interfaces.d/eth0
cat > /etc/network/interfaces << 'NETIF'
auto lo
iface lo inet loopback
NETIF

rm -f /usr/lib/NetworkManager/conf.d/10-globally-managed-devices.conf
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/10-globally-managed-devices.conf << 'NMOVERRIDE'
[keyfile]
unmanaged-devices=
NMOVERRIDE

mkdir -p /etc/NetworkManager/system-connections
ETH_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "8a8b4b7a-1e6d-4a6c-9b1a-1a2b3c4d5e6f")
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

cat > /etc/locale.gen << 'LGEN'
en_US.UTF-8 UTF-8
zh_CN.UTF-8 UTF-8
LGEN
locale-gen 2>/dev/null || true
cat > /etc/default/locale << 'LOCALE'
LANG=en_US.UTF-8
LC_ALL=en_US.UTF-8
LOCALE
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 >/dev/null 2>&1 || true

systemd-machine-id-setup 2>/dev/null || true
rm -f /etc/ssh/ssh_host_*
for _t in rsa ecdsa ed25519; do
  ssh-keygen -t "$_t" -N '' -f "/etc/ssh/ssh_host_${_t}_key" -C "root@${HOSTNAME}" -q >/dev/null 2>&1 || true
done

systemctl enable ssh networking NetworkManager systemd-timesyncd 2>/dev/null || true
systemctl mask motd-news.timer apt-daily.timer apt-daily-upgrade.timer dpkg-db-backup.timer 2>/dev/null || true
systemctl set-default multi-user.target 2>/dev/null || true
systemctl enable serial-getty@ttyS2.service 2>/dev/null || true

if [ "${DISTRO}" = "ubuntu" ]; then
  systemctl enable systemd-resolved 2>/dev/null || true
  mkdir -p /etc/systemd/resolved.conf.d
  cat > /etc/systemd/resolved.conf.d/99-dns.conf << 'DNS'
[Resolve]
DNS=223.5.5.5 223.6.6.6
FallbackDNS=119.29.29.29 1.1.1.1
DNS
else
  cat > /etc/resolv.conf << 'RESOLV'
nameserver 223.5.5.5
nameserver 223.6.6.6
RESOLV
fi

cat > /etc/systemd/timesyncd.conf << 'NTP'
[Time]
NTP=ntp.aliyun.com ntp.tencent.com cn.pool.ntp.org
NTP

apt-get autoremove -y --purge
apt-get clean
rm -rf /var/tmp/* /tmp/* /root/.cache 2>/dev/null || true
rm -rf /usr/share/doc /usr/share/man /usr/share/info /usr/share/lintian /usr/share/groff 2>/dev/null || true
find /usr/lib -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
find /usr/lib -name '*.pyc' -delete 2>/dev/null || true
rm -rf /usr/share/consolefonts /usr/share/keymaps 2>/dev/null || true
rm -f /etc/udev/hwdb.bin 2>/dev/null || true

if [ "${MINIMAL_MODE:-no}" = "yes" ]; then
    apt-get purge -y htop bash-completion rsyslog net-tools ethtool 2>/dev/null || true
    rm -rf /usr/share/bash-completion 2>/dev/null || true
fi

if [ -d /lib/modules ] && [ -n "$(ls -A /lib/modules 2>/dev/null)" ]; then
  depmod -a 2>/dev/null || true
fi

find /root -mindepth 1 -maxdepth 1 \
    ! -name '.bashrc' ! -name '.profile' ! -name '.bash_logout' \
    ! -name '.cache' ! -name '.local' -exec rm -rf {} + 2>/dev/null || true
find /tmp  -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
find /home -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true

# ---- 修改点 B：串口优先，默认屏蔽网络栈（ttl-11 实证）----
# 现象（ttl-9 / ttl-11 的 debug 日志）：
#   systemd-resolved.service 起来了，但永远不 acquire "org.freedesktop.resolve1"，
#   于是 network.target 永远完不成 →
#   systemd-user-sessions.service 被压住 →
#   serial-getty@ttyS2.service 被压住 →
#   屏幕永远不出 login:（这就是十几轮"卡住"的真正原因）。
# 做法：默认整条网络栈 mask 掉，刷机即得 login:。
# 要用网络时把 SERIAL_ONLY 设成 no 再构建，或在跑起来的系统里执行撤销：
#   rm -f /etc/systemd/system/systemd-resolved.service \
#         /etc/systemd/system/NetworkManager.service \
#         /etc/systemd/system/networking.service \
#         /etc/systemd/system/wpa_supplicant.service
#   systemctl daemon-reload
SERIAL_ONLY="${SERIAL_ONLY:-yes}"
if [ "${SERIAL_ONLY}" = "yes" ]; then
  # 先走 systemctl（脚本开头已 export SYSTEMD_OFFLINE=1，chroot 内可离线生效）
  systemctl mask systemd-resolved.service NetworkManager.service networking.service wpa_supplicant.service 2>/dev/null || true
  # 兜底：systemctl 在 chroot 里万一降级失败，就直接手工建符号链接，保证一定落盘
  for u in systemd-resolved NetworkManager networking wpa_supplicant; do
    if [ ! -L "/etc/systemd/system/${u}.service" ]; then
      mkdir -p /etc/systemd/system
      ln -snf /dev/null "/etc/systemd/system/${u}.service" 2>/dev/null || true
    fi
    if [ -L "/etc/systemd/system/${u}.service" ]; then
      echo "   masked: ${u}.service -> $(readlink /etc/systemd/system/${u}.service)"
    else
      echo "❌ 无法 mask ${u}.service（构建产物可能仍会卡在 network.target）"
    fi
  done
  echo "✅ SERIAL_ONLY=yes：已 mask 网络栈（systemd-resolved / NetworkManager / networking / wpa_supplicant）"
else
  echo "ℹ️  SERIAL_ONLY=no：保留网络栈（若 systemd-resolved 不 ready，串口 getty 会被压住）"
fi

echo "========== 审计 =========="
echo "DISTRO=$DISTRO CODENAME=$CODENAME"
cat /etc/apt/sources.list 2>/dev/null || cat /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null
iptables --version 2>/dev/null | grep -q legacy || { echo "❌ iptables 非 legacy"; exit 1; }
[ -f /etc/firstboot-pwd.txt ] || { echo "❌ 密码文件缺失"; exit 1; }
systemctl is-enabled firstboot-password.service >/dev/null 2>&1 || { echo "❌ 服务未启用"; exit 1; }
echo "✅ 审计通过"

# ---------- mdio-scan：MDIO 引脚探测工具（第二十六轮） ----------
# 用途：在实机上直接读写 GPIO/GRF 寄存器做 bit-bang，绕过 pinctrl 与 mdio-gpio 驱动，
#       用来逐脚找出 RTL8201FN 的 MDC/MDIO 到底接在哪两只 GPIO 上。
# 用法见 `mdio-scan` 无参数时的帮助；只碰 pinmux-pins 里标 GPIO UNCLAIMED 的脚，不会动 eMMC/UART。
mkdir -p /usr/local/bin
base64 -d > /usr/local/bin/mdio-scan <<'MDIOSCAN_B64'
IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwojIC0qLSBjb2Rpbmc6IHV0Zi04IC0qLQoiIiIKUkszMTg4
IE1ESU8g5byV6ISa5o6i5rWL5bel5YW377yI55u05o6l6K+75YaZIEdQSU8gLyBHUkYg5a+E5a2Y
5Zmo77yM57uV6L+HIHBpbmN0cmwg5LiOIG1kaW8tZ3BpbyDpqbHliqjvvIkKCuS4uuS7gOS5iOim
geacieWug++8mgogIHR0bC0xN++8iOehrOS7tiBNRElP77yJ5ZKMIHR0bC0xOe+8iEdQSU8gYml0
LWJhbmfvvIxEMS9EMO+8ieWcqCBSVEw4MjAxRk4g5LiK6YO95pivIDB+NyDlnLDlnYDlhaggbWlz
c2luZ++8mwogIHR0bC0yMCDnmoQgNjIg5p2h5oC757q/5omr6aKR54mI5Y+I5Zug5Li6IHBpbmN0
cmwg5Y2g55So77yIZ3Bpb2Qg6L+U5ZueIC1FQlVTWe+8ieWPquaciSA3IOadoeecn+eahOi3keWI
sOS6huOAggogIOimgeS4jeWPlyBwaW5jdHJsIOmZkOWItuWcsOmAkOiEmuivle+8jOWPquiDveeb
tOaOpeWGmeWvhOWtmOWZqOOAggoK5a6J5YWo562W55Wl77yaCiAgc3dlZXAgLyBjdGwg5Y+q56Kw
IC9zeXMva2VybmVsL2RlYnVnL3BpbmN0cmwvLi4uL3Bpbm11eC1waW5zIOmHjOaghyAiR1BJTyBV
TkNMQUlNRUQiIOeahOW8leiEmu+8jAogIOS5n+WwseaYryLlvZPliY3lpI3nlKjkuLogR1BJTyDk
uJTmsqHooqvku7vkvZXpqbHliqjnlLPor7ci55qE6ISa44CCZU1NQ+OAgVVBUlQy44CBUk1JSSDo
v5nkupvmraPlnKjnlKjnmoTohJrlhajpg6jooqvmjpLpmaTvvIwKICDmiYDku6XkuI3kvJrlm6Dk
uLrmlLnlpI3nlKjogIzmiormoLnliIbljLrmkJ7mjILjgIIKCuWvhOWtmOWZqOS+neaNru+8mgog
IFJLMzE4OCBUUk0gVjEuMyDCpzM4LjQg4oCU4oCUIEdQSU9fU1dQT1JUQV9EUiAweDAwIC8gR1BJ
T19TV1BPUlRBX0REUiAweDA0IC8gR1BJT19FWFRfUE9SVEEgMHg1MO+8jAogIOavj+S4qiBwb3J0
IOS4gOS4qiAzMiDkvY3lr4TlrZjlmajvvIjkuI3mmK8gX0wvX0gg5ouG5YiG77yJ44CCCiAgR1JG
77yI5Z+65Z2AIDB4MjAwMDgwMDDvvIlpb211eO+8mkdSRl9HUElPeEFfSU9NVVgg6LW35LqOIDB4
NjDvvIzmr48gYmFuayAweDEw44CB5q+PIDgg6ISa5LiA57uEIDQg5a2X6IqC77yMCiAg5q+P6ISa
IDIgYml077yM5YC8IDAgPSBHUElP44CCCgrnlKjms5XvvIhyb290IOS4i++8ie+8mgogIG1kaW8t
c2NhbiBwaW4gMTIwICAgICAgICAgICAgICAgICAjIOeci+afkOS4quiEmu+8muWkjeeUqOWAvC/m
lrnlkJEv55S15bmzCiAgbWRpby1zY2FuIHNhZmUgICAgICAgICAgICAgICAgICAgICMg5YiX5Ye6
5Y+v5a6J5YWo5pON5L2c55qE5byV6ISa77yIVU5DTEFJTUVE77yJCiAgbWRpby1zY2FuIHNjYW4g
MTIxIDEyMCAgICAgICAgICAgICMg5ZyoIE1EQz0xMjEoTURJTzNfRDEpL01ESU89MTIwKEdQSU8z
X0QwKSDkuIrmiasgMH43CiAgbWRpby1zY2FuIHNjYW4gMTIxIDEyMCAwIDcgICAgICAgICMg5oyH
5a6a5Zyw5Z2A6IyD5Zu0CiAgbWRpby1zY2FuIHN3ZWVwICAgICAgICAgICAgICAgICAgICMg5omA
5pyJ55u46YK75a6J5YWo6ISa5a+577yM5q2j5Y+N5Lik56eN5p6B5oCn77yM5ZCE5omrIDB+Nwog
IG1kaW8tc2NhbiBjdGwgICAgICAgICAgICAgICAgICAgICAjIOmAkOS4quaKiuWuieWFqOiEmuaL
iemrmO+8jOWGjeeciyBEMS9EMCDkuIrmnInmsqHmnIkgUEhZIOW6lOetlAogIG1kaW8tc2NhbiBj
dGwgMTIxIDEyMCAgICAgICAgICAgICAjIOaMh+WumiBNREMvTURJTyDlho3pgJDkuKrmi4npq5jl
iKvohJoKIiIiCgppbXBvcnQgbW1hcAppbXBvcnQgb3MKaW1wb3J0IHN5cwppbXBvcnQgdGltZQpp
bXBvcnQgZ2xvYgoKR1BJT19CQVNFID0gWzB4MjAwMEEwMDAsIDB4MjAwM0MwMDAsIDB4MjAwM0Uw
MDAsIDB4MjAwODAwMDBdCkdSRl9CQVNFID0gMHgyMDAwODAwMApSRUdfRFIgPSAweDAwClJFR19E
RFIgPSAweDA0ClJFR19FWFQgPSAweDUwClBBR0UgPSA0MDk2CgpEID0gM2UtNiAgICAgICAgICAj
IE1EQyDljYrlkajmnJ/vvIznuqYgMS42fjIgdXMg5a6e6ZmF77yMTURDIOi/nOS9juS6jiBSVEw4
MjAxRk4g55qEIDIuNU1IeiDkuIrpmZAKQkFEX0lEUyA9ICgweDAwMDAwMDAwLCAweDAwMDBGRkZG
LCAweEZGRkZGRkZGLCAweEZGRkYwMDAwLCAweDAwMDBGRkZFKQoKCmRlZiBwaW5fbmFtZShudW0p
OgogICAgYmFuayA9IG51bSAvLyAzMgogICAgZ3JwID0gIkFCQ0QiWyhudW0gJSAzMikgLy8gOF0K
ICAgIGlkeCA9IG51bSAlIDgKICAgIHJldHVybiAiR1BJTyVkXyVzJWQiICUgKGJhbmssIGdycCwg
aWR4KQoKCmNsYXNzIE1lbShvYmplY3QpOgogICAgZGVmIF9faW5pdF9fKHNlbGYpOgogICAgICAg
IHNlbGYuZmQgPSBvcy5vcGVuKCIvZGV2L21lbSIsIG9zLk9fUkRXUiB8IG9zLk9fU1lOQykKICAg
ICAgICBzZWxmLm1hcHMgPSB7fQoKICAgIGRlZiBfcGFnZShzZWxmLCBhZGRyKToKICAgICAgICBi
YXNlID0gYWRkciAmIH4oUEFHRSAtIDEpCiAgICAgICAgbSA9IHNlbGYubWFwcy5nZXQoYmFzZSkK
ICAgICAgICBpZiBtIGlzIE5vbmU6CiAgICAgICAgICAgIG0gPSBtbWFwLm1tYXAoc2VsZi5mZCwg
UEFHRSwgbW1hcC5NQVBfU0hBUkVELAogICAgICAgICAgICAgICAgICAgICAgICAgIG1tYXAuUFJP
VF9SRUFEIHwgbW1hcC5QUk9UX1dSSVRFLCBvZmZzZXQ9YmFzZSkKICAgICAgICAgICAgc2VsZi5t
YXBzW2Jhc2VdID0gbQogICAgICAgIHJldHVybiBtLCBhZGRyIC0gYmFzZQoKICAgIGRlZiByZChz
ZWxmLCBhZGRyKToKICAgICAgICBtLCBvID0gc2VsZi5fcGFnZShhZGRyKQogICAgICAgIHJldHVy
biBpbnQuZnJvbV9ieXRlcyhtW286byArIDRdLCAibGl0dGxlIikKCiAgICBkZWYgd3Ioc2VsZiwg
YWRkciwgdmFsKToKICAgICAgICBtLCBvID0gc2VsZi5fcGFnZShhZGRyKQogICAgICAgIG1bbzpv
ICsgNF0gPSAodmFsICYgMHhGRkZGRkZGRikudG9fYnl0ZXMoNCwgImxpdHRsZSIpCgoKY2xhc3Mg
UGluKG9iamVjdCk6CiAgICBkZWYgX19pbml0X18oc2VsZiwgbWVtLCBudW0pOgogICAgICAgIHNl
bGYubWVtID0gbWVtCiAgICAgICAgc2VsZi5udW0gPSBudW0KICAgICAgICBzZWxmLmJhbmsgPSBu
dW0gLy8gMzIKICAgICAgICBzZWxmLmlkeCA9IG51bSAlIDMyCiAgICAgICAgc2VsZi5iYXNlID0g
R1BJT19CQVNFW3NlbGYuYmFua10KCiAgICBkZWYgc2V0X2RpcihzZWxmLCBvdXQpOgogICAgICAg
IGEgPSBzZWxmLmJhc2UgKyBSRUdfRERSCiAgICAgICAgdiA9IHNlbGYubWVtLnJkKGEpCiAgICAg
ICAgaWYgb3V0OgogICAgICAgICAgICB2IHw9ICgxIDw8IHNlbGYuaWR4KQogICAgICAgIGVsc2U6
CiAgICAgICAgICAgIHYgJj0gfigxIDw8IHNlbGYuaWR4KQogICAgICAgIHNlbGYubWVtLndyKGEs
IHYpCgogICAgZGVmIHNldChzZWxmLCB2YWwpOgogICAgICAgIGEgPSBzZWxmLmJhc2UgKyBSRUdf
RFIKICAgICAgICB2ID0gc2VsZi5tZW0ucmQoYSkKICAgICAgICBpZiB2YWw6CiAgICAgICAgICAg
IHYgfD0gKDEgPDwgc2VsZi5pZHgpCiAgICAgICAgZWxzZToKICAgICAgICAgICAgdiAmPSB+KDEg
PDwgc2VsZi5pZHgpCiAgICAgICAgc2VsZi5tZW0ud3IoYSwgdikKCiAgICBkZWYgZ2V0KHNlbGYp
OgogICAgICAgIHJldHVybiAoc2VsZi5tZW0ucmQoc2VsZi5iYXNlICsgUkVHX0VYVCkgPj4gc2Vs
Zi5pZHgpICYgMQoKICAgIGRlZiBfaW9tdXhfYWRkcl9iaXQoc2VsZik6CiAgICAgICAgb2ZmID0g
MHg2MCArIChzZWxmLmJhbmsgKiA0ICsgc2VsZi5pZHggLy8gOCkgKiA0CiAgICAgICAgcmV0dXJu
IEdSRl9CQVNFICsgb2ZmLCAoc2VsZi5pZHggJSA4KSAqIDIKCiAgICBkZWYgbXV4X2dldChzZWxm
KToKICAgICAgICBhLCBiID0gc2VsZi5faW9tdXhfYWRkcl9iaXQoKQogICAgICAgIHJldHVybiAo
c2VsZi5tZW0ucmQoYSkgPj4gYikgJiAzCgogICAgZGVmIG11eF9zZXQoc2VsZiwgdmFsKToKICAg
ICAgICBhLCBiID0gc2VsZi5faW9tdXhfYWRkcl9iaXQoKQogICAgICAgIHYgPSBzZWxmLm1lbS5y
ZChhKQogICAgICAgIHNlbGYubWVtLndyKGEsICh2ICYgfigzIDw8IGIpKSB8ICgodmFsICYgMykg
PDwgYikpCgogICAgZGVmIG11eF9ncGlvKHNlbGYpOgogICAgICAgIHNlbGYubXV4X3NldCgwKQoK
CmRlZiBzYWZlX3BpbnMoKToKICAgICIiIuS7jiBkZWJ1Z2ZzIOmHjOWPliLlpI3nlKjkuLogR1BJ
TyDkuJTmnKrooqvnlLPor7ci55qE6ISa44CC5Y+W5LiN5Yiw5bCx6L+U5Zue5YWo6YOoIDEyOOOA
giIiIgogICAgcGlucyA9IHNldCgpCiAgICBmaWxlcyA9IGdsb2IuZ2xvYigiL3N5cy9rZXJuZWwv
ZGVidWcvcGluY3RybC8qL3Bpbm11eC1waW5zIikKICAgIGZvciBmbiBpbiBmaWxlczoKICAgICAg
ICB0cnk6CiAgICAgICAgICAgIGZvciBsaW5lIGluIG9wZW4oZm4pOgogICAgICAgICAgICAgICAg
cGFydHMgPSBsaW5lLnNwbGl0KCkKICAgICAgICAgICAgICAgIGlmIGxlbihwYXJ0cykgPCAyIG9y
IHBhcnRzWzBdICE9ICJwaW4iOgogICAgICAgICAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAg
ICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICAgICAgbnVtID0gaW50KHBhcnRzWzFdKQogICAg
ICAgICAgICAgICAgZXhjZXB0IFZhbHVlRXJyb3I6CiAgICAgICAgICAgICAgICAgICAgY29udGlu
dWUKICAgICAgICAgICAgICAgIGlmICJVTkNMQUlNRUQiIGluIGxpbmUgYW5kICIoR1BJTyBVTkNM
QUlNRUQpIiBpbiBsaW5lOgogICAgICAgICAgICAgICAgICAgIHBpbnMuYWRkKG51bSkKICAgICAg
ICBleGNlcHQgSU9FcnJvcjoKICAgICAgICAgICAgY29udGludWUKICAgIGlmIG5vdCBwaW5zOgog
ICAgICAgIHJldHVybiBzZXQocmFuZ2UoMTI4KSkKICAgIHJldHVybiBwaW5zCgoKZGVmIGJiX3Jl
YWQobWRjLCBtZGlvLCBwaHksIHJlZyk6CiAgICAiIiLmoIflh4YgQ2xhdXNlIDIyIOivu++8mnBy
ZWFtYmxlICsgU1QoMDEpICsgT1AoMTApICsgUEhZQUQoNSkgKyBSRUdBRCg1KSArIFRBICsgMTYg
5pWw5o2u5L2NIiIiCiAgICBtZGlvLm11eF9ncGlvKCkKICAgIG1kYy5tdXhfZ3BpbygpCiAgICBt
ZGMuc2V0X2RpcihUcnVlKQogICAgbWRjLnNldCgwKQogICAgbWRpby5zZXRfZGlyKFRydWUpCgog
ICAgZGVmIGNsa193cml0ZShiaXQpOgogICAgICAgIG1kaW8uc2V0KGJpdCkKICAgICAgICB0aW1l
LnNsZWVwKEQpCiAgICAgICAgbWRjLnNldCgxKQogICAgICAgIHRpbWUuc2xlZXAoRCkKICAgICAg
ICBtZGMuc2V0KDApCiAgICAgICAgdGltZS5zbGVlcChEKQoKICAgIGZvciBfIGluIHJhbmdlKDMy
KToKICAgICAgICBjbGtfd3JpdGUoMSkKCiAgICBiaXRzID0gWzAsIDEsIDEsIDBdCiAgICBmb3Ig
aSBpbiByYW5nZSg0LCAtMSwgLTEpOgogICAgICAgIGJpdHMuYXBwZW5kKChwaHkgPj4gaSkgJiAx
KQogICAgZm9yIGkgaW4gcmFuZ2UoNCwgLTEsIC0xKToKICAgICAgICBiaXRzLmFwcGVuZCgocmVn
ID4+IGkpICYgMSkKICAgIGZvciBiIGluIGJpdHM6CiAgICAgICAgY2xrX3dyaXRlKGIpCgogICAg
IyB0dXJuYXJvdW5k77ya5Li75py66YeK5pS+IE1ESU8KICAgIG1kaW8uc2V0X2RpcihGYWxzZSkK
ICAgIHRpbWUuc2xlZXAoRCkKICAgIG1kYy5zZXQoMSkKICAgIHRpbWUuc2xlZXAoRCkKICAgIG1k
Yy5zZXQoMCkKICAgIHRpbWUuc2xlZXAoRCkKCiAgICB2YWwgPSAwCiAgICBmb3IgXyBpbiByYW5n
ZSgxNik6CiAgICAgICAgdGltZS5zbGVlcChEKQogICAgICAgIG1kYy5zZXQoMSkKICAgICAgICB0
aW1lLnNsZWVwKEQpCiAgICAgICAgdmFsID0gKHZhbCA8PCAxKSB8IG1kaW8uZ2V0KCkKICAgICAg
ICBtZGMuc2V0KDApCiAgICAgICAgdGltZS5zbGVlcChEKQogICAgcmV0dXJuIHZhbAoKCmRlZiBw
aHlfaWQobWVtLCBtZGNfbnVtLCBtZGlvX251bSwgYWRkcik6CiAgICBtZGMgPSBQaW4obWVtLCBt
ZGNfbnVtKQogICAgbWRpbyA9IFBpbihtZW0sIG1kaW9fbnVtKQogICAgaGkgPSBiYl9yZWFkKG1k
YywgbWRpbywgYWRkciwgMikKICAgIGxvID0gYmJfcmVhZChtZGMsIG1kaW8sIGFkZHIsIDMpCiAg
ICByZXR1cm4gKGhpIDw8IDE2KSB8IGxvCgoKZGVmIGlzX3ZhbGlkKHBpZCk6CiAgICBpZiBwaWQg
aW4gQkFEX0lEUzoKICAgICAgICByZXR1cm4gRmFsc2UKICAgIGhpID0gKHBpZCA+PiAxNikgJiAw
eEZGRkYKICAgIGxvID0gcGlkICYgMHhGRkZGCiAgICBpZiBoaSBpbiAoMHgwMDAwLCAweEZGRkYp
IGFuZCBsbyBpbiAoMHgwMDAwLCAweEZGRkYpOgogICAgICAgIHJldHVybiBGYWxzZQogICAgcmV0
dXJuIFRydWUKCgpkZWYgY21kX3BpbihtZW0sIGFyZ3MpOgogICAgZm9yIGEgaW4gYXJnczoKICAg
ICAgICBwID0gUGluKG1lbSwgaW50KGEpKQogICAgICAgIHByaW50KCJwaW4gJS0zZCAlLTEwcyBt
dXg9JWQgZGlyPSVzIGxldmVsPSVkIiAlICgKICAgICAgICAgICAgcC5udW0sIHBpbl9uYW1lKHAu
bnVtKSwgcC5tdXhfZ2V0KCksCiAgICAgICAgICAgICJvdXQiIGlmIChtZW0ucmQocC5iYXNlICsg
UkVHX0REUikgPj4gcC5pZHgpICYgMSBlbHNlICJpbiIsCiAgICAgICAgICAgIHAuZ2V0KCkpKQoK
CmRlZiBjbWRfc2FmZShtZW0sIGFyZ3MpOgogICAgcGlucyA9IHNhZmVfcGlucygpCiAgICBncm91
cHMgPSB7fQogICAgZm9yIHAgaW4gc29ydGVkKHBpbnMpOgogICAgICAgIGdyb3Vwcy5zZXRkZWZh
dWx0KHAgLy8gOCwgW10pLmFwcGVuZChwKQogICAgcHJpbnQoIuWPr+WuieWFqOaTjeS9nOeahOW8
leiEmuWFsSAlZCDkuKrvvJoiICUgbGVuKHBpbnMpKQogICAgZm9yIGcgaW4gc29ydGVkKGdyb3Vw
cyk6CiAgICAgICAgcHJpbnQoIiAgR1BJTyVkXyVzJWR+JXMlZCA6ICVzIiAlICgKICAgICAgICAg
ICAgZyAvLyA0LCAiQUJDRCJbZyAlIDRdLCAwLCAiQUJDRCJbZyAlIDRdLCA3LAogICAgICAgICAg
ICAiLCIuam9pbihzdHIoeCkgZm9yIHggaW4gZ3JvdXBzW2ddKSBpZiBsZW4oZ3JvdXBzW2ddKSA8
PSA4IGVsc2UgIi4uLiIpKQoKCmRlZiBjbWRfc2NhbihtZW0sIGFyZ3MpOgogICAgbWRjX251bSA9
IGludChhcmdzWzBdKSBpZiBsZW4oYXJncykgPj0gMiBlbHNlIDEyMQogICAgbWRpb19udW0gPSBp
bnQoYXJnc1sxXSkgaWYgbGVuKGFyZ3MpID49IDIgZWxzZSAxMjAKICAgIGxvID0gaW50KGFyZ3Nb
Ml0pIGlmIGxlbihhcmdzKSA+PSAzIGVsc2UgMAogICAgaGkgPSBpbnQoYXJnc1szXSkgaWYgbGVu
KGFyZ3MpID49IDQgZWxzZSA3CiAgICBwcmludCgi5omrICVzKE1EQykgLyAlcyhNRElPKSDlnLDl
nYAgJWR+JWQiICUgKAogICAgICAgIHBpbl9uYW1lKG1kY19udW0pLCBwaW5fbmFtZShtZGlvX251
bSksIGxvLCBoaSkpCiAgICBoaXQgPSAwCiAgICBmb3IgYWRkciBpbiByYW5nZShsbywgaGkgKyAx
KToKICAgICAgICBwaWQgPSBwaHlfaWQobWVtLCBtZGNfbnVtLCBtZGlvX251bSwgYWRkcikKICAg
ICAgICBmbGFnID0gIiAgPD09IOacieW6lOetlCIgaWYgaXNfdmFsaWQocGlkKSBlbHNlICIiCiAg
ICAgICAgcHJpbnQoIiAgYWRkciAlZCA6IGlkPTB4JTA4WCVzIiAlIChhZGRyLCBwaWQsIGZsYWcp
KQogICAgICAgIGlmIGlzX3ZhbGlkKHBpZCk6CiAgICAgICAgICAgIGhpdCArPSAxCiAgICByZXR1
cm4gaGl0CgoKZGVmIGNtZF9zd2VlcChtZW0sIGFyZ3MpOgogICAgcGlucyA9IHNvcnRlZChzYWZl
X3BpbnMoKSkKICAgIHBhaXJzID0gW10KICAgIGZvciBwIGluIHBpbnM6CiAgICAgICAgaWYgcCAr
IDEgaW4gcGluczoKICAgICAgICAgICAgcGFpcnMuYXBwZW5kKChwLCBwICsgMSkpCiAgICAgICAg
ICAgIHBhaXJzLmFwcGVuZCgocCArIDEsIHApKQogICAgcHJpbnQoIuebuOmCu+WuieWFqOiEmuWv
uSAlZCDnu4TvvIjlkKvmraPlj43mnoHmgKfvvInvvIzlvIDlp4vmiavmj48gLi4uIiAlIGxlbihw
YWlycykpCiAgICBoaXRzID0gW10KICAgIGZvciBuLCAoYSwgYikgaW4gZW51bWVyYXRlKHBhaXJz
KToKICAgICAgICBzeXMuc3Rkb3V0LndyaXRlKCJcciAgWyVkLyVkXSBNREM9JWQgTURJTz0lZCAg
ICAgICIgJSAobiArIDEsIGxlbihwYWlycyksIGEsIGIpKQogICAgICAgIHN5cy5zdGRvdXQuZmx1
c2goKQogICAgICAgIGZvciBhZGRyIGluIHJhbmdlKDgpOgogICAgICAgICAgICBwaWQgPSBwaHlf
aWQobWVtLCBhLCBiLCBhZGRyKQogICAgICAgICAgICBpZiBpc192YWxpZChwaWQpOgogICAgICAg
ICAgICAgICAgaGl0cy5hcHBlbmQoKGEsIGIsIGFkZHIsIHBpZCkpCiAgICBwcmludCgiIikKICAg
IGlmIG5vdCBoaXRzOgogICAgICAgIHByaW50KCLnu5PmnpzvvJrmsqHmnInku7vkvZXkuIDlr7kg
KyDku7vkvZXlnLDlnYDmnInlupTnrZTjgIIiKQogICAgZWxzZToKICAgICAgICBwcmludCgi57uT
5p6c77ya5om+5YiwICVkIOWkhOW6lOetlO+8miIgJSBsZW4oaGl0cykpCiAgICAgICAgZm9yIGEs
IGIsIGFkZHIsIHBpZCBpbiBoaXRzOgogICAgICAgICAgICBwcmludCgiICBNREM9JXMoJWQpIE1E
SU89JXMoJWQpIFBIWeWcsOWdgD0lZCBpZD0weCUwOFgiICUgKAogICAgICAgICAgICAgICAgcGlu
X25hbWUoYSksIGEsIHBpbl9uYW1lKGIpLCBiLCBhZGRyLCBwaWQpKQogICAgcmV0dXJuIGxlbiho
aXRzKQoKCmRlZiBjbWRfY3RsKG1lbSwgYXJncyk6CiAgICBtZGNfbnVtID0gaW50KGFyZ3NbMF0p
IGlmIGxlbihhcmdzKSA+PSAyIGVsc2UgMTIxCiAgICBtZGlvX251bSA9IGludChhcmdzWzFdKSBp
ZiBsZW4oYXJncykgPj0gMiBlbHNlIDEyMAogICAgcGlucyA9IHNvcnRlZChzYWZlX3BpbnMoKSkK
ICAgIHByaW50KCLpgJDkuKrmiorlronlhajohJrmi4npq5jvvIzlkIzml7bmiasgJXMvJXMg55qE
IDB+NyAuLi4iICUgKAogICAgICAgIHBpbl9uYW1lKG1kY19udW0pLCBwaW5fbmFtZShtZGlvX251
bSkpKQogICAgaGl0cyA9IFtdCiAgICBmb3IgbiwgcCBpbiBlbnVtZXJhdGUocGlucyk6CiAgICAg
ICAgc3lzLnN0ZG91dC53cml0ZSgiXHIgIFslZC8lZF0g5ouJ6auYICVkICglcykgICAgICAiICUg
KG4gKyAxLCBsZW4ocGlucyksIHAsIHBpbl9uYW1lKHApKSkKICAgICAgICBzeXMuc3Rkb3V0LmZs
dXNoKCkKICAgICAgICBjdGwgPSBQaW4obWVtLCBwKQogICAgICAgIGN0bC5tdXhfZ3BpbygpCiAg
ICAgICAgY3RsLnNldF9kaXIoVHJ1ZSkKICAgICAgICBjdGwuc2V0KDEpCiAgICAgICAgZm9yIGFk
ZHIgaW4gcmFuZ2UoOCk6CiAgICAgICAgICAgIHBpZCA9IHBoeV9pZChtZW0sIG1kY19udW0sIG1k
aW9fbnVtLCBhZGRyKQogICAgICAgICAgICBpZiBpc192YWxpZChwaWQpOgogICAgICAgICAgICAg
ICAgaGl0cy5hcHBlbmQoKHAsIGFkZHIsIHBpZCkpCiAgICAgICAgY3RsLnNldCgwKQogICAgICAg
IGN0bC5zZXRfZGlyKEZhbHNlKQogICAgcHJpbnQoIiIpCiAgICBpZiBub3QgaGl0czoKICAgICAg
ICBwcmludCgi57uT5p6c77ya5rKh5pyJ5Lu75L2V5o6n5Yi26ISa6IO95ZSk6YaSIEQxL0QwIOS4
iueahCBQSFnjgIIiKQogICAgZWxzZToKICAgICAgICBwcmludCgi57uT5p6c77ya5om+5YiwICVk
IOWkhOW6lOetlO+8miIgJSBsZW4oaGl0cykpCiAgICAgICAgZm9yIHAsIGFkZHIsIHBpZCBpbiBo
aXRzOgogICAgICAgICAgICBwcmludCgiICDmjqfliLbohJo9JXMoJWQpIFBIWeWcsOWdgD0lZCBp
ZD0weCUwOFgiICUgKHBpbl9uYW1lKHApLCBwLCBhZGRyLCBwaWQpKQogICAgcmV0dXJuIGxlbiho
aXRzKQoKCmRlZiBjbWRfZHVtcChtZW0sIGFyZ3MpOgogICAgZm9yIGIsIGJhc2UgaW4gZW51bWVy
YXRlKEdQSU9fQkFTRSk6CiAgICAgICAgcHJpbnQoIkdQSU8lZCBiYXNlPTB4JTA4WCBEUj0weCUw
OFggRERSPTB4JTA4WCBFWFQ9MHglMDhYIiAlICgKICAgICAgICAgICAgYiwgYmFzZSwKICAgICAg
ICAgICAgbWVtLnJkKGJhc2UgKyBSRUdfRFIpLCBtZW0ucmQoYmFzZSArIFJFR19ERFIpLCBtZW0u
cmQoYmFzZSArIFJFR19FWFQpKSkKCgpDTURTID0gewogICAgInBpbiI6IGNtZF9waW4sCiAgICAi
c2FmZSI6IGNtZF9zYWZlLAogICAgInNjYW4iOiBjbWRfc2NhbiwKICAgICJzd2VlcCI6IGNtZF9z
d2VlcCwKICAgICJjdGwiOiBjbWRfY3RsLAogICAgImR1bXAiOiBjbWRfZHVtcCwKfQoKCmRlZiBt
YWluKCk6CiAgICBpZiBsZW4oc3lzLmFyZ3YpIDwgMiBvciBzeXMuYXJndlsxXSBub3QgaW4gQ01E
UzoKICAgICAgICBwcmludChfX2RvY19fIG9yICIiKQogICAgICAgIHByaW50KCLlj6/nlKjlkb3k
u6TvvJoiICsgIiAvICIuam9pbihzb3J0ZWQoQ01EUykpKQogICAgICAgIHJldHVybiAyCiAgICBt
ZW0gPSBNZW0oKQogICAgcmV0dXJuIDAgaWYgQ01EU1tzeXMuYXJndlsxXV0obWVtLCBzeXMuYXJn
dlsyOl0pID49IDAgZWxzZSAxCgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjoKICAgIHN5cy5l
eGl0KG1haW4oKSkK
MDIOSCAN_B64
chmod 755 /usr/local/bin/mdio-scan
if [ ! -x /usr/bin/python3 ] && [ ! -x /usr/local/bin/python3 ]; then
    echo "⚠️  rootfs 里没有 python3，mdio-scan 无法运行"
else
    echo "✅ 已安装 /usr/local/bin/mdio-scan（python3 版 MDIO 引脚探测工具）"
fi
