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
IE1ESU8g5byV6ISa5o6i5rWL5bel5YW3IHYz77yI55u05o6l6K+75YaZIEdQSU8gLyBHUkYg5a+E
5a2Y5Zmo77yM57uV6L+HIHBpbmN0cmwg5LiOIG1kaW8tZ3BpbyDpqbHliqjvvIkKCnYzIOebuOWv
uSB2MiDnmoTmlLnliqjvvIjph43opoHvvInvvJoKICAxKSDkv67mjokgc2FmZS9ob2xkL2ZyZWUv
cGluL2R1bXAg5rKh5pyJIHJldHVybiDlr7zoh7TnmoQgVHlwZUVycm9yIOW0qea6g+OAggogIDIp
IOWuieWFqOiEmuWIpOWumuS4jeWGjeino+aekCAvc3lzL2tlcm5lbC9kZWJ1Zy9waW5jdHJsLyov
cGlubXV4LXBpbnMg55qE5paH5pysCiAgICAg77yINi4xMiDnmoQgcGluY3RybF9waW5zX3Nob3cg
5qC55pys5LiN5omT5Y2wICJVTkNMQUlNRUQi77yMdjIg5rC46L+c5Y+q6IO95Yy56YWN5YiwIDAg
5Liq6ISa77yMCiAgICAgICBjdGwg5LqO5piv56m66L2s77yMc3dlZXAg5YiZ6YCA5YyW5oiQIuWF
qOmDqCAxMjgg6ISaIuS7juiAjOWGmeW0qSBHUElPMC8xIOS4iueahOmXquWtmOS4jiBQTUlD77yJ
44CCCiAgICAg5pS55Li677ya6Ieq5bex6K+7IEdSRiDnmoQgaW9tdXgg5a+E5a2Y5Zmo77yMbXV4
PT0wIOaJjeaYryLlvZPliY3lsLHmmK8gR1BJTyLnmoTohJrvvIzmiY3lhYHorrjnorDjgIIKICAz
KSBob2xkIOWJjeaKiuivpeiEmueahCDlpI3nlKjlgLwv5pa55ZCRL+i+k+WHuuWAvCDlrZjliLAg
L3RtcC9tZGlvLXNjYW4tb3JpZy5qc29u77yMCiAgICAgZnJlZSDml7bljp/moLfmgaLlpI3vvJtm
cmVlIGFsbCDlj6/kuIDmrKHmgaLlpI3lhajpg6jjgIJDdHJsLUMg5omT5pat5Lmf5LiN5Lya55WZ
5LiLIuW4uOmrmOiEmiLjgIIKICA0KSBiYW5rMCAvIGJhbmsxIOm7mOiupOaVtOe7hOaLiem7ke+8
iOmXquWtmOOAgVBNSUPjgIFlTU1D44CBVUFSVDIg6YO95Zyo6YeM6Z2i77yJ77yM6KaB56Kw5b+F
6aG7IC0tZm9yY2XjgIIKCuS4uuS7gOS5iOimgeacieWug++8mgogIHR0bC0xN++8iOehrOS7tiBN
RElP77yJ5ZKMIHR0bC0xOe+8iEdQSU8gYml0LWJhbmfvvIxEMS9EMO+8ieWcqCBSVEw4MjAxRk4g
5LiK6YO95pivIDB+NyDlnLDlnYDlhaggbWlzc2luZ++8mwogIHR0bC0yMCDnmoQgNjIg5p2h5oC7
57q/5omr6aKR54mI5Y+I5Zug5Li6IHBpbmN0cmwg5Y2g55So77yIZ3Bpb2Qg6L+U5ZueIC1FQlVT
We+8ieWPquaciSA3IOadoeecn+eahOi3keWIsOS6huOAggogIOimgeS4jeWPlyBwaW5jdHJsIOmZ
kOWItuWcsOmAkOiEmuivle+8jOWPquiDveebtOaOpeWGmeWvhOWtmOWZqOOAggoK5a+E5a2Y5Zmo
5L6d5o2u77yaCiAgUkszMTg4IFRSTSBWMS4zIMKnMzguNCDigJTigJQgR1BJT19TV1BPUlRBX0RS
IDB4MDAgLyBHUElPX1NXUE9SVEFfRERSIDB4MDQgLyBHUElPX0VYVF9QT1JUQSAweDUw77yMCiAg
5q+P5LiqIHBvcnQg5LiA5LiqIDMyIOS9jeWvhOWtmOWZqO+8iOS4jeaYryBfTC9fSCDmi4bliIbv
vInjgIIKICBHUkbvvIjln7rlnYAgMHgyMDAwODAwMO+8iWlvbXV477yaR1JGX0dQSU94QV9JT01V
WCDotbfkuo4gMHg2MO+8jOavjyBiYW5rIDB4MTDjgIHmr48gOCDohJrkuIDnu4QgNCDlrZfoioLv
vIwKICDmr4/ohJogMiBiaXTvvIzlgLwgMCA9IEdQSU/jgIIKCueUqOazle+8iHJvb3Qg5LiL77yJ
77yaCiAgbWRpby1zY2FuICAgICAgICAgICAgICAgICAgICAgICMg5omT5Y2w5biu5YqpCiAgbWRp
by1zY2FuIHNhZmUgICAgICAgICAgICAgICAgICMg5YiX5Ye6IGJhbmszIOmHjOWPr+WuieWFqOaT
jeS9nOeahOW8leiEmu+8iOWQqyBtdXgvZGlyL2xldmVs77yJCiAgbWRpby1zY2FuIHNhZmUgLS1s
aXN0ICAgICAgICAgICMg5Y+q5omT5Y2w6ISa5Y+377yM5pa55L6/IHNoZWxsIOW+queOrwogIG1k
aW8tc2NhbiBzYWZlIC0tYmFuaz0yIC0tYW55ICAjIOaUvuWuve+8mui/niBtdXghPTAg55qE5Lmf
566X6L+b5p2l77yI5Y2x6Zmp77yM5Lya5oqi5Yir5Lq655qE5Yqf6IO96ISa77yJCiAgbWRpby1z
Y2FuIHBpbiAxMjAgICAgICAgICAgICAgICMg55yL5p+Q5Liq6ISa77ya5aSN55So5YC8L+aWueWQ
kS/nlLXlubMKICBtZGlvLXNjYW4gc2NhbiAxMjEgMTIwICAgICAgICAgIyDpu5jorqTlnKggTURD
PTEyMShHUElPM19EMSkvTURJTz0xMjAoR1BJTzNfRDApIOS4iuaJqyAwfjcKICBtZGlvLXNjYW4g
aG9sZCA5NiAgICAgICAgICAgICAgIyDmiormn5DkuKrohJrmi4npq5jlubbkv53mjIHvvIjphY3l
kIgi55yLIFJKNDUg54GvIuWIpOWumuWkjeS9jS/kvpvnlLXohJrvvIkKICBtZGlvLXNjYW4gaG9s
ZCA5NiBsb3cgICAgICAgICAgIyDmi4nkvY7lubbkv53mjIEKICBtZGlvLXNjYW4gZnJlZSA5NiAg
ICAgICAgICAgICAgIyDmgaLlpI3liLAgaG9sZCDkuYvliY3nmoTnirbmgIEKICBtZGlvLXNjYW4g
ZnJlZSBhbGwgICAgICAgICAgICAgIyDmgaLlpI3lhajpg6jvvIhDdHJsLUMg5omT5pat5ZCO6LeR
6L+Z5Liq5pS25bC+77yJCiAgbWRpby1zY2FuIGN0bCAgICAgICAgICAgICAgICAgICMg6YCQ5Liq
5oqK5a6J5YWo6ISa5ouJ6auY77yM5YaN55yLIEQxL0QwIOS4iuacieayoeaciSBQSFkg5bqU562U
CiAgbWRpby1zY2FuIHN3ZWVwICAgICAgICAgICAgICAgICMg55u46YK75a6J5YWo6ISa5a+55q2j
5Y+N5p6B5oCn5omrIDB+N++8iOWPquWcqCBiYW5rM++8iQogIG1kaW8tc2NhbiBkdW1wICAgICAg
ICAgICAgICAgICAjIOaJk+WNsCA0IOS4qiBiYW5rIOeahCBEUi9ERFIvRVhUCiIiIgoKaW1wb3J0
IGdsb2IKaW1wb3J0IGpzb24KaW1wb3J0IG1tYXAKaW1wb3J0IG9zCmltcG9ydCBzeXMKaW1wb3J0
IHRpbWUKCkdQSU9fQkFTRSA9IFsweDIwMDBBMDAwLCAweDIwMDNDMDAwLCAweDIwMDNFMDAwLCAw
eDIwMDgwMDAwXQpHUkZfQkFTRSA9IDB4MjAwMDgwMDAKUkVHX0RSID0gMHgwMApSRUdfRERSID0g
MHgwNApSRUdfRVhUID0gMHg1MApQQUdFID0gNDA5NgoKRCA9IDNlLTYKQkFEX0lEUyA9ICgweDAw
MDAwMDAwLCAweDAwMDBGRkZGLCAweEZGRkZGRkZGLCAweEZGRkYwMDAwLCAweDAwMDBGRkZFKQoK
U1RBVEVfRklMRSA9ICIvdG1wL21kaW8tc2Nhbi1vcmlnLmpzb24iCgojIOaVtOe7hOaLiem7ke+8
mmJhbmswIOaciSBTUEkgRmxhc2ggLyBQTUlDKEkyQynvvIxiYW5rMSDmnIkgZU1NQyAvIFVBUlQy
KGNvbnNvbGUpCkJMQUNLX0JBTktTID0gKDAsIDEpCiMgYmFuazMg5LiK5q2j5Zyo6KKr5oiR5Lus
IERUUyDkvb/nlKjnmoTohJrvvJpDMH5DNyDmmK8gUk1JSe+8jEQwL0QxIOaYryBNREMvTURJT++8
jOmDveS4jeW9k+aOp+WItuiEmgpFTUFDX1JNSUkgPSB0dXBsZShyYW5nZSgxMTIsIDEyMCkpCk1E
SU9fUElOUyA9ICgxMjAsIDEyMSkKCgpkZWYgcGluX25hbWUobnVtKToKICAgIGJhbmsgPSBudW0g
Ly8gMzIKICAgIGdycCA9ICJBQkNEIlsobnVtICUgMzIpIC8vIDhdCiAgICBpZHggPSBudW0gJSA4
CiAgICByZXR1cm4gIkdQSU8lZF8lcyVkIiAlIChiYW5rLCBncnAsIGlkeCkKCgpjbGFzcyBNZW0o
b2JqZWN0KToKICAgIGRlZiBfX2luaXRfXyhzZWxmKToKICAgICAgICBzZWxmLmZkID0gb3Mub3Bl
bigiL2Rldi9tZW0iLCBvcy5PX1JEV1IgfCBvcy5PX1NZTkMpCiAgICAgICAgc2VsZi5tYXBzID0g
e30KCiAgICBkZWYgX3BhZ2Uoc2VsZiwgYWRkcik6CiAgICAgICAgYmFzZSA9IGFkZHIgJiB+KFBB
R0UgLSAxKQogICAgICAgIG0gPSBzZWxmLm1hcHMuZ2V0KGJhc2UpCiAgICAgICAgaWYgbSBpcyBO
b25lOgogICAgICAgICAgICBtID0gbW1hcC5tbWFwKHNlbGYuZmQsIFBBR0UsIG1tYXAuTUFQX1NI
QVJFRCwKICAgICAgICAgICAgICAgICAgICAgICAgICBtbWFwLlBST1RfUkVBRCB8IG1tYXAuUFJP
VF9XUklURSwgb2Zmc2V0PWJhc2UpCiAgICAgICAgICAgIHNlbGYubWFwc1tiYXNlXSA9IG0KICAg
ICAgICByZXR1cm4gbSwgYWRkciAtIGJhc2UKCiAgICBkZWYgcmQoc2VsZiwgYWRkcik6CiAgICAg
ICAgbSwgbyA9IHNlbGYuX3BhZ2UoYWRkcikKICAgICAgICByZXR1cm4gaW50LmZyb21fYnl0ZXMo
bVtvOm8gKyA0XSwgImxpdHRsZSIpCgogICAgZGVmIHdyKHNlbGYsIGFkZHIsIHZhbCk6CiAgICAg
ICAgbSwgbyA9IHNlbGYuX3BhZ2UoYWRkcikKICAgICAgICBtW286byArIDRdID0gKHZhbCAmIDB4
RkZGRkZGRkYpLnRvX2J5dGVzKDQsICJsaXR0bGUiKQoKCmNsYXNzIFBpbihvYmplY3QpOgogICAg
ZGVmIF9faW5pdF9fKHNlbGYsIG1lbSwgbnVtKToKICAgICAgICBzZWxmLm1lbSA9IG1lbQogICAg
ICAgIHNlbGYubnVtID0gbnVtCiAgICAgICAgc2VsZi5iYW5rID0gbnVtIC8vIDMyCiAgICAgICAg
c2VsZi5pZHggPSBudW0gJSAzMgogICAgICAgIHNlbGYuYmFzZSA9IEdQSU9fQkFTRVtzZWxmLmJh
bmtdCgogICAgZGVmIHNldF9kaXIoc2VsZiwgb3V0KToKICAgICAgICBhID0gc2VsZi5iYXNlICsg
UkVHX0REUgogICAgICAgIHYgPSBzZWxmLm1lbS5yZChhKQogICAgICAgIGlmIG91dDoKICAgICAg
ICAgICAgdiB8PSAoMSA8PCBzZWxmLmlkeCkKICAgICAgICBlbHNlOgogICAgICAgICAgICB2ICY9
IH4oMSA8PCBzZWxmLmlkeCkKICAgICAgICBzZWxmLm1lbS53cihhLCB2KQoKICAgIGRlZiBzZXQo
c2VsZiwgdmFsKToKICAgICAgICBhID0gc2VsZi5iYXNlICsgUkVHX0RSCiAgICAgICAgdiA9IHNl
bGYubWVtLnJkKGEpCiAgICAgICAgaWYgdmFsOgogICAgICAgICAgICB2IHw9ICgxIDw8IHNlbGYu
aWR4KQogICAgICAgIGVsc2U6CiAgICAgICAgICAgIHYgJj0gfigxIDw8IHNlbGYuaWR4KQogICAg
ICAgIHNlbGYubWVtLndyKGEsIHYpCgogICAgZGVmIGdldChzZWxmKToKICAgICAgICByZXR1cm4g
KHNlbGYubWVtLnJkKHNlbGYuYmFzZSArIFJFR19FWFQpID4+IHNlbGYuaWR4KSAmIDEKCiAgICBk
ZWYgX2lvbXV4X2FkZHJfYml0KHNlbGYpOgogICAgICAgIG9mZiA9IDB4NjAgKyAoc2VsZi5iYW5r
ICogNCArIHNlbGYuaWR4IC8vIDgpICogNAogICAgICAgIHJldHVybiBHUkZfQkFTRSArIG9mZiwg
KHNlbGYuaWR4ICUgOCkgKiAyCgogICAgZGVmIG11eF9nZXQoc2VsZik6CiAgICAgICAgYSwgYiA9
IHNlbGYuX2lvbXV4X2FkZHJfYml0KCkKICAgICAgICByZXR1cm4gKHNlbGYubWVtLnJkKGEpID4+
IGIpICYgMwoKICAgIGRlZiBtdXhfc2V0KHNlbGYsIHZhbCk6CiAgICAgICAgYSwgYiA9IHNlbGYu
X2lvbXV4X2FkZHJfYml0KCkKICAgICAgICB2ID0gc2VsZi5tZW0ucmQoYSkKICAgICAgICBzZWxm
Lm1lbS53cihhLCAodiAmIH4oMyA8PCBiKSkgfCAoKHZhbCAmIDMpIDw8IGIpKQoKICAgIGRlZiBt
dXhfZ3BpbyhzZWxmKToKICAgICAgICBzZWxmLm11eF9zZXQoMCkKCiAgICBkZWYgZGlyX291dChz
ZWxmKToKICAgICAgICByZXR1cm4gYm9vbCgoc2VsZi5tZW0ucmQoc2VsZi5iYXNlICsgUkVHX0RE
UikgPj4gc2VsZi5pZHgpICYgMSkKCiAgICBkZWYgc25hcHNob3Qoc2VsZik6CiAgICAgICAgcmV0
dXJuIHsibXV4Ijogc2VsZi5tdXhfZ2V0KCksICJvdXQiOiBzZWxmLmRpcl9vdXQoKSwgImRyIjog
c2VsZi5nZXQoKX0KCiAgICBkZWYgcmVzdG9yZShzZWxmLCBzKToKICAgICAgICBzZWxmLm11eF9z
ZXQoc1sibXV4Il0pCiAgICAgICAgaWYgc1sib3V0Il06CiAgICAgICAgICAgIHNlbGYuc2V0KDEg
aWYgc1siZHIiXSBlbHNlIDApCiAgICAgICAgICAgIHNlbGYuc2V0X2RpcihUcnVlKQogICAgICAg
IGVsc2U6CiAgICAgICAgICAgIHNlbGYuc2V0X2RpcihGYWxzZSkKCgpkZWYgbG9hZF9zdGF0ZSgp
OgogICAgdHJ5OgogICAgICAgIHJldHVybiBqc29uLmxvYWQob3BlbihTVEFURV9GSUxFKSkKICAg
IGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgcmV0dXJuIHt9CgoKZGVmIHNhdmVfc3RhdGUoc3Qp
OgogICAgdHJ5OgogICAgICAgIGpzb24uZHVtcChzdCwgb3BlbihTVEFURV9GSUxFLCAidyIpKQog
ICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICBwYXNzCgoKZGVmIHBhcnNlX2JhbmtzKGFyZ3Ms
IGRlZmF1bHQ9KDMsKSk6CiAgICBiYW5rcyA9IGRlZmF1bHQKICAgIGlmICItLWFsbCIgaW4gYXJn
czoKICAgICAgICBiYW5rcyA9ICgwLCAxLCAyLCAzKQogICAgZm9yIGEgaW4gYXJnczoKICAgICAg
ICBpZiBhLnN0YXJ0c3dpdGgoIi0tYmFuaz0iKToKICAgICAgICAgICAgYmFua3MgPSB0dXBsZShp
bnQoeCkgZm9yIHggaW4gYS5zcGxpdCgiPSIsIDEpWzFdLnNwbGl0KCIsIikpCiAgICByZXR1cm4g
YmFua3MKCgpkZWYgc2FmZV9waW5zKG1lbSwgYmFua3MsIGFueV9tdXg9RmFsc2UsIGZvcmNlPUZh
bHNlKToKICAgICIiIuiHquW3seivuyBpb211eCDliKTmlq3vvJptdXg9PTDvvIjlvZPliY3lsLHm
mK8gR1BJT++8ieS4lOWcqOWFgeiuuOeahCBiYW5rIOWGheaJjei/lOWbnuOAgiIiIgogICAgcGlu
cyA9IFtdCiAgICBmb3IgYiBpbiBiYW5rczoKICAgICAgICBpZiBiIGluIEJMQUNLX0JBTktTIGFu
ZCBub3QgZm9yY2U6CiAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgZm9yIHAgaW4gcmFuZ2Uo
YiAqIDMyLCBiICogMzIgKyAzMik6CiAgICAgICAgICAgIGlmIHAgaW4gTURJT19QSU5TIG9yIHAg
aW4gRU1BQ19STUlJOgogICAgICAgICAgICAgICAgY29udGludWUKICAgICAgICAgICAgaWYgbm90
IGFueV9tdXggYW5kIFBpbihtZW0sIHApLm11eF9nZXQoKSAhPSAwOgogICAgICAgICAgICAgICAg
Y29udGludWUKICAgICAgICAgICAgcGlucy5hcHBlbmQocCkKICAgIHJldHVybiBzb3J0ZWQocGlu
cykKCgpkZWYgYmJfcmVhZChtZGMsIG1kaW8sIHBoeSwgcmVnKToKICAgICIiIuagh+WHhiBDbGF1
c2UgMjIg6K+777yacHJlYW1ibGUgKyBTVCgwMSkgKyBPUCgxMCkgKyBQSFlBRCg1KSArIFJFR0FE
KDUpICsgVEEgKyAxNiDmlbDmja7kvY0iIiIKICAgIG1kaW8ubXV4X2dwaW8oKQogICAgbWRjLm11
eF9ncGlvKCkKICAgIG1kYy5zZXRfZGlyKFRydWUpCiAgICBtZGMuc2V0KDApCiAgICBtZGlvLnNl
dF9kaXIoVHJ1ZSkKCiAgICBkZWYgY2xrX3dyaXRlKGJpdCk6CiAgICAgICAgbWRpby5zZXQoYml0
KQogICAgICAgIHRpbWUuc2xlZXAoRCkKICAgICAgICBtZGMuc2V0KDEpCiAgICAgICAgdGltZS5z
bGVlcChEKQogICAgICAgIG1kYy5zZXQoMCkKICAgICAgICB0aW1lLnNsZWVwKEQpCgogICAgZm9y
IF8gaW4gcmFuZ2UoMzIpOgogICAgICAgIGNsa193cml0ZSgxKQoKICAgIGJpdHMgPSBbMCwgMSwg
MSwgMF0KICAgIGZvciBpIGluIHJhbmdlKDQsIC0xLCAtMSk6CiAgICAgICAgYml0cy5hcHBlbmQo
KHBoeSA+PiBpKSAmIDEpCiAgICBmb3IgaSBpbiByYW5nZSg0LCAtMSwgLTEpOgogICAgICAgIGJp
dHMuYXBwZW5kKChyZWcgPj4gaSkgJiAxKQogICAgZm9yIGIgaW4gYml0czoKICAgICAgICBjbGtf
d3JpdGUoYikKCiAgICBtZGlvLnNldF9kaXIoRmFsc2UpCiAgICB0aW1lLnNsZWVwKEQpCiAgICBt
ZGMuc2V0KDEpCiAgICB0aW1lLnNsZWVwKEQpCiAgICBtZGMuc2V0KDApCiAgICB0aW1lLnNsZWVw
KEQpCgogICAgdmFsID0gMAogICAgZm9yIF8gaW4gcmFuZ2UoMTYpOgogICAgICAgIHRpbWUuc2xl
ZXAoRCkKICAgICAgICBtZGMuc2V0KDEpCiAgICAgICAgdGltZS5zbGVlcChEKQogICAgICAgIHZh
bCA9ICh2YWwgPDwgMSkgfCBtZGlvLmdldCgpCiAgICAgICAgbWRjLnNldCgwKQogICAgICAgIHRp
bWUuc2xlZXAoRCkKICAgIHJldHVybiB2YWwKCgpkZWYgcGh5X2lkKG1lbSwgbWRjX251bSwgbWRp
b19udW0sIGFkZHIpOgogICAgbWRjID0gUGluKG1lbSwgbWRjX251bSkKICAgIG1kaW8gPSBQaW4o
bWVtLCBtZGlvX251bSkKICAgIGhpID0gYmJfcmVhZChtZGMsIG1kaW8sIGFkZHIsIDIpCiAgICBs
byA9IGJiX3JlYWQobWRjLCBtZGlvLCBhZGRyLCAzKQogICAgcmV0dXJuIChoaSA8PCAxNikgfCBs
bwoKCmRlZiBpc192YWxpZChwaWQpOgogICAgaWYgcGlkIGluIEJBRF9JRFM6CiAgICAgICAgcmV0
dXJuIEZhbHNlCiAgICBoaSA9IChwaWQgPj4gMTYpICYgMHhGRkZGCiAgICBsbyA9IHBpZCAmIDB4
RkZGRgogICAgaWYgaGkgaW4gKDB4MDAwMCwgMHhGRkZGKSBhbmQgbG8gaW4gKDB4MDAwMCwgMHhG
RkZGKToKICAgICAgICByZXR1cm4gRmFsc2UKICAgIHJldHVybiBUcnVlCgoKZGVmIGNtZF9waW4o
bWVtLCBhcmdzKToKICAgIGZvciBhIGluIGFyZ3M6CiAgICAgICAgcCA9IFBpbihtZW0sIGludChh
KSkKICAgICAgICBwcmludCgicGluICUtM2QgJS0xMHMgbXV4PSVkIGRpcj0lcyBsZXZlbD0lZCIg
JSAoCiAgICAgICAgICAgIHAubnVtLCBwaW5fbmFtZShwLm51bSksIHAubXV4X2dldCgpLAogICAg
ICAgICAgICAib3V0IiBpZiBwLmRpcl9vdXQoKSBlbHNlICJpbiIsIHAuZ2V0KCkpKQogICAgcmV0
dXJuIDAKCgpkZWYgY21kX3NhZmUobWVtLCBhcmdzKToKICAgIGJhbmtzID0gcGFyc2VfYmFua3Mo
YXJncykKICAgIGFueV9tdXggPSAiLS1hbnkiIGluIGFyZ3MKICAgIGZvcmNlID0gIi0tZm9yY2Ui
IGluIGFyZ3MKICAgIHBpbnMgPSBzYWZlX3BpbnMobWVtLCBiYW5rcywgYW55X211eCwgZm9yY2Up
CiAgICBpZiAiLS1saXN0IiBpbiBhcmdzOgogICAgICAgIGZvciBwIGluIHBpbnM6CiAgICAgICAg
ICAgIHByaW50KHApCiAgICAgICAgcmV0dXJuIDAKICAgIHByaW50KCJiYW5rICVzIOmHjOWPr+Wu
ieWFqOaTjeS9nOeahOW8leiEmuWFsSAlZCDkuKrvvIhtdXg9PTAg5LiU5pyq6KKr5o6S6Zmk77yJ
77yaIiAlICgKICAgICAgICAiLCIuam9pbihzdHIoYikgZm9yIGIgaW4gYmFua3MpLCBsZW4ocGlu
cykpKQogICAgZm9yIHAgaW4gcGluczoKICAgICAgICBxID0gUGluKG1lbSwgcCkKICAgICAgICBw
cmludCgiICAlLTNkICUtMTBzIG11eD0lZCBkaXI9JXMgbGV2ZWw9JWQiICUgKAogICAgICAgICAg
ICBwLCBwaW5fbmFtZShwKSwgcS5tdXhfZ2V0KCksICJvdXQiIGlmIHEuZGlyX291dCgpIGVsc2Ug
ImluIiwgcS5nZXQoKSkpCiAgICBpZiBub3QgcGluczoKICAgICAgICBwcmludCgiICDvvIjkuIDk
uKrpg73msqHmnInjgILlj6/og73ov5nkupsgYmFuayDnmoTohJrlhajooqvljaDnlKjkuobvvIzo
r5Xor5UgLS1iYW5rPTIg5oiWIC0tYW5577yJIikKICAgIHJldHVybiAwCgoKZGVmIGNtZF9zY2Fu
KG1lbSwgYXJncyk6CiAgICBudW1zID0gW2ludChhKSBmb3IgYSBpbiBhcmdzIGlmIGEuaXNkaWdp
dCgpXQogICAgbWRjX251bSA9IG51bXNbMF0gaWYgbGVuKG51bXMpID49IDEgZWxzZSAxMjEKICAg
IG1kaW9fbnVtID0gbnVtc1sxXSBpZiBsZW4obnVtcykgPj0gMiBlbHNlIDEyMAogICAgbG8gPSBu
dW1zWzJdIGlmIGxlbihudW1zKSA+PSAzIGVsc2UgMAogICAgaGkgPSBudW1zWzNdIGlmIGxlbihu
dW1zKSA+PSA0IGVsc2UgNwogICAgcHJpbnQoIuaJqyAlcyhNREMpIC8gJXMoTURJTykg5Zyw5Z2A
ICVkfiVkIiAlICgKICAgICAgICBwaW5fbmFtZShtZGNfbnVtKSwgcGluX25hbWUobWRpb19udW0p
LCBsbywgaGkpKQogICAgaGl0ID0gMAogICAgZm9yIGFkZHIgaW4gcmFuZ2UobG8sIGhpICsgMSk6
CiAgICAgICAgcGlkID0gcGh5X2lkKG1lbSwgbWRjX251bSwgbWRpb19udW0sIGFkZHIpCiAgICAg
ICAgZmxhZyA9ICIgIDw9PSDmnInlupTnrZQiIGlmIGlzX3ZhbGlkKHBpZCkgZWxzZSAiIgogICAg
ICAgIHByaW50KCIgIGFkZHIgJWQgOiBpZD0weCUwOFglcyIgJSAoYWRkciwgcGlkLCBmbGFnKSkK
ICAgICAgICBpZiBpc192YWxpZChwaWQpOgogICAgICAgICAgICBoaXQgKz0gMQogICAgcHJpbnQo
IuWQiOiuoeWRveS4rSAlZCDkuKrlnLDlnYDjgIIiICUgaGl0KQogICAgcmV0dXJuIGhpdAoKCmRl
ZiBjbWRfc3dlZXAobWVtLCBhcmdzKToKICAgIGJhbmtzID0gcGFyc2VfYmFua3MoYXJncykKICAg
IHBpbnMgPSBzYWZlX3BpbnMobWVtLCBiYW5rcykKICAgIHBhaXJzID0gW10KICAgIGZvciBwIGlu
IHBpbnM6CiAgICAgICAgaWYgcCArIDEgaW4gcGluczoKICAgICAgICAgICAgcGFpcnMuYXBwZW5k
KChwLCBwICsgMSkpCiAgICAgICAgICAgIHBhaXJzLmFwcGVuZCgocCArIDEsIHApKQogICAgcHJp
bnQoImJhbmsgJXMg5YaF55u46YK75a6J5YWo6ISa5a+5ICVkIOe7hO+8iOWQq+ato+WPjeaegeaA
p++8ie+8jOW8gOWni+aJq+aPjyAuLi4iICUgKAogICAgICAgICIsIi5qb2luKHN0cihiKSBmb3Ig
YiBpbiBiYW5rcyksIGxlbihwYWlycykpKQogICAgaWYgbm90IHBhaXJzOgogICAgICAgIHByaW50
KCLmsqHmnInlj6/miavnmoTnm7jpgrvohJrlr7nvvIznm7TmjqXpgIDlh7rjgIIiKQogICAgICAg
IHJldHVybiAwCiAgICBoaXRzID0gW10KICAgIGZvciBuLCAoYSwgYikgaW4gZW51bWVyYXRlKHBh
aXJzKToKICAgICAgICBzeXMuc3Rkb3V0LndyaXRlKCJcciAgWyVkLyVkXSBNREM9JWQgTURJTz0l
ZCAgICAgICIgJSAobiArIDEsIGxlbihwYWlycyksIGEsIGIpKQogICAgICAgIHN5cy5zdGRvdXQu
Zmx1c2goKQogICAgICAgIGZvciBhZGRyIGluIHJhbmdlKDgpOgogICAgICAgICAgICBwaWQgPSBw
aHlfaWQobWVtLCBhLCBiLCBhZGRyKQogICAgICAgICAgICBpZiBpc192YWxpZChwaWQpOgogICAg
ICAgICAgICAgICAgaGl0cy5hcHBlbmQoKGEsIGIsIGFkZHIsIHBpZCkpCiAgICBwcmludCgiIikK
ICAgIGlmIG5vdCBoaXRzOgogICAgICAgIHByaW50KCLnu5PmnpzvvJrmsqHmnInku7vkvZXkuIDl
r7kgKyDku7vkvZXlnLDlnYDmnInlupTnrZTjgIIiKQogICAgZWxzZToKICAgICAgICBwcmludCgi
57uT5p6c77ya5om+5YiwICVkIOWkhOW6lOetlO+8miIgJSBsZW4oaGl0cykpCiAgICAgICAgZm9y
IGEsIGIsIGFkZHIsIHBpZCBpbiBoaXRzOgogICAgICAgICAgICBwcmludCgiICBNREM9JXMoJWQp
IE1ESU89JXMoJWQpIFBIWeWcsOWdgD0lZCBpZD0weCUwOFgiICUgKAogICAgICAgICAgICAgICAg
cGluX25hbWUoYSksIGEsIHBpbl9uYW1lKGIpLCBiLCBhZGRyLCBwaWQpKQogICAgcmV0dXJuIGxl
bihoaXRzKQoKCmRlZiBjbWRfY3RsKG1lbSwgYXJncyk6CiAgICBiYW5rcyA9IHBhcnNlX2Jhbmtz
KGFyZ3MpCiAgICBudW1zID0gW2ludChhKSBmb3IgYSBpbiBhcmdzIGlmIGEuaXNkaWdpdCgpXQog
ICAgbWRjX251bSA9IG51bXNbMF0gaWYgbGVuKG51bXMpID49IDEgZWxzZSAxMjEKICAgIG1kaW9f
bnVtID0gbnVtc1sxXSBpZiBsZW4obnVtcykgPj0gMiBlbHNlIDEyMAogICAgcGlucyA9IHNhZmVf
cGlucyhtZW0sIGJhbmtzKQogICAgcHJpbnQoImJhbmsgJXPvvJolcy8lcyDkuIrlhYjmiavkuIDp
gY3ln7rnur8gLi4uIiAlICgKICAgICAgICAiLCIuam9pbihzdHIoYikgZm9yIGIgaW4gYmFua3Mp
LCBwaW5fbmFtZShtZGNfbnVtKSwgcGluX25hbWUobWRpb19udW0pKSkKICAgIGZvciBhZGRyIGlu
IHJhbmdlKDgpOgogICAgICAgIHBpZCA9IHBoeV9pZChtZW0sIG1kY19udW0sIG1kaW9fbnVtLCBh
ZGRyKQogICAgICAgIHByaW50KCIgIOWfuue6vyBhZGRyICVkIDogaWQ9MHglMDhYIiAlIChhZGRy
LCBwaWQpKQogICAgaWYgbm90IHBpbnM6CiAgICAgICAgcHJpbnQoIuayoeacieWPr+aTjeS9nOea
hOaOp+WItuiEmu+8jOmAgOWHuu+8iOWFiOi3kSBtZGlvLXNjYW4gc2FmZe+8ieOAgiIpCiAgICAg
ICAgcmV0dXJuIDAKICAgIHByaW50KCLpgJDkuKrmioogJWQg5Liq5a6J5YWo6ISa5ouJ6auY77yM
5ZCM5pe25omrIDB+NyAuLi4iICUgbGVuKHBpbnMpKQogICAgaGl0cyA9IFtdCiAgICBmb3Igbiwg
cCBpbiBlbnVtZXJhdGUocGlucyk6CiAgICAgICAgc3lzLnN0ZG91dC53cml0ZSgiXHIgIFslZC8l
ZF0g5ouJ6auYICVkICglcykgICAgICAiICUgKG4gKyAxLCBsZW4ocGlucyksIHAsIHBpbl9uYW1l
KHApKSkKICAgICAgICBzeXMuc3Rkb3V0LmZsdXNoKCkKICAgICAgICBjdGwgPSBQaW4obWVtLCBw
KQogICAgICAgIG9yaWcgPSBjdGwuc25hcHNob3QoKQogICAgICAgIGN0bC5tdXhfZ3BpbygpCiAg
ICAgICAgY3RsLnNldF9kaXIoVHJ1ZSkKICAgICAgICBjdGwuc2V0KDEpCiAgICAgICAgZm9yIGFk
ZHIgaW4gcmFuZ2UoOCk6CiAgICAgICAgICAgIHBpZCA9IHBoeV9pZChtZW0sIG1kY19udW0sIG1k
aW9fbnVtLCBhZGRyKQogICAgICAgICAgICBpZiBpc192YWxpZChwaWQpOgogICAgICAgICAgICAg
ICAgaGl0cy5hcHBlbmQoKHAsIGFkZHIsIHBpZCkpCiAgICAgICAgY3RsLnJlc3RvcmUob3JpZykK
ICAgIHByaW50KCIiKQogICAgaWYgbm90IGhpdHM6CiAgICAgICAgcHJpbnQoIue7k+aenO+8mui/
mSAlZCDkuKrohJrpgJDkuKrmi4npq5jvvIxEMS9EMCDkuIrpg73msqHmnIkgUEhZIOW6lOetlOOA
giIgJSBsZW4ocGlucykpCiAgICBlbHNlOgogICAgICAgIHByaW50KCLnu5PmnpzvvJrmib7liLAg
JWQg5aSE5bqU562U77yaIiAlIGxlbihoaXRzKSkKICAgICAgICBmb3IgcCwgYWRkciwgcGlkIGlu
IGhpdHM6CiAgICAgICAgICAgIHByaW50KCIgIOaOp+WItuiEmj0lcyglZCkgUEhZ5Zyw5Z2APSVk
IGlkPTB4JTA4WCIgJSAocGluX25hbWUocCksIHAsIGFkZHIsIHBpZCkpCiAgICByZXR1cm4gbGVu
KGhpdHMpCgoKZGVmIGNtZF9ob2xkKG1lbSwgYXJncyk6CiAgICBudW1zID0gW2ludChhKSBmb3Ig
YSBpbiBhcmdzIGlmIGEuaXNkaWdpdCgpXQogICAgbG93ID0gImxvdyIgaW4gYXJncwogICAgZm9y
IG4gaW4gbnVtczoKICAgICAgICBpZiBuIC8vIDMyIGluIEJMQUNLX0JBTktTOgogICAgICAgICAg
ICBwcmludCgi5ouS57ud77yaR1BJTyVkIOaYr+mXquWtmC9QTUlDL2VNTUMvVUFSVCDljLrvvIzk
uI3lhYHorrjliqjjgIIiICUgKG4gLy8gMzIpKQogICAgICAgICAgICBjb250aW51ZQogICAgICAg
IHAgPSBQaW4obWVtLCBuKQogICAgICAgIHN0ID0gbG9hZF9zdGF0ZSgpCiAgICAgICAga2V5ID0g
c3RyKG4pCiAgICAgICAgaWYga2V5IG5vdCBpbiBzdDoKICAgICAgICAgICAgc3Rba2V5XSA9IHAu
c25hcHNob3QoKQogICAgICAgICAgICBzYXZlX3N0YXRlKHN0KQogICAgICAgIHAubXV4X2dwaW8o
KQogICAgICAgIHAuc2V0KDAgaWYgbG93IGVsc2UgMSkKICAgICAgICBwLnNldF9kaXIoVHJ1ZSkK
ICAgICAgICBwcmludCgi5bey5oqKICVzKCVkKSDmi4klc+W5tuS/neaMgei+k+WHuuOAgueciyBS
SjQ1IOeBr++8m+S4jeS6ruWwsSBtZGlvLXNjYW4gZnJlZSAlZOOAguWOn+eKtuaAgT0lcyIgJSAo
CiAgICAgICAgICAgIHBpbl9uYW1lKG4pLCBuLCAi5L2OIiBpZiBsb3cgZWxzZSAi6auYIiwgbiwg
c3Rba2V5XSkpCiAgICByZXR1cm4gMAoKCmRlZiBjbWRfZnJlZShtZW0sIGFyZ3MpOgogICAgc3Qg
PSBsb2FkX3N0YXRlKCkKICAgIGlmICJhbGwiIGluIGFyZ3M6CiAgICAgICAgZm9yIGsgaW4gbGlz
dChzdC5rZXlzKCkpOgogICAgICAgICAgICBQaW4obWVtLCBpbnQoaykpLnJlc3RvcmUoc3Rba10p
CiAgICAgICAgICAgIHByaW50KCLlt7LmgaLlpI0gJXMoJWQpIC0+ICVzIiAlIChwaW5fbmFtZShp
bnQoaykpLCBpbnQoayksIHN0W2tdKSkKICAgICAgICBzYXZlX3N0YXRlKHt9KQogICAgICAgIHJl
dHVybiAwCiAgICBmb3IgYSBpbiBhcmdzOgogICAgICAgIG4gPSBpbnQoYSkKICAgICAgICBwID0g
UGluKG1lbSwgbikKICAgICAgICBpZiBzdHIobikgaW4gc3Q6CiAgICAgICAgICAgIHAucmVzdG9y
ZShzdFtzdHIobildKQogICAgICAgICAgICBwcmludCgi5bey5oqKICVzKCVkKSDmgaLlpI3liLAg
aG9sZCDkuYvliY3vvJolcyIgJSAocGluX25hbWUobiksIG4sIHN0W3N0cihuKV0pKQogICAgICAg
ICAgICBkZWwgc3Rbc3RyKG4pXQogICAgICAgICAgICBzYXZlX3N0YXRlKHN0KQogICAgICAgIGVs
c2U6CiAgICAgICAgICAgIHAuc2V0KDApCiAgICAgICAgICAgIHAuc2V0X2RpcihGYWxzZSkKICAg
ICAgICAgICAgcHJpbnQoIuW3suaKiiAlcyglZCkg5pS+5byA77yI6L6T5YWl44CB5L2O55S15bmz
77yJ44CCIiAlIChwaW5fbmFtZShuKSwgbikpCiAgICByZXR1cm4gMAoKCmRlZiBjbWRfZHVtcCht
ZW0sIGFyZ3MpOgogICAgZm9yIGIsIGJhc2UgaW4gZW51bWVyYXRlKEdQSU9fQkFTRSk6CiAgICAg
ICAgcHJpbnQoIkdQSU8lZCBiYXNlPTB4JTA4WCBEUj0weCUwOFggRERSPTB4JTA4WCBFWFQ9MHgl
MDhYIiAlICgKICAgICAgICAgICAgYiwgYmFzZSwKICAgICAgICAgICAgbWVtLnJkKGJhc2UgKyBS
RUdfRFIpLCBtZW0ucmQoYmFzZSArIFJFR19ERFIpLCBtZW0ucmQoYmFzZSArIFJFR19FWFQpKSkK
ICAgIHJldHVybiAwCgoKQ01EUyA9IHsKICAgICJwaW4iOiBjbWRfcGluLAogICAgInNhZmUiOiBj
bWRfc2FmZSwKICAgICJzY2FuIjogY21kX3NjYW4sCiAgICAic3dlZXAiOiBjbWRfc3dlZXAsCiAg
ICAiY3RsIjogY21kX2N0bCwKICAgICJob2xkIjogY21kX2hvbGQsCiAgICAiZnJlZSI6IGNtZF9m
cmVlLAogICAgImR1bXAiOiBjbWRfZHVtcCwKfQoKCmRlZiBtYWluKCk6CiAgICBpZiBsZW4oc3lz
LmFyZ3YpIDwgMiBvciBzeXMuYXJndlsxXSBub3QgaW4gQ01EUzoKICAgICAgICBwcmludChfX2Rv
Y19fIG9yICIiKQogICAgICAgIHByaW50KCLlj6/nlKjlkb3ku6TvvJoiICsgIiAvICIuam9pbihz
b3J0ZWQoQ01EUykpKQogICAgICAgIHJldHVybiAyCiAgICBtZW0gPSBNZW0oKQogICAgciA9IENN
RFNbc3lzLmFyZ3ZbMV1dKG1lbSwgc3lzLmFyZ3ZbMjpdKQogICAgaWYgciBpcyBOb25lOgogICAg
ICAgIHJldHVybiAwCiAgICByZXR1cm4gMCBpZiByID49IDAgZWxzZSAxCgoKaWYgX19uYW1lX18g
PT0gIl9fbWFpbl9fIjoKICAgIHN5cy5leGl0KG1haW4oKSkK
MDIOSCAN_B64
chmod 755 /usr/local/bin/mdio-scan
if [ ! -x /usr/bin/python3 ] && [ ! -x /usr/local/bin/python3 ]; then
    echo "⚠️  rootfs 里没有 python3，mdio-scan 无法运行"
else
    echo "✅ 已安装 /usr/local/bin/mdio-scan（python3 版 MDIO 引脚探测工具）"
fi
