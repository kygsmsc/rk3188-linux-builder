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
5oCBL+aOp+WItu+8iQogIG1kaW8tc2NhbiBob2xkIDk2ICAgICAgICAgICAgICAjIOaKiuafkOS4
quiEmuaLiemrmOW5tuS/neaMge+8iOmFjeWQiCLnnIsgUko0NSDnga8i5Yik5a6a5aSN5L2NL+S+
m+eUteiEmu+8iQogIG1kaW8tc2NhbiBob2xkIDk2IGxvdyAgICAgICAgICAjIOaLieS9juW5tuS/
neaMgQogIG1kaW8tc2NhbiBmcmVlIDk2ICAgICAgICAgICAgICAjIOaBouWkjeWIsCBob2xkIOS5
i+WJjeeahOeKtuaAgQogIG1kaW8tc2NhbiBmcmVlIGFsbCAgICAgICAgICAgICAjIOaBouWkjeWF
qOmDqO+8iEN0cmwtQyDmiZPmlq3lkI7ot5Hov5nkuKrmlLblsL7vvIkKICBtZGlvLXNjYW4gY3Rs
ICAgICAgICAgICAgICAgICAgIyDpgJDkuKrmiorlronlhajohJrmi4npq5jvvIzlho3nnIsgRDEv
RDAg5LiK5pyJ5rKh5pyJIFBIWSDlupTnrZQKICBtZGlvLXNjYW4gc3dlZXAgICAgICAgICAgICAg
ICAgIyDnm7jpgrvlronlhajohJrlr7nmraPlj43mnoHmgKfmiasgMH4377yI5Y+q5ZyoIGJhbmsz
77yJCiAgbWRpby1zY2FuIGR1bXAgICAgICAgICAgICAgICAgICMg5omT5Y2wIDQg5LiqIGJhbmsg
55qEIERSL0REUi9FWFQKIiIiCgppbXBvcnQgZ2xvYgppbXBvcnQganNvbgppbXBvcnQgbW1hcApp
bXBvcnQgb3MKaW1wb3J0IHN5cwppbXBvcnQgdGltZQoKR1BJT19CQVNFID0gWzB4MjAwMEEwMDAs
IDB4MjAwM0MwMDAsIDB4MjAwM0UwMDAsIDB4MjAwODAwMDBdCkdSRl9CQVNFID0gMHgyMDAwODAw
MApSRUdfRFIgPSAweDAwClJFR19ERFIgPSAweDA0ClJFR19FWFQgPSAweDUwClBBR0UgPSA0MDk2
CgpEID0gM2UtNgpCQURfSURTID0gKDB4MDAwMDAwMDAsIDB4MDAwMEZGRkYsIDB4RkZGRkZGRkYs
IDB4RkZGRjAwMDAsIDB4MDAwMEZGRkUpCgpTVEFURV9GSUxFID0gIi90bXAvbWRpby1zY2FuLW9y
aWcuanNvbiIKCiMg5pW057uE5ouJ6buR77yaYmFuazAg5pyJIFNQSSBGbGFzaCAvIFBNSUMoSTJD
Ke+8jGJhbmsxIOaciSBlTU1DIC8gVUFSVDIoY29uc29sZSkKQkxBQ0tfQkFOS1MgPSAoMCwgMSkK
IyBiYW5rMyDkuIrmraPlnKjooqvmiJHku6wgRFRTIOS9v+eUqOeahOiEmu+8mkMwfkM3IOaYryBS
TUlJ77yMRDAvRDEg5pivIE1EQy9NRElP77yM6YO95LiN5b2T5o6n5Yi26ISaCkVNQUNfUk1JSSA9
IHR1cGxlKHJhbmdlKDExMiwgMTIwKSkKTURJT19QSU5TID0gKDEyMCwgMTIxKQoKCmRlZiBwaW5f
bmFtZShudW0pOgogICAgYmFuayA9IG51bSAvLyAzMgogICAgZ3JwID0gIkFCQ0QiWyhudW0gJSAz
MikgLy8gOF0KICAgIGlkeCA9IG51bSAlIDgKICAgIHJldHVybiAiR1BJTyVkXyVzJWQiICUgKGJh
bmssIGdycCwgaWR4KQoKCmNsYXNzIE1lbShvYmplY3QpOgogICAgZGVmIF9faW5pdF9fKHNlbGYp
OgogICAgICAgIHNlbGYuZmQgPSBvcy5vcGVuKCIvZGV2L21lbSIsIG9zLk9fUkRXUiB8IG9zLk9f
U1lOQykKICAgICAgICBzZWxmLm1hcHMgPSB7fQoKICAgIGRlZiBfcGFnZShzZWxmLCBhZGRyKToK
ICAgICAgICBiYXNlID0gYWRkciAmIH4oUEFHRSAtIDEpCiAgICAgICAgbSA9IHNlbGYubWFwcy5n
ZXQoYmFzZSkKICAgICAgICBpZiBtIGlzIE5vbmU6CiAgICAgICAgICAgIG0gPSBtbWFwLm1tYXAo
c2VsZi5mZCwgUEFHRSwgbW1hcC5NQVBfU0hBUkVELAogICAgICAgICAgICAgICAgICAgICAgICAg
IG1tYXAuUFJPVF9SRUFEIHwgbW1hcC5QUk9UX1dSSVRFLCBvZmZzZXQ9YmFzZSkKICAgICAgICAg
ICAgc2VsZi5tYXBzW2Jhc2VdID0gbQogICAgICAgIHJldHVybiBtLCBhZGRyIC0gYmFzZQoKICAg
IGRlZiByZChzZWxmLCBhZGRyKToKICAgICAgICBtLCBvID0gc2VsZi5fcGFnZShhZGRyKQogICAg
ICAgIHJldHVybiBpbnQuZnJvbV9ieXRlcyhtW286byArIDRdLCAibGl0dGxlIikKCiAgICBkZWYg
d3Ioc2VsZiwgYWRkciwgdmFsKToKICAgICAgICBtLCBvID0gc2VsZi5fcGFnZShhZGRyKQogICAg
ICAgIG1bbzpvICsgNF0gPSAodmFsICYgMHhGRkZGRkZGRikudG9fYnl0ZXMoNCwgImxpdHRsZSIp
CgoKY2xhc3MgUGluKG9iamVjdCk6CiAgICBkZWYgX19pbml0X18oc2VsZiwgbWVtLCBudW0pOgog
ICAgICAgIHNlbGYubWVtID0gbWVtCiAgICAgICAgc2VsZi5udW0gPSBudW0KICAgICAgICBzZWxm
LmJhbmsgPSBudW0gLy8gMzIKICAgICAgICBzZWxmLmlkeCA9IG51bSAlIDMyCiAgICAgICAgc2Vs
Zi5iYXNlID0gR1BJT19CQVNFW3NlbGYuYmFua10KCiAgICBkZWYgc2V0X2RpcihzZWxmLCBvdXQp
OgogICAgICAgIGEgPSBzZWxmLmJhc2UgKyBSRUdfRERSCiAgICAgICAgdiA9IHNlbGYubWVtLnJk
KGEpCiAgICAgICAgaWYgb3V0OgogICAgICAgICAgICB2IHw9ICgxIDw8IHNlbGYuaWR4KQogICAg
ICAgIGVsc2U6CiAgICAgICAgICAgIHYgJj0gfigxIDw8IHNlbGYuaWR4KQogICAgICAgIHNlbGYu
bWVtLndyKGEsIHYpCgogICAgZGVmIHNldChzZWxmLCB2YWwpOgogICAgICAgIGEgPSBzZWxmLmJh
c2UgKyBSRUdfRFIKICAgICAgICB2ID0gc2VsZi5tZW0ucmQoYSkKICAgICAgICBpZiB2YWw6CiAg
ICAgICAgICAgIHYgfD0gKDEgPDwgc2VsZi5pZHgpCiAgICAgICAgZWxzZToKICAgICAgICAgICAg
diAmPSB+KDEgPDwgc2VsZi5pZHgpCiAgICAgICAgc2VsZi5tZW0ud3IoYSwgdikKCiAgICBkZWYg
Z2V0KHNlbGYpOgogICAgICAgIHJldHVybiAoc2VsZi5tZW0ucmQoc2VsZi5iYXNlICsgUkVHX0VY
VCkgPj4gc2VsZi5pZHgpICYgMQoKICAgIGRlZiBfaW9tdXhfYWRkcl9iaXQoc2VsZik6CiAgICAg
ICAgb2ZmID0gMHg2MCArIChzZWxmLmJhbmsgKiA0ICsgc2VsZi5pZHggLy8gOCkgKiA0CiAgICAg
ICAgcmV0dXJuIEdSRl9CQVNFICsgb2ZmLCAoc2VsZi5pZHggJSA4KSAqIDIKCiAgICBkZWYgbXV4
X2dldChzZWxmKToKICAgICAgICBhLCBiID0gc2VsZi5faW9tdXhfYWRkcl9iaXQoKQogICAgICAg
IHJldHVybiAoc2VsZi5tZW0ucmQoYSkgPj4gYikgJiAzCgogICAgZGVmIG11eF9zZXQoc2VsZiwg
dmFsKToKICAgICAgICBhLCBiID0gc2VsZi5faW9tdXhfYWRkcl9iaXQoKQogICAgICAgIHYgPSBz
ZWxmLm1lbS5yZChhKQogICAgICAgIHNlbGYubWVtLndyKGEsICh2ICYgfigzIDw8IGIpKSB8ICgo
dmFsICYgMykgPDwgYikpCgogICAgZGVmIG11eF9ncGlvKHNlbGYpOgogICAgICAgIHNlbGYubXV4
X3NldCgwKQoKICAgIGRlZiBkaXJfb3V0KHNlbGYpOgogICAgICAgIHJldHVybiBib29sKChzZWxm
Lm1lbS5yZChzZWxmLmJhc2UgKyBSRUdfRERSKSA+PiBzZWxmLmlkeCkgJiAxKQoKICAgIGRlZiBz
bmFwc2hvdChzZWxmKToKICAgICAgICByZXR1cm4geyJtdXgiOiBzZWxmLm11eF9nZXQoKSwgIm91
dCI6IHNlbGYuZGlyX291dCgpLCAiZHIiOiBzZWxmLmdldCgpfQoKICAgIGRlZiByZXN0b3JlKHNl
bGYsIHMpOgogICAgICAgIHNlbGYubXV4X3NldChzWyJtdXgiXSkKICAgICAgICBpZiBzWyJvdXQi
XToKICAgICAgICAgICAgc2VsZi5zZXQoMSBpZiBzWyJkciJdIGVsc2UgMCkKICAgICAgICAgICAg
c2VsZi5zZXRfZGlyKFRydWUpCiAgICAgICAgZWxzZToKICAgICAgICAgICAgc2VsZi5zZXRfZGly
KEZhbHNlKQoKCmRlZiBsb2FkX3N0YXRlKCk6CiAgICB0cnk6CiAgICAgICAgcmV0dXJuIGpzb24u
bG9hZChvcGVuKFNUQVRFX0ZJTEUpKQogICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICByZXR1
cm4ge30KCgpkZWYgc2F2ZV9zdGF0ZShzdCk6CiAgICB0cnk6CiAgICAgICAganNvbi5kdW1wKHN0
LCBvcGVuKFNUQVRFX0ZJTEUsICJ3IikpCiAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgIHBh
c3MKCgpkZWYgcGFyc2VfYmFua3MoYXJncywgZGVmYXVsdD0oMywpKToKICAgIGJhbmtzID0gZGVm
YXVsdAogICAgaWYgIi0tYWxsIiBpbiBhcmdzOgogICAgICAgIGJhbmtzID0gKDAsIDEsIDIsIDMp
CiAgICBmb3IgYSBpbiBhcmdzOgogICAgICAgIGlmIGEuc3RhcnRzd2l0aCgiLS1iYW5rPSIpOgog
ICAgICAgICAgICBiYW5rcyA9IHR1cGxlKGludCh4KSBmb3IgeCBpbiBhLnNwbGl0KCI9IiwgMSlb
MV0uc3BsaXQoIiwiKSkKICAgIHJldHVybiBiYW5rcwoKCmRlZiBzYWZlX3BpbnMobWVtLCBiYW5r
cywgYW55X211eD1GYWxzZSwgZm9yY2U9RmFsc2UpOgogICAgIiIi6Ieq5bex6K+7IGlvbXV4IOWI
pOaWre+8mm11eD09MO+8iOW9k+WJjeWwseaYryBHUElP77yJ5LiU5Zyo5YWB6K6455qEIGJhbmsg
5YaF5omN6L+U5Zue44CCIiIiCiAgICBoZWxkID0gc2V0KGludChrKSBmb3IgayBpbiBsb2FkX3N0
YXRlKCkua2V5cygpKQogICAgcGlucyA9IFtdCiAgICBmb3IgYiBpbiBiYW5rczoKICAgICAgICBp
ZiBiIGluIEJMQUNLX0JBTktTIGFuZCBub3QgZm9yY2U6CiAgICAgICAgICAgIGNvbnRpbnVlCiAg
ICAgICAgZm9yIHAgaW4gcmFuZ2UoYiAqIDMyLCBiICogMzIgKyAzMik6CiAgICAgICAgICAgIGlm
IHAgaW4gTURJT19QSU5TIG9yIHAgaW4gRU1BQ19STUlJIG9yIHAgaW4gaGVsZDoKICAgICAgICAg
ICAgICAgIGNvbnRpbnVlCiAgICAgICAgICAgIGlmIG5vdCBhbnlfbXV4IGFuZCBQaW4obWVtLCBw
KS5tdXhfZ2V0KCkgIT0gMDoKICAgICAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgICAgIHBp
bnMuYXBwZW5kKHApCiAgICByZXR1cm4gc29ydGVkKHBpbnMpCgoKZGVmIGJiX3JlYWQobWRjLCBt
ZGlvLCBwaHksIHJlZyk6CiAgICAiIiLmoIflh4YgQ2xhdXNlIDIyIOivu++8mnByZWFtYmxlICsg
U1QoMDEpICsgT1AoMTApICsgUEhZQUQoNSkgKyBSRUdBRCg1KSArIFRBICsgMTYg5pWw5o2u5L2N
IiIiCiAgICBtZGlvLm11eF9ncGlvKCkKICAgIG1kYy5tdXhfZ3BpbygpCiAgICBtZGMuc2V0X2Rp
cihUcnVlKQogICAgbWRjLnNldCgwKQogICAgbWRpby5zZXRfZGlyKFRydWUpCgogICAgZGVmIGNs
a193cml0ZShiaXQpOgogICAgICAgIG1kaW8uc2V0KGJpdCkKICAgICAgICB0aW1lLnNsZWVwKEQp
CiAgICAgICAgbWRjLnNldCgxKQogICAgICAgIHRpbWUuc2xlZXAoRCkKICAgICAgICBtZGMuc2V0
KDApCiAgICAgICAgdGltZS5zbGVlcChEKQoKICAgIGZvciBfIGluIHJhbmdlKDMyKToKICAgICAg
ICBjbGtfd3JpdGUoMSkKCiAgICBiaXRzID0gWzAsIDEsIDEsIDBdCiAgICBmb3IgaSBpbiByYW5n
ZSg0LCAtMSwgLTEpOgogICAgICAgIGJpdHMuYXBwZW5kKChwaHkgPj4gaSkgJiAxKQogICAgZm9y
IGkgaW4gcmFuZ2UoNCwgLTEsIC0xKToKICAgICAgICBiaXRzLmFwcGVuZCgocmVnID4+IGkpICYg
MSkKICAgIGZvciBiIGluIGJpdHM6CiAgICAgICAgY2xrX3dyaXRlKGIpCgogICAgbWRpby5zZXRf
ZGlyKEZhbHNlKQogICAgdGltZS5zbGVlcChEKQogICAgbWRjLnNldCgxKQogICAgdGltZS5zbGVl
cChEKQogICAgbWRjLnNldCgwKQogICAgdGltZS5zbGVlcChEKQoKICAgIHZhbCA9IDAKICAgIGZv
ciBfIGluIHJhbmdlKDE2KToKICAgICAgICB0aW1lLnNsZWVwKEQpCiAgICAgICAgbWRjLnNldCgx
KQogICAgICAgIHRpbWUuc2xlZXAoRCkKICAgICAgICB2YWwgPSAodmFsIDw8IDEpIHwgbWRpby5n
ZXQoKQogICAgICAgIG1kYy5zZXQoMCkKICAgICAgICB0aW1lLnNsZWVwKEQpCiAgICByZXR1cm4g
dmFsCgoKZGVmIHBoeV9pZChtZW0sIG1kY19udW0sIG1kaW9fbnVtLCBhZGRyKToKICAgIG1kYyA9
IFBpbihtZW0sIG1kY19udW0pCiAgICBtZGlvID0gUGluKG1lbSwgbWRpb19udW0pCiAgICBoaSA9
IGJiX3JlYWQobWRjLCBtZGlvLCBhZGRyLCAyKQogICAgbG8gPSBiYl9yZWFkKG1kYywgbWRpbywg
YWRkciwgMykKICAgIHJldHVybiAoaGkgPDwgMTYpIHwgbG8KCgpkZWYgaXNfdmFsaWQocGlkKToK
ICAgIGlmIHBpZCBpbiBCQURfSURTOgogICAgICAgIHJldHVybiBGYWxzZQogICAgaGkgPSAocGlk
ID4+IDE2KSAmIDB4RkZGRgogICAgbG8gPSBwaWQgJiAweEZGRkYKICAgIGlmIGhpIGluICgweDAw
MDAsIDB4RkZGRikgYW5kIGxvIGluICgweDAwMDAsIDB4RkZGRik6CiAgICAgICAgcmV0dXJuIEZh
bHNlCiAgICByZXR1cm4gVHJ1ZQoKCmRlZiBjbWRfcGluKG1lbSwgYXJncyk6CiAgICBmb3IgYSBp
biBhcmdzOgogICAgICAgIHAgPSBQaW4obWVtLCBpbnQoYSkpCiAgICAgICAgcHJpbnQoInBpbiAl
LTNkICUtMTBzIG11eD0lZCBkaXI9JXMgbGV2ZWw9JWQiICUgKAogICAgICAgICAgICBwLm51bSwg
cGluX25hbWUocC5udW0pLCBwLm11eF9nZXQoKSwKICAgICAgICAgICAgIm91dCIgaWYgcC5kaXJf
b3V0KCkgZWxzZSAiaW4iLCBwLmdldCgpKSkKICAgIHJldHVybiAwCgoKZGVmIGNtZF9zYWZlKG1l
bSwgYXJncyk6CiAgICBiYW5rcyA9IHBhcnNlX2JhbmtzKGFyZ3MpCiAgICBhbnlfbXV4ID0gIi0t
YW55IiBpbiBhcmdzCiAgICBmb3JjZSA9ICItLWZvcmNlIiBpbiBhcmdzCiAgICBwaW5zID0gc2Fm
ZV9waW5zKG1lbSwgYmFua3MsIGFueV9tdXgsIGZvcmNlKQogICAgaWYgIi0tbGlzdCIgaW4gYXJn
czoKICAgICAgICBmb3IgcCBpbiBwaW5zOgogICAgICAgICAgICBwcmludChwKQogICAgICAgIHJl
dHVybiAwCiAgICBwcmludCgiYmFuayAlcyDph4zlj6/lronlhajmk43kvZznmoTlvJXohJrlhbEg
JWQg5Liq77yIbXV4PT0wIOS4lOacquiiq+aOkumZpO+8ie+8miIgJSAoCiAgICAgICAgIiwiLmpv
aW4oc3RyKGIpIGZvciBiIGluIGJhbmtzKSwgbGVuKHBpbnMpKSkKICAgIGZvciBwIGluIHBpbnM6
CiAgICAgICAgcSA9IFBpbihtZW0sIHApCiAgICAgICAgcHJpbnQoIiAgJS0zZCAlLTEwcyBtdXg9
JWQgZGlyPSVzIGxldmVsPSVkIiAlICgKICAgICAgICAgICAgcCwgcGluX25hbWUocCksIHEubXV4
X2dldCgpLCAib3V0IiBpZiBxLmRpcl9vdXQoKSBlbHNlICJpbiIsIHEuZ2V0KCkpKQogICAgaWYg
bm90IHBpbnM6CiAgICAgICAgcHJpbnQoIiAg77yI5LiA5Liq6YO95rKh5pyJ44CC5Y+v6IO96L+Z
5LqbIGJhbmsg55qE6ISa5YWo6KKr5Y2g55So5LqG77yM6K+V6K+VIC0tYmFuaz0yIOaIliAtLWFu
ee+8iSIpCiAgICByZXR1cm4gMAoKCmRlZiBjbWRfc2NhbihtZW0sIGFyZ3MpOgogICAgbnVtcyA9
IFtpbnQoYSkgZm9yIGEgaW4gYXJncyBpZiBhLmlzZGlnaXQoKV0KICAgIG1kY19udW0gPSBudW1z
WzBdIGlmIGxlbihudW1zKSA+PSAxIGVsc2UgMTIxCiAgICBtZGlvX251bSA9IG51bXNbMV0gaWYg
bGVuKG51bXMpID49IDIgZWxzZSAxMjAKICAgIGxvID0gbnVtc1syXSBpZiBsZW4obnVtcykgPj0g
MyBlbHNlIDAKICAgIGhpID0gbnVtc1szXSBpZiBsZW4obnVtcykgPj0gNCBlbHNlIDcKICAgIHBy
aW50KCLmiasgJXMoTURDKSAvICVzKE1ESU8pIOWcsOWdgCAlZH4lZCIgJSAoCiAgICAgICAgcGlu
X25hbWUobWRjX251bSksIHBpbl9uYW1lKG1kaW9fbnVtKSwgbG8sIGhpKSkKICAgIGhpdCA9IDAK
ICAgIGZvciBhZGRyIGluIHJhbmdlKGxvLCBoaSArIDEpOgogICAgICAgIHBpZCA9IHBoeV9pZCht
ZW0sIG1kY19udW0sIG1kaW9fbnVtLCBhZGRyKQogICAgICAgIGZsYWcgPSAiICA8PT0g5pyJ5bqU
562UIiBpZiBpc192YWxpZChwaWQpIGVsc2UgIiIKICAgICAgICBwcmludCgiICBhZGRyICVkIDog
aWQ9MHglMDhYJXMiICUgKGFkZHIsIHBpZCwgZmxhZykpCiAgICAgICAgaWYgaXNfdmFsaWQocGlk
KToKICAgICAgICAgICAgaGl0ICs9IDEKICAgIHByaW50KCLlkIjorqHlkb3kuK0gJWQg5Liq5Zyw
5Z2A44CCIiAlIGhpdCkKICAgIHJldHVybiBoaXQKCgpkZWYgY21kX3N3ZWVwKG1lbSwgYXJncyk6
CiAgICBiYW5rcyA9IHBhcnNlX2JhbmtzKGFyZ3MpCiAgICBwaW5zID0gc2FmZV9waW5zKG1lbSwg
YmFua3MpCiAgICBwYWlycyA9IFtdCiAgICBmb3IgcCBpbiBwaW5zOgogICAgICAgIGlmIHAgKyAx
IGluIHBpbnM6CiAgICAgICAgICAgIHBhaXJzLmFwcGVuZCgocCwgcCArIDEpKQogICAgICAgICAg
ICBwYWlycy5hcHBlbmQoKHAgKyAxLCBwKSkKICAgIHByaW50KCJiYW5rICVzIOWGheebuOmCu+Wu
ieWFqOiEmuWvuSAlZCDnu4TvvIjlkKvmraPlj43mnoHmgKfvvInvvIzlvIDlp4vmiavmj48gLi4u
IiAlICgKICAgICAgICAiLCIuam9pbihzdHIoYikgZm9yIGIgaW4gYmFua3MpLCBsZW4ocGFpcnMp
KSkKICAgIGlmIG5vdCBwYWlyczoKICAgICAgICBwcmludCgi5rKh5pyJ5Y+v5omr55qE55u46YK7
6ISa5a+577yM55u05o6l6YCA5Ye644CCIikKICAgICAgICByZXR1cm4gMAogICAgaGl0cyA9IFtd
CiAgICBmb3IgbiwgKGEsIGIpIGluIGVudW1lcmF0ZShwYWlycyk6CiAgICAgICAgc3lzLnN0ZG91
dC53cml0ZSgiXHIgIFslZC8lZF0gTURDPSVkIE1ESU89JWQgICAgICAiICUgKG4gKyAxLCBsZW4o
cGFpcnMpLCBhLCBiKSkKICAgICAgICBzeXMuc3Rkb3V0LmZsdXNoKCkKICAgICAgICBmb3IgYWRk
ciBpbiByYW5nZSg4KToKICAgICAgICAgICAgcGlkID0gcGh5X2lkKG1lbSwgYSwgYiwgYWRkcikK
ICAgICAgICAgICAgaWYgaXNfdmFsaWQocGlkKToKICAgICAgICAgICAgICAgIGhpdHMuYXBwZW5k
KChhLCBiLCBhZGRyLCBwaWQpKQogICAgcHJpbnQoIiIpCiAgICBpZiBub3QgaGl0czoKICAgICAg
ICBwcmludCgi57uT5p6c77ya5rKh5pyJ5Lu75L2V5LiA5a+5ICsg5Lu75L2V5Zyw5Z2A5pyJ5bqU
562U44CCIikKICAgIGVsc2U6CiAgICAgICAgcHJpbnQoIue7k+aenO+8muaJvuWIsCAlZCDlpITl
upTnrZTvvJoiICUgbGVuKGhpdHMpKQogICAgICAgIGZvciBhLCBiLCBhZGRyLCBwaWQgaW4gaGl0
czoKICAgICAgICAgICAgcHJpbnQoIiAgTURDPSVzKCVkKSBNRElPPSVzKCVkKSBQSFnlnLDlnYA9
JWQgaWQ9MHglMDhYIiAlICgKICAgICAgICAgICAgICAgIHBpbl9uYW1lKGEpLCBhLCBwaW5fbmFt
ZShiKSwgYiwgYWRkciwgcGlkKSkKICAgIHJldHVybiBsZW4oaGl0cykKCgpkZWYgY21kX2N0bCht
ZW0sIGFyZ3MpOgogICAgYmFua3MgPSBwYXJzZV9iYW5rcyhhcmdzKQogICAgbnVtcyA9IFtpbnQo
YSkgZm9yIGEgaW4gYXJncyBpZiBhLmlzZGlnaXQoKV0KICAgIG1kY19udW0gPSBudW1zWzBdIGlm
IGxlbihudW1zKSA+PSAxIGVsc2UgMTIxCiAgICBtZGlvX251bSA9IG51bXNbMV0gaWYgbGVuKG51
bXMpID49IDIgZWxzZSAxMjAKICAgIHBpbnMgPSBzYWZlX3BpbnMobWVtLCBiYW5rcykKICAgIHBy
aW50KCJiYW5rICVz77yaJXMvJXMg5LiK5YWI5omr5LiA6YGN5Z+657q/IC4uLiIgJSAoCiAgICAg
ICAgIiwiLmpvaW4oc3RyKGIpIGZvciBiIGluIGJhbmtzKSwgcGluX25hbWUobWRjX251bSksIHBp
bl9uYW1lKG1kaW9fbnVtKSkpCiAgICBmb3IgYWRkciBpbiByYW5nZSg4KToKICAgICAgICBwaWQg
PSBwaHlfaWQobWVtLCBtZGNfbnVtLCBtZGlvX251bSwgYWRkcikKICAgICAgICBwcmludCgiICDl
n7rnur8gYWRkciAlZCA6IGlkPTB4JTA4WCIgJSAoYWRkciwgcGlkKSkKICAgIGlmIG5vdCBwaW5z
OgogICAgICAgIHByaW50KCLmsqHmnInlj6/mk43kvZznmoTmjqfliLbohJrvvIzpgIDlh7rvvIjl
hYjot5EgbWRpby1zY2FuIHNhZmXvvInjgIIiKQogICAgICAgIHJldHVybiAwCiAgICBwcmludCgi
6YCQ5Liq5oqKICVkIOS4quWuieWFqOiEmuaLiemrmO+8jOWQjOaXtuaJqyAwfjcgLi4uIiAlIGxl
bihwaW5zKSkKICAgIGhpdHMgPSBbXQogICAgZm9yIG4sIHAgaW4gZW51bWVyYXRlKHBpbnMpOgog
ICAgICAgIHN5cy5zdGRvdXQud3JpdGUoIlxyICBbJWQvJWRdIOaLiemrmCAlZCAoJXMpICAgICAg
IiAlIChuICsgMSwgbGVuKHBpbnMpLCBwLCBwaW5fbmFtZShwKSkpCiAgICAgICAgc3lzLnN0ZG91
dC5mbHVzaCgpCiAgICAgICAgY3RsID0gUGluKG1lbSwgcCkKICAgICAgICBvcmlnID0gY3RsLnNu
YXBzaG90KCkKICAgICAgICBjdGwubXV4X2dwaW8oKQogICAgICAgIGN0bC5zZXRfZGlyKFRydWUp
CiAgICAgICAgY3RsLnNldCgxKQogICAgICAgIGZvciBhZGRyIGluIHJhbmdlKDgpOgogICAgICAg
ICAgICBwaWQgPSBwaHlfaWQobWVtLCBtZGNfbnVtLCBtZGlvX251bSwgYWRkcikKICAgICAgICAg
ICAgaWYgaXNfdmFsaWQocGlkKToKICAgICAgICAgICAgICAgIGhpdHMuYXBwZW5kKChwLCBhZGRy
LCBwaWQpKQogICAgICAgIGN0bC5yZXN0b3JlKG9yaWcpCiAgICBwcmludCgiIikKICAgIGlmIG5v
dCBoaXRzOgogICAgICAgIHByaW50KCLnu5PmnpzvvJrov5kgJWQg5Liq6ISa6YCQ5Liq5ouJ6auY
77yMRDEvRDAg5LiK6YO95rKh5pyJIFBIWSDlupTnrZTjgIIiICUgbGVuKHBpbnMpKQogICAgZWxz
ZToKICAgICAgICBwcmludCgi57uT5p6c77ya5om+5YiwICVkIOWkhOW6lOetlO+8miIgJSBsZW4o
aGl0cykpCiAgICAgICAgZm9yIHAsIGFkZHIsIHBpZCBpbiBoaXRzOgogICAgICAgICAgICBwcmlu
dCgiICDmjqfliLbohJo9JXMoJWQpIFBIWeWcsOWdgD0lZCBpZD0weCUwOFgiICUgKHBpbl9uYW1l
KHApLCBwLCBhZGRyLCBwaWQpKQogICAgcmV0dXJuIGxlbihoaXRzKQoKCmRlZiBjbWRfaG9sZCht
ZW0sIGFyZ3MpOgogICAgbnVtcyA9IFtpbnQoYSkgZm9yIGEgaW4gYXJncyBpZiBhLmlzZGlnaXQo
KV0KICAgIGxvdyA9ICJsb3ciIGluIGFyZ3MKICAgIGZvciBuIGluIG51bXM6CiAgICAgICAgaWYg
biAvLyAzMiBpbiBCTEFDS19CQU5LUzoKICAgICAgICAgICAgcHJpbnQoIuaLkue7ne+8mkdQSU8l
ZCDmmK/pl6rlrZgvUE1JQy9lTU1DL1VBUlQg5Yy677yM5LiN5YWB6K645Yqo44CCIiAlIChuIC8v
IDMyKSkKICAgICAgICAgICAgY29udGludWUKICAgICAgICBwID0gUGluKG1lbSwgbikKICAgICAg
ICBzdCA9IGxvYWRfc3RhdGUoKQogICAgICAgIGtleSA9IHN0cihuKQogICAgICAgIGlmIGtleSBu
b3QgaW4gc3Q6CiAgICAgICAgICAgIHN0W2tleV0gPSBwLnNuYXBzaG90KCkKICAgICAgICAgICAg
c2F2ZV9zdGF0ZShzdCkKICAgICAgICBwLm11eF9ncGlvKCkKICAgICAgICBwLnNldCgwIGlmIGxv
dyBlbHNlIDEpCiAgICAgICAgcC5zZXRfZGlyKFRydWUpCiAgICAgICAgcHJpbnQoIuW3suaKiiAl
cyglZCkg5ouJJXPlubbkv53mjIHovpPlh7rjgILnnIsgUko0NSDnga/vvJvkuI3kuq7lsLEgbWRp
by1zY2FuIGZyZWUgJWTjgILljp/nirbmgIE9JXMiICUgKAogICAgICAgICAgICBwaW5fbmFtZShu
KSwgbiwgIuS9jiIgaWYgbG93IGVsc2UgIumrmCIsIG4sIHN0W2tleV0pKQogICAgcmV0dXJuIDAK
CgpkZWYgY21kX2ZyZWUobWVtLCBhcmdzKToKICAgIHN0ID0gbG9hZF9zdGF0ZSgpCiAgICBpZiAi
YWxsIiBpbiBhcmdzOgogICAgICAgIGZvciBrIGluIGxpc3Qoc3Qua2V5cygpKToKICAgICAgICAg
ICAgUGluKG1lbSwgaW50KGspKS5yZXN0b3JlKHN0W2tdKQogICAgICAgICAgICBwcmludCgi5bey
5oGi5aSNICVzKCVkKSAtPiAlcyIgJSAocGluX25hbWUoaW50KGspKSwgaW50KGspLCBzdFtrXSkp
CiAgICAgICAgc2F2ZV9zdGF0ZSh7fSkKICAgICAgICByZXR1cm4gMAogICAgZm9yIGEgaW4gYXJn
czoKICAgICAgICBuID0gaW50KGEpCiAgICAgICAgcCA9IFBpbihtZW0sIG4pCiAgICAgICAgaWYg
c3RyKG4pIGluIHN0OgogICAgICAgICAgICBwLnJlc3RvcmUoc3Rbc3RyKG4pXSkKICAgICAgICAg
ICAgcHJpbnQoIuW3suaKiiAlcyglZCkg5oGi5aSN5YiwIGhvbGQg5LmL5YmN77yaJXMiICUgKHBp
bl9uYW1lKG4pLCBuLCBzdFtzdHIobildKSkKICAgICAgICAgICAgZGVsIHN0W3N0cihuKV0KICAg
ICAgICAgICAgc2F2ZV9zdGF0ZShzdCkKICAgICAgICBlbHNlOgogICAgICAgICAgICBwLnNldCgw
KQogICAgICAgICAgICBwLnNldF9kaXIoRmFsc2UpCiAgICAgICAgICAgIHByaW50KCLlt7Lmioog
JXMoJWQpIOaUvuW8gO+8iOi+k+WFpeOAgeS9jueUteW5s++8ieOAgiIgJSAocGluX25hbWUobiks
IG4pKQogICAgcmV0dXJuIDAKCgpkZWYgY21kX3dha2UobWVtLCBhcmdzKToKICAgICIiIuWFiOe7
mSBQSFkg5L2/6IO96ISa77yI6buY6K6kIEdQSU8zX0QyPTEyMu+8ieS4iueUteW5tuS/neaMge+8
jOWGjeaJqyBEMS9EMCDnmoQgMH4344CCCiAgICDov5nmnaHlkb3ku6TlsLHmmK8idHRsLTIzIOWP
keeOsOeahOmCo+WPquiEmiArIOeri+WIu+aJvuWcsOWdgCLnmoTlkIjlubbniYjvvIwxMjIg5Lya
5LiA55u05L+d5oyB6auY55S15bmz77yMCiAgICDnu5PmnZ/lkI7lj6/ku6XnlKggbWRpby1zY2Fu
IGZyZWUgMTIyIOaUvuW8gOOAgiIiIgogICAgbnVtcyA9IFtpbnQoYSkgZm9yIGEgaW4gYXJncyBp
ZiBhLmlzZGlnaXQoKV0KICAgIGVuID0gbnVtc1swXSBpZiBsZW4obnVtcykgPj0gMSBlbHNlIDEy
MgogICAgbWRjX251bSA9IG51bXNbMV0gaWYgbGVuKG51bXMpID49IDIgZWxzZSAxMjEKICAgIG1k
aW9fbnVtID0gbnVtc1syXSBpZiBsZW4obnVtcykgPj0gMyBlbHNlIDEyMAogICAgcCA9IFBpbiht
ZW0sIGVuKQogICAgc3QgPSBsb2FkX3N0YXRlKCkKICAgIGtleSA9IHN0cihlbikKICAgIGlmIGtl
eSBub3QgaW4gc3Q6CiAgICAgICAgc3Rba2V5XSA9IHAuc25hcHNob3QoKQogICAgICAgIHNhdmVf
c3RhdGUoc3QpCiAgICAgICAgcHJpbnQoIuS9v+iDveiEmiAlcyglZCkg5Y6f54q25oCBPSVzIiAl
IChwaW5fbmFtZShlbiksIGVuLCBzdFtrZXldKSkKICAgIHAubXV4X2dwaW8oKQogICAgcC5zZXQo
MSkKICAgIHAuc2V0X2RpcihUcnVlKQogICAgdGltZS5zbGVlcCgwLjMpCiAgICBwcmludCgi5bey
5oqKICVzKCVkKSDmi4npq5jvvIhQSFkg5LiK55S177yJ77yM562JIDMwMG1z77yM5byA5aeL5omr
ICVzLyVzIOeahCAwfjcgLi4uIiAlICgKICAgICAgICBwaW5fbmFtZShlbiksIGVuLCBwaW5fbmFt
ZShtZGNfbnVtKSwgcGluX25hbWUobWRpb19udW0pKSkKICAgIGhpdHMgPSBbXQogICAgZm9yIGFk
ZHIgaW4gcmFuZ2UoOCk6CiAgICAgICAgcGlkID0gcGh5X2lkKG1lbSwgbWRjX251bSwgbWRpb19u
dW0sIGFkZHIpCiAgICAgICAgb2sgPSBpc192YWxpZChwaWQpCiAgICAgICAgcHJpbnQoIiAgYWRk
ciAlZCA6IGlkPTB4JTA4WCVzIiAlIChhZGRyLCBwaWQsICIgIDw9PSDmnInlupTnrZQiIGlmIG9r
IGVsc2UgIiIpKQogICAgICAgIGlmIG9rOgogICAgICAgICAgICBoaXRzLmFwcGVuZCgoYWRkciwg
cGlkKSkKICAgIGlmIG5vdCBoaXRzOgogICAgICAgIHByaW50KCLnu5PmnpzvvJpQSFkg5bey5LiK
55S15L2GIDB+NyDlhajml6DlupTnrZQg4oCU4oCUIOivtOaYjiBNREMvTURJTyDkuI3lnKggRDEv
RDDvvIwiKQogICAgICAgIHByaW50KCIgICAgICDmjqXnnYDot5EgbWRpby1zY2FuIHN3ZWVw77yI
5Lya6Ieq5Yqo6Lez6L+H6KKrIGhvbGQg55qE6ISa77yJ5Y675om+55yf5q2j55qEIE1EQy9NRElP
IOiEmuWvueOAgiIpCiAgICBlbHNlOgogICAgICAgIHByaW50KCLnu5PmnpzvvJpQSFkg5Zyw5Z2A
ID0gJWTvvIhpZD0weCUwOFjvvInjgILkuIvkuIDmraUgbWRpby1zY2FuIHJlZ3MgJWQg5aSN6K+7
5a+E5a2Y5Zmo56Gu6K6k44CCIiAlICgKICAgICAgICAgICAgaGl0c1swXVswXSwgaGl0c1swXVsx
XSwgaGl0c1swXVswXSkpCiAgICAgICAgcHJpbnQoIiAgICAgICVzKCVkKSDkv53mjIHpq5jnlLXl
ubPvvIznu5PmnZ/ml7YgbWRpby1zY2FuIGZyZWUgJWTjgIIiICUgKAogICAgICAgICAgICBwaW5f
bmFtZShlbiksIGVuLCBlbikpCiAgICByZXR1cm4gbGVuKGhpdHMpCgoKZGVmIGNtZF9yZWdzKG1l
bSwgYXJncyk6CiAgICAiIiLor7vmn5DkuKogUEhZIOWcsOWdgOeahCAwfjUg5Y+35a+E5a2Y5Zmo
77yM55So5LqO56Gu6K6kIFBIWSDnnJ/nmoTmtLvnnYDjgIIiIiIKICAgIG51bXMgPSBbaW50KGEp
IGZvciBhIGluIGFyZ3MgaWYgYS5pc2RpZ2l0KCldCiAgICBhZGRyID0gbnVtc1swXSBpZiBsZW4o
bnVtcykgPj0gMSBlbHNlIDAKICAgIG1kY19udW0gPSBudW1zWzFdIGlmIGxlbihudW1zKSA+PSAy
IGVsc2UgMTIxCiAgICBtZGlvX251bSA9IG51bXNbMl0gaWYgbGVuKG51bXMpID49IDMgZWxzZSAx
MjAKICAgIG5hbWVzID0gWyJCTUNSIiwgIkJNU1IiLCAiUEhZSUQxIiwgIlBIWUlEMiIsICJBTkFS
IiwgIkFOTFBBUiJdCiAgICBwcmludCgi6K+7ICVzLyVzIOS4iiBQSFkg5Zyw5Z2AICVkIOeahOWv
hOWtmOWZqO+8miIgJSAoCiAgICAgICAgcGluX25hbWUobWRjX251bSksIHBpbl9uYW1lKG1kaW9f
bnVtKSwgYWRkcikpCiAgICB2YWxzID0gW10KICAgIGZvciByIGluIHJhbmdlKDYpOgogICAgICAg
IHYgPSBiYl9yZWFkKFBpbihtZW0sIG1kY19udW0pLCBQaW4obWVtLCBtZGlvX251bSksIGFkZHIs
IHIpCiAgICAgICAgdmFscy5hcHBlbmQodikKICAgICAgICBwcmludCgiICByZWclZCAlLTdzID0g
MHglMDRYIiAlIChyLCBuYW1lc1tyXSwgdikpCiAgICBwaWQgPSAodmFsc1syXSA8PCAxNikgfCB2
YWxzWzNdCiAgICBwcmludCgiICBQSFkgSUQgPSAweCUwOFglcyIgJSAocGlkLCAiICA8PT0g5pyJ
5pWIIiBpZiBpc192YWxpZChwaWQpIGVsc2UgIiAgPD09IOaXoOaViC/ml6DlupTnrZQiKSkKICAg
IGlmIGlzX3ZhbGlkKHBpZCk6CiAgICAgICAgcHJpbnQoIiAgT1VJPTB4JTA2WCAg5Z6L5Y+3PTB4
JTAzWCAg54mI5pysPSVkIiAlICgKICAgICAgICAgICAgKHBpZCA+PiAxMCkgJiAweEZGRkZGRiwg
KHBpZCA+PiA0KSAmIDB4M0YsIHBpZCAmIDB4RikpCiAgICAgICAgaWYgKHBpZCA+PiAxMCkgJiAw
eEZGRkZGRiA9PSAweDAwMUNDMDoKICAgICAgICAgICAgcHJpbnQoIiAgT1VJIDB4MDAxQ0MwID0g
UmVhbHRla++8jOS4juS9oOadv+S4iueahCBSVEw4MjAxRk4g5ZC75ZCIIikKICAgIGJtc3IgPSB2
YWxzWzFdCiAgICBpZiBpc192YWxpZChwaWQpOgogICAgICAgIHByaW50KCIgIEJNU1I6IOmTvui3
rz0lcyDoh6rljY/llYblrozmiJA9JXMgMTBNPSVzIDEwME09JXMiICUgKAogICAgICAgICAgICAi
dXAiIGlmIGJtc3IgJiAweDAwMDQgZWxzZSAiZG93biIsCiAgICAgICAgICAgICLmmK8iIGlmIGJt
c3IgJiAweDAwMjAgZWxzZSAi5ZCmIiwKICAgICAgICAgICAgIuaUr+aMgSIgaWYgYm1zciAmIDB4
MDgwMCBlbHNlICLkuI3mlK/mjIEiLAogICAgICAgICAgICAi5pSv5oyBIiBpZiBibXNyICYgMHgx
MDAwIGVsc2UgIuS4jeaUr+aMgSIpKQogICAgcmV0dXJuIDAKCgpkZWYgY21kX2R1bXAobWVtLCBh
cmdzKToKICAgIGZvciBiLCBiYXNlIGluIGVudW1lcmF0ZShHUElPX0JBU0UpOgogICAgICAgIHBy
aW50KCJHUElPJWQgYmFzZT0weCUwOFggRFI9MHglMDhYIEREUj0weCUwOFggRVhUPTB4JTA4WCIg
JSAoCiAgICAgICAgICAgIGIsIGJhc2UsCiAgICAgICAgICAgIG1lbS5yZChiYXNlICsgUkVHX0RS
KSwgbWVtLnJkKGJhc2UgKyBSRUdfRERSKSwgbWVtLnJkKGJhc2UgKyBSRUdfRVhUKSkpCiAgICBy
ZXR1cm4gMAoKCkNNRFMgPSB7CiAgICAicGluIjogY21kX3BpbiwKICAgICJzYWZlIjogY21kX3Nh
ZmUsCiAgICAic2NhbiI6IGNtZF9zY2FuLAogICAgInN3ZWVwIjogY21kX3N3ZWVwLAogICAgImN0
bCI6IGNtZF9jdGwsCiAgICAiaG9sZCI6IGNtZF9ob2xkLAogICAgImZyZWUiOiBjbWRfZnJlZSwK
ICAgICJ3YWtlIjogY21kX3dha2UsCiAgICAicmVncyI6IGNtZF9yZWdzLAogICAgImR1bXAiOiBj
bWRfZHVtcCwKfQoKCmRlZiBtYWluKCk6CiAgICBpZiBsZW4oc3lzLmFyZ3YpIDwgMiBvciBzeXMu
YXJndlsxXSBub3QgaW4gQ01EUzoKICAgICAgICBwcmludChfX2RvY19fIG9yICIiKQogICAgICAg
IHByaW50KCLlj6/nlKjlkb3ku6TvvJoiICsgIiAvICIuam9pbihzb3J0ZWQoQ01EUykpKQogICAg
ICAgIHJldHVybiAyCiAgICBtZW0gPSBNZW0oKQogICAgciA9IENNRFNbc3lzLmFyZ3ZbMV1dKG1l
bSwgc3lzLmFyZ3ZbMjpdKQogICAgaWYgciBpcyBOb25lOgogICAgICAgIHJldHVybiAwCiAgICBy
ZXR1cm4gMCBpZiByID49IDAgZWxzZSAxCgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjoKICAg
IHN5cy5leGl0KG1haW4oKSkK
MDIOSCAN_B64
chmod 755 /usr/local/bin/mdio-scan
if [ ! -x /usr/bin/python3 ] && [ ! -x /usr/local/bin/python3 ]; then
    echo "⚠️  rootfs 里没有 python3，mdio-scan 无法运行"
else
    echo "✅ 已安装 /usr/local/bin/mdio-scan（python3 版 MDIO 引脚探测工具）"
fi
