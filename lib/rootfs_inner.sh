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

# ---- 第三十四轮：把网口初始化推到 systemd 早期之后 ----
# 背景（ttl-27~ttl-32 实证）：
#   emac 一旦在启动早期 probe 成功（eth0 存在），PID1 会在 manager_preset_all()
#   枚举 /lib/systemd/system 时硬卡死（关中断，hung_task/softlockup 都报不出来）；
#   tt-33（dts 里 &emac status=disabled）能正常进 login，证明 eth0 存在就是触发条件。
#   而 tt-30（init=/bin/sh 里手动 ip link set eth0 up）证明驱动运行期完全正常，
#   能协商出 100Mbps/Full。
# 做法：emac 编成模块（CONFIG_EMAC_ROCKCHIP=m），启动早期根本不存在 eth0；
#   由本 unit 在 multi-user 阶段再 modprobe + 拉起 + DHCP。
#   本 unit **默认不启用**（不 enable），第一次请手工 systemctl start 验证不再卡死，
#   确认后再 systemctl enable emac-late 让它随系统自启。
cat > /etc/systemd/system/emac-late.service << 'EMACLATE'
[Unit]
Description=Late-load Rockchip EMAC (RTL8201FN) and bring eth0 up
After=systemd-udevd.service local-fs.target
ConditionPathExists=!/sys/class/net/eth0

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'modprobe emac_rockchip || modprobe rockchip_emac || true'
ExecStart=/bin/sh -c 'i=0; while [ ! -e /sys/class/net/eth0 ] && [ $i -lt 10 ]; do i=$((i+1)); sleep 1; done; ls /sys/class/net'
ExecStart=/bin/sh -c 'IP=$(command -v ip || echo /usr/sbin/ip); $IP link set eth0 up'
ExecStart=-/bin/sh -c 'DH=$(command -v dhclient || echo /usr/sbin/dhclient); $DH -4 -1 -t 20 eth0'

