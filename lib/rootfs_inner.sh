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
d2FrZSAgICAgICAgICAgICAgICAgIyDlhYjmioogR1BJTzNfRDIoMTIyKSDmi4npq5jnu5kgUEhZ
IOS4iueUte+8jOWGjeaJqyAxMjEvMTIwIOeahCAwfjcKICBtZGlvLXNjYW4gcmVncyAzICAgICAg
ICAgICAgICAgIyDor7sgUEhZIOWcsOWdgCAzIOeahCAwfjUg5Y+35a+E5a2Y5Zmo77yISUQv54q2
5oCBL+aOp+WItu+8iQogIG1kaW8tc2NhbiB3YWtlIC0tY2xrICAgICAgICAgICAjIOaLiemrmCAx
MjIgKyDmioogR1BJTzNfQzUoMTE3KSDliIfliLAgcm1paV9jbGtvdXTvvIjnu5kgUEhZIOmAgSA1
ME1Ieu+8iQogIG1kaW8tc2NhbiBtdXggMTE3IDIgICAgICAgICAgICAjIOebtOaOpeaUueafkOWP
quiEmueahCBpb211eO+8iDA9R1BJTyAvIDI95Yqf6IO9Mu+8jOS7hemZkCBiYW5rM++8iQogIG1k
aW8tc2NhbiBzd2VlcCAtLWFkaiAgICAgICAgICAjIOWPquaJq+ebuOmCu+iEmuWvue+8iHY0IOea
hOaXp+ihjOS4uu+8ie+8jOm7mOiupOaJq+WFqOe7hOWQiAogIG1kaW8tc2NhbiBob2xkIDk2ICAg
ICAgICAgICAgICAjIOaKiuafkOS4quiEmuaLiemrmOW5tuS/neaMge+8iOmFjeWQiCLnnIsgUko0
NSDnga8i5Yik5a6a5aSN5L2NL+S+m+eUteiEmu+8iQogIG1kaW8tc2NhbiBob2xkIDk2IGxvdyAg
ICAgICAgICAjIOaLieS9juW5tuS/neaMgQogIG1kaW8tc2NhbiBmcmVlIDk2ICAgICAgICAgICAg
ICAjIOaBouWkjeWIsCBob2xkIOS5i+WJjeeahOeKtuaAgQogIG1kaW8tc2NhbiBmcmVlIGFsbCAg
ICAgICAgICAgICAjIOaBouWkjeWFqOmDqO+8iEN0cmwtQyDmiZPmlq3lkI7ot5Hov5nkuKrmlLbl
sL7vvIkKICBtZGlvLXNjYW4gY3RsICAgICAgICAgICAgICAgICAgIyDpgJDkuKrmiorlronlhajo
hJrmi4npq5jvvIzlho3nnIsgRDEvRDAg5LiK5pyJ5rKh5pyJIFBIWSDlupTnrZQKICBtZGlvLXNj
YW4gc3dlZXAgICAgICAgICAgICAgICAgIyDnm7jpgrvlronlhajohJrlr7nmraPlj43mnoHmgKfm
iasgMH4377yI5Y+q5ZyoIGJhbmsz77yJCiAgbWRpby1zY2FuIGR1bXAgICAgICAgICAgICAgICAg
ICMg5omT5Y2wIDQg5LiqIGJhbmsg55qEIERSL0REUi9FWFQKIiIiCgppbXBvcnQgZ2xvYgppbXBv
cnQganNvbgppbXBvcnQgbW1hcAppbXBvcnQgb3MKaW1wb3J0IHN5cwppbXBvcnQgdGltZQoKR1BJ
T19CQVNFID0gWzB4MjAwMEEwMDAsIDB4MjAwM0MwMDAsIDB4MjAwM0UwMDAsIDB4MjAwODAwMDBd
CkdSRl9CQVNFID0gMHgyMDAwODAwMApSRUdfRFIgPSAweDAwClJFR19ERFIgPSAweDA0ClJFR19F
WFQgPSAweDUwClBBR0UgPSA0MDk2CgpEID0gM2UtNgpCQURfSURTID0gKDB4MDAwMDAwMDAsIDB4
MDAwMEZGRkYsIDB4RkZGRkZGRkYsIDB4RkZGRjAwMDAsIDB4MDAwMEZGRkUpCgpTVEFURV9GSUxF
ID0gIi90bXAvbWRpby1zY2FuLW9yaWcuanNvbiIKCiMg5pW057uE5ouJ6buR77yaYmFuazAg5pyJ
IFNQSSBGbGFzaCAvIFBNSUMoSTJDKe+8jGJhbmsxIOaciSBlTU1DIC8gVUFSVDIoY29uc29sZSkK
QkxBQ0tfQkFOS1MgPSAoMCwgMSkKIyBiYW5rMyDkuIrmraPlnKjooqvmiJHku6wgRFRTIOS9v+eU
qOeahOiEmu+8mkMwfkM3IOaYryBSTUlJ77yMRDAvRDEg5pivIE1EQy9NRElP77yM6YO95LiN5b2T
5o6n5Yi26ISaCkVNQUNfUk1JSSA9IHR1cGxlKHJhbmdlKDExMiwgMTIwKSkKTURJT19QSU5TID0g
KDEyMCwgMTIxKQoKCmRlZiBwaW5fbmFtZShudW0pOgogICAgYmFuayA9IG51bSAvLyAzMgogICAg
Z3JwID0gIkFCQ0QiWyhudW0gJSAzMikgLy8gOF0KICAgIGlkeCA9IG51bSAlIDgKICAgIHJldHVy
biAiR1BJTyVkXyVzJWQiICUgKGJhbmssIGdycCwgaWR4KQoKCmNsYXNzIE1lbShvYmplY3QpOgog
ICAgZGVmIF9faW5pdF9fKHNlbGYpOgogICAgICAgIHNlbGYuZmQgPSBvcy5vcGVuKCIvZGV2L21l
bSIsIG9zLk9fUkRXUiB8IG9zLk9fU1lOQykKICAgICAgICBzZWxmLm1hcHMgPSB7fQoKICAgIGRl
ZiBfcGFnZShzZWxmLCBhZGRyKToKICAgICAgICBiYXNlID0gYWRkciAmIH4oUEFHRSAtIDEpCiAg
ICAgICAgbSA9IHNlbGYubWFwcy5nZXQoYmFzZSkKICAgICAgICBpZiBtIGlzIE5vbmU6CiAgICAg
ICAgICAgIG0gPSBtbWFwLm1tYXAoc2VsZi5mZCwgUEFHRSwgbW1hcC5NQVBfU0hBUkVELAogICAg
ICAgICAgICAgICAgICAgICAgICAgIG1tYXAuUFJPVF9SRUFEIHwgbW1hcC5QUk9UX1dSSVRFLCBv
ZmZzZXQ9YmFzZSkKICAgICAgICAgICAgc2VsZi5tYXBzW2Jhc2VdID0gbQogICAgICAgIHJldHVy
biBtLCBhZGRyIC0gYmFzZQoKICAgIGRlZiByZChzZWxmLCBhZGRyKToKICAgICAgICBtLCBvID0g
c2VsZi5fcGFnZShhZGRyKQogICAgICAgIHJldHVybiBpbnQuZnJvbV9ieXRlcyhtW286byArIDRd
LCAibGl0dGxlIikKCiAgICBkZWYgd3Ioc2VsZiwgYWRkciwgdmFsKToKICAgICAgICBtLCBvID0g
c2VsZi5fcGFnZShhZGRyKQogICAgICAgIG1bbzpvICsgNF0gPSAodmFsICYgMHhGRkZGRkZGRiku
dG9fYnl0ZXMoNCwgImxpdHRsZSIpCgoKY2xhc3MgUGluKG9iamVjdCk6CiAgICBkZWYgX19pbml0
X18oc2VsZiwgbWVtLCBudW0pOgogICAgICAgIHNlbGYubWVtID0gbWVtCiAgICAgICAgc2VsZi5u
dW0gPSBudW0KICAgICAgICBzZWxmLmJhbmsgPSBudW0gLy8gMzIKICAgICAgICBzZWxmLmlkeCA9
IG51bSAlIDMyCiAgICAgICAgc2VsZi5iYXNlID0gR1BJT19CQVNFW3NlbGYuYmFua10KCiAgICBk
ZWYgc2V0X2RpcihzZWxmLCBvdXQpOgogICAgICAgIGEgPSBzZWxmLmJhc2UgKyBSRUdfRERSCiAg
ICAgICAgdiA9IHNlbGYubWVtLnJkKGEpCiAgICAgICAgaWYgb3V0OgogICAgICAgICAgICB2IHw9
ICgxIDw8IHNlbGYuaWR4KQogICAgICAgIGVsc2U6CiAgICAgICAgICAgIHYgJj0gfigxIDw8IHNl
bGYuaWR4KQogICAgICAgIHNlbGYubWVtLndyKGEsIHYpCgogICAgZGVmIHNldChzZWxmLCB2YWwp
OgogICAgICAgIGEgPSBzZWxmLmJhc2UgKyBSRUdfRFIKICAgICAgICB2ID0gc2VsZi5tZW0ucmQo
YSkKICAgICAgICBpZiB2YWw6CiAgICAgICAgICAgIHYgfD0gKDEgPDwgc2VsZi5pZHgpCiAgICAg
ICAgZWxzZToKICAgICAgICAgICAgdiAmPSB+KDEgPDwgc2VsZi5pZHgpCiAgICAgICAgc2VsZi5t
ZW0ud3IoYSwgdikKCiAgICBkZWYgZ2V0KHNlbGYpOgogICAgICAgIHJldHVybiAoc2VsZi5tZW0u
cmQoc2VsZi5iYXNlICsgUkVHX0VYVCkgPj4gc2VsZi5pZHgpICYgMQoKICAgIGRlZiBfaW9tdXhf
YWRkcl9iaXQoc2VsZik6CiAgICAgICAgb2ZmID0gMHg2MCArIChzZWxmLmJhbmsgKiA0ICsgc2Vs
Zi5pZHggLy8gOCkgKiA0CiAgICAgICAgcmV0dXJuIEdSRl9CQVNFICsgb2ZmLCAoc2VsZi5pZHgg
JSA4KSAqIDIKCiAgICBkZWYgbXV4X2dldChzZWxmKToKICAgICAgICBhLCBiID0gc2VsZi5faW9t
dXhfYWRkcl9iaXQoKQogICAgICAgIHJldHVybiAoc2VsZi5tZW0ucmQoYSkgPj4gYikgJiAzCgog
ICAgZGVmIG11eF9zZXQoc2VsZiwgdmFsKToKICAgICAgICBhLCBiID0gc2VsZi5faW9tdXhfYWRk
cl9iaXQoKQogICAgICAgIHYgPSBzZWxmLm1lbS5yZChhKQogICAgICAgIHNlbGYubWVtLndyKGEs
ICh2ICYgfigzIDw8IGIpKSB8ICgodmFsICYgMykgPDwgYikpCgogICAgZGVmIG11eF9ncGlvKHNl
bGYpOgogICAgICAgIHNlbGYubXV4X3NldCgwKQoKICAgIGRlZiBkaXJfb3V0KHNlbGYpOgogICAg
ICAgIHJldHVybiBib29sKChzZWxmLm1lbS5yZChzZWxmLmJhc2UgKyBSRUdfRERSKSA+PiBzZWxm
LmlkeCkgJiAxKQoKICAgIGRlZiBzbmFwc2hvdChzZWxmKToKICAgICAgICByZXR1cm4geyJtdXgi
OiBzZWxmLm11eF9nZXQoKSwgIm91dCI6IHNlbGYuZGlyX291dCgpLCAiZHIiOiBzZWxmLmdldCgp
fQoKICAgIGRlZiByZXN0b3JlKHNlbGYsIHMpOgogICAgICAgIHNlbGYubXV4X3NldChzWyJtdXgi
XSkKICAgICAgICBpZiBzWyJvdXQiXToKICAgICAgICAgICAgc2VsZi5zZXQoMSBpZiBzWyJkciJd
IGVsc2UgMCkKICAgICAgICAgICAgc2VsZi5zZXRfZGlyKFRydWUpCiAgICAgICAgZWxzZToKICAg
ICAgICAgICAgc2VsZi5zZXRfZGlyKEZhbHNlKQoKCmRlZiBsb2FkX3N0YXRlKCk6CiAgICB0cnk6
CiAgICAgICAgcmV0dXJuIGpzb24ubG9hZChvcGVuKFNUQVRFX0ZJTEUpKQogICAgZXhjZXB0IEV4
Y2VwdGlvbjoKICAgICAgICByZXR1cm4ge30KCgpkZWYgc2F2ZV9zdGF0ZShzdCk6CiAgICB0cnk6
CiAgICAgICAganNvbi5kdW1wKHN0LCBvcGVuKFNUQVRFX0ZJTEUsICJ3IikpCiAgICBleGNlcHQg
RXhjZXB0aW9uOgogICAgICAgIHBhc3MKCgpkZWYgcGFyc2VfYmFua3MoYXJncywgZGVmYXVsdD0o
MywpKToKICAgIGJhbmtzID0gZGVmYXVsdAogICAgaWYgIi0tYWxsIiBpbiBhcmdzOgogICAgICAg
IGJhbmtzID0gKDAsIDEsIDIsIDMpCiAgICBmb3IgYSBpbiBhcmdzOgogICAgICAgIGlmIGEuc3Rh
cnRzd2l0aCgiLS1iYW5rPSIpOgogICAgICAgICAgICBiYW5rcyA9IHR1cGxlKGludCh4KSBmb3Ig
eCBpbiBhLnNwbGl0KCI9IiwgMSlbMV0uc3BsaXQoIiwiKSkKICAgIHJldHVybiBiYW5rcwoKCmRl
ZiBoZWxkX3BpbnMoKToKICAgIG91dCA9IHNldCgpCiAgICBmb3IgayBpbiBsb2FkX3N0YXRlKCku
a2V5cygpOgogICAgICAgIGlmIHN0cihrKS5pc2RpZ2l0KCk6CiAgICAgICAgICAgIG91dC5hZGQo
aW50KGspKQogICAgcmV0dXJuIG91dAoKCmRlZiBzYWZlX3BpbnMobWVtLCBiYW5rcywgYW55X211
eD1GYWxzZSwgZm9yY2U9RmFsc2UsIHdpdGhfbWRpbz1UcnVlKToKICAgICIiIuiHquW3seivuyBp
b211eCDliKTmlq3vvJptdXg9PTDvvIjlvZPliY3lsLHmmK8gR1BJT++8ieS4lOWcqOWFgeiuuOea
hCBiYW5rIOWGheaJjei/lOWbnuOAggogICAgd2l0aF9tZGlvPVRydWUg5pe25oqKIEQwL0QxKDEy
MC8xMjEpIOS5n+eul+i/m+WAmemAiSDigJTigJQg5a6D5Lus5pivIE1EQy9NRElPIOeahOmmluim
geWrjOeWke+8jAogICAg5b+F6aG76IO96KKr5b2T5oiQIuW+hea1i+iEmuWvuSLnmoTkuIDpg6jl
iIbvvIjlj43mnoHmgKcgMTIwLzEyMSDku6XliY3ku47msqHmtYvov4fvvInjgIIiIiIKICAgIGhl
bGQgPSBoZWxkX3BpbnMoKQogICAgcGlucyA9IFtdCiAgICBmb3IgYiBpbiBiYW5rczoKICAgICAg
ICBpZiBiIGluIEJMQUNLX0JBTktTIGFuZCBub3QgZm9yY2U6CiAgICAgICAgICAgIGNvbnRpbnVl
CiAgICAgICAgZm9yIHAgaW4gcmFuZ2UoYiAqIDMyLCBiICogMzIgKyAzMik6CiAgICAgICAgICAg
IGlmIHAgaW4gRU1BQ19STUlJIG9yIHAgaW4gaGVsZDoKICAgICAgICAgICAgICAgIGNvbnRpbnVl
CiAgICAgICAgICAgIGlmIHAgaW4gTURJT19QSU5TIGFuZCBub3Qgd2l0aF9tZGlvOgogICAgICAg
ICAgICAgICAgY29udGludWUKICAgICAgICAgICAgaWYgbm90IGFueV9tdXggYW5kIFBpbihtZW0s
IHApLm11eF9nZXQoKSAhPSAwOgogICAgICAgICAgICAgICAgY29udGludWUKICAgICAgICAgICAg
cGlucy5hcHBlbmQocCkKICAgIHJldHVybiBzb3J0ZWQocGlucykKCgpNVVhfRklMRSA9ICIvdG1w
L21kaW8tc2Nhbi1tdXguanNvbiIKCgpkZWYgbG9hZF9tdXgoKToKICAgIHRyeToKICAgICAgICBy
ZXR1cm4ganNvbi5sb2FkKG9wZW4oTVVYX0ZJTEUpKQogICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAg
ICAgICByZXR1cm4ge30KCgpkZWYgc2F2ZV9tdXgoc3QpOgogICAgdHJ5OgogICAgICAgIGpzb24u
ZHVtcChzdCwgb3BlbihNVVhfRklMRSwgInciKSkKICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAg
ICAgcGFzcwoKCmRlZiBiYl9yZWFkKG1kYywgbWRpbywgcGh5LCByZWcpOgogICAgIiIi5qCH5YeG
IENsYXVzZSAyMiDor7vvvJpwcmVhbWJsZSArIFNUKDAxKSArIE9QKDEwKSArIFBIWUFEKDUpICsg
UkVHQUQoNSkgKyBUQSArIDE2IOaVsOaNruS9jSIiIgogICAgbWRpby5tdXhfZ3BpbygpCiAgICBt
ZGMubXV4X2dwaW8oKQogICAgbWRjLnNldF9kaXIoVHJ1ZSkKICAgIG1kYy5zZXQoMCkKICAgIG1k
aW8uc2V0X2RpcihUcnVlKQoKICAgIGRlZiBjbGtfd3JpdGUoYml0KToKICAgICAgICBtZGlvLnNl
dChiaXQpCiAgICAgICAgdGltZS5zbGVlcChEKQogICAgICAgIG1kYy5zZXQoMSkKICAgICAgICB0
aW1lLnNsZWVwKEQpCiAgICAgICAgbWRjLnNldCgwKQogICAgICAgIHRpbWUuc2xlZXAoRCkKCiAg
ICBmb3IgXyBpbiByYW5nZSgzMik6CiAgICAgICAgY2xrX3dyaXRlKDEpCgogICAgYml0cyA9IFsw
LCAxLCAxLCAwXQogICAgZm9yIGkgaW4gcmFuZ2UoNCwgLTEsIC0xKToKICAgICAgICBiaXRzLmFw
cGVuZCgocGh5ID4+IGkpICYgMSkKICAgIGZvciBpIGluIHJhbmdlKDQsIC0xLCAtMSk6CiAgICAg
ICAgYml0cy5hcHBlbmQoKHJlZyA+PiBpKSAmIDEpCiAgICBmb3IgYiBpbiBiaXRzOgogICAgICAg
IGNsa193cml0ZShiKQoKICAgIG1kaW8uc2V0X2RpcihGYWxzZSkKICAgIHRpbWUuc2xlZXAoRCkK
ICAgIG1kYy5zZXQoMSkKICAgIHRpbWUuc2xlZXAoRCkKICAgIG1kYy5zZXQoMCkKICAgIHRpbWUu
c2xlZXAoRCkKCiAgICB2YWwgPSAwCiAgICBmb3IgXyBpbiByYW5nZSgxNik6CiAgICAgICAgdGlt
ZS5zbGVlcChEKQogICAgICAgIG1kYy5zZXQoMSkKICAgICAgICB0aW1lLnNsZWVwKEQpCiAgICAg
ICAgdmFsID0gKHZhbCA8PCAxKSB8IG1kaW8uZ2V0KCkKICAgICAgICBtZGMuc2V0KDApCiAgICAg
ICAgdGltZS5zbGVlcChEKQogICAgcmV0dXJuIHZhbAoKCmRlZiBwaHlfaWQobWVtLCBtZGNfbnVt
LCBtZGlvX251bSwgYWRkcik6CiAgICBtZGMgPSBQaW4obWVtLCBtZGNfbnVtKQogICAgbWRpbyA9
IFBpbihtZW0sIG1kaW9fbnVtKQogICAgaGkgPSBiYl9yZWFkKG1kYywgbWRpbywgYWRkciwgMikK
ICAgIGxvID0gYmJfcmVhZChtZGMsIG1kaW8sIGFkZHIsIDMpCiAgICByZXR1cm4gKGhpIDw8IDE2
KSB8IGxvCgoKZGVmIGlzX3ZhbGlkKHBpZCk6CiAgICBpZiBwaWQgaW4gQkFEX0lEUzoKICAgICAg
ICByZXR1cm4gRmFsc2UKICAgIGhpID0gKHBpZCA+PiAxNikgJiAweEZGRkYKICAgIGxvID0gcGlk
ICYgMHhGRkZGCiAgICBpZiBoaSBpbiAoMHgwMDAwLCAweEZGRkYpIGFuZCBsbyBpbiAoMHgwMDAw
LCAweEZGRkYpOgogICAgICAgIHJldHVybiBGYWxzZQogICAgcmV0dXJuIFRydWUKCgpkZWYgY21k
X3BpbihtZW0sIGFyZ3MpOgogICAgZm9yIGEgaW4gYXJnczoKICAgICAgICBwID0gUGluKG1lbSwg
aW50KGEpKQogICAgICAgIHByaW50KCJwaW4gJS0zZCAlLTEwcyBtdXg9JWQgZGlyPSVzIGxldmVs
PSVkIiAlICgKICAgICAgICAgICAgcC5udW0sIHBpbl9uYW1lKHAubnVtKSwgcC5tdXhfZ2V0KCks
CiAgICAgICAgICAgICJvdXQiIGlmIHAuZGlyX291dCgpIGVsc2UgImluIiwgcC5nZXQoKSkpCiAg
ICByZXR1cm4gMAoKCmRlZiBjbWRfc2FmZShtZW0sIGFyZ3MpOgogICAgYmFua3MgPSBwYXJzZV9i
YW5rcyhhcmdzKQogICAgYW55X211eCA9ICItLWFueSIgaW4gYXJncwogICAgZm9yY2UgPSAiLS1m
b3JjZSIgaW4gYXJncwogICAgcGlucyA9IHNhZmVfcGlucyhtZW0sIGJhbmtzLCBhbnlfbXV4LCBm
b3JjZSkKICAgIGlmICItLWxpc3QiIGluIGFyZ3M6CiAgICAgICAgZm9yIHAgaW4gcGluczoKICAg
ICAgICAgICAgcHJpbnQocCkKICAgICAgICByZXR1cm4gMAogICAgcHJpbnQoImJhbmsgJXMg6YeM
5Y+v5a6J5YWo5pON5L2c55qE5byV6ISa5YWxICVkIOS4qu+8iG11eD09MCDkuJTmnKrooqvmjpLp
maTvvInvvJoiICUgKAogICAgICAgICIsIi5qb2luKHN0cihiKSBmb3IgYiBpbiBiYW5rcyksIGxl
bihwaW5zKSkpCiAgICBmb3IgcCBpbiBwaW5zOgogICAgICAgIHEgPSBQaW4obWVtLCBwKQogICAg
ICAgIHByaW50KCIgICUtM2QgJS0xMHMgbXV4PSVkIGRpcj0lcyBsZXZlbD0lZCIgJSAoCiAgICAg
ICAgICAgIHAsIHBpbl9uYW1lKHApLCBxLm11eF9nZXQoKSwgIm91dCIgaWYgcS5kaXJfb3V0KCkg
ZWxzZSAiaW4iLCBxLmdldCgpKSkKICAgIGlmIG5vdCBwaW5zOgogICAgICAgIHByaW50KCIgIO+8
iOS4gOS4qumDveayoeacieOAguWPr+iDvei/meS6myBiYW5rIOeahOiEmuWFqOiiq+WNoOeUqOS6
hu+8jOivleivlSAtLWJhbms9MiDmiJYgLS1hbnnvvIkiKQogICAgcmV0dXJuIDAKCgpkZWYgY21k
X3NjYW4obWVtLCBhcmdzKToKICAgIG51bXMgPSBbaW50KGEpIGZvciBhIGluIGFyZ3MgaWYgYS5p
c2RpZ2l0KCldCiAgICBtZGNfbnVtID0gbnVtc1swXSBpZiBsZW4obnVtcykgPj0gMSBlbHNlIDEy
MQogICAgbWRpb19udW0gPSBudW1zWzFdIGlmIGxlbihudW1zKSA+PSAyIGVsc2UgMTIwCiAgICBs
byA9IG51bXNbMl0gaWYgbGVuKG51bXMpID49IDMgZWxzZSAwCiAgICBoaSA9IG51bXNbM10gaWYg
bGVuKG51bXMpID49IDQgZWxzZSA3CiAgICBwcmludCgi5omrICVzKE1EQykgLyAlcyhNRElPKSDl
nLDlnYAgJWR+JWQiICUgKAogICAgICAgIHBpbl9uYW1lKG1kY19udW0pLCBwaW5fbmFtZShtZGlv
X251bSksIGxvLCBoaSkpCiAgICBoaXQgPSAwCiAgICBmb3IgYWRkciBpbiByYW5nZShsbywgaGkg
KyAxKToKICAgICAgICBwaWQgPSBwaHlfaWQobWVtLCBtZGNfbnVtLCBtZGlvX251bSwgYWRkcikK
ICAgICAgICBmbGFnID0gIiAgPD09IOacieW6lOetlCIgaWYgaXNfdmFsaWQocGlkKSBlbHNlICIi
CiAgICAgICAgcHJpbnQoIiAgYWRkciAlZCA6IGlkPTB4JTA4WCVzIiAlIChhZGRyLCBwaWQsIGZs
YWcpKQogICAgICAgIGlmIGlzX3ZhbGlkKHBpZCk6CiAgICAgICAgICAgIGhpdCArPSAxCiAgICBw
cmludCgi5ZCI6K6h5ZG95LitICVkIOS4quWcsOWdgOOAgiIgJSBoaXQpCiAgICByZXR1cm4gaGl0
CgoKZGVmIGNtZF9zd2VlcChtZW0sIGFyZ3MpOgogICAgYmFua3MgPSBwYXJzZV9iYW5rcyhhcmdz
KQogICAgYWRqID0gIi0tYWRqIiBpbiBhcmdzCiAgICBwaW5zID0gc2FmZV9waW5zKG1lbSwgYmFu
a3MpCiAgICBwYWlycyA9IFtdCiAgICBpZiBhZGo6CiAgICAgICAgZm9yIHAgaW4gcGluczoKICAg
ICAgICAgICAgaWYgcCArIDEgaW4gcGluczoKICAgICAgICAgICAgICAgIHBhaXJzLmFwcGVuZCgo
cCwgcCArIDEpKQogICAgICAgICAgICAgICAgcGFpcnMuYXBwZW5kKChwICsgMSwgcCkpCiAgICAg
ICAgcHJpbnQoImJhbmsgJXMg5YaF55u46YK75a6J5YWo6ISa5a+5ICVkIOe7hO+8iOWQq+ato+WP
jeaegeaAp++8ie+8jOW8gOWni+aJq+aPjyAuLi4iICUgKAogICAgICAgICAgICAiLCIuam9pbihz
dHIoYikgZm9yIGIgaW4gYmFua3MpLCBsZW4ocGFpcnMpKSkKICAgIGVsc2U6CiAgICAgICAgZm9y
IGEgaW4gcGluczoKICAgICAgICAgICAgZm9yIGIgaW4gcGluczoKICAgICAgICAgICAgICAgIGlm
IGEgIT0gYjoKICAgICAgICAgICAgICAgICAgICBwYWlycy5hcHBlbmQoKGEsIGIpKQogICAgICAg
IHByaW50KCJiYW5rICVzIOWGhSAlZCDlj6rlgJnpgInohJrnmoTkuKTkuKTnu4TlkIggJWQg57uE
77yI5ZCr5q2j5Y+N5p6B5oCn77yJ77yM5byA5aeL5omr5o+PIC4uLiIgJSAoCiAgICAgICAgICAg
ICIsIi5qb2luKHN0cihiKSBmb3IgYiBpbiBiYW5rcyksIGxlbihwaW5zKSwgbGVuKHBhaXJzKSkp
CiAgICAgICAgcHJpbnQoIue6pumcgCAzMH42MCDnp5LvvIzov5vluqbooYzkvJrkuIDnm7TliLfm
lrDvvIzlkb3kuK3kvJrlgZzkuIvmnaXmiZPljbDjgIIiKQogICAgaWYgbm90IHBhaXJzOgogICAg
ICAgIHByaW50KCLmsqHmnInlj6/miavnmoTnm7jpgrvohJrlr7nvvIznm7TmjqXpgIDlh7rjgIIi
KQogICAgICAgIHJldHVybiAwCiAgICBoaXRzID0gW10KICAgIGZvciBuLCAoYSwgYikgaW4gZW51
bWVyYXRlKHBhaXJzKToKICAgICAgICBzeXMuc3Rkb3V0LndyaXRlKCJcciAgWyVkLyVkXSBNREM9
JWQgTURJTz0lZCAgICAgICIgJSAobiArIDEsIGxlbihwYWlycyksIGEsIGIpKQogICAgICAgIHN5
cy5zdGRvdXQuZmx1c2goKQogICAgICAgIGZvciBhZGRyIGluIHJhbmdlKDgpOgogICAgICAgICAg
ICBwaWQgPSBwaHlfaWQobWVtLCBhLCBiLCBhZGRyKQogICAgICAgICAgICBpZiBpc192YWxpZChw
aWQpOgogICAgICAgICAgICAgICAgaGl0cy5hcHBlbmQoKGEsIGIsIGFkZHIsIHBpZCkpCiAgICBw
cmludCgiIikKICAgIGlmIG5vdCBoaXRzOgogICAgICAgIHByaW50KCLnu5PmnpzvvJrmsqHmnInk
u7vkvZXkuIDlr7kgKyDku7vkvZXlnLDlnYDmnInlupTnrZTjgIIiKQogICAgZWxzZToKICAgICAg
ICBwcmludCgi57uT5p6c77ya5om+5YiwICVkIOWkhOW6lOetlO+8miIgJSBsZW4oaGl0cykpCiAg
ICAgICAgZm9yIGEsIGIsIGFkZHIsIHBpZCBpbiBoaXRzOgogICAgICAgICAgICBwcmludCgiICBN
REM9JXMoJWQpIE1ESU89JXMoJWQpIFBIWeWcsOWdgD0lZCBpZD0weCUwOFgiICUgKAogICAgICAg
ICAgICAgICAgcGluX25hbWUoYSksIGEsIHBpbl9uYW1lKGIpLCBiLCBhZGRyLCBwaWQpKQogICAg
cmV0dXJuIGxlbihoaXRzKQoKCmRlZiBjbWRfY3RsKG1lbSwgYXJncyk6CiAgICBiYW5rcyA9IHBh
cnNlX2JhbmtzKGFyZ3MpCiAgICBudW1zID0gW2ludChhKSBmb3IgYSBpbiBhcmdzIGlmIGEuaXNk
aWdpdCgpXQogICAgbWRjX251bSA9IG51bXNbMF0gaWYgbGVuKG51bXMpID49IDEgZWxzZSAxMjEK
ICAgIG1kaW9fbnVtID0gbnVtc1sxXSBpZiBsZW4obnVtcykgPj0gMiBlbHNlIDEyMAogICAgcGlu
cyA9IHNhZmVfcGlucyhtZW0sIGJhbmtzKQogICAgcHJpbnQoImJhbmsgJXPvvJolcy8lcyDkuIrl
hYjmiavkuIDpgY3ln7rnur8gLi4uIiAlICgKICAgICAgICAiLCIuam9pbihzdHIoYikgZm9yIGIg
aW4gYmFua3MpLCBwaW5fbmFtZShtZGNfbnVtKSwgcGluX25hbWUobWRpb19udW0pKSkKICAgIGZv
ciBhZGRyIGluIHJhbmdlKDgpOgogICAgICAgIHBpZCA9IHBoeV9pZChtZW0sIG1kY19udW0sIG1k
aW9fbnVtLCBhZGRyKQogICAgICAgIHByaW50KCIgIOWfuue6vyBhZGRyICVkIDogaWQ9MHglMDhY
IiAlIChhZGRyLCBwaWQpKQogICAgaWYgbm90IHBpbnM6CiAgICAgICAgcHJpbnQoIuayoeacieWP
r+aTjeS9nOeahOaOp+WItuiEmu+8jOmAgOWHuu+8iOWFiOi3kSBtZGlvLXNjYW4gc2FmZe+8ieOA
giIpCiAgICAgICAgcmV0dXJuIDAKICAgIHByaW50KCLpgJDkuKrmioogJWQg5Liq5a6J5YWo6ISa
5ouJ6auY77yM5ZCM5pe25omrIDB+NyAuLi4iICUgbGVuKHBpbnMpKQogICAgaGl0cyA9IFtdCiAg
ICBmb3IgbiwgcCBpbiBlbnVtZXJhdGUocGlucyk6CiAgICAgICAgc3lzLnN0ZG91dC53cml0ZSgi
XHIgIFslZC8lZF0g5ouJ6auYICVkICglcykgICAgICAiICUgKG4gKyAxLCBsZW4ocGlucyksIHAs
IHBpbl9uYW1lKHApKSkKICAgICAgICBzeXMuc3Rkb3V0LmZsdXNoKCkKICAgICAgICBjdGwgPSBQ
aW4obWVtLCBwKQogICAgICAgIG9yaWcgPSBjdGwuc25hcHNob3QoKQogICAgICAgIGN0bC5tdXhf
Z3BpbygpCiAgICAgICAgY3RsLnNldF9kaXIoVHJ1ZSkKICAgICAgICBjdGwuc2V0KDEpCiAgICAg
ICAgZm9yIGFkZHIgaW4gcmFuZ2UoOCk6CiAgICAgICAgICAgIHBpZCA9IHBoeV9pZChtZW0sIG1k
Y19udW0sIG1kaW9fbnVtLCBhZGRyKQogICAgICAgICAgICBpZiBpc192YWxpZChwaWQpOgogICAg
ICAgICAgICAgICAgaGl0cy5hcHBlbmQoKHAsIGFkZHIsIHBpZCkpCiAgICAgICAgY3RsLnJlc3Rv
cmUob3JpZykKICAgIHByaW50KCIiKQogICAgaWYgbm90IGhpdHM6CiAgICAgICAgcHJpbnQoIue7
k+aenO+8mui/mSAlZCDkuKrohJrpgJDkuKrmi4npq5jvvIxEMS9EMCDkuIrpg73msqHmnIkgUEhZ
IOW6lOetlOOAgiIgJSBsZW4ocGlucykpCiAgICBlbHNlOgogICAgICAgIHByaW50KCLnu5Pmnpzv
vJrmib7liLAgJWQg5aSE5bqU562U77yaIiAlIGxlbihoaXRzKSkKICAgICAgICBmb3IgcCwgYWRk
ciwgcGlkIGluIGhpdHM6CiAgICAgICAgICAgIHByaW50KCIgIOaOp+WItuiEmj0lcyglZCkgUEhZ
5Zyw5Z2APSVkIGlkPTB4JTA4WCIgJSAocGluX25hbWUocCksIHAsIGFkZHIsIHBpZCkpCiAgICBy
ZXR1cm4gbGVuKGhpdHMpCgoKZGVmIGNtZF9ob2xkKG1lbSwgYXJncyk6CiAgICBudW1zID0gW2lu
dChhKSBmb3IgYSBpbiBhcmdzIGlmIGEuaXNkaWdpdCgpXQogICAgbG93ID0gImxvdyIgaW4gYXJn
cwogICAgZm9yIG4gaW4gbnVtczoKICAgICAgICBpZiBuIC8vIDMyIGluIEJMQUNLX0JBTktTOgog
ICAgICAgICAgICBwcmludCgi5ouS57ud77yaR1BJTyVkIOaYr+mXquWtmC9QTUlDL2VNTUMvVUFS
VCDljLrvvIzkuI3lhYHorrjliqjjgIIiICUgKG4gLy8gMzIpKQogICAgICAgICAgICBjb250aW51
ZQogICAgICAgIHAgPSBQaW4obWVtLCBuKQogICAgICAgIHN0ID0gbG9hZF9zdGF0ZSgpCiAgICAg
ICAga2V5ID0gc3RyKG4pCiAgICAgICAgaWYga2V5IG5vdCBpbiBzdDoKICAgICAgICAgICAgc3Rb
a2V5XSA9IHAuc25hcHNob3QoKQogICAgICAgICAgICBzYXZlX3N0YXRlKHN0KQogICAgICAgIHAu
bXV4X2dwaW8oKQogICAgICAgIHAuc2V0KDAgaWYgbG93IGVsc2UgMSkKICAgICAgICBwLnNldF9k
aXIoVHJ1ZSkKICAgICAgICBwcmludCgi5bey5oqKICVzKCVkKSDmi4klc+W5tuS/neaMgei+k+WH
uuOAgueciyBSSjQ1IOeBr++8m+S4jeS6ruWwsSBtZGlvLXNjYW4gZnJlZSAlZOOAguWOn+eKtuaA
gT0lcyIgJSAoCiAgICAgICAgICAgIHBpbl9uYW1lKG4pLCBuLCAi5L2OIiBpZiBsb3cgZWxzZSAi
6auYIiwgbiwgc3Rba2V5XSkpCiAgICByZXR1cm4gMAoKCmRlZiBjbWRfZnJlZShtZW0sIGFyZ3Mp
OgogICAgc3QgPSBsb2FkX3N0YXRlKCkKICAgIGlmICJhbGwiIGluIGFyZ3M6CiAgICAgICAgbXN0
ID0gbG9hZF9tdXgoKQogICAgICAgIGZvciBrIGluIGxpc3QobXN0LmtleXMoKSk6CiAgICAgICAg
ICAgIFBpbihtZW0sIGludChrKSkubXV4X3NldChtc3Rba10pCiAgICAgICAgICAgIHByaW50KCLl
t7LmgaLlpI0gJXMoJWQpIGlvbXV4IC0+ICVkIiAlIChwaW5fbmFtZShpbnQoaykpLCBpbnQoayks
IG1zdFtrXSkpCiAgICAgICAgc2F2ZV9tdXgoe30pCiAgICAgICAgZm9yIGsgaW4gbGlzdChzdC5r
ZXlzKCkpOgogICAgICAgICAgICBQaW4obWVtLCBpbnQoaykpLnJlc3RvcmUoc3Rba10pCiAgICAg
ICAgICAgIHByaW50KCLlt7LmgaLlpI0gJXMoJWQpIC0+ICVzIiAlIChwaW5fbmFtZShpbnQoaykp
LCBpbnQoayksIHN0W2tdKSkKICAgICAgICBzYXZlX3N0YXRlKHt9KQogICAgICAgIHJldHVybiAw
CiAgICBmb3IgYSBpbiBhcmdzOgogICAgICAgIG4gPSBpbnQoYSkKICAgICAgICBwID0gUGluKG1l
bSwgbikKICAgICAgICBpZiBzdHIobikgaW4gc3Q6CiAgICAgICAgICAgIHAucmVzdG9yZShzdFtz
dHIobildKQogICAgICAgICAgICBwcmludCgi5bey5oqKICVzKCVkKSDmgaLlpI3liLAgaG9sZCDk
uYvliY3vvJolcyIgJSAocGluX25hbWUobiksIG4sIHN0W3N0cihuKV0pKQogICAgICAgICAgICBk
ZWwgc3Rbc3RyKG4pXQogICAgICAgICAgICBzYXZlX3N0YXRlKHN0KQogICAgICAgIGVsc2U6CiAg
ICAgICAgICAgIHAuc2V0KDApCiAgICAgICAgICAgIHAuc2V0X2RpcihGYWxzZSkKICAgICAgICAg
ICAgcHJpbnQoIuW3suaKiiAlcyglZCkg5pS+5byA77yI6L6T5YWl44CB5L2O55S15bmz77yJ44CC
IiAlIChwaW5fbmFtZShuKSwgbikpCiAgICByZXR1cm4gMAoKCmRlZiBjbWRfd2FrZShtZW0sIGFy
Z3MpOgogICAgIiIi5YWI57uZIFBIWSDkvb/og73ohJrvvIjpu5jorqQgR1BJTzNfRDI9MTIy77yJ
5LiK55S15bm25L+d5oyB77yM5YaN5omrIEQxL0QwIOeahCAwfjfjgIIKICAgIOi/meadoeWRveS7
pOWwseaYryJ0dGwtMjMg5Y+R546w55qE6YKj5Y+q6ISaICsg56uL5Yi75om+5Zyw5Z2AIueahOWQ
iOW5tueJiO+8jDEyMiDkvJrkuIDnm7Tkv53mjIHpq5jnlLXlubPvvIwKICAgIOe7k+adn+WQjuWP
r+S7peeUqCBtZGlvLXNjYW4gZnJlZSAxMjIg5pS+5byA44CCIiIiCiAgICBudW1zID0gW2ludChh
KSBmb3IgYSBpbiBhcmdzIGlmIGEuaXNkaWdpdCgpXQogICAgZW4gPSBudW1zWzBdIGlmIGxlbihu
dW1zKSA+PSAxIGVsc2UgMTIyCiAgICBtZGNfbnVtID0gbnVtc1sxXSBpZiBsZW4obnVtcykgPj0g
MiBlbHNlIDEyMQogICAgbWRpb19udW0gPSBudW1zWzJdIGlmIGxlbihudW1zKSA+PSAzIGVsc2Ug
MTIwCiAgICBwID0gUGluKG1lbSwgZW4pCiAgICBzdCA9IGxvYWRfc3RhdGUoKQogICAga2V5ID0g
c3RyKGVuKQogICAgaWYga2V5IG5vdCBpbiBzdDoKICAgICAgICBzdFtrZXldID0gcC5zbmFwc2hv
dCgpCiAgICAgICAgc2F2ZV9zdGF0ZShzdCkKICAgICAgICBwcmludCgi5L2/6IO96ISaICVzKCVk
KSDljp/nirbmgIE9JXMiICUgKHBpbl9uYW1lKGVuKSwgZW4sIHN0W2tleV0pKQogICAgcC5tdXhf
Z3BpbygpCiAgICBwLnNldCgxKQogICAgcC5zZXRfZGlyKFRydWUpCiAgICBpZiAiLS1jbGsiIGlu
IGFyZ3M6CiAgICAgICAgYyA9IFBpbihtZW0sIDExNykKICAgICAgICBtc3QgPSBsb2FkX211eCgp
CiAgICAgICAgaWYgIjExNyIgbm90IGluIG1zdDoKICAgICAgICAgICAgbXN0WyIxMTciXSA9IGMu
bXV4X2dldCgpCiAgICAgICAgICAgIHNhdmVfbXV4KG1zdCkKICAgICAgICBjLm11eF9zZXQoMikK
ICAgICAgICBwcmludCgiR1BJTzNfQzUoMTE3KSBpb211eCAwIC0+IDLvvIhybWlpX2Nsa291dO+8
jOe7mSBQSFkg6YCBIDUwTUh677yJ77yM5Y6f5YC8PSVkIiAlIG1zdFsiMTE3Il0pCiAgICB0aW1l
LnNsZWVwKDAuMykKICAgIHByaW50KCLlt7LmioogJXMoJWQpIOaLiemrmO+8iFBIWSDkuIrnlLXv
vInvvIznrYkgMzAwbXPvvIzlvIDlp4vmiasgJXMvJXMg55qEIDB+NyAuLi4iICUgKAogICAgICAg
IHBpbl9uYW1lKGVuKSwgZW4sIHBpbl9uYW1lKG1kY19udW0pLCBwaW5fbmFtZShtZGlvX251bSkp
KQogICAgaGl0cyA9IFtdCiAgICBmb3IgYWRkciBpbiByYW5nZSg4KToKICAgICAgICBwaWQgPSBw
aHlfaWQobWVtLCBtZGNfbnVtLCBtZGlvX251bSwgYWRkcikKICAgICAgICBvayA9IGlzX3ZhbGlk
KHBpZCkKICAgICAgICBwcmludCgiICBhZGRyICVkIDogaWQ9MHglMDhYJXMiICUgKGFkZHIsIHBp
ZCwgIiAgPD09IOacieW6lOetlCIgaWYgb2sgZWxzZSAiIikpCiAgICAgICAgaWYgb2s6CiAgICAg
ICAgICAgIGhpdHMuYXBwZW5kKChhZGRyLCBwaWQpKQogICAgaWYgbm90IGhpdHM6CiAgICAgICAg
cHJpbnQoIue7k+aenO+8mlBIWSDlt7LkuIrnlLXkvYYgMH43IOWFqOaXoOW6lOetlCDigJTigJQg
6K+05piOIE1EQy9NRElPIOS4jeWcqCBEMS9EMO+8jCIpCiAgICAgICAgcHJpbnQoIiAgICAgIOaO
peedgOi3kSBtZGlvLXNjYW4gc3dlZXDvvIjkvJroh6rliqjot7Pov4fooqsgaG9sZCDnmoTohJrv
vInljrvmib7nnJ/mraPnmoQgTURDL01ESU8g6ISa5a+544CCIikKICAgIGVsc2U6CiAgICAgICAg
cHJpbnQoIue7k+aenO+8mlBIWSDlnLDlnYAgPSAlZO+8iGlkPTB4JTA4WO+8ieOAguS4i+S4gOat
pSBtZGlvLXNjYW4gcmVncyAlZCDlpI3or7vlr4TlrZjlmajnoa7orqTjgIIiICUgKAogICAgICAg
ICAgICBoaXRzWzBdWzBdLCBoaXRzWzBdWzFdLCBoaXRzWzBdWzBdKSkKICAgICAgICBwcmludCgi
ICAgICAgJXMoJWQpIOS/neaMgemrmOeUteW5s++8jOe7k+adn+aXtiBtZGlvLXNjYW4gZnJlZSAl
ZOOAgiIgJSAoCiAgICAgICAgICAgIHBpbl9uYW1lKGVuKSwgZW4sIGVuKSkKICAgIHJldHVybiBs
ZW4oaGl0cykKCgpkZWYgY21kX211eChtZW0sIGFyZ3MpOgogICAgIiIi55u05o6l5pS55p+Q5Y+q
6ISa55qEIGlvbXV4IOWAvO+8iDA9R1BJT++8jDEvMi8zPeivpeiEmueahOWKn+iDveWPt++8ieOA
guWPquWFgeiuuCBiYW5rMi9iYW5rM+OAgiIiIgogICAgbnVtcyA9IFtpbnQoYSkgZm9yIGEgaW4g
YXJncyBpZiBhLmlzZGlnaXQoKV0KICAgIGlmIGxlbihudW1zKSA8IDI6CiAgICAgICAgcHJpbnQo
IueUqOazle+8mm1kaW8tc2NhbiBtdXggPOiEmuWPtz4gPOWAvD4gICDkvovlpoIgbWRpby1zY2Fu
IG11eCAxMTcgMiIpCiAgICAgICAgcmV0dXJuIDEKICAgIG4sIHZhbCA9IG51bXNbMF0sIG51bXNb
MV0KICAgIGlmIG4gLy8gMzIgaW4gQkxBQ0tfQkFOS1MgYW5kICItLWZvcmNlIiBub3QgaW4gYXJn
czoKICAgICAgICBwcmludCgi5ouS57ud77yaR1BJTyVkIOaYr+mXquWtmC9QTUlDL2VNTUMg5Yy6
77yM5LiN5YWB6K645pS5IGlvbXV444CCIiAlIChuIC8vIDMyKSkKICAgICAgICByZXR1cm4gMQog
ICAgcCA9IFBpbihtZW0sIG4pCiAgICBtc3QgPSBsb2FkX211eCgpCiAgICBrZXkgPSBzdHIobikK
ICAgIGlmIGtleSBub3QgaW4gbXN0OgogICAgICAgIG1zdFtrZXldID0gcC5tdXhfZ2V0KCkKICAg
ICAgICBzYXZlX211eChtc3QpCiAgICBwLm11eF9zZXQodmFsKQogICAgcHJpbnQoIiVzKCVkKSBp
b211eCAlZCAtPiAlZO+8iOWOn+WAvCAlZO+8jOWPr+eUqCBtZGlvLXNjYW4gZnJlZSBhbGwg5oGi
5aSN77yJIiAlICgKICAgICAgICBwaW5fbmFtZShuKSwgbiwgbXN0W2tleV0sIHZhbCwgbXN0W2tl
eV0pKQogICAgcmV0dXJuIDAKCgpkZWYgY21kX3JlZ3MobWVtLCBhcmdzKToKICAgICIiIuivu+af
kOS4qiBQSFkg5Zyw5Z2A55qEIDB+NSDlj7flr4TlrZjlmajvvIznlKjkuo7noa7orqQgUEhZIOec
n+eahOa0u+edgOOAgiIiIgogICAgbnVtcyA9IFtpbnQoYSkgZm9yIGEgaW4gYXJncyBpZiBhLmlz
ZGlnaXQoKV0KICAgIGFkZHIgPSBudW1zWzBdIGlmIGxlbihudW1zKSA+PSAxIGVsc2UgMAogICAg
bWRjX251bSA9IG51bXNbMV0gaWYgbGVuKG51bXMpID49IDIgZWxzZSAxMjEKICAgIG1kaW9fbnVt
ID0gbnVtc1syXSBpZiBsZW4obnVtcykgPj0gMyBlbHNlIDEyMAogICAgbmFtZXMgPSBbIkJNQ1Ii
LCAiQk1TUiIsICJQSFlJRDEiLCAiUEhZSUQyIiwgIkFOQVIiLCAiQU5MUEFSIl0KICAgIHByaW50
KCLor7sgJXMvJXMg5LiKIFBIWSDlnLDlnYAgJWQg55qE5a+E5a2Y5Zmo77yaIiAlICgKICAgICAg
ICBwaW5fbmFtZShtZGNfbnVtKSwgcGluX25hbWUobWRpb19udW0pLCBhZGRyKSkKICAgIHZhbHMg
PSBbXQogICAgZm9yIHIgaW4gcmFuZ2UoNik6CiAgICAgICAgdiA9IGJiX3JlYWQoUGluKG1lbSwg
bWRjX251bSksIFBpbihtZW0sIG1kaW9fbnVtKSwgYWRkciwgcikKICAgICAgICB2YWxzLmFwcGVu
ZCh2KQogICAgICAgIHByaW50KCIgIHJlZyVkICUtN3MgPSAweCUwNFgiICUgKHIsIG5hbWVzW3Jd
LCB2KSkKICAgIHBpZCA9ICh2YWxzWzJdIDw8IDE2KSB8IHZhbHNbM10KICAgIHByaW50KCIgIFBI
WSBJRCA9IDB4JTA4WCVzIiAlIChwaWQsICIgIDw9PSDmnInmlYgiIGlmIGlzX3ZhbGlkKHBpZCkg
ZWxzZSAiICA8PT0g5peg5pWIL+aXoOW6lOetlCIpKQogICAgaWYgaXNfdmFsaWQocGlkKToKICAg
ICAgICBwcmludCgiICBPVUk9MHglMDZYICDlnovlj7c9MHglMDNYICDniYjmnKw9JWQiICUgKAog
ICAgICAgICAgICAocGlkID4+IDEwKSAmIDB4RkZGRkZGLCAocGlkID4+IDQpICYgMHgzRiwgcGlk
ICYgMHhGKSkKICAgICAgICBpZiAocGlkID4+IDEwKSAmIDB4RkZGRkZGID09IDB4MDAxQ0MwOgog
ICAgICAgICAgICBwcmludCgiICBPVUkgMHgwMDFDQzAgPSBSZWFsdGVr77yM5LiO5L2g5p2/5LiK
55qEIFJUTDgyMDFGTiDlkLvlkIgiKQogICAgYm1zciA9IHZhbHNbMV0KICAgIGlmIGlzX3ZhbGlk
KHBpZCk6CiAgICAgICAgcHJpbnQoIiAgQk1TUjog6ZO+6LevPSVzIOiHquWNj+WVhuWujOaIkD0l
cyAxME09JXMgMTAwTT0lcyIgJSAoCiAgICAgICAgICAgICJ1cCIgaWYgYm1zciAmIDB4MDAwNCBl
bHNlICJkb3duIiwKICAgICAgICAgICAgIuaYryIgaWYgYm1zciAmIDB4MDAyMCBlbHNlICLlkKYi
LAogICAgICAgICAgICAi5pSv5oyBIiBpZiBibXNyICYgMHgwODAwIGVsc2UgIuS4jeaUr+aMgSIs
CiAgICAgICAgICAgICLmlK/mjIEiIGlmIGJtc3IgJiAweDEwMDAgZWxzZSAi5LiN5pSv5oyBIikp
CiAgICByZXR1cm4gMAoKCmRlZiBjbWRfZHVtcChtZW0sIGFyZ3MpOgogICAgZm9yIGIsIGJhc2Ug
aW4gZW51bWVyYXRlKEdQSU9fQkFTRSk6CiAgICAgICAgcHJpbnQoIkdQSU8lZCBiYXNlPTB4JTA4
WCBEUj0weCUwOFggRERSPTB4JTA4WCBFWFQ9MHglMDhYIiAlICgKICAgICAgICAgICAgYiwgYmFz
ZSwKICAgICAgICAgICAgbWVtLnJkKGJhc2UgKyBSRUdfRFIpLCBtZW0ucmQoYmFzZSArIFJFR19E
RFIpLCBtZW0ucmQoYmFzZSArIFJFR19FWFQpKSkKICAgIHJldHVybiAwCgoKQ01EUyA9IHsKICAg
ICJwaW4iOiBjbWRfcGluLAogICAgInNhZmUiOiBjbWRfc2FmZSwKICAgICJzY2FuIjogY21kX3Nj
YW4sCiAgICAic3dlZXAiOiBjbWRfc3dlZXAsCiAgICAiY3RsIjogY21kX2N0bCwKICAgICJob2xk
IjogY21kX2hvbGQsCiAgICAiZnJlZSI6IGNtZF9mcmVlLAogICAgIndha2UiOiBjbWRfd2FrZSwK
ICAgICJtdXgiOiBjbWRfbXV4LAogICAgInJlZ3MiOiBjbWRfcmVncywKICAgICJkdW1wIjogY21k
X2R1bXAsCn0KCgpkZWYgbWFpbigpOgogICAgaWYgbGVuKHN5cy5hcmd2KSA8IDIgb3Igc3lzLmFy
Z3ZbMV0gbm90IGluIENNRFM6CiAgICAgICAgcHJpbnQoX19kb2NfXyBvciAiIikKICAgICAgICBw
cmludCgi5Y+v55So5ZG95Luk77yaIiArICIgLyAiLmpvaW4oc29ydGVkKENNRFMpKSkKICAgICAg
ICByZXR1cm4gMgogICAgbWVtID0gTWVtKCkKICAgIHIgPSBDTURTW3N5cy5hcmd2WzFdXShtZW0s
IHN5cy5hcmd2WzI6XSkKICAgIGlmIHIgaXMgTm9uZToKICAgICAgICByZXR1cm4gMAogICAgcmV0
dXJuIDAgaWYgciA+PSAwIGVsc2UgMQoKCmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICBz
eXMuZXhpdChtYWluKCkpCg==
MDIOSCAN_B64
chmod 755 /usr/local/bin/mdio-scan
if [ ! -x /usr/bin/python3 ] && [ ! -x /usr/local/bin/python3 ]; then
    echo "⚠️  rootfs 里没有 python3，mdio-scan 无法运行"
else
    echo "✅ 已安装 /usr/local/bin/mdio-scan（python3 版 MDIO 引脚探测工具）"
fi
