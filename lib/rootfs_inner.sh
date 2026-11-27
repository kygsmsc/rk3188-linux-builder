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
ME1Ieu+8iQogIG1kaW8tc2NhbiBwcm9iZSAgICAgICAgICAgICAgICAjIOaMieS9jyAxMjIg5ZCO
77yM6YCQ5Liq5oqK5YCZ6YCJ6ISa5ouJ6auYL+aLieS9ju+8jOavj+asoeaJqyBEMS9EMO+8iOaJ
viBQSFkg5L6b55S16ISa77yJCiAgbWRpby1zY2FuIG11eCAxMTcgMiAgICAgICAgICAgICMg55u0
5o6l5pS55p+Q5Y+q6ISa55qEIGlvbXV477yIMD1HUElPIC8gMj3lip/og70y77yM5LuF6ZmQIGJh
bmsz77yJCiAgbWRpby1zY2FuIHN3ZWVwIC0tYWRqICAgICAgICAgICMg5Y+q5omr55u46YK76ISa
5a+577yIdjQg55qE5pen6KGM5Li677yJ77yM6buY6K6k5omr5YWo57uE5ZCICiAgbWRpby1zY2Fu
IGhvbGQgOTYgICAgICAgICAgICAgICMg5oqK5p+Q5Liq6ISa5ouJ6auY5bm25L+d5oyB77yI6YWN
5ZCIIueciyBSSjQ1IOeBryLliKTlrprlpI3kvY0v5L6b55S16ISa77yJCiAgbWRpby1zY2FuIGhv
bGQgOTYgbG93ICAgICAgICAgICMg5ouJ5L2O5bm25L+d5oyBCiAgbWRpby1zY2FuIGZyZWUgOTYg
ICAgICAgICAgICAgICMg5oGi5aSN5YiwIGhvbGQg5LmL5YmN55qE54q25oCBCiAgbWRpby1zY2Fu
IGZyZWUgYWxsICAgICAgICAgICAgICMg5oGi5aSN5YWo6YOo77yIQ3RybC1DIOaJk+aWreWQjui3
kei/meS4quaUtuWwvu+8iQogIG1kaW8tc2NhbiBjdGwgICAgICAgICAgICAgICAgICAjIOmAkOS4
quaKiuWuieWFqOiEmuaLiemrmO+8jOWGjeeciyBEMS9EMCDkuIrmnInmsqHmnIkgUEhZIOW6lOet
lAogIG1kaW8tc2NhbiBzd2VlcCAgICAgICAgICAgICAgICAjIOebuOmCu+WuieWFqOiEmuWvueat
o+WPjeaegeaAp+aJqyAwfjfvvIjlj6rlnKggYmFuazPvvIkKICBtZGlvLXNjYW4gZHVtcCAgICAg
ICAgICAgICAgICAgIyDmiZPljbAgNCDkuKogYmFuayDnmoQgRFIvRERSL0VYVAoiIiIKCmltcG9y
dCBnbG9iCmltcG9ydCBqc29uCmltcG9ydCBtbWFwCmltcG9ydCBvcwppbXBvcnQgc3lzCmltcG9y
dCB0aW1lCgpHUElPX0JBU0UgPSBbMHgyMDAwQTAwMCwgMHgyMDAzQzAwMCwgMHgyMDAzRTAwMCwg
MHgyMDA4MDAwMF0KR1JGX0JBU0UgPSAweDIwMDA4MDAwClJFR19EUiA9IDB4MDAKUkVHX0REUiA9
IDB4MDQKUkVHX0VYVCA9IDB4NTAKUEFHRSA9IDQwOTYKCkQgPSAzZS02CkJBRF9JRFMgPSAoMHgw
MDAwMDAwMCwgMHgwMDAwRkZGRiwgMHhGRkZGRkZGRiwgMHhGRkZGMDAwMCwgMHgwMDAwRkZGRSkK
ClNUQVRFX0ZJTEUgPSAiL3RtcC9tZGlvLXNjYW4tb3JpZy5qc29uIgoKIyDmlbTnu4Tmi4npu5Hv
vJpiYW5rMCDmnIkgU1BJIEZsYXNoIC8gUE1JQyhJMkMp77yMYmFuazEg5pyJIGVNTUMgLyBVQVJU
Mihjb25zb2xlKQpCTEFDS19CQU5LUyA9ICgwLCAxKQojIGJhbmszIOS4iuato+WcqOiiq+aIkeS7
rCBEVFMg5L2/55So55qE6ISa77yaQzB+Qzcg5pivIFJNSUnvvIxEMC9EMSDmmK8gTURDL01ESU/v
vIzpg73kuI3lvZPmjqfliLbohJoKRU1BQ19STUlJID0gdHVwbGUocmFuZ2UoMTEyLCAxMjApKQpN
RElPX1BJTlMgPSAoMTIwLCAxMjEpCgoKZGVmIHBpbl9uYW1lKG51bSk6CiAgICBiYW5rID0gbnVt
IC8vIDMyCiAgICBncnAgPSAiQUJDRCJbKG51bSAlIDMyKSAvLyA4XQogICAgaWR4ID0gbnVtICUg
OAogICAgcmV0dXJuICJHUElPJWRfJXMlZCIgJSAoYmFuaywgZ3JwLCBpZHgpCgoKY2xhc3MgTWVt
KG9iamVjdCk6CiAgICBkZWYgX19pbml0X18oc2VsZik6CiAgICAgICAgc2VsZi5mZCA9IG9zLm9w
ZW4oIi9kZXYvbWVtIiwgb3MuT19SRFdSIHwgb3MuT19TWU5DKQogICAgICAgIHNlbGYubWFwcyA9
IHt9CgogICAgZGVmIF9wYWdlKHNlbGYsIGFkZHIpOgogICAgICAgIGJhc2UgPSBhZGRyICYgfihQ
QUdFIC0gMSkKICAgICAgICBtID0gc2VsZi5tYXBzLmdldChiYXNlKQogICAgICAgIGlmIG0gaXMg
Tm9uZToKICAgICAgICAgICAgbSA9IG1tYXAubW1hcChzZWxmLmZkLCBQQUdFLCBtbWFwLk1BUF9T
SEFSRUQsCiAgICAgICAgICAgICAgICAgICAgICAgICAgbW1hcC5QUk9UX1JFQUQgfCBtbWFwLlBS
T1RfV1JJVEUsIG9mZnNldD1iYXNlKQogICAgICAgICAgICBzZWxmLm1hcHNbYmFzZV0gPSBtCiAg
ICAgICAgcmV0dXJuIG0sIGFkZHIgLSBiYXNlCgogICAgZGVmIHJkKHNlbGYsIGFkZHIpOgogICAg
ICAgIG0sIG8gPSBzZWxmLl9wYWdlKGFkZHIpCiAgICAgICAgcmV0dXJuIGludC5mcm9tX2J5dGVz
KG1bbzpvICsgNF0sICJsaXR0bGUiKQoKICAgIGRlZiB3cihzZWxmLCBhZGRyLCB2YWwpOgogICAg
ICAgIG0sIG8gPSBzZWxmLl9wYWdlKGFkZHIpCiAgICAgICAgbVtvOm8gKyA0XSA9ICh2YWwgJiAw
eEZGRkZGRkZGKS50b19ieXRlcyg0LCAibGl0dGxlIikKCgpjbGFzcyBQaW4ob2JqZWN0KToKICAg
IGRlZiBfX2luaXRfXyhzZWxmLCBtZW0sIG51bSk6CiAgICAgICAgc2VsZi5tZW0gPSBtZW0KICAg
ICAgICBzZWxmLm51bSA9IG51bQogICAgICAgIHNlbGYuYmFuayA9IG51bSAvLyAzMgogICAgICAg
IHNlbGYuaWR4ID0gbnVtICUgMzIKICAgICAgICBzZWxmLmJhc2UgPSBHUElPX0JBU0Vbc2VsZi5i
YW5rXQoKICAgIGRlZiBzZXRfZGlyKHNlbGYsIG91dCk6CiAgICAgICAgYSA9IHNlbGYuYmFzZSAr
IFJFR19ERFIKICAgICAgICB2ID0gc2VsZi5tZW0ucmQoYSkKICAgICAgICBpZiBvdXQ6CiAgICAg
ICAgICAgIHYgfD0gKDEgPDwgc2VsZi5pZHgpCiAgICAgICAgZWxzZToKICAgICAgICAgICAgdiAm
PSB+KDEgPDwgc2VsZi5pZHgpCiAgICAgICAgc2VsZi5tZW0ud3IoYSwgdikKCiAgICBkZWYgc2V0
KHNlbGYsIHZhbCk6CiAgICAgICAgYSA9IHNlbGYuYmFzZSArIFJFR19EUgogICAgICAgIHYgPSBz
ZWxmLm1lbS5yZChhKQogICAgICAgIGlmIHZhbDoKICAgICAgICAgICAgdiB8PSAoMSA8PCBzZWxm
LmlkeCkKICAgICAgICBlbHNlOgogICAgICAgICAgICB2ICY9IH4oMSA8PCBzZWxmLmlkeCkKICAg
ICAgICBzZWxmLm1lbS53cihhLCB2KQoKICAgIGRlZiBnZXQoc2VsZik6CiAgICAgICAgcmV0dXJu
IChzZWxmLm1lbS5yZChzZWxmLmJhc2UgKyBSRUdfRVhUKSA+PiBzZWxmLmlkeCkgJiAxCgogICAg
ZGVmIF9pb211eF9hZGRyX2JpdChzZWxmKToKICAgICAgICBvZmYgPSAweDYwICsgKHNlbGYuYmFu
ayAqIDQgKyBzZWxmLmlkeCAvLyA4KSAqIDQKICAgICAgICByZXR1cm4gR1JGX0JBU0UgKyBvZmYs
IChzZWxmLmlkeCAlIDgpICogMgoKICAgIGRlZiBtdXhfZ2V0KHNlbGYpOgogICAgICAgIGEsIGIg
PSBzZWxmLl9pb211eF9hZGRyX2JpdCgpCiAgICAgICAgcmV0dXJuIChzZWxmLm1lbS5yZChhKSA+
PiBiKSAmIDMKCiAgICBkZWYgbXV4X3NldChzZWxmLCB2YWwpOgogICAgICAgIGEsIGIgPSBzZWxm
Ll9pb211eF9hZGRyX2JpdCgpCiAgICAgICAgdiA9IHNlbGYubWVtLnJkKGEpCiAgICAgICAgc2Vs
Zi5tZW0ud3IoYSwgKHYgJiB+KDMgPDwgYikpIHwgKCh2YWwgJiAzKSA8PCBiKSkKCiAgICBkZWYg
bXV4X2dwaW8oc2VsZik6CiAgICAgICAgc2VsZi5tdXhfc2V0KDApCgogICAgZGVmIGRpcl9vdXQo
c2VsZik6CiAgICAgICAgcmV0dXJuIGJvb2woKHNlbGYubWVtLnJkKHNlbGYuYmFzZSArIFJFR19E
RFIpID4+IHNlbGYuaWR4KSAmIDEpCgogICAgZGVmIHNuYXBzaG90KHNlbGYpOgogICAgICAgIHJl
dHVybiB7Im11eCI6IHNlbGYubXV4X2dldCgpLCAib3V0Ijogc2VsZi5kaXJfb3V0KCksICJkciI6
IHNlbGYuZ2V0KCl9CgogICAgZGVmIHJlc3RvcmUoc2VsZiwgcyk6CiAgICAgICAgc2VsZi5tdXhf
c2V0KHNbIm11eCJdKQogICAgICAgIGlmIHNbIm91dCJdOgogICAgICAgICAgICBzZWxmLnNldCgx
IGlmIHNbImRyIl0gZWxzZSAwKQogICAgICAgICAgICBzZWxmLnNldF9kaXIoVHJ1ZSkKICAgICAg
ICBlbHNlOgogICAgICAgICAgICBzZWxmLnNldF9kaXIoRmFsc2UpCgoKZGVmIGxvYWRfc3RhdGUo
KToKICAgIHRyeToKICAgICAgICByZXR1cm4ganNvbi5sb2FkKG9wZW4oU1RBVEVfRklMRSkpCiAg
ICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgIHJldHVybiB7fQoKCmRlZiBzYXZlX3N0YXRlKHN0
KToKICAgIHRyeToKICAgICAgICBqc29uLmR1bXAoc3QsIG9wZW4oU1RBVEVfRklMRSwgInciKSkK
ICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgcGFzcwoKCmRlZiBwYXJzZV9iYW5rcyhhcmdz
LCBkZWZhdWx0PSgzLCkpOgogICAgYmFua3MgPSBkZWZhdWx0CiAgICBpZiAiLS1hbGwiIGluIGFy
Z3M6CiAgICAgICAgYmFua3MgPSAoMCwgMSwgMiwgMykKICAgIGZvciBhIGluIGFyZ3M6CiAgICAg
ICAgaWYgYS5zdGFydHN3aXRoKCItLWJhbms9Iik6CiAgICAgICAgICAgIGJhbmtzID0gdHVwbGUo
aW50KHgpIGZvciB4IGluIGEuc3BsaXQoIj0iLCAxKVsxXS5zcGxpdCgiLCIpKQogICAgcmV0dXJu
IGJhbmtzCgoKZGVmIGhlbGRfcGlucygpOgogICAgb3V0ID0gc2V0KCkKICAgIGZvciBrIGluIGxv
YWRfc3RhdGUoKS5rZXlzKCk6CiAgICAgICAgaWYgc3RyKGspLmlzZGlnaXQoKToKICAgICAgICAg
ICAgb3V0LmFkZChpbnQoaykpCiAgICByZXR1cm4gb3V0CgoKZGVmIHNhZmVfcGlucyhtZW0sIGJh
bmtzLCBhbnlfbXV4PUZhbHNlLCBmb3JjZT1GYWxzZSwgd2l0aF9tZGlvPVRydWUpOgogICAgIiIi
6Ieq5bex6K+7IGlvbXV4IOWIpOaWre+8mm11eD09MO+8iOW9k+WJjeWwseaYryBHUElP77yJ5LiU
5Zyo5YWB6K6455qEIGJhbmsg5YaF5omN6L+U5Zue44CCCiAgICB3aXRoX21kaW89VHJ1ZSDml7bm
ioogRDAvRDEoMTIwLzEyMSkg5Lmf566X6L+b5YCZ6YCJIOKAlOKAlCDlroPku6zmmK8gTURDL01E
SU8g55qE6aaW6KaB5auM55aR77yMCiAgICDlv4Xpobvog73ooqvlvZPmiJAi5b6F5rWL6ISa5a+5
IueahOS4gOmDqOWIhu+8iOWPjeaegeaApyAxMjAvMTIxIOS7peWJjeS7juayoea1i+i/h++8ieOA
giIiIgogICAgaGVsZCA9IGhlbGRfcGlucygpCiAgICBwaW5zID0gW10KICAgIGZvciBiIGluIGJh
bmtzOgogICAgICAgIGlmIGIgaW4gQkxBQ0tfQkFOS1MgYW5kIG5vdCBmb3JjZToKICAgICAgICAg
ICAgY29udGludWUKICAgICAgICBmb3IgcCBpbiByYW5nZShiICogMzIsIGIgKiAzMiArIDMyKToK
ICAgICAgICAgICAgaWYgcCBpbiBFTUFDX1JNSUkgb3IgcCBpbiBoZWxkOgogICAgICAgICAgICAg
ICAgY29udGludWUKICAgICAgICAgICAgaWYgcCBpbiBNRElPX1BJTlMgYW5kIG5vdCB3aXRoX21k
aW86CiAgICAgICAgICAgICAgICBjb250aW51ZQogICAgICAgICAgICBpZiBub3QgYW55X211eCBh
bmQgUGluKG1lbSwgcCkubXV4X2dldCgpICE9IDA6CiAgICAgICAgICAgICAgICBjb250aW51ZQog
ICAgICAgICAgICBwaW5zLmFwcGVuZChwKQogICAgcmV0dXJuIHNvcnRlZChwaW5zKQoKCk1VWF9G
SUxFID0gIi90bXAvbWRpby1zY2FuLW11eC5qc29uIgoKCmRlZiBsb2FkX211eCgpOgogICAgdHJ5
OgogICAgICAgIHJldHVybiBqc29uLmxvYWQob3BlbihNVVhfRklMRSkpCiAgICBleGNlcHQgRXhj
ZXB0aW9uOgogICAgICAgIHJldHVybiB7fQoKCmRlZiBzYXZlX211eChzdCk6CiAgICB0cnk6CiAg
ICAgICAganNvbi5kdW1wKHN0LCBvcGVuKE1VWF9GSUxFLCAidyIpKQogICAgZXhjZXB0IEV4Y2Vw
dGlvbjoKICAgICAgICBwYXNzCgoKZGVmIGJiX3JlYWQobWRjLCBtZGlvLCBwaHksIHJlZyk6CiAg
ICAiIiLmoIflh4YgQ2xhdXNlIDIyIOivu++8mnByZWFtYmxlICsgU1QoMDEpICsgT1AoMTApICsg
UEhZQUQoNSkgKyBSRUdBRCg1KSArIFRBICsgMTYg5pWw5o2u5L2NIiIiCiAgICBtZGlvLm11eF9n
cGlvKCkKICAgIG1kYy5tdXhfZ3BpbygpCiAgICBtZGMuc2V0X2RpcihUcnVlKQogICAgbWRjLnNl
dCgwKQogICAgbWRpby5zZXRfZGlyKFRydWUpCgogICAgZGVmIGNsa193cml0ZShiaXQpOgogICAg
ICAgIG1kaW8uc2V0KGJpdCkKICAgICAgICB0aW1lLnNsZWVwKEQpCiAgICAgICAgbWRjLnNldCgx
KQogICAgICAgIHRpbWUuc2xlZXAoRCkKICAgICAgICBtZGMuc2V0KDApCiAgICAgICAgdGltZS5z
bGVlcChEKQoKICAgIGZvciBfIGluIHJhbmdlKDMyKToKICAgICAgICBjbGtfd3JpdGUoMSkKCiAg
ICBiaXRzID0gWzAsIDEsIDEsIDBdCiAgICBmb3IgaSBpbiByYW5nZSg0LCAtMSwgLTEpOgogICAg
ICAgIGJpdHMuYXBwZW5kKChwaHkgPj4gaSkgJiAxKQogICAgZm9yIGkgaW4gcmFuZ2UoNCwgLTEs
IC0xKToKICAgICAgICBiaXRzLmFwcGVuZCgocmVnID4+IGkpICYgMSkKICAgIGZvciBiIGluIGJp
dHM6CiAgICAgICAgY2xrX3dyaXRlKGIpCgogICAgbWRpby5zZXRfZGlyKEZhbHNlKQogICAgdGlt
ZS5zbGVlcChEKQogICAgbWRjLnNldCgxKQogICAgdGltZS5zbGVlcChEKQogICAgbWRjLnNldCgw
KQogICAgdGltZS5zbGVlcChEKQoKICAgIHZhbCA9IDAKICAgIGZvciBfIGluIHJhbmdlKDE2KToK
ICAgICAgICB0aW1lLnNsZWVwKEQpCiAgICAgICAgbWRjLnNldCgxKQogICAgICAgIHRpbWUuc2xl
ZXAoRCkKICAgICAgICB2YWwgPSAodmFsIDw8IDEpIHwgbWRpby5nZXQoKQogICAgICAgIG1kYy5z
ZXQoMCkKICAgICAgICB0aW1lLnNsZWVwKEQpCiAgICByZXR1cm4gdmFsCgoKZGVmIHBoeV9pZCht
ZW0sIG1kY19udW0sIG1kaW9fbnVtLCBhZGRyKToKICAgIG1kYyA9IFBpbihtZW0sIG1kY19udW0p
CiAgICBtZGlvID0gUGluKG1lbSwgbWRpb19udW0pCiAgICBoaSA9IGJiX3JlYWQobWRjLCBtZGlv
LCBhZGRyLCAyKQogICAgbG8gPSBiYl9yZWFkKG1kYywgbWRpbywgYWRkciwgMykKICAgIHJldHVy
biAoaGkgPDwgMTYpIHwgbG8KCgpkZWYgaXNfdmFsaWQocGlkKToKICAgIGlmIHBpZCBpbiBCQURf
SURTOgogICAgICAgIHJldHVybiBGYWxzZQogICAgaGkgPSAocGlkID4+IDE2KSAmIDB4RkZGRgog
ICAgbG8gPSBwaWQgJiAweEZGRkYKICAgIGlmIGhpIGluICgweDAwMDAsIDB4RkZGRikgYW5kIGxv
IGluICgweDAwMDAsIDB4RkZGRik6CiAgICAgICAgcmV0dXJuIEZhbHNlCiAgICByZXR1cm4gVHJ1
ZQoKCmRlZiBjbWRfcGluKG1lbSwgYXJncyk6CiAgICBmb3IgYSBpbiBhcmdzOgogICAgICAgIHAg
PSBQaW4obWVtLCBpbnQoYSkpCiAgICAgICAgcHJpbnQoInBpbiAlLTNkICUtMTBzIG11eD0lZCBk
aXI9JXMgbGV2ZWw9JWQiICUgKAogICAgICAgICAgICBwLm51bSwgcGluX25hbWUocC5udW0pLCBw
Lm11eF9nZXQoKSwKICAgICAgICAgICAgIm91dCIgaWYgcC5kaXJfb3V0KCkgZWxzZSAiaW4iLCBw
LmdldCgpKSkKICAgIHJldHVybiAwCgoKZGVmIGNtZF9zYWZlKG1lbSwgYXJncyk6CiAgICBiYW5r
cyA9IHBhcnNlX2JhbmtzKGFyZ3MpCiAgICBhbnlfbXV4ID0gIi0tYW55IiBpbiBhcmdzCiAgICBm
b3JjZSA9ICItLWZvcmNlIiBpbiBhcmdzCiAgICBwaW5zID0gc2FmZV9waW5zKG1lbSwgYmFua3Ms
IGFueV9tdXgsIGZvcmNlKQogICAgaWYgIi0tbGlzdCIgaW4gYXJnczoKICAgICAgICBmb3IgcCBp
biBwaW5zOgogICAgICAgICAgICBwcmludChwKQogICAgICAgIHJldHVybiAwCiAgICBwcmludCgi
YmFuayAlcyDph4zlj6/lronlhajmk43kvZznmoTlvJXohJrlhbEgJWQg5Liq77yIbXV4PT0wIOS4
lOacquiiq+aOkumZpO+8ie+8miIgJSAoCiAgICAgICAgIiwiLmpvaW4oc3RyKGIpIGZvciBiIGlu
IGJhbmtzKSwgbGVuKHBpbnMpKSkKICAgIGZvciBwIGluIHBpbnM6CiAgICAgICAgcSA9IFBpbiht
ZW0sIHApCiAgICAgICAgcHJpbnQoIiAgJS0zZCAlLTEwcyBtdXg9JWQgZGlyPSVzIGxldmVsPSVk
IiAlICgKICAgICAgICAgICAgcCwgcGluX25hbWUocCksIHEubXV4X2dldCgpLCAib3V0IiBpZiBx
LmRpcl9vdXQoKSBlbHNlICJpbiIsIHEuZ2V0KCkpKQogICAgaWYgbm90IHBpbnM6CiAgICAgICAg
cHJpbnQoIiAg77yI5LiA5Liq6YO95rKh5pyJ44CC5Y+v6IO96L+Z5LqbIGJhbmsg55qE6ISa5YWo
6KKr5Y2g55So5LqG77yM6K+V6K+VIC0tYmFuaz0yIOaIliAtLWFuee+8iSIpCiAgICByZXR1cm4g
MAoKCmRlZiBjbWRfc2NhbihtZW0sIGFyZ3MpOgogICAgbnVtcyA9IFtpbnQoYSkgZm9yIGEgaW4g
YXJncyBpZiBhLmlzZGlnaXQoKV0KICAgIG1kY19udW0gPSBudW1zWzBdIGlmIGxlbihudW1zKSA+
PSAxIGVsc2UgMTIxCiAgICBtZGlvX251bSA9IG51bXNbMV0gaWYgbGVuKG51bXMpID49IDIgZWxz
ZSAxMjAKICAgIGxvID0gbnVtc1syXSBpZiBsZW4obnVtcykgPj0gMyBlbHNlIDAKICAgIGhpID0g
bnVtc1szXSBpZiBsZW4obnVtcykgPj0gNCBlbHNlIDcKICAgIHByaW50KCLmiasgJXMoTURDKSAv
ICVzKE1ESU8pIOWcsOWdgCAlZH4lZCIgJSAoCiAgICAgICAgcGluX25hbWUobWRjX251bSksIHBp
bl9uYW1lKG1kaW9fbnVtKSwgbG8sIGhpKSkKICAgIGhpdCA9IDAKICAgIGZvciBhZGRyIGluIHJh
bmdlKGxvLCBoaSArIDEpOgogICAgICAgIHBpZCA9IHBoeV9pZChtZW0sIG1kY19udW0sIG1kaW9f
bnVtLCBhZGRyKQogICAgICAgIGZsYWcgPSAiICA8PT0g5pyJ5bqU562UIiBpZiBpc192YWxpZChw
aWQpIGVsc2UgIiIKICAgICAgICBwcmludCgiICBhZGRyICVkIDogaWQ9MHglMDhYJXMiICUgKGFk
ZHIsIHBpZCwgZmxhZykpCiAgICAgICAgaWYgaXNfdmFsaWQocGlkKToKICAgICAgICAgICAgaGl0
ICs9IDEKICAgIHByaW50KCLlkIjorqHlkb3kuK0gJWQg5Liq5Zyw5Z2A44CCIiAlIGhpdCkKICAg
IHJldHVybiBoaXQKCgpkZWYgY21kX3N3ZWVwKG1lbSwgYXJncyk6CiAgICBiYW5rcyA9IHBhcnNl
X2JhbmtzKGFyZ3MpCiAgICBhZGogPSAiLS1hZGoiIGluIGFyZ3MKICAgIHBpbnMgPSBzYWZlX3Bp
bnMobWVtLCBiYW5rcykKICAgIHBhaXJzID0gW10KICAgIGlmIGFkajoKICAgICAgICBmb3IgcCBp
biBwaW5zOgogICAgICAgICAgICBpZiBwICsgMSBpbiBwaW5zOgogICAgICAgICAgICAgICAgcGFp
cnMuYXBwZW5kKChwLCBwICsgMSkpCiAgICAgICAgICAgICAgICBwYWlycy5hcHBlbmQoKHAgKyAx
LCBwKSkKICAgICAgICBwcmludCgiYmFuayAlcyDlhoXnm7jpgrvlronlhajohJrlr7kgJWQg57uE
77yI5ZCr5q2j5Y+N5p6B5oCn77yJ77yM5byA5aeL5omr5o+PIC4uLiIgJSAoCiAgICAgICAgICAg
ICIsIi5qb2luKHN0cihiKSBmb3IgYiBpbiBiYW5rcyksIGxlbihwYWlycykpKQogICAgZWxzZToK
ICAgICAgICBmb3IgYSBpbiBwaW5zOgogICAgICAgICAgICBmb3IgYiBpbiBwaW5zOgogICAgICAg
ICAgICAgICAgaWYgYSAhPSBiOgogICAgICAgICAgICAgICAgICAgIHBhaXJzLmFwcGVuZCgoYSwg
YikpCiAgICAgICAgcHJpbnQoImJhbmsgJXMg5YaFICVkIOWPquWAmemAieiEmueahOS4pOS4pOe7
hOWQiCAlZCDnu4TvvIjlkKvmraPlj43mnoHmgKfvvInvvIzlvIDlp4vmiavmj48gLi4uIiAlICgK
ICAgICAgICAgICAgIiwiLmpvaW4oc3RyKGIpIGZvciBiIGluIGJhbmtzKSwgbGVuKHBpbnMpLCBs
ZW4ocGFpcnMpKSkKICAgICAgICBwcmludCgi57qm6ZyAIDMwfjYwIOenku+8jOi/m+W6puihjOS8
muS4gOebtOWIt+aWsO+8jOWRveS4reS8muWBnOS4i+adpeaJk+WNsOOAgiIpCiAgICBpZiBub3Qg
cGFpcnM6CiAgICAgICAgcHJpbnQoIuayoeacieWPr+aJq+eahOebuOmCu+iEmuWvue+8jOebtOaO
pemAgOWHuuOAgiIpCiAgICAgICAgcmV0dXJuIDAKICAgIGhpdHMgPSBbXQogICAgZm9yIG4sIChh
LCBiKSBpbiBlbnVtZXJhdGUocGFpcnMpOgogICAgICAgIHN5cy5zdGRvdXQud3JpdGUoIlxyICBb
JWQvJWRdIE1EQz0lZCBNRElPPSVkICAgICAgIiAlIChuICsgMSwgbGVuKHBhaXJzKSwgYSwgYikp
CiAgICAgICAgc3lzLnN0ZG91dC5mbHVzaCgpCiAgICAgICAgZm9yIGFkZHIgaW4gcmFuZ2UoOCk6
CiAgICAgICAgICAgIHBpZCA9IHBoeV9pZChtZW0sIGEsIGIsIGFkZHIpCiAgICAgICAgICAgIGlm
IGlzX3ZhbGlkKHBpZCk6CiAgICAgICAgICAgICAgICBoaXRzLmFwcGVuZCgoYSwgYiwgYWRkciwg
cGlkKSkKICAgIHByaW50KCIiKQogICAgaWYgbm90IGhpdHM6CiAgICAgICAgcHJpbnQoIue7k+ae
nO+8muayoeacieS7u+S9leS4gOWvuSArIOS7u+S9leWcsOWdgOacieW6lOetlOOAgiIpCiAgICBl
bHNlOgogICAgICAgIHByaW50KCLnu5PmnpzvvJrmib7liLAgJWQg5aSE5bqU562U77yaIiAlIGxl
bihoaXRzKSkKICAgICAgICBmb3IgYSwgYiwgYWRkciwgcGlkIGluIGhpdHM6CiAgICAgICAgICAg
IHByaW50KCIgIE1EQz0lcyglZCkgTURJTz0lcyglZCkgUEhZ5Zyw5Z2APSVkIGlkPTB4JTA4WCIg
JSAoCiAgICAgICAgICAgICAgICBwaW5fbmFtZShhKSwgYSwgcGluX25hbWUoYiksIGIsIGFkZHIs
IHBpZCkpCiAgICByZXR1cm4gbGVuKGhpdHMpCgoKZGVmIGNtZF9jdGwobWVtLCBhcmdzKToKICAg
IGJhbmtzID0gcGFyc2VfYmFua3MoYXJncykKICAgIG51bXMgPSBbaW50KGEpIGZvciBhIGluIGFy
Z3MgaWYgYS5pc2RpZ2l0KCldCiAgICBtZGNfbnVtID0gbnVtc1swXSBpZiBsZW4obnVtcykgPj0g
MSBlbHNlIDEyMQogICAgbWRpb19udW0gPSBudW1zWzFdIGlmIGxlbihudW1zKSA+PSAyIGVsc2Ug
MTIwCiAgICBwaW5zID0gc2FmZV9waW5zKG1lbSwgYmFua3MpCiAgICBwcmludCgiYmFuayAlc++8
miVzLyVzIOS4iuWFiOaJq+S4gOmBjeWfuue6vyAuLi4iICUgKAogICAgICAgICIsIi5qb2luKHN0
cihiKSBmb3IgYiBpbiBiYW5rcyksIHBpbl9uYW1lKG1kY19udW0pLCBwaW5fbmFtZShtZGlvX251
bSkpKQogICAgZm9yIGFkZHIgaW4gcmFuZ2UoOCk6CiAgICAgICAgcGlkID0gcGh5X2lkKG1lbSwg
bWRjX251bSwgbWRpb19udW0sIGFkZHIpCiAgICAgICAgcHJpbnQoIiAg5Z+657q/IGFkZHIgJWQg
OiBpZD0weCUwOFgiICUgKGFkZHIsIHBpZCkpCiAgICBpZiBub3QgcGluczoKICAgICAgICBwcmlu
dCgi5rKh5pyJ5Y+v5pON5L2c55qE5o6n5Yi26ISa77yM6YCA5Ye677yI5YWI6LeRIG1kaW8tc2Nh
biBzYWZl77yJ44CCIikKICAgICAgICByZXR1cm4gMAogICAgcHJpbnQoIumAkOS4quaKiiAlZCDk
uKrlronlhajohJrmi4npq5jvvIzlkIzml7bmiasgMH43IC4uLiIgJSBsZW4ocGlucykpCiAgICBo
aXRzID0gW10KICAgIGZvciBuLCBwIGluIGVudW1lcmF0ZShwaW5zKToKICAgICAgICBzeXMuc3Rk
b3V0LndyaXRlKCJcciAgWyVkLyVkXSDmi4npq5ggJWQgKCVzKSAgICAgICIgJSAobiArIDEsIGxl
bihwaW5zKSwgcCwgcGluX25hbWUocCkpKQogICAgICAgIHN5cy5zdGRvdXQuZmx1c2goKQogICAg
ICAgIGN0bCA9IFBpbihtZW0sIHApCiAgICAgICAgb3JpZyA9IGN0bC5zbmFwc2hvdCgpCiAgICAg
ICAgY3RsLm11eF9ncGlvKCkKICAgICAgICBjdGwuc2V0X2RpcihUcnVlKQogICAgICAgIGN0bC5z
ZXQoMSkKICAgICAgICBmb3IgYWRkciBpbiByYW5nZSg4KToKICAgICAgICAgICAgcGlkID0gcGh5
X2lkKG1lbSwgbWRjX251bSwgbWRpb19udW0sIGFkZHIpCiAgICAgICAgICAgIGlmIGlzX3ZhbGlk
KHBpZCk6CiAgICAgICAgICAgICAgICBoaXRzLmFwcGVuZCgocCwgYWRkciwgcGlkKSkKICAgICAg
ICBjdGwucmVzdG9yZShvcmlnKQogICAgcHJpbnQoIiIpCiAgICBpZiBub3QgaGl0czoKICAgICAg
ICBwcmludCgi57uT5p6c77ya6L+ZICVkIOS4quiEmumAkOS4quaLiemrmO+8jEQxL0QwIOS4iumD
veayoeaciSBQSFkg5bqU562U44CCIiAlIGxlbihwaW5zKSkKICAgIGVsc2U6CiAgICAgICAgcHJp
bnQoIue7k+aenO+8muaJvuWIsCAlZCDlpITlupTnrZTvvJoiICUgbGVuKGhpdHMpKQogICAgICAg
IGZvciBwLCBhZGRyLCBwaWQgaW4gaGl0czoKICAgICAgICAgICAgcHJpbnQoIiAg5o6n5Yi26ISa
PSVzKCVkKSBQSFnlnLDlnYA9JWQgaWQ9MHglMDhYIiAlIChwaW5fbmFtZShwKSwgcCwgYWRkciwg
cGlkKSkKICAgIHJldHVybiBsZW4oaGl0cykKCgpkZWYgY21kX2hvbGQobWVtLCBhcmdzKToKICAg
IG51bXMgPSBbaW50KGEpIGZvciBhIGluIGFyZ3MgaWYgYS5pc2RpZ2l0KCldCiAgICBsb3cgPSAi
bG93IiBpbiBhcmdzCiAgICBmb3IgbiBpbiBudW1zOgogICAgICAgIGlmIG4gLy8gMzIgaW4gQkxB
Q0tfQkFOS1M6CiAgICAgICAgICAgIHByaW50KCLmi5Lnu53vvJpHUElPJWQg5piv6Zeq5a2YL1BN
SUMvZU1NQy9VQVJUIOWMuu+8jOS4jeWFgeiuuOWKqOOAgiIgJSAobiAvLyAzMikpCiAgICAgICAg
ICAgIGNvbnRpbnVlCiAgICAgICAgcCA9IFBpbihtZW0sIG4pCiAgICAgICAgc3QgPSBsb2FkX3N0
YXRlKCkKICAgICAgICBrZXkgPSBzdHIobikKICAgICAgICBpZiBrZXkgbm90IGluIHN0OgogICAg
ICAgICAgICBzdFtrZXldID0gcC5zbmFwc2hvdCgpCiAgICAgICAgICAgIHNhdmVfc3RhdGUoc3Qp
CiAgICAgICAgcC5tdXhfZ3BpbygpCiAgICAgICAgcC5zZXQoMCBpZiBsb3cgZWxzZSAxKQogICAg
ICAgIHAuc2V0X2RpcihUcnVlKQogICAgICAgIHByaW50KCLlt7LmioogJXMoJWQpIOaLiSVz5bm2
5L+d5oyB6L6T5Ye644CC55yLIFJKNDUg54Gv77yb5LiN5Lqu5bCxIG1kaW8tc2NhbiBmcmVlICVk
44CC5Y6f54q25oCBPSVzIiAlICgKICAgICAgICAgICAgcGluX25hbWUobiksIG4sICLkvY4iIGlm
IGxvdyBlbHNlICLpq5giLCBuLCBzdFtrZXldKSkKICAgIHJldHVybiAwCgoKZGVmIGNtZF9mcmVl
KG1lbSwgYXJncyk6CiAgICBzdCA9IGxvYWRfc3RhdGUoKQogICAgaWYgImFsbCIgaW4gYXJnczoK
ICAgICAgICBtc3QgPSBsb2FkX211eCgpCiAgICAgICAgZm9yIGsgaW4gbGlzdChtc3Qua2V5cygp
KToKICAgICAgICAgICAgUGluKG1lbSwgaW50KGspKS5tdXhfc2V0KG1zdFtrXSkKICAgICAgICAg
ICAgcHJpbnQoIuW3suaBouWkjSAlcyglZCkgaW9tdXggLT4gJWQiICUgKHBpbl9uYW1lKGludChr
KSksIGludChrKSwgbXN0W2tdKSkKICAgICAgICBzYXZlX211eCh7fSkKICAgICAgICBmb3IgayBp
biBsaXN0KHN0LmtleXMoKSk6CiAgICAgICAgICAgIFBpbihtZW0sIGludChrKSkucmVzdG9yZShz
dFtrXSkKICAgICAgICAgICAgcHJpbnQoIuW3suaBouWkjSAlcyglZCkgLT4gJXMiICUgKHBpbl9u
YW1lKGludChrKSksIGludChrKSwgc3Rba10pKQogICAgICAgIHNhdmVfc3RhdGUoe30pCiAgICAg
ICAgcmV0dXJuIDAKICAgIGZvciBhIGluIGFyZ3M6CiAgICAgICAgbiA9IGludChhKQogICAgICAg
IHAgPSBQaW4obWVtLCBuKQogICAgICAgIGlmIHN0cihuKSBpbiBzdDoKICAgICAgICAgICAgcC5y
ZXN0b3JlKHN0W3N0cihuKV0pCiAgICAgICAgICAgIHByaW50KCLlt7LmioogJXMoJWQpIOaBouWk
jeWIsCBob2xkIOS5i+WJje+8miVzIiAlIChwaW5fbmFtZShuKSwgbiwgc3Rbc3RyKG4pXSkpCiAg
ICAgICAgICAgIGRlbCBzdFtzdHIobildCiAgICAgICAgICAgIHNhdmVfc3RhdGUoc3QpCiAgICAg
ICAgZWxzZToKICAgICAgICAgICAgcC5zZXQoMCkKICAgICAgICAgICAgcC5zZXRfZGlyKEZhbHNl
KQogICAgICAgICAgICBwcmludCgi5bey5oqKICVzKCVkKSDmlL7lvIDvvIjovpPlhaXjgIHkvY7n
lLXlubPvvInjgIIiICUgKHBpbl9uYW1lKG4pLCBuKSkKICAgIHJldHVybiAwCgoKZGVmIGNtZF93
YWtlKG1lbSwgYXJncyk6CiAgICAiIiLlhYjnu5kgUEhZIOS9v+iDveiEmu+8iOm7mOiupCBHUElP
M19EMj0xMjLvvInkuIrnlLXlubbkv53mjIHvvIzlho3miasgRDEvRDAg55qEIDB+N+OAggogICAg
6L+Z5p2h5ZG95Luk5bCx5pivInR0bC0yMyDlj5HnjrDnmoTpgqPlj6rohJogKyDnq4vliLvmib7l
nLDlnYAi55qE5ZCI5bm254mI77yMMTIyIOS8muS4gOebtOS/neaMgemrmOeUteW5s++8jAogICAg
57uT5p2f5ZCO5Y+v5Lul55SoIG1kaW8tc2NhbiBmcmVlIDEyMiDmlL7lvIDjgIIiIiIKICAgIG51
bXMgPSBbaW50KGEpIGZvciBhIGluIGFyZ3MgaWYgYS5pc2RpZ2l0KCldCiAgICBlbiA9IG51bXNb
MF0gaWYgbGVuKG51bXMpID49IDEgZWxzZSAxMjIKICAgIG1kY19udW0gPSBudW1zWzFdIGlmIGxl
bihudW1zKSA+PSAyIGVsc2UgMTIxCiAgICBtZGlvX251bSA9IG51bXNbMl0gaWYgbGVuKG51bXMp
ID49IDMgZWxzZSAxMjAKICAgIHAgPSBQaW4obWVtLCBlbikKICAgIHN0ID0gbG9hZF9zdGF0ZSgp
CiAgICBrZXkgPSBzdHIoZW4pCiAgICBpZiBrZXkgbm90IGluIHN0OgogICAgICAgIHN0W2tleV0g
PSBwLnNuYXBzaG90KCkKICAgICAgICBzYXZlX3N0YXRlKHN0KQogICAgICAgIHByaW50KCLkvb/o
g73ohJogJXMoJWQpIOWOn+eKtuaAgT0lcyIgJSAocGluX25hbWUoZW4pLCBlbiwgc3Rba2V5XSkp
CiAgICBwLm11eF9ncGlvKCkKICAgIHAuc2V0KDEpCiAgICBwLnNldF9kaXIoVHJ1ZSkKICAgIGlm
ICItLWNsayIgaW4gYXJnczoKICAgICAgICBjID0gUGluKG1lbSwgMTE3KQogICAgICAgIG1zdCA9
IGxvYWRfbXV4KCkKICAgICAgICBpZiAiMTE3IiBub3QgaW4gbXN0OgogICAgICAgICAgICBtc3Rb
IjExNyJdID0gYy5tdXhfZ2V0KCkKICAgICAgICAgICAgc2F2ZV9tdXgobXN0KQogICAgICAgIGMu
bXV4X3NldCgyKQogICAgICAgIHByaW50KCJHUElPM19DNSgxMTcpIGlvbXV4IDAgLT4gMu+8iHJt
aWlfY2xrb3V077yM57uZIFBIWSDpgIEgNTBNSHrvvInvvIzljp/lgLw9JWQiICUgbXN0WyIxMTci
XSkKICAgIHRpbWUuc2xlZXAoMC4zKQogICAgcHJpbnQoIuW3suaKiiAlcyglZCkg5ouJ6auY77yI
UEhZIOS4iueUte+8ie+8jOetiSAzMDBtc++8jOW8gOWni+aJqyAlcy8lcyDnmoQgMH43IC4uLiIg
JSAoCiAgICAgICAgcGluX25hbWUoZW4pLCBlbiwgcGluX25hbWUobWRjX251bSksIHBpbl9uYW1l
KG1kaW9fbnVtKSkpCiAgICBoaXRzID0gW10KICAgIGZvciBhZGRyIGluIHJhbmdlKDgpOgogICAg
ICAgIHBpZCA9IHBoeV9pZChtZW0sIG1kY19udW0sIG1kaW9fbnVtLCBhZGRyKQogICAgICAgIG9r
ID0gaXNfdmFsaWQocGlkKQogICAgICAgIHByaW50KCIgIGFkZHIgJWQgOiBpZD0weCUwOFglcyIg
JSAoYWRkciwgcGlkLCAiICA8PT0g5pyJ5bqU562UIiBpZiBvayBlbHNlICIiKSkKICAgICAgICBp
ZiBvazoKICAgICAgICAgICAgaGl0cy5hcHBlbmQoKGFkZHIsIHBpZCkpCiAgICBpZiBub3QgaGl0
czoKICAgICAgICBwcmludCgi57uT5p6c77yaUEhZIOW3suS4iueUteS9hiAwfjcg5YWo5peg5bqU
562UIOKAlOKAlCDor7TmmI4gTURDL01ESU8g5LiN5ZyoIEQxL0Qw77yMIikKICAgICAgICBwcmlu
dCgiICAgICAg5o6l552A6LeRIG1kaW8tc2NhbiBzd2VlcO+8iOS8muiHquWKqOi3s+i/h+iiqyBo
b2xkIOeahOiEmu+8ieWOu+aJvuecn+ato+eahCBNREMvTURJTyDohJrlr7njgIIiKQogICAgZWxz
ZToKICAgICAgICBwcmludCgi57uT5p6c77yaUEhZIOWcsOWdgCA9ICVk77yIaWQ9MHglMDhY77yJ
44CC5LiL5LiA5q2lIG1kaW8tc2NhbiByZWdzICVkIOWkjeivu+WvhOWtmOWZqOehruiupOOAgiIg
JSAoCiAgICAgICAgICAgIGhpdHNbMF1bMF0sIGhpdHNbMF1bMV0sIGhpdHNbMF1bMF0pKQogICAg
ICAgIHByaW50KCIgICAgICAlcyglZCkg5L+d5oyB6auY55S15bmz77yM57uT5p2f5pe2IG1kaW8t
c2NhbiBmcmVlICVk44CCIiAlICgKICAgICAgICAgICAgcGluX25hbWUoZW4pLCBlbiwgZW4pKQog
ICAgcmV0dXJuIGxlbihoaXRzKQoKCmRlZiBjbWRfcHJvYmUobWVtLCBhcmdzKToKICAgICIiIuaJ
viJQSFkg5L6b55S1L+S9v+iDveiEmiLvvJrmjInkvY8gMTIyIOmrmOeUteW5s++8jOmAkOS4quaK
iuWAmemAieiEmuaLiemrmOOAgeaLieS9ju+8jAogICAg5q+P5Liq54q25oCB5omr5LiA6YGNIEQx
L0QwIOeahCAwfjfjgILlk6rkuKrohJrkuIDmi4nlsLHmnInlupTnrZTvvIzpgqPkuKrlsLHmmK/o
rqkgUEhZIOecn+ato+mAmueUteeahOiEmuOAgiIiIgogICAgbnVtcyA9IFtpbnQoYSkgZm9yIGEg
aW4gYXJncyBpZiBhLmlzZGlnaXQoKV0KICAgIGVuID0gbnVtc1swXSBpZiBsZW4obnVtcykgPj0g
MSBlbHNlIDEyMgogICAgYmFua3MgPSBwYXJzZV9iYW5rcyhhcmdzLCBkZWZhdWx0PSgyLCAzKSkK
ICAgIGZvcmNlID0gIi0tZm9yY2UiIGluIGFyZ3MKICAgIGtlZXAgPSBQaW4obWVtLCBlbikKICAg
IHN0ID0gbG9hZF9zdGF0ZSgpCiAgICBpZiBzdHIoZW4pIG5vdCBpbiBzdDoKICAgICAgICBzdFtz
dHIoZW4pXSA9IGtlZXAuc25hcHNob3QoKQogICAgICAgIHNhdmVfc3RhdGUoc3QpCiAgICBrZWVw
Lm11eF9ncGlvKCkKICAgIGtlZXAuc2V0KDEpCiAgICBrZWVwLnNldF9kaXIoVHJ1ZSkKICAgIHRp
bWUuc2xlZXAoMC4zKQogICAgY2FuZHMgPSBbcSBmb3IgcSBpbiBzYWZlX3BpbnMobWVtLCBiYW5r
cywgZm9yY2U9Zm9yY2UsIHdpdGhfbWRpbz1GYWxzZSkgaWYgcSAhPSBlbl0KICAgIHByaW50KCLl
t7LmjInkvY8gJXMoJWQpIOmrmOeUteW5s++8m2JhbmsgJXMg6YeMICVkIOWPquWAmemAieiEmu+8
jOavj+WPquivlSDpq5gv5L2OIOS4pOenje+8jOWQhOaJqyAwfjcgLi4uIiAlICgKICAgICAgICBw
aW5fbmFtZShlbiksIGVuLCAiLCIuam9pbihzdHIoYikgZm9yIGIgaW4gYmFua3MpLCBsZW4oY2Fu
ZHMpKSkKICAgIHByaW50KCLpooTorqEgJWQg56eS77yM6L+b5bqm5Lya5LiA55u05Yi35paw77yM
5ZG95Lit5Lya5YGc5LiL5p2l5omT5Y2w44CCIiAlIChsZW4oY2FuZHMpICogMiAqIDAuMykpCiAg
ICBoaXRzID0gW10KICAgIGZvciBuLCBxIGluIGVudW1lcmF0ZShjYW5kcyk6CiAgICAgICAgZm9y
IHZhbCBpbiAoMSwgMCk6CiAgICAgICAgICAgIGN0bCA9IFBpbihtZW0sIHEpCiAgICAgICAgICAg
IG9yaWcgPSBjdGwuc25hcHNob3QoKQogICAgICAgICAgICBjdGwubXV4X2dwaW8oKQogICAgICAg
ICAgICBjdGwuc2V0KHZhbCkKICAgICAgICAgICAgY3RsLnNldF9kaXIoVHJ1ZSkKICAgICAgICAg
ICAgc3lzLnN0ZG91dC53cml0ZSgiXHIgIFslZC8lZF0gJXMoJWQpPSVkICAgICAgIiAlICgKICAg
ICAgICAgICAgICAgIChuICogMiArICgwIGlmIHZhbCBlbHNlIDEpICsgMSksIGxlbihjYW5kcykg
KiAyLCBwaW5fbmFtZShxKSwgcSwgdmFsKSkKICAgICAgICAgICAgc3lzLnN0ZG91dC5mbHVzaCgp
CiAgICAgICAgICAgIHRpbWUuc2xlZXAoMC4yNSkKICAgICAgICAgICAgZm9yIGFkZHIgaW4gcmFu
Z2UoOCk6CiAgICAgICAgICAgICAgICBwaWQgPSBwaHlfaWQobWVtLCAxMjEsIDEyMCwgYWRkcikK
ICAgICAgICAgICAgICAgIGlmIGlzX3ZhbGlkKHBpZCk6CiAgICAgICAgICAgICAgICAgICAgaGl0
cy5hcHBlbmQoKHEsIHZhbCwgYWRkciwgcGlkKSkKICAgICAgICAgICAgICAgICAgICBwcmludCgi
IikKICAgICAgICAgICAgICAgICAgICBwcmludCgiICDlkb3kuK3vvIHmjqfliLbohJo9JXMoJWQp
IOaLiSVzIFBIWeWcsOWdgD0lZCBpZD0weCUwOFgiICUgKAogICAgICAgICAgICAgICAgICAgICAg
ICBwaW5fbmFtZShxKSwgcSwgIumrmCIgaWYgdmFsIGVsc2UgIuS9jiIsIGFkZHIsIHBpZCkpCiAg
ICAgICAgICAgIGN0bC5yZXN0b3JlKG9yaWcpCiAgICBwcmludCgiIikKICAgIGlmIG5vdCBoaXRz
OgogICAgICAgIHByaW50KCLnu5PmnpzvvJpiYW5rICVzIOi/mSAlZCDlj6rohJrvvIzml6Dorrrm
i4npq5jov5jmmK/mi4nkvY7vvIxEMS9EMCDkuIrpg73msqHmnIkgUEhZIOW6lOetlOOAgiIgJSAo
CiAgICAgICAgICAgICIsIi5qb2luKHN0cihiKSBmb3IgYiBpbiBiYW5rcyksIGxlbihjYW5kcykp
KQogICAgICAgIHByaW50KCIgICAgICDor7TmmI4gUEhZIOS4jeWcqCBEMS9EMCDkuIrvvIzmiJbo
gIUgUEhZIOagueacrOayoeS+m+eUte+8iOS4i+S4gOatpeafpSBiYW5rMC9iYW5rMSDnmoTnqbrp
l7LohJrvvInjgIIiKQogICAgZWxzZToKICAgICAgICBwcmludCgi57uT5p6c77ya5om+5YiwICVk
IOWkhOW6lOetlO+8jOingeS4iumdouWIl+ihqOOAgiIgJSBsZW4oaGl0cykpCiAgICBwcmludCgi
5pS25bC+77yabWRpby1zY2FuIGZyZWUgYWxsIikKICAgIHJldHVybiBsZW4oaGl0cykKCgpkZWYg
Y21kX211eChtZW0sIGFyZ3MpOgogICAgIiIi55u05o6l5pS55p+Q5Y+q6ISa55qEIGlvbXV4IOWA
vO+8iDA9R1BJT++8jDEvMi8zPeivpeiEmueahOWKn+iDveWPt++8ieOAguWPquWFgeiuuCBiYW5r
Mi9iYW5rM+OAgiIiIgogICAgbnVtcyA9IFtpbnQoYSkgZm9yIGEgaW4gYXJncyBpZiBhLmlzZGln
aXQoKV0KICAgIGlmIGxlbihudW1zKSA8IDI6CiAgICAgICAgcHJpbnQoIueUqOazle+8mm1kaW8t
c2NhbiBtdXggPOiEmuWPtz4gPOWAvD4gICDkvovlpoIgbWRpby1zY2FuIG11eCAxMTcgMiIpCiAg
ICAgICAgcmV0dXJuIDEKICAgIG4sIHZhbCA9IG51bXNbMF0sIG51bXNbMV0KICAgIGlmIG4gLy8g
MzIgaW4gQkxBQ0tfQkFOS1MgYW5kICItLWZvcmNlIiBub3QgaW4gYXJnczoKICAgICAgICBwcmlu
dCgi5ouS57ud77yaR1BJTyVkIOaYr+mXquWtmC9QTUlDL2VNTUMg5Yy677yM5LiN5YWB6K645pS5
IGlvbXV444CCIiAlIChuIC8vIDMyKSkKICAgICAgICByZXR1cm4gMQogICAgcCA9IFBpbihtZW0s
IG4pCiAgICBtc3QgPSBsb2FkX211eCgpCiAgICBrZXkgPSBzdHIobikKICAgIGlmIGtleSBub3Qg
aW4gbXN0OgogICAgICAgIG1zdFtrZXldID0gcC5tdXhfZ2V0KCkKICAgICAgICBzYXZlX211eCht
c3QpCiAgICBwLm11eF9zZXQodmFsKQogICAgcHJpbnQoIiVzKCVkKSBpb211eCAlZCAtPiAlZO+8
iOWOn+WAvCAlZO+8jOWPr+eUqCBtZGlvLXNjYW4gZnJlZSBhbGwg5oGi5aSN77yJIiAlICgKICAg
ICAgICBwaW5fbmFtZShuKSwgbiwgbXN0W2tleV0sIHZhbCwgbXN0W2tleV0pKQogICAgcmV0dXJu
IDAKCgpkZWYgY21kX3JlZ3MobWVtLCBhcmdzKToKICAgICIiIuivu+afkOS4qiBQSFkg5Zyw5Z2A
55qEIDB+NSDlj7flr4TlrZjlmajvvIznlKjkuo7noa7orqQgUEhZIOecn+eahOa0u+edgOOAgiIi
IgogICAgbnVtcyA9IFtpbnQoYSkgZm9yIGEgaW4gYXJncyBpZiBhLmlzZGlnaXQoKV0KICAgIGFk
ZHIgPSBudW1zWzBdIGlmIGxlbihudW1zKSA+PSAxIGVsc2UgMAogICAgbWRjX251bSA9IG51bXNb
MV0gaWYgbGVuKG51bXMpID49IDIgZWxzZSAxMjEKICAgIG1kaW9fbnVtID0gbnVtc1syXSBpZiBs
ZW4obnVtcykgPj0gMyBlbHNlIDEyMAogICAgbmFtZXMgPSBbIkJNQ1IiLCAiQk1TUiIsICJQSFlJ
RDEiLCAiUEhZSUQyIiwgIkFOQVIiLCAiQU5MUEFSIl0KICAgIHByaW50KCLor7sgJXMvJXMg5LiK
IFBIWSDlnLDlnYAgJWQg55qE5a+E5a2Y5Zmo77yaIiAlICgKICAgICAgICBwaW5fbmFtZShtZGNf
bnVtKSwgcGluX25hbWUobWRpb19udW0pLCBhZGRyKSkKICAgIHZhbHMgPSBbXQogICAgZm9yIHIg
aW4gcmFuZ2UoNik6CiAgICAgICAgdiA9IGJiX3JlYWQoUGluKG1lbSwgbWRjX251bSksIFBpbiht
ZW0sIG1kaW9fbnVtKSwgYWRkciwgcikKICAgICAgICB2YWxzLmFwcGVuZCh2KQogICAgICAgIHBy
aW50KCIgIHJlZyVkICUtN3MgPSAweCUwNFgiICUgKHIsIG5hbWVzW3JdLCB2KSkKICAgIHBpZCA9
ICh2YWxzWzJdIDw8IDE2KSB8IHZhbHNbM10KICAgIHByaW50KCIgIFBIWSBJRCA9IDB4JTA4WCVz
IiAlIChwaWQsICIgIDw9PSDmnInmlYgiIGlmIGlzX3ZhbGlkKHBpZCkgZWxzZSAiICA8PT0g5peg
5pWIL+aXoOW6lOetlCIpKQogICAgaWYgaXNfdmFsaWQocGlkKToKICAgICAgICBwcmludCgiICBP
VUk9MHglMDZYICDlnovlj7c9MHglMDNYICDniYjmnKw9JWQiICUgKAogICAgICAgICAgICAocGlk
ID4+IDEwKSAmIDB4RkZGRkZGLCAocGlkID4+IDQpICYgMHgzRiwgcGlkICYgMHhGKSkKICAgICAg
ICBpZiAocGlkID4+IDEwKSAmIDB4RkZGRkZGID09IDB4MDAxQ0MwOgogICAgICAgICAgICBwcmlu
dCgiICBPVUkgMHgwMDFDQzAgPSBSZWFsdGVr77yM5LiO5L2g5p2/5LiK55qEIFJUTDgyMDFGTiDl
kLvlkIgiKQogICAgYm1zciA9IHZhbHNbMV0KICAgIGlmIGlzX3ZhbGlkKHBpZCk6CiAgICAgICAg
cHJpbnQoIiAgQk1TUjog6ZO+6LevPSVzIOiHquWNj+WVhuWujOaIkD0lcyAxME09JXMgMTAwTT0l
cyIgJSAoCiAgICAgICAgICAgICJ1cCIgaWYgYm1zciAmIDB4MDAwNCBlbHNlICJkb3duIiwKICAg
ICAgICAgICAgIuaYryIgaWYgYm1zciAmIDB4MDAyMCBlbHNlICLlkKYiLAogICAgICAgICAgICAi
5pSv5oyBIiBpZiBibXNyICYgMHgwODAwIGVsc2UgIuS4jeaUr+aMgSIsCiAgICAgICAgICAgICLm
lK/mjIEiIGlmIGJtc3IgJiAweDEwMDAgZWxzZSAi5LiN5pSv5oyBIikpCiAgICByZXR1cm4gMAoK
CmRlZiBjbWRfZHVtcChtZW0sIGFyZ3MpOgogICAgZm9yIGIsIGJhc2UgaW4gZW51bWVyYXRlKEdQ
SU9fQkFTRSk6CiAgICAgICAgcHJpbnQoIkdQSU8lZCBiYXNlPTB4JTA4WCBEUj0weCUwOFggRERS
PTB4JTA4WCBFWFQ9MHglMDhYIiAlICgKICAgICAgICAgICAgYiwgYmFzZSwKICAgICAgICAgICAg
bWVtLnJkKGJhc2UgKyBSRUdfRFIpLCBtZW0ucmQoYmFzZSArIFJFR19ERFIpLCBtZW0ucmQoYmFz
ZSArIFJFR19FWFQpKSkKICAgIHJldHVybiAwCgoKQ01EUyA9IHsKICAgICJwaW4iOiBjbWRfcGlu
LAogICAgInNhZmUiOiBjbWRfc2FmZSwKICAgICJzY2FuIjogY21kX3NjYW4sCiAgICAic3dlZXAi
OiBjbWRfc3dlZXAsCiAgICAiY3RsIjogY21kX2N0bCwKICAgICJob2xkIjogY21kX2hvbGQsCiAg
ICAiZnJlZSI6IGNtZF9mcmVlLAogICAgIndha2UiOiBjbWRfd2FrZSwKICAgICJtdXgiOiBjbWRf
bXV4LAogICAgInByb2JlIjogY21kX3Byb2JlLAogICAgInJlZ3MiOiBjbWRfcmVncywKICAgICJk
dW1wIjogY21kX2R1bXAsCn0KCgpkZWYgbWFpbigpOgogICAgaWYgbGVuKHN5cy5hcmd2KSA8IDIg
b3Igc3lzLmFyZ3ZbMV0gbm90IGluIENNRFM6CiAgICAgICAgcHJpbnQoX19kb2NfXyBvciAiIikK
ICAgICAgICBwcmludCgi5Y+v55So5ZG95Luk77yaIiArICIgLyAiLmpvaW4oc29ydGVkKENNRFMp
KSkKICAgICAgICByZXR1cm4gMgogICAgbWVtID0gTWVtKCkKICAgIHIgPSBDTURTW3N5cy5hcmd2
WzFdXShtZW0sIHN5cy5hcmd2WzI6XSkKICAgIGlmIHIgaXMgTm9uZToKICAgICAgICByZXR1cm4g
MAogICAgcmV0dXJuIDAgaWYgciA+PSAwIGVsc2UgMQoKCmlmIF9fbmFtZV9fID09ICJfX21haW5f
XyI6CiAgICBzeXMuZXhpdChtYWluKCkpCg==
MDIOSCAN_B64
chmod 755 /usr/local/bin/mdio-scan
if [ ! -x /usr/bin/python3 ] && [ ! -x /usr/local/bin/python3 ]; then
    echo "⚠️  rootfs 里没有 python3，mdio-scan 无法运行"
else
    echo "✅ 已安装 /usr/local/bin/mdio-scan（python3 版 MDIO 引脚探测工具）"
fi