[Install]
WantedBy=multi-user.target
EMACLATE
echo "  created: /etc/systemd/system/emac-late.service (未 enable，手工验证后再 enable)"

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
bGQgOTYgbG93ICAgICAgICAgICMg5ouJ5L2O5bm25L+d5oyBCiAgbWRpby1zY2FuIGhvbGQgMCBs
b3cgLS1mb3JjZSAgICMg5a+5IGJhbmswL2JhbmsxIOeahOiEmuaUvuihjO+8iOW3suWunua1iyBH
UElPMF9BMCDmmK8gUEhZIOS9v+iDveiEmu+8iQogIG1kaW8tc2NhbiBmcmVlIDk2ICAgICAgICAg
ICAgICAjIOaBouWkjeWIsCBob2xkIOS5i+WJjeeahOeKtuaAgQogIG1kaW8tc2NhbiBmcmVlIGFs
bCAgICAgICAgICAgICAjIOaBouWkjeWFqOmDqO+8iEN0cmwtQyDmiZPmlq3lkI7ot5Hov5nkuKrm
lLblsL7vvIkKICBtZGlvLXNjYW4gY3RsICAgICAgICAgICAgICAgICAgIyDpgJDkuKrmiorlronl
hajohJrmi4npq5jvvIzlho3nnIsgRDEvRDAg5LiK5pyJ5rKh5pyJIFBIWSDlupTnrZQKICBtZGlv
LXNjYW4gc3dlZXAgICAgICAgICAgICAgICAgIyDnm7jpgrvlronlhajohJrlr7nmraPlj43mnoHm
gKfmiasgMH4377yI5Y+q5ZyoIGJhbmsz77yJCiAgbWRpby1zY2FuIGR1bXAgICAgICAgICAgICAg
ICAgICMg5omT5Y2wIDQg5LiqIGJhbmsg55qEIERSL0REUi9FWFQKIiIiCgppbXBvcnQgZ2xvYgpp
bXBvcnQganNvbgppbXBvcnQgbW1hcAppbXBvcnQgb3MKaW1wb3J0IHN5cwppbXBvcnQgdGltZQoK
R1BJT19CQVNFID0gWzB4MjAwMEEwMDAsIDB4MjAwM0MwMDAsIDB4MjAwM0UwMDAsIDB4MjAwODAw
MDBdCkdSRl9CQVNFID0gMHgyMDAwODAwMApSRUdfRFIgPSAweDAwClJFR19ERFIgPSAweDA0ClJF
R19FWFQgPSAweDUwClBBR0UgPSA0MDk2CgpEID0gM2UtNgpCQURfSURTID0gKDB4MDAwMDAwMDAs
IDB4MDAwMEZGRkYsIDB4RkZGRkZGRkYsIDB4RkZGRjAwMDAsIDB4MDAwMEZGRkUpCgpTVEFURV9G
SUxFID0gIi90bXAvbWRpby1zY2FuLW9yaWcuanNvbiIKCiMg5pW057uE5ouJ6buR77yaYmFuazAg
5pyJIFNQSSBGbGFzaCAvIFBNSUMoSTJDKe+8jGJhbmsxIOaciSBlTU1DIC8gVUFSVDIoY29uc29s
ZSkKQkxBQ0tfQkFOS1MgPSAoMCwgMSkKIyBiYW5rMyDkuIrmraPlnKjooqvmiJHku6wgRFRTIOS9
v+eUqOeahOiEmu+8mkMwfkM3IOaYryBSTUlJ77yMRDAvRDEg5pivIE1EQy9NRElP77yM6YO95LiN
5b2T5o6n5Yi26ISaCkVNQUNfUk1JSSA9IHR1cGxlKHJhbmdlKDExMiwgMTIwKSkKTURJT19QSU5T
ID0gKDEyMCwgMTIxKQoKCmRlZiBwaW5fbmFtZShudW0pOgogICAgYmFuayA9IG51bSAvLyAzMgog
ICAgZ3JwID0gIkFCQ0QiWyhudW0gJSAzMikgLy8gOF0KICAgIGlkeCA9IG51bSAlIDgKICAgIHJl
dHVybiAiR1BJTyVkXyVzJWQiICUgKGJhbmssIGdycCwgaWR4KQoKCmNsYXNzIE1lbShvYmplY3Qp
OgogICAgZGVmIF9faW5pdF9fKHNlbGYpOgogICAgICAgIHNlbGYuZmQgPSBvcy5vcGVuKCIvZGV2
L21lbSIsIG9zLk9fUkRXUiB8IG9zLk9fU1lOQykKICAgICAgICBzZWxmLm1hcHMgPSB7fQoKICAg
IGRlZiBfcGFnZShzZWxmLCBhZGRyKToKICAgICAgICBiYXNlID0gYWRkciAmIH4oUEFHRSAtIDEp
CiAgICAgICAgbSA9IHNlbGYubWFwcy5nZXQoYmFzZSkKICAgICAgICBpZiBtIGlzIE5vbmU6CiAg
ICAgICAgICAgIG0gPSBtbWFwLm1tYXAoc2VsZi5mZCwgUEFHRSwgbW1hcC5NQVBfU0hBUkVELAog
ICAgICAgICAgICAgICAgICAgICAgICAgIG1tYXAuUFJPVF9SRUFEIHwgbW1hcC5QUk9UX1dSSVRF
LCBvZmZzZXQ9YmFzZSkKICAgICAgICAgICAgc2VsZi5tYXBzW2Jhc2VdID0gbQogICAgICAgIHJl
dHVybiBtLCBhZGRyIC0gYmFzZQoKICAgIGRlZiByZChzZWxmLCBhZGRyKToKICAgICAgICBtLCBv
ID0gc2VsZi5fcGFnZShhZGRyKQogICAgICAgIHJldHVybiBpbnQuZnJvbV9ieXRlcyhtW286byAr
IDRdLCAibGl0dGxlIikKCiAgICBkZWYgd3Ioc2VsZiwgYWRkciwgdmFsKToKICAgICAgICBtLCBv
ID0gc2VsZi5fcGFnZShhZGRyKQogICAgICAgIG1bbzpvICsgNF0gPSAodmFsICYgMHhGRkZGRkZG
RikudG9fYnl0ZXMoNCwgImxpdHRsZSIpCgoKY2xhc3MgUGluKG9iamVjdCk6CiAgICBkZWYgX19p
bml0X18oc2VsZiwgbWVtLCBudW0pOgogICAgICAgIHNlbGYubWVtID0gbWVtCiAgICAgICAgc2Vs
Zi5udW0gPSBudW0KICAgICAgICBzZWxmLmJhbmsgPSBudW0gLy8gMzIKICAgICAgICBzZWxmLmlk
eCA9IG51bSAlIDMyCiAgICAgICAgc2VsZi5iYXNlID0gR1BJT19CQVNFW3NlbGYuYmFua10KCiAg
ICBkZWYgc2V0X2RpcihzZWxmLCBvdXQpOgogICAgICAgIGEgPSBzZWxmLmJhc2UgKyBSRUdfRERS
CiAgICAgICAgdiA9IHNlbGYubWVtLnJkKGEpCiAgICAgICAgaWYgb3V0OgogICAgICAgICAgICB2
IHw9ICgxIDw8IHNlbGYuaWR4KQogICAgICAgIGVsc2U6CiAgICAgICAgICAgIHYgJj0gfigxIDw8
IHNlbGYuaWR4KQogICAgICAgIHNlbGYubWVtLndyKGEsIHYpCgogICAgZGVmIHNldChzZWxmLCB2
YWwpOgogICAgICAgIGEgPSBzZWxmLmJhc2UgKyBSRUdfRFIKICAgICAgICB2ID0gc2VsZi5tZW0u
cmQoYSkKICAgICAgICBpZiB2YWw6CiAgICAgICAgICAgIHYgfD0gKDEgPDwgc2VsZi5pZHgpCiAg
ICAgICAgZWxzZToKICAgICAgICAgICAgdiAmPSB+KDEgPDwgc2VsZi5pZHgpCiAgICAgICAgc2Vs
Zi5tZW0ud3IoYSwgdikKCiAgICBkZWYgZ2V0KHNlbGYpOgogICAgICAgIHJldHVybiAoc2VsZi5t
ZW0ucmQoc2VsZi5iYXNlICsgUkVHX0VYVCkgPj4gc2VsZi5pZHgpICYgMQoKICAgIGRlZiBfaW9t
dXhfYWRkcl9iaXQoc2VsZik6CiAgICAgICAgb2ZmID0gMHg2MCArIChzZWxmLmJhbmsgKiA0ICsg
c2VsZi5pZHggLy8gOCkgKiA0CiAgICAgICAgcmV0dXJuIEdSRl9CQVNFICsgb2ZmLCAoc2VsZi5p
ZHggJSA4KSAqIDIKCiAgICBkZWYgbXV4X2dldChzZWxmKToKICAgICAgICBhLCBiID0gc2VsZi5f
aW9tdXhfYWRkcl9iaXQoKQogICAgICAgIHJldHVybiAoc2VsZi5tZW0ucmQoYSkgPj4gYikgJiAz
CgogICAgZGVmIG11eF9zZXQoc2VsZiwgdmFsKToKICAgICAgICBhLCBiID0gc2VsZi5faW9tdXhf
YWRkcl9iaXQoKQogICAgICAgIHYgPSBzZWxmLm1lbS5yZChhKQogICAgICAgIHNlbGYubWVtLndy
KGEsICh2ICYgfigzIDw8IGIpKSB8ICgodmFsICYgMykgPDwgYikpCgogICAgZGVmIG11eF9ncGlv
KHNlbGYpOgogICAgICAgIHNlbGYubXV4X3NldCgwKQoKICAgIGRlZiBkaXJfb3V0KHNlbGYpOgog
ICAgICAgIHJldHVybiBib29sKChzZWxmLm1lbS5yZChzZWxmLmJhc2UgKyBSRUdfRERSKSA+PiBz
ZWxmLmlkeCkgJiAxKQoKICAgIGRlZiBzbmFwc2hvdChzZWxmKToKICAgICAgICByZXR1cm4geyJt
dXgiOiBzZWxmLm11eF9nZXQoKSwgIm91dCI6IHNlbGYuZGlyX291dCgpLCAiZHIiOiBzZWxmLmdl
dCgpfQoKICAgIGRlZiByZXN0b3JlKHNlbGYsIHMpOgogICAgICAgIHNlbGYubXV4X3NldChzWyJt
dXgiXSkKICAgICAgICBpZiBzWyJvdXQiXToKICAgICAgICAgICAgc2VsZi5zZXQoMSBpZiBzWyJk
ciJdIGVsc2UgMCkKICAgICAgICAgICAgc2VsZi5zZXRfZGlyKFRydWUpCiAgICAgICAgZWxzZToK
ICAgICAgICAgICAgc2VsZi5zZXRfZGlyKEZhbHNlKQoKCmRlZiBsb2FkX3N0YXRlKCk6CiAgICB0
cnk6CiAgICAgICAgcmV0dXJuIGpzb24ubG9hZChvcGVuKFNUQVRFX0ZJTEUpKQogICAgZXhjZXB0
IEV4Y2VwdGlvbjoKICAgICAgICByZXR1cm4ge30KCgpkZWYgc2F2ZV9zdGF0ZShzdCk6CiAgICB0
cnk6CiAgICAgICAganNvbi5kdW1wKHN0LCBvcGVuKFNUQVRFX0ZJTEUsICJ3IikpCiAgICBleGNl
cHQgRXhjZXB0aW9uOgogICAgICAgIHBhc3MKCgpkZWYgcGFyc2VfYmFua3MoYXJncywgZGVmYXVs
dD0oMywpKToKICAgIGJhbmtzID0gZGVmYXVsdAogICAgaWYgIi0tYWxsIiBpbiBhcmdzOgogICAg
ICAgIGJhbmtzID0gKDAsIDEsIDIsIDMpCiAgICBmb3IgYSBpbiBhcmdzOgogICAgICAgIGlmIGEu
c3RhcnRzd2l0aCgiLS1iYW5rPSIpOgogICAgICAgICAgICBiYW5rcyA9IHR1cGxlKGludCh4KSBm
b3IgeCBpbiBhLnNwbGl0KCI9IiwgMSlbMV0uc3BsaXQoIiwiKSkKICAgIHJldHVybiBiYW5rcwoK
CmRlZiBoZWxkX3BpbnMoKToKICAgIG91dCA9IHNldCgpCiAgICBmb3IgayBpbiBsb2FkX3N0YXRl
KCkua2V5cygpOgogICAgICAgIGlmIHN0cihrKS5pc2RpZ2l0KCk6CiAgICAgICAgICAgIG91dC5h
ZGQoaW50KGspKQogICAgcmV0dXJuIG91dAoKCmRlZiBzYWZlX3BpbnMobWVtLCBiYW5rcywgYW55
X211eD1GYWxzZSwgZm9yY2U9RmFsc2UsIHdpdGhfbWRpbz1UcnVlKToKICAgICIiIuiHquW3seiv
uyBpb211eCDliKTmlq3vvJptdXg9PTDvvIjlvZPliY3lsLHmmK8gR1BJT++8ieS4lOWcqOWFgeiu
uOeahCBiYW5rIOWGheaJjei/lOWbnuOAggogICAgd2l0aF9tZGlvPVRydWUg5pe25oqKIEQwL0Qx
KDEyMC8xMjEpIOS5n+eul+i/m+WAmemAiSDigJTigJQg5a6D5Lus5pivIE1EQy9NRElPIOeahOmm
luimgeWrjOeWke+8jAogICAg5b+F6aG76IO96KKr5b2T5oiQIuW+hea1i+iEmuWvuSLnmoTkuIDp
g6jliIbvvIjlj43mnoHmgKcgMTIwLzEyMSDku6XliY3ku47msqHmtYvov4fvvInjgIIiIiIKICAg
IGhlbGQgPSBoZWxkX3BpbnMoKQogICAgcGlucyA9IFtdCiAgICBmb3IgYiBpbiBiYW5rczoKICAg
ICAgICBpZiBiIGluIEJMQUNLX0JBTktTIGFuZCBub3QgZm9yY2U6CiAgICAgICAgICAgIGNvbnRp
bnVlCiAgICAgICAgZm9yIHAgaW4gcmFuZ2UoYiAqIDMyLCBiICogMzIgKyAzMik6CiAgICAgICAg
ICAgIGlmIHAgaW4gRU1BQ19STUlJIG9yIHAgaW4gaGVsZDoKICAgICAgICAgICAgICAgIGNvbnRp
bnVlCiAgICAgICAgICAgIGlmIHAgaW4gTURJT19QSU5TIGFuZCBub3Qgd2l0aF9tZGlvOgogICAg
ICAgICAgICAgICAgY29udGludWUKICAgICAgICAgICAgaWYgbm90IGFueV9tdXggYW5kIFBpbiht
ZW0sIHApLm11eF9nZXQoKSAhPSAwOgogICAgICAgICAgICAgICAgY29udGludWUKICAgICAgICAg
ICAgcGlucy5hcHBlbmQocCkKICAgIHJldHVybiBzb3J0ZWQocGlucykKCgpNVVhfRklMRSA9ICIv
dG1wL21kaW8tc2Nhbi1tdXguanNvbiIKCgpkZWYgbG9hZF9tdXgoKToKICAgIHRyeToKICAgICAg
ICByZXR1cm4ganNvbi5sb2FkKG9wZW4oTVVYX0ZJTEUpKQogICAgZXhjZXB0IEV4Y2VwdGlvbjoK
ICAgICAgICByZXR1cm4ge30KCgpkZWYgc2F2ZV9tdXgoc3QpOgogICAgdHJ5OgogICAgICAgIGpz
b24uZHVtcChzdCwgb3BlbihNVVhfRklMRSwgInciKSkKICAgIGV4Y2VwdCBFeGNlcHRpb246CiAg
ICAgICAgcGFzcwoKCmRlZiBiYl9yZWFkKG1kYywgbWRpbywgcGh5LCByZWcpOgogICAgIiIi5qCH
5YeGIENsYXVzZSAyMiDor7vvvJpwcmVhbWJsZSArIFNUKDAxKSArIE9QKDEwKSArIFBIWUFEKDUp
ICsgUkVHQUQoNSkgKyBUQSArIDE2IOaVsOaNruS9jSIiIgogICAgbWRpby5tdXhfZ3BpbygpCiAg
ICBtZGMubXV4X2dwaW8oKQogICAgbWRjLnNldF9kaXIoVHJ1ZSkKICAgIG1kYy5zZXQoMCkKICAg
IG1kaW8uc2V0X2RpcihUcnVlKQoKICAgIGRlZiBjbGtfd3JpdGUoYml0KToKICAgICAgICBtZGlv
LnNldChiaXQpCiAgICAgICAgdGltZS5zbGVlcChEKQogICAgICAgIG1kYy5zZXQoMSkKICAgICAg
ICB0aW1lLnNsZWVwKEQpCiAgICAgICAgbWRjLnNldCgwKQogICAgICAgIHRpbWUuc2xlZXAoRCkK
CiAgICBmb3IgXyBpbiByYW5nZSgzMik6CiAgICAgICAgY2xrX3dyaXRlKDEpCgogICAgYml0cyA9
IFswLCAxLCAxLCAwXQogICAgZm9yIGkgaW4gcmFuZ2UoNCwgLTEsIC0xKToKICAgICAgICBiaXRz
LmFwcGVuZCgocGh5ID4+IGkpICYgMSkKICAgIGZvciBpIGluIHJhbmdlKDQsIC0xLCAtMSk6CiAg
ICAgICAgYml0cy5hcHBlbmQoKHJlZyA+PiBpKSAmIDEpCiAgICBmb3IgYiBpbiBiaXRzOgogICAg
ICAgIGNsa193cml0ZShiKQoKICAgIG1kaW8uc2V0X2RpcihGYWxzZSkKICAgIHRpbWUuc2xlZXAo
RCkKICAgIG1kYy5zZXQoMSkKICAgIHRpbWUuc2xlZXAoRCkKICAgIG1kYy5zZXQoMCkKICAgIHRp
bWUuc2xlZXAoRCkKCiAgICB2YWwgPSAwCiAgICBmb3IgXyBpbiByYW5nZSgxNik6CiAgICAgICAg
dGltZS5zbGVlcChEKQogICAgICAgIG1kYy5zZXQoMSkKICAgICAgICB0aW1lLnNsZWVwKEQpCiAg
ICAgICAgdmFsID0gKHZhbCA8PCAxKSB8IG1kaW8uZ2V0KCkKICAgICAgICBtZGMuc2V0KDApCiAg
ICAgICAgdGltZS5zbGVlcChEKQogICAgcmV0dXJuIHZhbAoKCmRlZiBwaHlfaWQobWVtLCBtZGNf
bnVtLCBtZGlvX251bSwgYWRkcik6CiAgICBtZGMgPSBQaW4obWVtLCBtZGNfbnVtKQogICAgbWRp
byA9IFBpbihtZW0sIG1kaW9fbnVtKQogICAgaGkgPSBiYl9yZWFkKG1kYywgbWRpbywgYWRkciwg
MikKICAgIGxvID0gYmJfcmVhZChtZGMsIG1kaW8sIGFkZHIsIDMpCiAgICByZXR1cm4gKGhpIDw8
IDE2KSB8IGxvCgoKZGVmIGlzX3ZhbGlkKHBpZCk6CiAgICBpZiBwaWQgaW4gQkFEX0lEUzoKICAg
ICAgICByZXR1cm4gRmFsc2UKICAgIGhpID0gKHBpZCA+PiAxNikgJiAweEZGRkYKICAgIGxvID0g
cGlkICYgMHhGRkZGCiAgICBpZiBoaSBpbiAoMHgwMDAwLCAweEZGRkYpIGFuZCBsbyBpbiAoMHgw
MDAwLCAweEZGRkYpOgogICAgICAgIHJldHVybiBGYWxzZQogICAgcmV0dXJuIFRydWUKCgpkZWYg
Y21kX3BpbihtZW0sIGFyZ3MpOgogICAgZm9yIGEgaW4gYXJnczoKICAgICAgICBwID0gUGluKG1l
bSwgaW50KGEpKQogICAgICAgIHByaW50KCJwaW4gJS0zZCAlLTEwcyBtdXg9JWQgZGlyPSVzIGxl
dmVsPSVkIiAlICgKICAgICAgICAgICAgcC5udW0sIHBpbl9uYW1lKHAubnVtKSwgcC5tdXhfZ2V0
KCksCiAgICAgICAgICAgICJvdXQiIGlmIHAuZGlyX291dCgpIGVsc2UgImluIiwgcC5nZXQoKSkp
CiAgICByZXR1cm4gMAoKCmRlZiBjbWRfc2FmZShtZW0sIGFyZ3MpOgogICAgYmFua3MgPSBwYXJz
ZV9iYW5rcyhhcmdzKQogICAgYW55X211eCA9ICItLWFueSIgaW4gYXJncwogICAgZm9yY2UgPSAi
LS1mb3JjZSIgaW4gYXJncwogICAgcGlucyA9IHNhZmVfcGlucyhtZW0sIGJhbmtzLCBhbnlfbXV4
LCBmb3JjZSkKICAgIGlmICItLWxpc3QiIGluIGFyZ3M6CiAgICAgICAgZm9yIHAgaW4gcGluczoK
ICAgICAgICAgICAgcHJpbnQocCkKICAgICAgICByZXR1cm4gMAogICAgcHJpbnQoImJhbmsgJXMg
6YeM5Y+v5a6J5YWo5pON5L2c55qE5byV6ISa5YWxICVkIOS4qu+8iG11eD09MCDkuJTmnKrooqvm
jpLpmaTvvInvvJoiICUgKAogICAgICAgICIsIi5qb2luKHN0cihiKSBmb3IgYiBpbiBiYW5rcyks
IGxlbihwaW5zKSkpCiAgICBmb3IgcCBpbiBwaW5zOgogICAgICAgIHEgPSBQaW4obWVtLCBwKQog
ICAgICAgIHByaW50KCIgICUtM2QgJS0xMHMgbXV4PSVkIGRpcj0lcyBsZXZlbD0lZCIgJSAoCiAg
ICAgICAgICAgIHAsIHBpbl9uYW1lKHApLCBxLm11eF9nZXQoKSwgIm91dCIgaWYgcS5kaXJfb3V0
KCkgZWxzZSAiaW4iLCBxLmdldCgpKSkKICAgIGlmIG5vdCBwaW5zOgogICAgICAgIHByaW50KCIg
IO+8iOS4gOS4qumDveayoeacieOAguWPr+iDvei/meS6myBiYW5rIOeahOiEmuWFqOiiq+WNoOeU
qOS6hu+8jOivleivlSAtLWJhbms9MiDmiJYgLS1hbnnvvIkiKQogICAgcmV0dXJuIDAKCgpkZWYg
Y21kX3NjYW4obWVtLCBhcmdzKToKICAgIG51bXMgPSBbaW50KGEpIGZvciBhIGluIGFyZ3MgaWYg
YS5pc2RpZ2l0KCldCiAgICBtZGNfbnVtID0gbnVtc1swXSBpZiBsZW4obnVtcykgPj0gMSBlbHNl
IDEyMQogICAgbWRpb19udW0gPSBudW1zWzFdIGlmIGxlbihudW1zKSA+PSAyIGVsc2UgMTIwCiAg
ICBsbyA9IG51bXNbMl0gaWYgbGVuKG51bXMpID49IDMgZWxzZSAwCiAgICBoaSA9IG51bXNbM10g
aWYgbGVuKG51bXMpID49IDQgZWxzZSA3CiAgICBwcmludCgi5omrICVzKE1EQykgLyAlcyhNRElP
KSDlnLDlnYAgJWR+JWQiICUgKAogICAgICAgIHBpbl9uYW1lKG1kY19udW0pLCBwaW5fbmFtZSht
ZGlvX251bSksIGxvLCBoaSkpCiAgICBoaXQgPSAwCiAgICBmb3IgYWRkciBpbiByYW5nZShsbywg
aGkgKyAxKToKICAgICAgICBwaWQgPSBwaHlfaWQobWVtLCBtZGNfbnVtLCBtZGlvX251bSwgYWRk
cikKICAgICAgICBmbGFnID0gIiAgPD09IOacieW6lOetlCIgaWYgaXNfdmFsaWQocGlkKSBlbHNl
ICIiCiAgICAgICAgcHJpbnQoIiAgYWRkciAlZCA6IGlkPTB4JTA4WCVzIiAlIChhZGRyLCBwaWQs
IGZsYWcpKQogICAgICAgIGlmIGlzX3ZhbGlkKHBpZCk6CiAgICAgICAgICAgIGhpdCArPSAxCiAg
ICBwcmludCgi5ZCI6K6h5ZG95LitICVkIOS4quWcsOWdgOOAgiIgJSBoaXQpCiAgICByZXR1cm4g
aGl0CgoKZGVmIGNtZF9zd2VlcChtZW0sIGFyZ3MpOgogICAgYmFua3MgPSBwYXJzZV9iYW5rcyhh
cmdzKQogICAgYWRqID0gIi0tYWRqIiBpbiBhcmdzCiAgICBwaW5zID0gc2FmZV9waW5zKG1lbSwg
YmFua3MpCiAgICBwYWlycyA9IFtdCiAgICBpZiBhZGo6CiAgICAgICAgZm9yIHAgaW4gcGluczoK
ICAgICAgICAgICAgaWYgcCArIDEgaW4gcGluczoKICAgICAgICAgICAgICAgIHBhaXJzLmFwcGVu
ZCgocCwgcCArIDEpKQogICAgICAgICAgICAgICAgcGFpcnMuYXBwZW5kKChwICsgMSwgcCkpCiAg
ICAgICAgcHJpbnQoImJhbmsgJXMg5YaF55u46YK75a6J5YWo6ISa5a+5ICVkIOe7hO+8iOWQq+at
o+WPjeaegeaAp++8ie+8jOW8gOWni+aJq+aPjyAuLi4iICUgKAogICAgICAgICAgICAiLCIuam9p
bihzdHIoYikgZm9yIGIgaW4gYmFua3MpLCBsZW4ocGFpcnMpKSkKICAgIGVsc2U6CiAgICAgICAg
Zm9yIGEgaW4gcGluczoKICAgICAgICAgICAgZm9yIGIgaW4gcGluczoKICAgICAgICAgICAgICAg
IGlmIGEgIT0gYjoKICAgICAgICAgICAgICAgICAgICBwYWlycy5hcHBlbmQoKGEsIGIpKQogICAg
ICAgIHByaW50KCJiYW5rICVzIOWGhSAlZCDlj6rlgJnpgInohJrnmoTkuKTkuKTnu4TlkIggJWQg
57uE77yI5ZCr5q2j5Y+N5p6B5oCn77yJ77yM5byA5aeL5omr5o+PIC4uLiIgJSAoCiAgICAgICAg
ICAgICIsIi5qb2luKHN0cihiKSBmb3IgYiBpbiBiYW5rcyksIGxlbihwaW5zKSwgbGVuKHBhaXJz
KSkpCiAgICAgICAgcHJpbnQoIue6pumcgCAzMH42MCDnp5LvvIzov5vluqbooYzkvJrkuIDnm7Tl
iLfmlrDvvIzlkb3kuK3kvJrlgZzkuIvmnaXmiZPljbDjgIIiKQogICAgaWYgbm90IHBhaXJzOgog
ICAgICAgIHByaW50KCLmsqHmnInlj6/miavnmoTnm7jpgrvohJrlr7nvvIznm7TmjqXpgIDlh7rj
gIIiKQogICAgICAgIHJldHVybiAwCiAgICBoaXRzID0gW10KICAgIGZvciBuLCAoYSwgYikgaW4g
ZW51bWVyYXRlKHBhaXJzKToKICAgICAgICBzeXMuc3Rkb3V0LndyaXRlKCJcciAgWyVkLyVkXSBN
REM9JWQgTURJTz0lZCAgICAgICIgJSAobiArIDEsIGxlbihwYWlycyksIGEsIGIpKQogICAgICAg
IHN5cy5zdGRvdXQuZmx1c2goKQogICAgICAgIGZvciBhZGRyIGluIHJhbmdlKDgpOgogICAgICAg
ICAgICBwaWQgPSBwaHlfaWQobWVtLCBhLCBiLCBhZGRyKQogICAgICAgICAgICBpZiBpc192YWxp
ZChwaWQpOgogICAgICAgICAgICAgICAgaGl0cy5hcHBlbmQoKGEsIGIsIGFkZHIsIHBpZCkpCiAg
ICBwcmludCgiIikKICAgIGlmIG5vdCBoaXRzOgogICAgICAgIHByaW50KCLnu5PmnpzvvJrmsqHm
nInku7vkvZXkuIDlr7kgKyDku7vkvZXlnLDlnYDmnInlupTnrZTjgIIiKQogICAgZWxzZToKICAg
ICAgICBwcmludCgi57uT5p6c77ya5om+5YiwICVkIOWkhOW6lOetlO+8miIgJSBsZW4oaGl0cykp
CiAgICAgICAgZm9yIGEsIGIsIGFkZHIsIHBpZCBpbiBoaXRzOgogICAgICAgICAgICBwcmludCgi
ICBNREM9JXMoJWQpIE1ESU89JXMoJWQpIFBIWeWcsOWdgD0lZCBpZD0weCUwOFgiICUgKAogICAg
ICAgICAgICAgICAgcGluX25hbWUoYSksIGEsIHBpbl9uYW1lKGIpLCBiLCBhZGRyLCBwaWQpKQog
ICAgcmV0dXJuIGxlbihoaXRzKQoKCmRlZiBjbWRfY3RsKG1lbSwgYXJncyk6CiAgICBiYW5rcyA9
IHBhcnNlX2JhbmtzKGFyZ3MpCiAgICBudW1zID0gW2ludChhKSBmb3IgYSBpbiBhcmdzIGlmIGEu
aXNkaWdpdCgpXQogICAgbWRjX251bSA9IG51bXNbMF0gaWYgbGVuKG51bXMpID49IDEgZWxzZSAx
MjEKICAgIG1kaW9fbnVtID0gbnVtc1sxXSBpZiBsZW4obnVtcykgPj0gMiBlbHNlIDEyMAogICAg
cGlucyA9IHNhZmVfcGlucyhtZW0sIGJhbmtzKQogICAgcHJpbnQoImJhbmsgJXPvvJolcy8lcyDk
uIrlhYjmiavkuIDpgY3ln7rnur8gLi4uIiAlICgKICAgICAgICAiLCIuam9pbihzdHIoYikgZm9y
IGIgaW4gYmFua3MpLCBwaW5fbmFtZShtZGNfbnVtKSwgcGluX25hbWUobWRpb19udW0pKSkKICAg
IGZvciBhZGRyIGluIHJhbmdlKDgpOgogICAgICAgIHBpZCA9IHBoeV9pZChtZW0sIG1kY19udW0s
IG1kaW9fbnVtLCBhZGRyKQogICAgICAgIHByaW50KCIgIOWfuue6vyBhZGRyICVkIDogaWQ9MHgl
MDhYIiAlIChhZGRyLCBwaWQpKQogICAgaWYgbm90IHBpbnM6CiAgICAgICAgcHJpbnQoIuayoeac
ieWPr+aTjeS9nOeahOaOp+WItuiEmu+8jOmAgOWHuu+8iOWFiOi3kSBtZGlvLXNjYW4gc2FmZe+8
ieOAgiIpCiAgICAgICAgcmV0dXJuIDAKICAgIHByaW50KCLpgJDkuKrmioogJWQg5Liq5a6J5YWo
6ISa5ouJ6auY77yM5ZCM5pe25omrIDB+NyAuLi4iICUgbGVuKHBpbnMpKQogICAgaGl0cyA9IFtd
CiAgICBmb3IgbiwgcCBpbiBlbnVtZXJhdGUocGlucyk6CiAgICAgICAgc3lzLnN0ZG91dC53cml0
ZSgiXHIgIFslZC8lZF0g5ouJ6auYICVkICglcykgICAgICAiICUgKG4gKyAxLCBsZW4ocGlucyks
IHAsIHBpbl9uYW1lKHApKSkKICAgICAgICBzeXMuc3Rkb3V0LmZsdXNoKCkKICAgICAgICBjdGwg
PSBQaW4obWVtLCBwKQogICAgICAgIG9yaWcgPSBjdGwuc25hcHNob3QoKQogICAgICAgIGN0bC5t
dXhfZ3BpbygpCiAgICAgICAgY3RsLnNldF9kaXIoVHJ1ZSkKICAgICAgICBjdGwuc2V0KDEpCiAg
ICAgICAgZm9yIGFkZHIgaW4gcmFuZ2UoOCk6CiAgICAgICAgICAgIHBpZCA9IHBoeV9pZChtZW0s
IG1kY19udW0sIG1kaW9fbnVtLCBhZGRyKQogICAgICAgICAgICBpZiBpc192YWxpZChwaWQpOgog
ICAgICAgICAgICAgICAgaGl0cy5hcHBlbmQoKHAsIGFkZHIsIHBpZCkpCiAgICAgICAgY3RsLnJl
c3RvcmUob3JpZykKICAgIHByaW50KCIiKQogICAgaWYgbm90IGhpdHM6CiAgICAgICAgcHJpbnQo
Iue7k+aenO+8mui/mSAlZCDkuKrohJrpgJDkuKrmi4npq5jvvIxEMS9EMCDkuIrpg73msqHmnIkg
UEhZIOW6lOetlOOAgiIgJSBsZW4ocGlucykpCiAgICBlbHNlOgogICAgICAgIHByaW50KCLnu5Pm
npzvvJrmib7liLAgJWQg5aSE5bqU562U77yaIiAlIGxlbihoaXRzKSkKICAgICAgICBmb3IgcCwg
YWRkciwgcGlkIGluIGhpdHM6CiAgICAgICAgICAgIHByaW50KCIgIOaOp+WItuiEmj0lcyglZCkg
UEhZ5Zyw5Z2APSVkIGlkPTB4JTA4WCIgJSAocGluX25hbWUocCksIHAsIGFkZHIsIHBpZCkpCiAg
ICByZXR1cm4gbGVuKGhpdHMpCgoKZGVmIGNtZF9ob2xkKG1lbSwgYXJncyk6CiAgICBudW1zID0g
W2ludChhKSBmb3IgYSBpbiBhcmdzIGlmIGEuaXNkaWdpdCgpXQogICAgbG93ID0gImxvdyIgaW4g
YXJncwogICAgZm9yIG4gaW4gbnVtczoKICAgICAgICBpZiBuIC8vIDMyIGluIEJMQUNLX0JBTktT
IGFuZCAiLS1mb3JjZSIgbm90IGluIGFyZ3M6CiAgICAgICAgICAgIHByaW50KCLmi5Lnu53vvJpH
UElPJWQg5piv6Zeq5a2YL1BNSUMvZU1NQy9VQVJUIOWMuuOAguehruiupOaXoOivr+WPr+WKoCAt
LWZvcmNlIOaUvuihjOOAgiIgJSAobiAvLyAzMikpCiAgICAgICAgICAgIGNvbnRpbnVlCiAgICAg
ICAgcCA9IFBpbihtZW0sIG4pCiAgICAgICAgc3QgPSBsb2FkX3N0YXRlKCkKICAgICAgICBrZXkg
PSBzdHIobikKICAgICAgICBpZiBrZXkgbm90IGluIHN0OgogICAgICAgICAgICBzdFtrZXldID0g
cC5zbmFwc2hvdCgpCiAgICAgICAgICAgIHNhdmVfc3RhdGUoc3QpCiAgICAgICAgcC5tdXhfZ3Bp
bygpCiAgICAgICAgcC5zZXQoMCBpZiBsb3cgZWxzZSAxKQogICAgICAgIHAuc2V0X2RpcihUcnVl
KQogICAgICAgIHByaW50KCLlt7LmioogJXMoJWQpIOaLiSVz5bm25L+d5oyB6L6T5Ye644CC55yL
IFJKNDUg54Gv77yb5LiN5Lqu5bCxIG1kaW8tc2NhbiBmcmVlICVk44CC5Y6f54q25oCBPSVzIiAl
ICgKICAgICAgICAgICAgcGluX25hbWUobiksIG4sICLkvY4iIGlmIGxvdyBlbHNlICLpq5giLCBu
LCBzdFtrZXldKSkKICAgIHJldHVybiAwCgoKZGVmIGNtZF9mcmVlKG1lbSwgYXJncyk6CiAgICBz
dCA9IGxvYWRfc3RhdGUoKQogICAgaWYgImFsbCIgaW4gYXJnczoKICAgICAgICBtc3QgPSBsb2Fk
X211eCgpCiAgICAgICAgZm9yIGsgaW4gbGlzdChtc3Qua2V5cygpKToKICAgICAgICAgICAgUGlu
KG1lbSwgaW50KGspKS5tdXhfc2V0KG1zdFtrXSkKICAgICAgICAgICAgcHJpbnQoIuW3suaBouWk
jSAlcyglZCkgaW9tdXggLT4gJWQiICUgKHBpbl9uYW1lKGludChrKSksIGludChrKSwgbXN0W2td
KSkKICAgICAgICBzYXZlX211eCh7fSkKICAgICAgICBmb3IgayBpbiBsaXN0KHN0LmtleXMoKSk6
CiAgICAgICAgICAgIFBpbihtZW0sIGludChrKSkucmVzdG9yZShzdFtrXSkKICAgICAgICAgICAg
cHJpbnQoIuW3suaBouWkjSAlcyglZCkgLT4gJXMiICUgKHBpbl9uYW1lKGludChrKSksIGludChr
KSwgc3Rba10pKQogICAgICAgIHNhdmVfc3RhdGUoe30pCiAgICAgICAgcmV0dXJuIDAKICAgIGZv
ciBhIGluIGFyZ3M6CiAgICAgICAgbiA9IGludChhKQogICAgICAgIHAgPSBQaW4obWVtLCBuKQog
ICAgICAgIGlmIHN0cihuKSBpbiBzdDoKICAgICAgICAgICAgcC5yZXN0b3JlKHN0W3N0cihuKV0p
CiAgICAgICAgICAgIHByaW50KCLlt7LmioogJXMoJWQpIOaBouWkjeWIsCBob2xkIOS5i+WJje+8
miVzIiAlIChwaW5fbmFtZShuKSwgbiwgc3Rbc3RyKG4pXSkpCiAgICAgICAgICAgIGRlbCBzdFtz
dHIobildCiAgICAgICAgICAgIHNhdmVfc3RhdGUoc3QpCiAgICAgICAgZWxzZToKICAgICAgICAg
ICAgcC5zZXQoMCkKICAgICAgICAgICAgcC5zZXRfZGlyKEZhbHNlKQogICAgICAgICAgICBwcmlu
dCgi5bey5oqKICVzKCVkKSDmlL7lvIDvvIjovpPlhaXjgIHkvY7nlLXlubPvvInjgIIiICUgKHBp
bl9uYW1lKG4pLCBuKSkKICAgIHJldHVybiAwCgoKZGVmIGNtZF93YWtlKG1lbSwgYXJncyk6CiAg
ICAiIiLlhYjnu5kgUEhZIOS9v+iDveiEmu+8iOm7mOiupCBHUElPM19EMj0xMjLvvInkuIrnlLXl
ubbkv53mjIHvvIzlho3miasgRDEvRDAg55qEIDB+N+OAggogICAg6L+Z5p2h5ZG95Luk5bCx5piv
InR0bC0yMyDlj5HnjrDnmoTpgqPlj6rohJogKyDnq4vliLvmib7lnLDlnYAi55qE5ZCI5bm254mI
77yMMTIyIOS8muS4gOebtOS/neaMgemrmOeUteW5s++8jAogICAg57uT5p2f5ZCO5Y+v5Lul55So
IG1kaW8tc2NhbiBmcmVlIDEyMiDmlL7lvIDjgIIiIiIKICAgIG51bXMgPSBbaW50KGEpIGZvciBh
IGluIGFyZ3MgaWYgYS5pc2RpZ2l0KCldCiAgICBlbiA9IG51bXNbMF0gaWYgbGVuKG51bXMpID49
IDEgZWxzZSAxMjIKICAgIG1kY19udW0gPSBudW1zWzFdIGlmIGxlbihudW1zKSA+PSAyIGVsc2Ug
MTIxCiAgICBtZGlvX251bSA9IG51bXNbMl0gaWYgbGVuKG51bXMpID49IDMgZWxzZSAxMjAKICAg
IHAgPSBQaW4obWVtLCBlbikKICAgIHN0ID0gbG9hZF9zdGF0ZSgpCiAgICBrZXkgPSBzdHIoZW4p
CiAgICBpZiBrZXkgbm90IGluIHN0OgogICAgICAgIHN0W2tleV0gPSBwLnNuYXBzaG90KCkKICAg
ICAgICBzYXZlX3N0YXRlKHN0KQogICAgICAgIHByaW50KCLkvb/og73ohJogJXMoJWQpIOWOn+eK
tuaAgT0lcyIgJSAocGluX25hbWUoZW4pLCBlbiwgc3Rba2V5XSkpCiAgICBwLm11eF9ncGlvKCkK
ICAgIHAuc2V0KDEpCiAgICBwLnNldF9kaXIoVHJ1ZSkKICAgIGlmICItLWNsayIgaW4gYXJnczoK
ICAgICAgICBjID0gUGluKG1lbSwgMTE3KQogICAgICAgIG1zdCA9IGxvYWRfbXV4KCkKICAgICAg
ICBpZiAiMTE3IiBub3QgaW4gbXN0OgogICAgICAgICAgICBtc3RbIjExNyJdID0gYy5tdXhfZ2V0
KCkKICAgICAgICAgICAgc2F2ZV9tdXgobXN0KQogICAgICAgIGMubXV4X3NldCgyKQogICAgICAg
IHByaW50KCJHUElPM19DNSgxMTcpIGlvbXV4IDAgLT4gMu+8iHJtaWlfY2xrb3V077yM57uZIFBI
WSDpgIEgNTBNSHrvvInvvIzljp/lgLw9JWQiICUgbXN0WyIxMTciXSkKICAgIHRpbWUuc2xlZXAo
MC4zKQogICAgcHJpbnQoIuW3suaKiiAlcyglZCkg5ouJ6auY77yIUEhZIOS4iueUte+8ie+8jOet
iSAzMDBtc++8jOW8gOWni+aJqyAlcy8lcyDnmoQgMH43IC4uLiIgJSAoCiAgICAgICAgcGluX25h
bWUoZW4pLCBlbiwgcGluX25hbWUobWRjX251bSksIHBpbl9uYW1lKG1kaW9fbnVtKSkpCiAgICBo
aXRzID0gW10KICAgIGZvciBhZGRyIGluIHJhbmdlKDgpOgogICAgICAgIHBpZCA9IHBoeV9pZCht
ZW0sIG1kY19udW0sIG1kaW9fbnVtLCBhZGRyKQogICAgICAgIG9rID0gaXNfdmFsaWQocGlkKQog
ICAgICAgIHByaW50KCIgIGFkZHIgJWQgOiBpZD0weCUwOFglcyIgJSAoYWRkciwgcGlkLCAiICA8
PT0g5pyJ5bqU562UIiBpZiBvayBlbHNlICIiKSkKICAgICAgICBpZiBvazoKICAgICAgICAgICAg
aGl0cy5hcHBlbmQoKGFkZHIsIHBpZCkpCiAgICBpZiBub3QgaGl0czoKICAgICAgICBwcmludCgi
57uT5p6c77yaUEhZIOW3suS4iueUteS9hiAwfjcg5YWo5peg5bqU562UIOKAlOKAlCDor7TmmI4g
TURDL01ESU8g5LiN5ZyoIEQxL0Qw77yMIikKICAgICAgICBwcmludCgiICAgICAg5o6l552A6LeR
IG1kaW8tc2NhbiBzd2VlcO+8iOS8muiHquWKqOi3s+i/h+iiqyBob2xkIOeahOiEmu+8ieWOu+aJ
vuecn+ato+eahCBNREMvTURJTyDohJrlr7njgIIiKQogICAgZWxzZToKICAgICAgICBwcmludCgi
57uT5p6c77yaUEhZIOWcsOWdgCA9ICVk77yIaWQ9MHglMDhY77yJ44CC5LiL5LiA5q2lIG1kaW8t
c2NhbiByZWdzICVkIOWkjeivu+WvhOWtmOWZqOehruiupOOAgiIgJSAoCiAgICAgICAgICAgIGhp
dHNbMF1bMF0sIGhpdHNbMF1bMV0sIGhpdHNbMF1bMF0pKQogICAgICAgIHByaW50KCIgICAgICAl
cyglZCkg5L+d5oyB6auY55S15bmz77yM57uT5p2f5pe2IG1kaW8tc2NhbiBmcmVlICVk44CCIiAl
ICgKICAgICAgICAgICAgcGluX25hbWUoZW4pLCBlbiwgZW4pKQogICAgcmV0dXJuIGxlbihoaXRz
KQoKCmRlZiBjbWRfcHJvYmUobWVtLCBhcmdzKToKICAgICIiIuaJviJQSFkg5L6b55S1L+S9v+iD
veiEmiLvvJrmjInkvY8gMTIyIOmrmOeUteW5s++8jOmAkOS4quaKiuWAmemAieiEmuaLiemrmOOA
geaLieS9ju+8jAogICAg5q+P5Liq54q25oCB5omr5LiA6YGNIEQxL0QwIOeahCAwfjfjgILlk6rk
uKrohJrkuIDmi4nlsLHmnInlupTnrZTvvIzpgqPkuKrlsLHmmK/orqkgUEhZIOecn+ato+mAmueU
teeahOiEmuOAgiIiIgogICAgbnVtcyA9IFtpbnQoYSkgZm9yIGEgaW4gYXJncyBpZiBhLmlzZGln
aXQoKV0KICAgIGVuID0gbnVtc1swXSBpZiBsZW4obnVtcykgPj0gMSBlbHNlIDEyMgogICAgYmFu
a3MgPSBwYXJzZV9iYW5rcyhhcmdzLCBkZWZhdWx0PSgyLCAzKSkKICAgIGZvcmNlID0gIi0tZm9y
Y2UiIGluIGFyZ3MKICAgIGtlZXAgPSBQaW4obWVtLCBlbikKICAgIHN0ID0gbG9hZF9zdGF0ZSgp
CiAgICBpZiBzdHIoZW4pIG5vdCBpbiBzdDoKICAgICAgICBzdFtzdHIoZW4pXSA9IGtlZXAuc25h
cHNob3QoKQogICAgICAgIHNhdmVfc3RhdGUoc3QpCiAgICBrZWVwLm11eF9ncGlvKCkKICAgIGtl
ZXAuc2V0KDEpCiAgICBrZWVwLnNldF9kaXIoVHJ1ZSkKICAgIHRpbWUuc2xlZXAoMC4zKQogICAg
Y2FuZHMgPSBbcSBmb3IgcSBpbiBzYWZlX3BpbnMobWVtLCBiYW5rcywgZm9yY2U9Zm9yY2UsIHdp
dGhfbWRpbz1GYWxzZSkgaWYgcSAhPSBlbl0KICAgIHByaW50KCLlt7LmjInkvY8gJXMoJWQpIOmr
mOeUteW5s++8m2JhbmsgJXMg6YeMICVkIOWPquWAmemAieiEmu+8jOavj+WPquivlSDpq5gv5L2O
IOS4pOenje+8jOWQhOaJqyAwfjcgLi4uIiAlICgKICAgICAgICBwaW5fbmFtZShlbiksIGVuLCAi
LCIuam9pbihzdHIoYikgZm9yIGIgaW4gYmFua3MpLCBsZW4oY2FuZHMpKSkKICAgIHByaW50KCLp
ooTorqEgJWQg56eS77yM6L+b5bqm5Lya5LiA55u05Yi35paw77yM5ZG95Lit5Lya5YGc5LiL5p2l
5omT5Y2w44CCIiAlIChsZW4oY2FuZHMpICogMiAqIDAuMykpCiAgICBoaXRzID0gW10KICAgIGZv
ciBuLCBxIGluIGVudW1lcmF0ZShjYW5kcyk6CiAgICAgICAgZm9yIHZhbCBpbiAoMSwgMCk6CiAg
ICAgICAgICAgIGN0bCA9IFBpbihtZW0sIHEpCiAgICAgICAgICAgIG9yaWcgPSBjdGwuc25hcHNo
b3QoKQogICAgICAgICAgICBjdGwubXV4X2dwaW8oKQogICAgICAgICAgICBjdGwuc2V0KHZhbCkK
ICAgICAgICAgICAgY3RsLnNldF9kaXIoVHJ1ZSkKICAgICAgICAgICAgc3lzLnN0ZG91dC53cml0
ZSgiXHIgIFslZC8lZF0gJXMoJWQpPSVkICAgICAgIiAlICgKICAgICAgICAgICAgICAgIChuICog
MiArICgwIGlmIHZhbCBlbHNlIDEpICsgMSksIGxlbihjYW5kcykgKiAyLCBwaW5fbmFtZShxKSwg
cSwgdmFsKSkKICAgICAgICAgICAgc3lzLnN0ZG91dC5mbHVzaCgpCiAgICAgICAgICAgIHRpbWUu
c2xlZXAoMC4yNSkKICAgICAgICAgICAgZm9yIGFkZHIgaW4gcmFuZ2UoOCk6CiAgICAgICAgICAg
ICAgICBwaWQgPSBwaHlfaWQobWVtLCAxMjEsIDEyMCwgYWRkcikKICAgICAgICAgICAgICAgIGlm
IGlzX3ZhbGlkKHBpZCk6CiAgICAgICAgICAgICAgICAgICAgaGl0cy5hcHBlbmQoKHEsIHZhbCwg
YWRkciwgcGlkKSkKICAgICAgICAgICAgICAgICAgICBwcmludCgiIikKICAgICAgICAgICAgICAg
ICAgICBwcmludCgiICDlkb3kuK3vvIHmjqfliLbohJo9JXMoJWQpIOaLiSVzIFBIWeWcsOWdgD0l
ZCBpZD0weCUwOFgiICUgKAogICAgICAgICAgICAgICAgICAgICAgICBwaW5fbmFtZShxKSwgcSwg
IumrmCIgaWYgdmFsIGVsc2UgIuS9jiIsIGFkZHIsIHBpZCkpCiAgICAgICAgICAgIGN0bC5yZXN0
b3JlKG9yaWcpCiAgICBwcmludCgiIikKICAgIGlmIG5vdCBoaXRzOgogICAgICAgIHByaW50KCLn
u5PmnpzvvJpiYW5rICVzIOi/mSAlZCDlj6rohJrvvIzml6Dorrrmi4npq5jov5jmmK/mi4nkvY7v
vIxEMS9EMCDkuIrpg73msqHmnIkgUEhZIOW6lOetlOOAgiIgJSAoCiAgICAgICAgICAgICIsIi5q
b2luKHN0cihiKSBmb3IgYiBpbiBiYW5rcyksIGxlbihjYW5kcykpKQogICAgICAgIHByaW50KCIg
ICAgICDor7TmmI4gUEhZIOS4jeWcqCBEMS9EMCDkuIrvvIzmiJbogIUgUEhZIOagueacrOayoeS+
m+eUte+8iOS4i+S4gOatpeafpSBiYW5rMC9iYW5rMSDnmoTnqbrpl7LohJrvvInjgIIiKQogICAg
ZWxzZToKICAgICAgICBwcmludCgi57uT5p6c77ya5om+5YiwICVkIOWkhOW6lOetlO+8jOingeS4
iumdouWIl+ihqOOAgiIgJSBsZW4oaGl0cykpCiAgICBwcmludCgi5pS25bC+77yabWRpby1zY2Fu
IGZyZWUgYWxsIikKICAgIHJldHVybiBsZW4oaGl0cykKCgpkZWYgY21kX211eChtZW0sIGFyZ3Mp
OgogICAgIiIi55u05o6l5pS55p+Q5Y+q6ISa55qEIGlvbXV4IOWAvO+8iDA9R1BJT++8jDEvMi8z
PeivpeiEmueahOWKn+iDveWPt++8ieOAguWPquWFgeiuuCBiYW5rMi9iYW5rM+OAgiIiIgogICAg
bnVtcyA9IFtpbnQoYSkgZm9yIGEgaW4gYXJncyBpZiBhLmlzZGlnaXQoKV0KICAgIGlmIGxlbihu
dW1zKSA8IDI6CiAgICAgICAgcHJpbnQoIueUqOazle+8mm1kaW8tc2NhbiBtdXggPOiEmuWPtz4g
POWAvD4gICDkvovlpoIgbWRpby1zY2FuIG11eCAxMTcgMiIpCiAgICAgICAgcmV0dXJuIDEKICAg
IG4sIHZhbCA9IG51bXNbMF0sIG51bXNbMV0KICAgIGlmIG4gLy8gMzIgaW4gQkxBQ0tfQkFOS1Mg
YW5kICItLWZvcmNlIiBub3QgaW4gYXJnczoKICAgICAgICBwcmludCgi5ouS57ud77yaR1BJTyVk
IOaYr+mXquWtmC9QTUlDL2VNTUMg5Yy677yM5LiN5YWB6K645pS5IGlvbXV444CCIiAlIChuIC8v
IDMyKSkKICAgICAgICByZXR1cm4gMQogICAgcCA9IFBpbihtZW0sIG4pCiAgICBtc3QgPSBsb2Fk
X211eCgpCiAgICBrZXkgPSBzdHIobikKICAgIGlmIGtleSBub3QgaW4gbXN0OgogICAgICAgIG1z
dFtrZXldID0gcC5tdXhfZ2V0KCkKICAgICAgICBzYXZlX211eChtc3QpCiAgICBwLm11eF9zZXQo
dmFsKQogICAgcHJpbnQoIiVzKCVkKSBpb211eCAlZCAtPiAlZO+8iOWOn+WAvCAlZO+8jOWPr+eU
qCBtZGlvLXNjYW4gZnJlZSBhbGwg5oGi5aSN77yJIiAlICgKICAgICAgICBwaW5fbmFtZShuKSwg
biwgbXN0W2tleV0sIHZhbCwgbXN0W2tleV0pKQogICAgcmV0dXJuIDAKCgpkZWYgY21kX3JlZ3Mo
bWVtLCBhcmdzKToKICAgICIiIuivu+afkOS4qiBQSFkg5Zyw5Z2A55qEIDB+NSDlj7flr4TlrZjl
majvvIznlKjkuo7noa7orqQgUEhZIOecn+eahOa0u+edgOOAgiIiIgogICAgbnVtcyA9IFtpbnQo
YSkgZm9yIGEgaW4gYXJncyBpZiBhLmlzZGlnaXQoKV0KICAgIGFkZHIgPSBudW1zWzBdIGlmIGxl
bihudW1zKSA+PSAxIGVsc2UgMAogICAgbWRjX251bSA9IG51bXNbMV0gaWYgbGVuKG51bXMpID49
IDIgZWxzZSAxMjEKICAgIG1kaW9fbnVtID0gbnVtc1syXSBpZiBsZW4obnVtcykgPj0gMyBlbHNl
IDEyMAogICAgbmFtZXMgPSBbIkJNQ1IiLCAiQk1TUiIsICJQSFlJRDEiLCAiUEhZSUQyIiwgIkFO
QVIiLCAiQU5MUEFSIl0KICAgIHByaW50KCLor7sgJXMvJXMg5LiKIFBIWSDlnLDlnYAgJWQg55qE
5a+E5a2Y5Zmo77yaIiAlICgKICAgICAgICBwaW5fbmFtZShtZGNfbnVtKSwgcGluX25hbWUobWRp
b19udW0pLCBhZGRyKSkKICAgIHZhbHMgPSBbXQogICAgZm9yIHIgaW4gcmFuZ2UoNik6CiAgICAg
ICAgdiA9IGJiX3JlYWQoUGluKG1lbSwgbWRjX251bSksIFBpbihtZW0sIG1kaW9fbnVtKSwgYWRk
ciwgcikKICAgICAgICB2YWxzLmFwcGVuZCh2KQogICAgICAgIHByaW50KCIgIHJlZyVkICUtN3Mg
PSAweCUwNFgiICUgKHIsIG5hbWVzW3JdLCB2KSkKICAgIHBpZCA9ICh2YWxzWzJdIDw8IDE2KSB8
IHZhbHNbM10KICAgIHByaW50KCIgIFBIWSBJRCA9IDB4JTA4WCVzIiAlIChwaWQsICIgIDw9PSDm
nInmlYgiIGlmIGlzX3ZhbGlkKHBpZCkgZWxzZSAiICA8PT0g5peg5pWIL+aXoOW6lOetlCIpKQog
ICAgaWYgaXNfdmFsaWQocGlkKToKICAgICAgICBwcmludCgiICBPVUk9MHglMDZYICDlnovlj7c9
MHglMDNYICDniYjmnKw9JWQiICUgKAogICAgICAgICAgICAocGlkID4+IDEwKSAmIDB4RkZGRkZG
LCAocGlkID4+IDQpICYgMHgzRiwgcGlkICYgMHhGKSkKICAgICAgICBpZiAocGlkID4+IDEwKSAm
IDB4RkZGRkZGID09IDB4MDAxQ0MwOgogICAgICAgICAgICBwcmludCgiICBPVUkgMHgwMDFDQzAg
PSBSZWFsdGVr77yM5LiO5L2g5p2/5LiK55qEIFJUTDgyMDFGTiDlkLvlkIgiKQogICAgYm1zciA9
IHZhbHNbMV0KICAgIGlmIGlzX3ZhbGlkKHBpZCk6CiAgICAgICAgcHJpbnQoIiAgQk1TUjog6ZO+
6LevPSVzIOiHquWNj+WVhuWujOaIkD0lcyAxME09JXMgMTAwTT0lcyIgJSAoCiAgICAgICAgICAg
ICJ1cCIgaWYgYm1zciAmIDB4MDAwNCBlbHNlICJkb3duIiwKICAgICAgICAgICAgIuaYryIgaWYg
Ym1zciAmIDB4MDAyMCBlbHNlICLlkKYiLAogICAgICAgICAgICAi5pSv5oyBIiBpZiBibXNyICYg
MHgwODAwIGVsc2UgIuS4jeaUr+aMgSIsCiAgICAgICAgICAgICLmlK/mjIEiIGlmIGJtc3IgJiAw
eDEwMDAgZWxzZSAi5LiN5pSv5oyBIikpCiAgICByZXR1cm4gMAoKCmRlZiBjbWRfZHVtcChtZW0s
IGFyZ3MpOgogICAgZm9yIGIsIGJhc2UgaW4gZW51bWVyYXRlKEdQSU9fQkFTRSk6CiAgICAgICAg
cHJpbnQoIkdQSU8lZCBiYXNlPTB4JTA4WCBEUj0weCUwOFggRERSPTB4JTA4WCBFWFQ9MHglMDhY
IiAlICgKICAgICAgICAgICAgYiwgYmFzZSwKICAgICAgICAgICAgbWVtLnJkKGJhc2UgKyBSRUdf
RFIpLCBtZW0ucmQoYmFzZSArIFJFR19ERFIpLCBtZW0ucmQoYmFzZSArIFJFR19FWFQpKSkKICAg
IHJldHVybiAwCgoKQ01EUyA9IHsKICAgICJwaW4iOiBjbWRfcGluLAogICAgInNhZmUiOiBjbWRf
c2FmZSwKICAgICJzY2FuIjogY21kX3NjYW4sCiAgICAic3dlZXAiOiBjbWRfc3dlZXAsCiAgICAi
Y3RsIjogY21kX2N0bCwKICAgICJob2xkIjogY21kX2hvbGQsCiAgICAiZnJlZSI6IGNtZF9mcmVl
LAogICAgIndha2UiOiBjbWRfd2FrZSwKICAgICJtdXgiOiBjbWRfbXV4LAogICAgInByb2JlIjog
Y21kX3Byb2JlLAogICAgInJlZ3MiOiBjbWRfcmVncywKICAgICJkdW1wIjogY21kX2R1bXAsCn0K
CgpkZWYgbWFpbigpOgogICAgaWYgbGVuKHN5cy5hcmd2KSA8IDIgb3Igc3lzLmFyZ3ZbMV0gbm90
IGluIENNRFM6CiAgICAgICAgcHJpbnQoX19kb2NfXyBvciAiIikKICAgICAgICBwcmludCgi5Y+v
55So5ZG95Luk77yaIiArICIgLyAiLmpvaW4oc29ydGVkKENNRFMpKSkKICAgICAgICByZXR1cm4g
MgogICAgbWVtID0gTWVtKCkKICAgIHIgPSBDTURTW3N5cy5hcmd2WzFdXShtZW0sIHN5cy5hcmd2
WzI6XSkKICAgIGlmIHIgaXMgTm9uZToKICAgICAgICByZXR1cm4gMAogICAgcmV0dXJuIDAgaWYg
ciA+PSAwIGVsc2UgMQoKCmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICBzeXMuZXhpdCht
YWluKCkpCg==
MDIOSCAN_B64
chmod 755 /usr/local/bin/mdio-scan
if [ ! -x /usr/bin/python3 ] && [ ! -x /usr/local/bin/python3 ]; then
    echo "⚠️  rootfs 里没有 python3，mdio-scan 无法运行"
else
    echo "✅ 已安装 /usr/local/bin/mdio-scan（python3 版 MDIO 引脚探测工具）"
fi
