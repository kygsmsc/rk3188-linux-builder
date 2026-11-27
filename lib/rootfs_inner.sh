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

# ---- 第三十四~三十七轮：网口迟到初始化 + 自愈网络守护 ----
# 实测时间线（ttl-27 ~ ttl-36）：
#   * emac =y 内建时，eth0 在启动早期就存在 → PID1 在 4~6s 的 manager_preset_all()
#     阶段硬卡死。改 =m 后由 udev 在 9.4s 自动加载，能正常进 login（ttl-33/34）。
#   * ttl-34: eth0 up、静态 IP + 网关 ping 通，但 RX errors 持续增长。
#   * ttl-36: 运行约 40 分钟后出现
#       [2393.387] speed 4294967295 not supported   ← phydev->speed = SPEED_UNKNOWN
#       [2393.392] eth0: Link is Down               ← PHY 真的掉了链，不是 ICMP 丢包
#       [2397.497] eth0: Link is Up - 100Mbps/Full  ← 4 秒后自己回来
#       [2436.168] 又一次 Down → Up
#     说明链路本身在 flapping（phy_stop/phy_start 时 speed 被置为 SPEED_UNKNOWN，
#     arc_emac_adjust_link 见 speed 变化就调 set_mac_speed(0xFFFFFFFF) → 打这行错，
#     本身只是噪音，但它是"链路掉过"的铁证）。
#   * ttl-36 里 `ip -br addr` 显示 eth0 = 192.168.0.104/24 metric 1024 →
#     **DHCP 其实是能用的**（先前"DHCP 完全无应答"是链路质量差时的假象）。
#     但 ISC dhclient 在链路 down 时会执行 dhclient-script 把地址撤掉，
#     于是每次 flap 都变成"彻底没 IP" → 只能靠串口救。
# 做法：
#   1) blacklist 掉模块，让 udev 不再早期自动加载（彻底避开卡死窗口）；
#   2) 一个常驻守护进程 emac-netd.sh：上模块 → 拉起链路 → 配 IP（先 DHCP，
#      连败 3 次就锁死用静态）→ 监视 carrier，掉了就自己重启链路；
#      不依赖 dhclient 常驻，所以 flap 后能自动恢复，不用再插串口。
mkdir -p /etc/modprobe.d
cat > /etc/modprobe.d/emac-late.conf << 'EMACMOD'
# 禁止 udev 按设备别名自动加载网口驱动，
# 改由 emac-net.service 在系统启动完成后再 modprobe（避开 PID1 早期卡死窗口）。
blacklist emac_rockchip
blacklist arc_emac
EMACMOD

cat > /etc/emac-net.conf << 'EMACCONF'
# emac-net.service 的运行参数。改完 systemctl restart emac-net 就生效，不用重编内核。
# DHCP_TRY=1：先试 DHCP；连续失败 3 次后本轮启动不再试，直接锁静态 IP。
DHCP_TRY=1
STATIC_IP=192.168.0.88
STATIC_MASK=24
STATIC_GW=192.168.0.254
DNS1=223.5.5.5
DNS2=223.6.6.6
# PING_WATCH=1：链路显示 up 但连续 3 次 ping 不通网关时，自动重启链路。
# 若你的网关屏蔽 ICMP，把它改成 0，就只按 carrier 判断。
PING_WATCH=1
LOOP_SEC=20
EMACCONF

cat > /usr/local/sbin/emac-netd.sh << 'EMACD'
#!/bin/sh
# 网口(RTL8201FN) 常驻守护：上模块 / 拉起链路 / 配 IP / 掉链自愈
CFG=/etc/emac-net.conf
[ -f "$CFG" ] && . "$CFG"
: "${DHCP_TRY:=1}"
: "${STATIC_IP:=192.168.0.88}"
: "${STATIC_MASK:=24}"
: "${STATIC_GW:=192.168.0.254}"
: "${DNS1:=223.5.5.5}"
: "${DNS2:=223.6.6.6}"
: "${PING_WATCH:=1}"
: "${LOOP_SEC:=20}"

IPCMD=/usr/sbin/ip
[ -x "$IPCMD" ] || IPCMD=/bin/ip
[ -x "$IPCMD" ] || IPCMD=ip

log() { echo "emac-netd: $*" > /dev/kmsg 2>/dev/null || true; }

has_ip() { $IPCMD -4 addr show eth0 2>/dev/null | grep -q " inet "; }
get_carrier() { cat /sys/class/net/eth0/carrier 2>/dev/null; }

wait_eth0() {
  i=0
  while [ ! -d /sys/class/net/eth0 ] && [ $i -lt 15 ]; do i=$((i+1)); sleep 1; done
  [ -d /sys/class/net/eth0 ]
}

load_mod() {
  log "modprobe emac_rockchip"
  modprobe emac_rockchip 2>/dev/null || modprobe arc_emac 2>/dev/null || true
}

fix_dns() {
  if ! grep -q "$DNS1" /etc/resolv.conf 2>/dev/null; then
    # /etc/resolv.conf 在 Ubuntu Base 里是指向 /run/systemd/resolve/... 的悬空符号链接，
    # 直接重定向会 ENOENT，必须先删链接再建普通文件。
    rm -f /etc/resolv.conf
    { echo "nameserver $DNS1"; echo "nameserver $DNS2"; } > /etc/resolv.conf 2>/dev/null || true
    log "resolv.conf -> $DNS1 $DNS2"
  fi
}

DHCP_FAIL=0
ensure_ip() {
  has_ip && return 0
  if [ "$DHCP_TRY" = "1" ] && [ $DHCP_FAIL -lt 3 ] && [ -x /usr/sbin/dhclient ]; then
    log "dhclient 尝试"
    if /usr/sbin/dhclient -4 -1 -t 10 -q eth0 >/dev/null 2>&1 && has_ip; then
      DHCP_FAIL=0
      log "DHCP 成功: $($IPCMD -4 -br addr show eth0 2>/dev/null)"
      return 0
    fi
    DHCP_FAIL=$((DHCP_FAIL+1))
    log "dhclient 失败（$DHCP_FAIL/3）"
  fi
  has_ip && return 0
  log "回落静态 $STATIC_IP/$STATIC_MASK 网关 $STATIC_GW"
  $IPCMD -4 addr add "$STATIC_IP/$STATIC_MASK" dev eth0 2>/dev/null || true
  $IPCMD -4 route replace default via "$STATIC_GW" dev eth0 2>/dev/null || true
  has_ip
}

# 清掉可能残留的常驻 dhclient：它会在链路 down 时把地址撤掉，正是 ttl-36 的坑
pkill -f "dhclient.*eth0" 2>/dev/null || true

[ -d /sys/class/net/eth0 ] || { load_mod; wait_eth0; }

DOWN_CNT=0
PING_FAIL=0
while :; do
  if [ ! -d /sys/class/net/eth0 ]; then
    load_mod
    wait_eth0
    sleep 3
  fi

  $IPCMD link set eth0 up 2>/dev/null || true
  C=$(get_carrier)

  if [ "$C" != "1" ]; then
    DOWN_CNT=$((DOWN_CNT+1))
    log "carrier=$C（连续 $DOWN_CNT 次）"
    if [ $DOWN_CNT -ge 3 ]; then
      log "链路持续断开，重启 eth0"
      $IPCMD link set eth0 down 2>/dev/null || true
      sleep 2
      $IPCMD link set eth0 up 2>/dev/null || true
      DOWN_CNT=0
      sleep 3
    fi
  else
    if [ $DOWN_CNT -gt 0 ]; then
      log "链路已恢复"
      DOWN_CNT=0
      PING_FAIL=0
    fi
    if ! has_ip; then
      log "eth0 没有 IPv4，开始配置"
      ensure_ip
    fi
    if [ "$PING_WATCH" = "1" ] && has_ip; then
      if ping -c1 -W3 "$STATIC_GW" >/dev/null 2>&1; then
        PING_FAIL=0
      else
        PING_FAIL=$((PING_FAIL+1))
        log "ping $STATIC_GW 失败（$PING_FAIL/3）"
        if [ $PING_FAIL -ge 3 ]; then
          log "链路 up 但通信不通，重启 eth0"
          $IPCMD link set eth0 down 2>/dev/null || true
          sleep 3
          $IPCMD link set eth0 up 2>/dev/null || true
          PING_FAIL=0
        fi
      fi
    fi
    fix_dns
  fi

  sleep "$LOOP_SEC"
done
EMACD
chmod 755 /usr/local/sbin/emac-netd.sh

cat > /etc/systemd/system/emac-net.service << 'EMACUNIT'
[Unit]
Description=Rockchip EMAC (RTL8201FN) bring-up and keep-alive
Documentation=file:///etc/emac-net.conf
After=local-fs.target
Wants=local-fs.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/emac-netd.sh
Restart=always
RestartSec=10
StandardOutput=journal+console

[Install]
WantedBy=multi-user.target
EMACUNIT

systemctl enable emac-net.service 2>/dev/null || true
if [ -L /etc/systemd/system/multi-user.target.wants/emac-net.service ]; then
  echo "✅ emac-net.service 已启用（守护进程：自动 modprobe + 配 IP + 掉链自愈）"
else
  mkdir -p /etc/systemd/system/multi-user.target.wants
  ln -snf /etc/systemd/system/emac-net.service /etc/systemd/system/multi-user.target.wants/emac-net.service
  echo "✅ emac-net.service 已启用（手工建符号链接兜底）"
fi

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
ICAgICAgdGltZS5zbGVlcChEKQogICAgcmV0dXJuIHZhbAoKCmRlZiBiYl93cml0ZShtZGMsIG1k
aW8sIHBoeSwgcmVnLCB2YWwpOgogICAgIiIi5qCH5YeGIENsYXVzZSAyMiDlhpnvvJpwcmVhbWJs
ZSArIFNUKDAxKSArIE9QKDAxKSArIFBIWUFEKDUpICsgUkVHQUQoNSkgKyBUQSgxMCkgKyAxNiDm
lbDmja7kvY0iIiIKICAgIG1kaW8ubXV4X2dwaW8oKQogICAgbWRjLm11eF9ncGlvKCkKICAgIG1k
Yy5zZXRfZGlyKFRydWUpCiAgICBtZGMuc2V0KDApCiAgICBtZGlvLnNldF9kaXIoVHJ1ZSkKCiAg
ICBkZWYgY2xrX3dyaXRlKGJpdCk6CiAgICAgICAgbWRpby5zZXQoYml0KQogICAgICAgIHRpbWUu
c2xlZXAoRCkKICAgICAgICBtZGMuc2V0KDEpCiAgICAgICAgdGltZS5zbGVlcChEKQogICAgICAg
IG1kYy5zZXQoMCkKICAgICAgICB0aW1lLnNsZWVwKEQpCgogICAgZm9yIF8gaW4gcmFuZ2UoMzIp
OgogICAgICAgIGNsa193cml0ZSgxKQoKICAgIGJpdHMgPSBbMCwgMSwgMCwgMV0gICAgICAgICAg
ICAgICAgICAgICAgICMgU1Q9MDEsIE9QPTAxKOWGmSkKICAgIGZvciBpIGluIHJhbmdlKDQsIC0x
LCAtMSk6CiAgICAgICAgYml0cy5hcHBlbmQoKHBoeSA+PiBpKSAmIDEpCiAgICBmb3IgaSBpbiBy
YW5nZSg0LCAtMSwgLTEpOgogICAgICAgIGJpdHMuYXBwZW5kKChyZWcgPj4gaSkgJiAxKQogICAg
Yml0cy5hcHBlbmQoMSkgICAgICAgICAgICAgICAgICAgICAgICAgICAgIyBUQTog5YWIIE1ESU8g
6L6T5Ye6IDEKICAgIGJpdHMuYXBwZW5kKDApICAgICAgICAgICAgICAgICAgICAgICAgICAgICMg
ICAg5YaN6YeK5pS+77yI5YaZ5pON5L2cIFRBPTEw77yJCiAgICBmb3IgYiBpbiBiaXRzOgogICAg
ICAgIGNsa193cml0ZShiKQoKICAgIG1kaW8uc2V0X2RpcihUcnVlKQogICAgZm9yIGkgaW4gcmFu
Z2UoMTUsIC0xLCAtMSk6CiAgICAgICAgY2xrX3dyaXRlKCh2YWwgPj4gaSkgJiAxKQoKICAgIG1k
aW8uc2V0X2RpcihGYWxzZSkKICAgIHRpbWUuc2xlZXAoRCkKICAgIHJldHVybiAwCgoKZGVmIHJk
X3N0YWJsZShtZGMsIG1kaW8sIHBoeSwgcmVnLCB0cmllcz0zKToKICAgICIiIui/nuivu+WHoOas
oeWPluWkmuaVsO+8jOaKtea2iCBQeXRob24g5Zyo55So5oi35oCB6LeRIGJpdC1iYW5nIOaXtuea
hOWBtuWPkeaXtuW6j+aKluWKqOOAgiIiIgogICAgdmFscyA9IFtiYl9yZWFkKG1kYywgbWRpbywg
cGh5LCByZWcpIGZvciBfIGluIHJhbmdlKHRyaWVzKV0KICAgIGZvciB2IGluIHZhbHM6CiAgICAg
ICAgaWYgdmFscy5jb3VudCh2KSA+PSAyOgogICAgICAgICAgICByZXR1cm4gdgogICAgcmV0dXJu
IHZhbHNbLTFdCgoKZGVmIHBhcnNlX3BoeV9hcmdzKGFyZ3MsIGRlZmF1bHRzKToKICAgIG51bXMg
PSBbaW50KGEsIDApIGZvciBhIGluIGFyZ3MgaWYgYS5sb3dlcigpLnN0YXJ0c3dpdGgoIjB4Iikg
b3IgYS5pc2RpZ2l0KCldCiAgICB2YWxzID0gbGlzdChkZWZhdWx0cykKICAgIGZvciBpLCB2IGlu
IGVudW1lcmF0ZShudW1zWzpsZW4odmFscyldKToKICAgICAgICB2YWxzW2ldID0gdgogICAgcmV0
dXJuIHZhbHMKCgpkZWYgcGh5X2lkKG1lbSwgbWRjX251bSwgbWRpb19udW0sIGFkZHIpOgogICAg
bWRjID0gUGluKG1lbSwgbWRjX251bSkKICAgIG1kaW8gPSBQaW4obWVtLCBtZGlvX251bSkKICAg
IGhpID0gYmJfcmVhZChtZGMsIG1kaW8sIGFkZHIsIDIpCiAgICBsbyA9IGJiX3JlYWQobWRjLCBt
ZGlvLCBhZGRyLCAzKQogICAgcmV0dXJuIChoaSA8PCAxNikgfCBsbwoKCmRlZiBpc192YWxpZChw
aWQpOgogICAgaWYgcGlkIGluIEJBRF9JRFM6CiAgICAgICAgcmV0dXJuIEZhbHNlCiAgICBoaSA9
IChwaWQgPj4gMTYpICYgMHhGRkZGCiAgICBsbyA9IHBpZCAmIDB4RkZGRgogICAgaWYgaGkgaW4g
KDB4MDAwMCwgMHhGRkZGKSBhbmQgbG8gaW4gKDB4MDAwMCwgMHhGRkZGKToKICAgICAgICByZXR1
cm4gRmFsc2UKICAgIHJldHVybiBUcnVlCgoKZGVmIGNtZF9waW4obWVtLCBhcmdzKToKICAgIGZv
ciBhIGluIGFyZ3M6CiAgICAgICAgcCA9IFBpbihtZW0sIGludChhKSkKICAgICAgICBwcmludCgi
cGluICUtM2QgJS0xMHMgbXV4PSVkIGRpcj0lcyBsZXZlbD0lZCIgJSAoCiAgICAgICAgICAgIHAu
bnVtLCBwaW5fbmFtZShwLm51bSksIHAubXV4X2dldCgpLAogICAgICAgICAgICAib3V0IiBpZiBw
LmRpcl9vdXQoKSBlbHNlICJpbiIsIHAuZ2V0KCkpKQogICAgcmV0dXJuIDAKCgpkZWYgY21kX3Nh
ZmUobWVtLCBhcmdzKToKICAgIGJhbmtzID0gcGFyc2VfYmFua3MoYXJncykKICAgIGFueV9tdXgg
PSAiLS1hbnkiIGluIGFyZ3MKICAgIGZvcmNlID0gIi0tZm9yY2UiIGluIGFyZ3MKICAgIHBpbnMg
PSBzYWZlX3BpbnMobWVtLCBiYW5rcywgYW55X211eCwgZm9yY2UpCiAgICBpZiAiLS1saXN0IiBp
biBhcmdzOgogICAgICAgIGZvciBwIGluIHBpbnM6CiAgICAgICAgICAgIHByaW50KHApCiAgICAg
ICAgcmV0dXJuIDAKICAgIHByaW50KCJiYW5rICVzIOmHjOWPr+WuieWFqOaTjeS9nOeahOW8leiE
muWFsSAlZCDkuKrvvIhtdXg9PTAg5LiU5pyq6KKr5o6S6Zmk77yJ77yaIiAlICgKICAgICAgICAi
LCIuam9pbihzdHIoYikgZm9yIGIgaW4gYmFua3MpLCBsZW4ocGlucykpKQogICAgZm9yIHAgaW4g
cGluczoKICAgICAgICBxID0gUGluKG1lbSwgcCkKICAgICAgICBwcmludCgiICAlLTNkICUtMTBz
IG11eD0lZCBkaXI9JXMgbGV2ZWw9JWQiICUgKAogICAgICAgICAgICBwLCBwaW5fbmFtZShwKSwg
cS5tdXhfZ2V0KCksICJvdXQiIGlmIHEuZGlyX291dCgpIGVsc2UgImluIiwgcS5nZXQoKSkpCiAg
ICBpZiBub3QgcGluczoKICAgICAgICBwcmludCgiICDvvIjkuIDkuKrpg73msqHmnInjgILlj6/o
g73ov5nkupsgYmFuayDnmoTohJrlhajooqvljaDnlKjkuobvvIzor5Xor5UgLS1iYW5rPTIg5oiW
IC0tYW5577yJIikKICAgIHJldHVybiAwCgoKZGVmIGNtZF9zY2FuKG1lbSwgYXJncyk6CiAgICBu
dW1zID0gW2ludChhKSBmb3IgYSBpbiBhcmdzIGlmIGEuaXNkaWdpdCgpXQogICAgbWRjX251bSA9
IG51bXNbMF0gaWYgbGVuKG51bXMpID49IDEgZWxzZSAxMjEKICAgIG1kaW9fbnVtID0gbnVtc1sx
XSBpZiBsZW4obnVtcykgPj0gMiBlbHNlIDEyMAogICAgbG8gPSBudW1zWzJdIGlmIGxlbihudW1z
KSA+PSAzIGVsc2UgMAogICAgaGkgPSBudW1zWzNdIGlmIGxlbihudW1zKSA+PSA0IGVsc2UgNwog
ICAgcHJpbnQoIuaJqyAlcyhNREMpIC8gJXMoTURJTykg5Zyw5Z2AICVkfiVkIiAlICgKICAgICAg
ICBwaW5fbmFtZShtZGNfbnVtKSwgcGluX25hbWUobWRpb19udW0pLCBsbywgaGkpKQogICAgaGl0
ID0gMAogICAgZm9yIGFkZHIgaW4gcmFuZ2UobG8sIGhpICsgMSk6CiAgICAgICAgcGlkID0gcGh5
X2lkKG1lbSwgbWRjX251bSwgbWRpb19udW0sIGFkZHIpCiAgICAgICAgZmxhZyA9ICIgIDw9PSDm
nInlupTnrZQiIGlmIGlzX3ZhbGlkKHBpZCkgZWxzZSAiIgogICAgICAgIHByaW50KCIgIGFkZHIg
JWQgOiBpZD0weCUwOFglcyIgJSAoYWRkciwgcGlkLCBmbGFnKSkKICAgICAgICBpZiBpc192YWxp
ZChwaWQpOgogICAgICAgICAgICBoaXQgKz0gMQogICAgcHJpbnQoIuWQiOiuoeWRveS4rSAlZCDk
uKrlnLDlnYDjgIIiICUgaGl0KQogICAgcmV0dXJuIGhpdAoKCmRlZiBjbWRfc3dlZXAobWVtLCBh
cmdzKToKICAgIGJhbmtzID0gcGFyc2VfYmFua3MoYXJncykKICAgIGFkaiA9ICItLWFkaiIgaW4g
YXJncwogICAgcGlucyA9IHNhZmVfcGlucyhtZW0sIGJhbmtzKQogICAgcGFpcnMgPSBbXQogICAg
aWYgYWRqOgogICAgICAgIGZvciBwIGluIHBpbnM6CiAgICAgICAgICAgIGlmIHAgKyAxIGluIHBp
bnM6CiAgICAgICAgICAgICAgICBwYWlycy5hcHBlbmQoKHAsIHAgKyAxKSkKICAgICAgICAgICAg
ICAgIHBhaXJzLmFwcGVuZCgocCArIDEsIHApKQogICAgICAgIHByaW50KCJiYW5rICVzIOWGheeb
uOmCu+WuieWFqOiEmuWvuSAlZCDnu4TvvIjlkKvmraPlj43mnoHmgKfvvInvvIzlvIDlp4vmiavm
j48gLi4uIiAlICgKICAgICAgICAgICAgIiwiLmpvaW4oc3RyKGIpIGZvciBiIGluIGJhbmtzKSwg
bGVuKHBhaXJzKSkpCiAgICBlbHNlOgogICAgICAgIGZvciBhIGluIHBpbnM6CiAgICAgICAgICAg
IGZvciBiIGluIHBpbnM6CiAgICAgICAgICAgICAgICBpZiBhICE9IGI6CiAgICAgICAgICAgICAg
ICAgICAgcGFpcnMuYXBwZW5kKChhLCBiKSkKICAgICAgICBwcmludCgiYmFuayAlcyDlhoUgJWQg
5Y+q5YCZ6YCJ6ISa55qE5Lik5Lik57uE5ZCIICVkIOe7hO+8iOWQq+ato+WPjeaegeaAp++8ie+8
jOW8gOWni+aJq+aPjyAuLi4iICUgKAogICAgICAgICAgICAiLCIuam9pbihzdHIoYikgZm9yIGIg
aW4gYmFua3MpLCBsZW4ocGlucyksIGxlbihwYWlycykpKQogICAgICAgIHByaW50KCLnuqbpnIAg
MzB+NjAg56eS77yM6L+b5bqm6KGM5Lya5LiA55u05Yi35paw77yM5ZG95Lit5Lya5YGc5LiL5p2l
5omT5Y2w44CCIikKICAgIGlmIG5vdCBwYWlyczoKICAgICAgICBwcmludCgi5rKh5pyJ5Y+v5omr
55qE55u46YK76ISa5a+577yM55u05o6l6YCA5Ye644CCIikKICAgICAgICByZXR1cm4gMAogICAg
aGl0cyA9IFtdCiAgICBmb3IgbiwgKGEsIGIpIGluIGVudW1lcmF0ZShwYWlycyk6CiAgICAgICAg
c3lzLnN0ZG91dC53cml0ZSgiXHIgIFslZC8lZF0gTURDPSVkIE1ESU89JWQgICAgICAiICUgKG4g
KyAxLCBsZW4ocGFpcnMpLCBhLCBiKSkKICAgICAgICBzeXMuc3Rkb3V0LmZsdXNoKCkKICAgICAg
ICBmb3IgYWRkciBpbiByYW5nZSg4KToKICAgICAgICAgICAgcGlkID0gcGh5X2lkKG1lbSwgYSwg
YiwgYWRkcikKICAgICAgICAgICAgaWYgaXNfdmFsaWQocGlkKToKICAgICAgICAgICAgICAgIGhp
dHMuYXBwZW5kKChhLCBiLCBhZGRyLCBwaWQpKQogICAgcHJpbnQoIiIpCiAgICBpZiBub3QgaGl0
czoKICAgICAgICBwcmludCgi57uT5p6c77ya5rKh5pyJ5Lu75L2V5LiA5a+5ICsg5Lu75L2V5Zyw
5Z2A5pyJ5bqU562U44CCIikKICAgIGVsc2U6CiAgICAgICAgcHJpbnQoIue7k+aenO+8muaJvuWI
sCAlZCDlpITlupTnrZTvvJoiICUgbGVuKGhpdHMpKQogICAgICAgIGZvciBhLCBiLCBhZGRyLCBw
aWQgaW4gaGl0czoKICAgICAgICAgICAgcHJpbnQoIiAgTURDPSVzKCVkKSBNRElPPSVzKCVkKSBQ
SFnlnLDlnYA9JWQgaWQ9MHglMDhYIiAlICgKICAgICAgICAgICAgICAgIHBpbl9uYW1lKGEpLCBh
LCBwaW5fbmFtZShiKSwgYiwgYWRkciwgcGlkKSkKICAgIHJldHVybiBsZW4oaGl0cykKCgpkZWYg
Y21kX2N0bChtZW0sIGFyZ3MpOgogICAgYmFua3MgPSBwYXJzZV9iYW5rcyhhcmdzKQogICAgbnVt
cyA9IFtpbnQoYSkgZm9yIGEgaW4gYXJncyBpZiBhLmlzZGlnaXQoKV0KICAgIG1kY19udW0gPSBu
dW1zWzBdIGlmIGxlbihudW1zKSA+PSAxIGVsc2UgMTIxCiAgICBtZGlvX251bSA9IG51bXNbMV0g
aWYgbGVuKG51bXMpID49IDIgZWxzZSAxMjAKICAgIHBpbnMgPSBzYWZlX3BpbnMobWVtLCBiYW5r
cykKICAgIHByaW50KCJiYW5rICVz77yaJXMvJXMg5LiK5YWI5omr5LiA6YGN5Z+657q/IC4uLiIg
JSAoCiAgICAgICAgIiwiLmpvaW4oc3RyKGIpIGZvciBiIGluIGJhbmtzKSwgcGluX25hbWUobWRj
X251bSksIHBpbl9uYW1lKG1kaW9fbnVtKSkpCiAgICBmb3IgYWRkciBpbiByYW5nZSg4KToKICAg
ICAgICBwaWQgPSBwaHlfaWQobWVtLCBtZGNfbnVtLCBtZGlvX251bSwgYWRkcikKICAgICAgICBw
cmludCgiICDln7rnur8gYWRkciAlZCA6IGlkPTB4JTA4WCIgJSAoYWRkciwgcGlkKSkKICAgIGlm
IG5vdCBwaW5zOgogICAgICAgIHByaW50KCLmsqHmnInlj6/mk43kvZznmoTmjqfliLbohJrvvIzp
gIDlh7rvvIjlhYjot5EgbWRpby1zY2FuIHNhZmXvvInjgIIiKQogICAgICAgIHJldHVybiAwCiAg
ICBwcmludCgi6YCQ5Liq5oqKICVkIOS4quWuieWFqOiEmuaLiemrmO+8jOWQjOaXtuaJqyAwfjcg
Li4uIiAlIGxlbihwaW5zKSkKICAgIGhpdHMgPSBbXQogICAgZm9yIG4sIHAgaW4gZW51bWVyYXRl
KHBpbnMpOgogICAgICAgIHN5cy5zdGRvdXQud3JpdGUoIlxyICBbJWQvJWRdIOaLiemrmCAlZCAo
JXMpICAgICAgIiAlIChuICsgMSwgbGVuKHBpbnMpLCBwLCBwaW5fbmFtZShwKSkpCiAgICAgICAg
c3lzLnN0ZG91dC5mbHVzaCgpCiAgICAgICAgY3RsID0gUGluKG1lbSwgcCkKICAgICAgICBvcmln
ID0gY3RsLnNuYXBzaG90KCkKICAgICAgICBjdGwubXV4X2dwaW8oKQogICAgICAgIGN0bC5zZXRf
ZGlyKFRydWUpCiAgICAgICAgY3RsLnNldCgxKQogICAgICAgIGZvciBhZGRyIGluIHJhbmdlKDgp
OgogICAgICAgICAgICBwaWQgPSBwaHlfaWQobWVtLCBtZGNfbnVtLCBtZGlvX251bSwgYWRkcikK
ICAgICAgICAgICAgaWYgaXNfdmFsaWQocGlkKToKICAgICAgICAgICAgICAgIGhpdHMuYXBwZW5k
KChwLCBhZGRyLCBwaWQpKQogICAgICAgIGN0bC5yZXN0b3JlKG9yaWcpCiAgICBwcmludCgiIikK
ICAgIGlmIG5vdCBoaXRzOgogICAgICAgIHByaW50KCLnu5PmnpzvvJrov5kgJWQg5Liq6ISa6YCQ
5Liq5ouJ6auY77yMRDEvRDAg5LiK6YO95rKh5pyJIFBIWSDlupTnrZTjgIIiICUgbGVuKHBpbnMp
KQogICAgZWxzZToKICAgICAgICBwcmludCgi57uT5p6c77ya5om+5YiwICVkIOWkhOW6lOetlO+8
miIgJSBsZW4oaGl0cykpCiAgICAgICAgZm9yIHAsIGFkZHIsIHBpZCBpbiBoaXRzOgogICAgICAg
ICAgICBwcmludCgiICDmjqfliLbohJo9JXMoJWQpIFBIWeWcsOWdgD0lZCBpZD0weCUwOFgiICUg
KHBpbl9uYW1lKHApLCBwLCBhZGRyLCBwaWQpKQogICAgcmV0dXJuIGxlbihoaXRzKQoKCmRlZiBj
bWRfaG9sZChtZW0sIGFyZ3MpOgogICAgbnVtcyA9IFtpbnQoYSkgZm9yIGEgaW4gYXJncyBpZiBh
LmlzZGlnaXQoKV0KICAgIGxvdyA9ICJsb3ciIGluIGFyZ3MKICAgIGZvciBuIGluIG51bXM6CiAg
ICAgICAgaWYgbiAvLyAzMiBpbiBCTEFDS19CQU5LUyBhbmQgIi0tZm9yY2UiIG5vdCBpbiBhcmdz
OgogICAgICAgICAgICBwcmludCgi5ouS57ud77yaR1BJTyVkIOaYr+mXquWtmC9QTUlDL2VNTUMv
VUFSVCDljLrjgILnoa7orqTml6Dor6/lj6/liqAgLS1mb3JjZSDmlL7ooYzjgIIiICUgKG4gLy8g
MzIpKQogICAgICAgICAgICBjb250aW51ZQogICAgICAgIHAgPSBQaW4obWVtLCBuKQogICAgICAg
IHN0ID0gbG9hZF9zdGF0ZSgpCiAgICAgICAga2V5ID0gc3RyKG4pCiAgICAgICAgaWYga2V5IG5v
dCBpbiBzdDoKICAgICAgICAgICAgc3Rba2V5XSA9IHAuc25hcHNob3QoKQogICAgICAgICAgICBz
YXZlX3N0YXRlKHN0KQogICAgICAgIHAubXV4X2dwaW8oKQogICAgICAgIHAuc2V0KDAgaWYgbG93
IGVsc2UgMSkKICAgICAgICBwLnNldF9kaXIoVHJ1ZSkKICAgICAgICBwcmludCgi5bey5oqKICVz
KCVkKSDmi4klc+W5tuS/neaMgei+k+WHuuOAgueciyBSSjQ1IOeBr++8m+S4jeS6ruWwsSBtZGlv
LXNjYW4gZnJlZSAlZOOAguWOn+eKtuaAgT0lcyIgJSAoCiAgICAgICAgICAgIHBpbl9uYW1lKG4p
LCBuLCAi5L2OIiBpZiBsb3cgZWxzZSAi6auYIiwgbiwgc3Rba2V5XSkpCiAgICByZXR1cm4gMAoK
CmRlZiBjbWRfZnJlZShtZW0sIGFyZ3MpOgogICAgc3QgPSBsb2FkX3N0YXRlKCkKICAgIGlmICJh
bGwiIGluIGFyZ3M6CiAgICAgICAgbXN0ID0gbG9hZF9tdXgoKQogICAgICAgIGZvciBrIGluIGxp
c3QobXN0LmtleXMoKSk6CiAgICAgICAgICAgIFBpbihtZW0sIGludChrKSkubXV4X3NldChtc3Rb
a10pCiAgICAgICAgICAgIHByaW50KCLlt7LmgaLlpI0gJXMoJWQpIGlvbXV4IC0+ICVkIiAlIChw
aW5fbmFtZShpbnQoaykpLCBpbnQoayksIG1zdFtrXSkpCiAgICAgICAgc2F2ZV9tdXgoe30pCiAg
ICAgICAgZm9yIGsgaW4gbGlzdChzdC5rZXlzKCkpOgogICAgICAgICAgICBQaW4obWVtLCBpbnQo
aykpLnJlc3RvcmUoc3Rba10pCiAgICAgICAgICAgIHByaW50KCLlt7LmgaLlpI0gJXMoJWQpIC0+
ICVzIiAlIChwaW5fbmFtZShpbnQoaykpLCBpbnQoayksIHN0W2tdKSkKICAgICAgICBzYXZlX3N0
YXRlKHt9KQogICAgICAgIHJldHVybiAwCiAgICBmb3IgYSBpbiBhcmdzOgogICAgICAgIG4gPSBp
bnQoYSkKICAgICAgICBwID0gUGluKG1lbSwgbikKICAgICAgICBpZiBzdHIobikgaW4gc3Q6CiAg
ICAgICAgICAgIHAucmVzdG9yZShzdFtzdHIobildKQogICAgICAgICAgICBwcmludCgi5bey5oqK
ICVzKCVkKSDmgaLlpI3liLAgaG9sZCDkuYvliY3vvJolcyIgJSAocGluX25hbWUobiksIG4sIHN0
W3N0cihuKV0pKQogICAgICAgICAgICBkZWwgc3Rbc3RyKG4pXQogICAgICAgICAgICBzYXZlX3N0
YXRlKHN0KQogICAgICAgIGVsc2U6CiAgICAgICAgICAgIHAuc2V0KDApCiAgICAgICAgICAgIHAu
c2V0X2RpcihGYWxzZSkKICAgICAgICAgICAgcHJpbnQoIuW3suaKiiAlcyglZCkg5pS+5byA77yI
6L6T5YWl44CB5L2O55S15bmz77yJ44CCIiAlIChwaW5fbmFtZShuKSwgbikpCiAgICByZXR1cm4g
MAoKCmRlZiBjbWRfd2FrZShtZW0sIGFyZ3MpOgogICAgIiIi5YWI57uZIFBIWSDkvb/og73ohJrv
vIjpu5jorqQgR1BJTzNfRDI9MTIy77yJ5LiK55S15bm25L+d5oyB77yM5YaN5omrIEQxL0QwIOea
hCAwfjfjgIIKICAgIOi/meadoeWRveS7pOWwseaYryJ0dGwtMjMg5Y+R546w55qE6YKj5Y+q6ISa
ICsg56uL5Yi75om+5Zyw5Z2AIueahOWQiOW5tueJiO+8jDEyMiDkvJrkuIDnm7Tkv53mjIHpq5jn
lLXlubPvvIwKICAgIOe7k+adn+WQjuWPr+S7peeUqCBtZGlvLXNjYW4gZnJlZSAxMjIg5pS+5byA
44CCIiIiCiAgICBudW1zID0gW2ludChhKSBmb3IgYSBpbiBhcmdzIGlmIGEuaXNkaWdpdCgpXQog
ICAgZW4gPSBudW1zWzBdIGlmIGxlbihudW1zKSA+PSAxIGVsc2UgMTIyCiAgICBtZGNfbnVtID0g
bnVtc1sxXSBpZiBsZW4obnVtcykgPj0gMiBlbHNlIDEyMQogICAgbWRpb19udW0gPSBudW1zWzJd
IGlmIGxlbihudW1zKSA+PSAzIGVsc2UgMTIwCiAgICBwID0gUGluKG1lbSwgZW4pCiAgICBzdCA9
IGxvYWRfc3RhdGUoKQogICAga2V5ID0gc3RyKGVuKQogICAgaWYga2V5IG5vdCBpbiBzdDoKICAg
ICAgICBzdFtrZXldID0gcC5zbmFwc2hvdCgpCiAgICAgICAgc2F2ZV9zdGF0ZShzdCkKICAgICAg
ICBwcmludCgi5L2/6IO96ISaICVzKCVkKSDljp/nirbmgIE9JXMiICUgKHBpbl9uYW1lKGVuKSwg
ZW4sIHN0W2tleV0pKQogICAgcC5tdXhfZ3BpbygpCiAgICBwLnNldCgxKQogICAgcC5zZXRfZGly
KFRydWUpCiAgICBpZiAiLS1jbGsiIGluIGFyZ3M6CiAgICAgICAgYyA9IFBpbihtZW0sIDExNykK
ICAgICAgICBtc3QgPSBsb2FkX211eCgpCiAgICAgICAgaWYgIjExNyIgbm90IGluIG1zdDoKICAg
ICAgICAgICAgbXN0WyIxMTciXSA9IGMubXV4X2dldCgpCiAgICAgICAgICAgIHNhdmVfbXV4KG1z
dCkKICAgICAgICBjLm11eF9zZXQoMikKICAgICAgICBwcmludCgiR1BJTzNfQzUoMTE3KSBpb211
eCAwIC0+IDLvvIhybWlpX2Nsa291dO+8jOe7mSBQSFkg6YCBIDUwTUh677yJ77yM5Y6f5YC8PSVk
IiAlIG1zdFsiMTE3Il0pCiAgICB0aW1lLnNsZWVwKDAuMykKICAgIHByaW50KCLlt7LmioogJXMo
JWQpIOaLiemrmO+8iFBIWSDkuIrnlLXvvInvvIznrYkgMzAwbXPvvIzlvIDlp4vmiasgJXMvJXMg
55qEIDB+NyAuLi4iICUgKAogICAgICAgIHBpbl9uYW1lKGVuKSwgZW4sIHBpbl9uYW1lKG1kY19u
dW0pLCBwaW5fbmFtZShtZGlvX251bSkpKQogICAgaGl0cyA9IFtdCiAgICBmb3IgYWRkciBpbiBy
YW5nZSg4KToKICAgICAgICBwaWQgPSBwaHlfaWQobWVtLCBtZGNfbnVtLCBtZGlvX251bSwgYWRk
cikKICAgICAgICBvayA9IGlzX3ZhbGlkKHBpZCkKICAgICAgICBwcmludCgiICBhZGRyICVkIDog
aWQ9MHglMDhYJXMiICUgKGFkZHIsIHBpZCwgIiAgPD09IOacieW6lOetlCIgaWYgb2sgZWxzZSAi
IikpCiAgICAgICAgaWYgb2s6CiAgICAgICAgICAgIGhpdHMuYXBwZW5kKChhZGRyLCBwaWQpKQog
ICAgaWYgbm90IGhpdHM6CiAgICAgICAgcHJpbnQoIue7k+aenO+8mlBIWSDlt7LkuIrnlLXkvYYg
MH43IOWFqOaXoOW6lOetlCDigJTigJQg6K+05piOIE1EQy9NRElPIOS4jeWcqCBEMS9EMO+8jCIp
CiAgICAgICAgcHJpbnQoIiAgICAgIOaOpeedgOi3kSBtZGlvLXNjYW4gc3dlZXDvvIjkvJroh6rl
iqjot7Pov4fooqsgaG9sZCDnmoTohJrvvInljrvmib7nnJ/mraPnmoQgTURDL01ESU8g6ISa5a+5
44CCIikKICAgIGVsc2U6CiAgICAgICAgcHJpbnQoIue7k+aenO+8mlBIWSDlnLDlnYAgPSAlZO+8
iGlkPTB4JTA4WO+8ieOAguS4i+S4gOatpSBtZGlvLXNjYW4gcmVncyAlZCDlpI3or7vlr4TlrZjl
majnoa7orqTjgIIiICUgKAogICAgICAgICAgICBoaXRzWzBdWzBdLCBoaXRzWzBdWzFdLCBoaXRz
WzBdWzBdKSkKICAgICAgICBwcmludCgiICAgICAgJXMoJWQpIOS/neaMgemrmOeUteW5s++8jOe7
k+adn+aXtiBtZGlvLXNjYW4gZnJlZSAlZOOAgiIgJSAoCiAgICAgICAgICAgIHBpbl9uYW1lKGVu
KSwgZW4sIGVuKSkKICAgIHJldHVybiBsZW4oaGl0cykKCgpkZWYgY21kX3Byb2JlKG1lbSwgYXJn
cyk6CiAgICAiIiLmib4iUEhZIOS+m+eUtS/kvb/og73ohJoi77ya5oyJ5L2PIDEyMiDpq5jnlLXl
ubPvvIzpgJDkuKrmiorlgJnpgInohJrmi4npq5jjgIHmi4nkvY7vvIwKICAgIOavj+S4queKtuaA
geaJq+S4gOmBjSBEMS9EMCDnmoQgMH4344CC5ZOq5Liq6ISa5LiA5ouJ5bCx5pyJ5bqU562U77yM
6YKj5Liq5bCx5piv6K6pIFBIWSDnnJ/mraPpgJrnlLXnmoTohJrjgIIiIiIKICAgIG51bXMgPSBb
aW50KGEpIGZvciBhIGluIGFyZ3MgaWYgYS5pc2RpZ2l0KCldCiAgICBlbiA9IG51bXNbMF0gaWYg
bGVuKG51bXMpID49IDEgZWxzZSAxMjIKICAgIGJhbmtzID0gcGFyc2VfYmFua3MoYXJncywgZGVm
YXVsdD0oMiwgMykpCiAgICBmb3JjZSA9ICItLWZvcmNlIiBpbiBhcmdzCiAgICBrZWVwID0gUGlu
KG1lbSwgZW4pCiAgICBzdCA9IGxvYWRfc3RhdGUoKQogICAgaWYgc3RyKGVuKSBub3QgaW4gc3Q6
CiAgICAgICAgc3Rbc3RyKGVuKV0gPSBrZWVwLnNuYXBzaG90KCkKICAgICAgICBzYXZlX3N0YXRl
KHN0KQogICAga2VlcC5tdXhfZ3BpbygpCiAgICBrZWVwLnNldCgxKQogICAga2VlcC5zZXRfZGly
KFRydWUpCiAgICB0aW1lLnNsZWVwKDAuMykKICAgIGNhbmRzID0gW3EgZm9yIHEgaW4gc2FmZV9w
aW5zKG1lbSwgYmFua3MsIGZvcmNlPWZvcmNlLCB3aXRoX21kaW89RmFsc2UpIGlmIHEgIT0gZW5d
CiAgICBwcmludCgi5bey5oyJ5L2PICVzKCVkKSDpq5jnlLXlubPvvJtiYW5rICVzIOmHjCAlZCDl
j6rlgJnpgInohJrvvIzmr4/lj6ror5Ug6auYL+S9jiDkuKTnp43vvIzlkITmiasgMH43IC4uLiIg
JSAoCiAgICAgICAgcGluX25hbWUoZW4pLCBlbiwgIiwiLmpvaW4oc3RyKGIpIGZvciBiIGluIGJh
bmtzKSwgbGVuKGNhbmRzKSkpCiAgICBwcmludCgi6aKE6K6hICVkIOenku+8jOi/m+W6puS8muS4
gOebtOWIt+aWsO+8jOWRveS4reS8muWBnOS4i+adpeaJk+WNsOOAgiIgJSAobGVuKGNhbmRzKSAq
IDIgKiAwLjMpKQogICAgaGl0cyA9IFtdCiAgICBmb3IgbiwgcSBpbiBlbnVtZXJhdGUoY2FuZHMp
OgogICAgICAgIGZvciB2YWwgaW4gKDEsIDApOgogICAgICAgICAgICBjdGwgPSBQaW4obWVtLCBx
KQogICAgICAgICAgICBvcmlnID0gY3RsLnNuYXBzaG90KCkKICAgICAgICAgICAgY3RsLm11eF9n
cGlvKCkKICAgICAgICAgICAgY3RsLnNldCh2YWwpCiAgICAgICAgICAgIGN0bC5zZXRfZGlyKFRy
dWUpCiAgICAgICAgICAgIHN5cy5zdGRvdXQud3JpdGUoIlxyICBbJWQvJWRdICVzKCVkKT0lZCAg
ICAgICIgJSAoCiAgICAgICAgICAgICAgICAobiAqIDIgKyAoMCBpZiB2YWwgZWxzZSAxKSArIDEp
LCBsZW4oY2FuZHMpICogMiwgcGluX25hbWUocSksIHEsIHZhbCkpCiAgICAgICAgICAgIHN5cy5z
dGRvdXQuZmx1c2goKQogICAgICAgICAgICB0aW1lLnNsZWVwKDAuMjUpCiAgICAgICAgICAgIGZv
ciBhZGRyIGluIHJhbmdlKDgpOgogICAgICAgICAgICAgICAgcGlkID0gcGh5X2lkKG1lbSwgMTIx
LCAxMjAsIGFkZHIpCiAgICAgICAgICAgICAgICBpZiBpc192YWxpZChwaWQpOgogICAgICAgICAg
ICAgICAgICAgIGhpdHMuYXBwZW5kKChxLCB2YWwsIGFkZHIsIHBpZCkpCiAgICAgICAgICAgICAg
ICAgICAgcHJpbnQoIiIpCiAgICAgICAgICAgICAgICAgICAgcHJpbnQoIiAg5ZG95Lit77yB5o6n
5Yi26ISaPSVzKCVkKSDmi4klcyBQSFnlnLDlnYA9JWQgaWQ9MHglMDhYIiAlICgKICAgICAgICAg
ICAgICAgICAgICAgICAgcGluX25hbWUocSksIHEsICLpq5giIGlmIHZhbCBlbHNlICLkvY4iLCBh
ZGRyLCBwaWQpKQogICAgICAgICAgICBjdGwucmVzdG9yZShvcmlnKQogICAgcHJpbnQoIiIpCiAg
ICBpZiBub3QgaGl0czoKICAgICAgICBwcmludCgi57uT5p6c77yaYmFuayAlcyDov5kgJWQg5Y+q
6ISa77yM5peg6K665ouJ6auY6L+Y5piv5ouJ5L2O77yMRDEvRDAg5LiK6YO95rKh5pyJIFBIWSDl
upTnrZTjgIIiICUgKAogICAgICAgICAgICAiLCIuam9pbihzdHIoYikgZm9yIGIgaW4gYmFua3Mp
LCBsZW4oY2FuZHMpKSkKICAgICAgICBwcmludCgiICAgICAg6K+05piOIFBIWSDkuI3lnKggRDEv
RDAg5LiK77yM5oiW6ICFIFBIWSDmoLnmnKzmsqHkvpvnlLXvvIjkuIvkuIDmraXmn6UgYmFuazAv
YmFuazEg55qE56m66Zey6ISa77yJ44CCIikKICAgIGVsc2U6CiAgICAgICAgcHJpbnQoIue7k+ae
nO+8muaJvuWIsCAlZCDlpITlupTnrZTvvIzop4HkuIrpnaLliJfooajjgIIiICUgbGVuKGhpdHMp
KQogICAgcHJpbnQoIuaUtuWwvu+8mm1kaW8tc2NhbiBmcmVlIGFsbCIpCiAgICByZXR1cm4gbGVu
KGhpdHMpCgoKZGVmIGNtZF9tdXgobWVtLCBhcmdzKToKICAgICIiIuebtOaOpeaUueafkOWPquiE
mueahCBpb211eCDlgLzvvIgwPUdQSU/vvIwxLzIvMz3or6XohJrnmoTlip/og73lj7fvvInjgILl
j6rlhYHorrggYmFuazIvYmFuazPjgIIiIiIKICAgIG51bXMgPSBbaW50KGEpIGZvciBhIGluIGFy
Z3MgaWYgYS5pc2RpZ2l0KCldCiAgICBpZiBsZW4obnVtcykgPCAyOgogICAgICAgIHByaW50KCLn
lKjms5XvvJptZGlvLXNjYW4gbXV4IDzohJrlj7c+IDzlgLw+ICAg5L6L5aaCIG1kaW8tc2NhbiBt
dXggMTE3IDIiKQogICAgICAgIHJldHVybiAxCiAgICBuLCB2YWwgPSBudW1zWzBdLCBudW1zWzFd
CiAgICBpZiBuIC8vIDMyIGluIEJMQUNLX0JBTktTIGFuZCAiLS1mb3JjZSIgbm90IGluIGFyZ3M6
CiAgICAgICAgcHJpbnQoIuaLkue7ne+8mkdQSU8lZCDmmK/pl6rlrZgvUE1JQy9lTU1DIOWMuu+8
jOS4jeWFgeiuuOaUuSBpb211eOOAgiIgJSAobiAvLyAzMikpCiAgICAgICAgcmV0dXJuIDEKICAg
IHAgPSBQaW4obWVtLCBuKQogICAgbXN0ID0gbG9hZF9tdXgoKQogICAga2V5ID0gc3RyKG4pCiAg
ICBpZiBrZXkgbm90IGluIG1zdDoKICAgICAgICBtc3Rba2V5XSA9IHAubXV4X2dldCgpCiAgICAg
ICAgc2F2ZV9tdXgobXN0KQogICAgcC5tdXhfc2V0KHZhbCkKICAgIHByaW50KCIlcyglZCkgaW9t
dXggJWQgLT4gJWTvvIjljp/lgLwgJWTvvIzlj6/nlKggbWRpby1zY2FuIGZyZWUgYWxsIOaBouWk
je+8iSIgJSAoCiAgICAgICAgcGluX25hbWUobiksIG4sIG1zdFtrZXldLCB2YWwsIG1zdFtrZXld
KSkKICAgIHJldHVybiAwCgoKZGVmIGNtZF9yZChtZW0sIGFyZ3MpOgogICAgIiIi6K+75Y2V5Liq
5a+E5a2Y5Zmo77yacmQgPHBoeT4gPHJlZz4gW21kY10gW21kaW9dIiIiCiAgICBwaHksIHJlZywg
bWRjX251bSwgbWRpb19udW0gPSBwYXJzZV9waHlfYXJncyhhcmdzLCAoMCwgMCwgMTIxLCAxMjAp
KQogICAgdiA9IHJkX3N0YWJsZShQaW4obWVtLCBtZGNfbnVtKSwgUGluKG1lbSwgbWRpb19udW0p
LCBwaHksIHJlZykKICAgIHByaW50KCJQSFklZCByZWcweCUwMlggKCVkKSA9IDB4JTA0WCIgJSAo
cGh5LCByZWcsIHJlZywgdikpCiAgICBpZiByZWcgPT0gMDoKICAgICAgICBwcmludCgiICBCTUNS
OiDoh6rljY/llYY9JXMgIOmAn+eOhz0lcyAg5Y+M5belPSVzICDph43lkK/oh6rljY/llYY9JXMi
ICUgKAogICAgICAgICAgICAi5byAIiBpZiB2ICYgMHgxMDAwIGVsc2UgIuWFsyIsCiAgICAgICAg
ICAgICIxMDBNIiBpZiB2ICYgMHgyMDAwIGVsc2UgIjEwTSIsCiAgICAgICAgICAgICLlhajlj4zl
t6UiIGlmIHYgJiAweDAxMDAgZWxzZSAi5Y2K5Y+M5belIiwKICAgICAgICAgICAgIuaYryIgaWYg
diAmIDB4MDIwMCBlbHNlICLlkKYiKSkKICAgIHJldHVybiAwCgoKZGVmIGNtZF9zZXQobWVtLCBh
cmdzKToKICAgICIiIuWGmeWNleS4quWvhOWtmOWZqO+8mnNldCA8cGh5PiA8cmVnPiA8dmFsdWU+
IFttZGNdIFttZGlvXQoKICAgIOW4uOeUqOWAvO+8iHJlZzAgPSBCTUNS77yJ77yaCiAgICAgIDB4
MjEwMCDlvLrliLYgMTAwTSDlhajlj4zlt6XjgIHlhbPpl63oh6rljY/llYYKICAgICAgMHgwMTAw
IOW8uuWItiAxME0gIOWFqOWPjOW3peOAgeWFs+mXreiHquWNj+WVhgogICAgICAweDMzMDAg6YeN
5ZCv6Ieq5Y2P5ZWG44CB6YeN6LWwIDEwME0g5YWo5Y+M5bel77yI5oGi5aSN6buY6K6k77yJCiAg
ICAiIiIKICAgIHBoeSwgcmVnLCB2YWwsIG1kY19udW0sIG1kaW9fbnVtID0gcGFyc2VfcGh5X2Fy
Z3MoYXJncywgKDAsIDAsIDAsIDEyMSwgMTIwKSkKICAgIHByaW50KCLlhpkgUEhZJWQgcmVnMHgl
MDJYICglZCkgPSAweCUwNFgiICUgKHBoeSwgcmVnLCByZWcsIHZhbCkpCiAgICBtZGMgPSBQaW4o
bWVtLCBtZGNfbnVtKQogICAgbWRpbyA9IFBpbihtZW0sIG1kaW9fbnVtKQogICAgZm9yIG4gaW4g
cmFuZ2UoMyk6CiAgICAgICAgYmJfd3JpdGUobWRjLCBtZGlvLCBwaHksIHJlZywgdmFsKQogICAg
ICAgIGJhY2sgPSByZF9zdGFibGUobWRjLCBtZGlvLCBwaHksIHJlZykKICAgICAgICBpZiBiYWNr
ID09IHZhbDoKICAgICAgICAgICAgcHJpbnQoIuWbnuivuyA9IDB4JTA0WCAgPD09IOWGmeWFpeaI
kOWKn++8iOesrCAlZCDmrKHvvIkiICUgKGJhY2ssIG4gKyAxKSkKICAgICAgICAgICAgcmV0dXJu
IDAKICAgIHByaW50KCLlm57or7sgPSAweCUwNFggIDw9PSDkuI7lhpnlhaXlgLwgMHglMDRYIOS4
jeS4gOiHtO+8jOWvhOWtmOWZqOWPr+iDveayoeWGmei/myIgJSAoYmFjaywgdmFsKSkKICAgIHJl
dHVybiAxCgoKZGVmIGNtZF9wYWdlKG1lbSwgYXJncyk6CiAgICAiIiLpgInpobXvvJpwYWdlIDxu
PiBbcGh5XSBbbWRjXSBbbWRpb10KICAgIOWvhOWtmOWZqCAzMe+8iDB4MUbvvInnmoTkvY4gOCDk
vY3lsLHmmK/pobXlnLDlnYDvvIxSVEw4MjAxRk4g5paH5qGjIFRhYmxlIDIz44CCCiAgICDpgInp
obXlkI7lho3nlKggcmQvc2V0IOiuv+mXruivpemhteeahOWvhOWtmOWZqO+8m+eUqOWujOiusOW+
lyBwYWdlIDAg5Zue5Yiw6buY6K6k6aG144CCCiAgICAiIiIKICAgIG51bXMgPSBbaW50KGEsIDAp
IGZvciBhIGluIGFyZ3MgaWYgYS5sb3dlcigpLnN0YXJ0c3dpdGgoIjB4Iikgb3IgYS5pc2RpZ2l0
KCldCiAgICBwYWdlID0gbnVtc1swXSBpZiBudW1zIGVsc2UgMAogICAgcGh5ID0gbnVtc1sxXSBp
ZiBsZW4obnVtcykgPj0gMiBlbHNlIDAKICAgIG1kY19udW0gPSBudW1zWzJdIGlmIGxlbihudW1z
KSA+PSAzIGVsc2UgMTIxCiAgICBtZGlvX251bSA9IG51bXNbM10gaWYgbGVuKG51bXMpID49IDQg
ZWxzZSAxMjAKICAgIG1kYyA9IFBpbihtZW0sIG1kY19udW0pCiAgICBtZGlvID0gUGluKG1lbSwg
bWRpb19udW0pCiAgICBiYl93cml0ZShtZGMsIG1kaW8sIHBoeSwgMHgxRiwgcGFnZSAmIDB4RkYp
CiAgICBiYWNrID0gcmRfc3RhYmxlKG1kYywgbWRpbywgcGh5LCAweDFGKQogICAgcHJpbnQoIlBI
WSVkIOmAiemhtSAtPiAlZO+8iOWbnuivuyAweCUwNFglc++8iSIgJSAoCiAgICAgICAgcGh5LCBw
YWdlLCBiYWNrLCAiIiBpZiAoYmFjayAmIDB4RkYpID09IChwYWdlICYgMHhGRikgZWxzZSAiICA8
PT0g5Zue6K+75LiN5LiA6Ie077yM6YeN6K+VIikpCiAgICByZXR1cm4gMAoKCmRlZiBjbWRfcmVn
cyhtZW0sIGFyZ3MpOgogICAgIiIi6K+75p+Q5LiqIFBIWSDlnLDlnYDnmoQgMH41IOWPt+WvhOWt
mOWZqO+8jOeUqOS6juehruiupCBQSFkg55yf55qE5rS7552A44CCIiIiCiAgICBudW1zID0gW2lu
dChhKSBmb3IgYSBpbiBhcmdzIGlmIGEuaXNkaWdpdCgpXQogICAgYWRkciA9IG51bXNbMF0gaWYg
bGVuKG51bXMpID49IDEgZWxzZSAwCiAgICBtZGNfbnVtID0gbnVtc1sxXSBpZiBsZW4obnVtcykg
Pj0gMiBlbHNlIDEyMQogICAgbWRpb19udW0gPSBudW1zWzJdIGlmIGxlbihudW1zKSA+PSAzIGVs
c2UgMTIwCiAgICBuYW1lcyA9IFsiQk1DUiIsICJCTVNSIiwgIlBIWUlEMSIsICJQSFlJRDIiLCAi
QU5BUiIsICJBTkxQQVIiXQogICAgcHJpbnQoIuivuyAlcy8lcyDkuIogUEhZIOWcsOWdgCAlZCDn
moTlr4TlrZjlmajvvJoiICUgKAogICAgICAgIHBpbl9uYW1lKG1kY19udW0pLCBwaW5fbmFtZSht
ZGlvX251bSksIGFkZHIpKQogICAgdmFscyA9IFtdCiAgICBtZGNfcCA9IFBpbihtZW0sIG1kY19u
dW0pCiAgICBtZGlvX3AgPSBQaW4obWVtLCBtZGlvX251bSkKICAgIGZvciByIGluIHJhbmdlKDYp
OgogICAgICAgIHYgPSByZF9zdGFibGUobWRjX3AsIG1kaW9fcCwgYWRkciwgcikKICAgICAgICB2
YWxzLmFwcGVuZCh2KQogICAgICAgIHByaW50KCIgIHJlZyVkICUtN3MgPSAweCUwNFgiICUgKHIs
IG5hbWVzW3JdLCB2KSkKICAgIHBpZCA9ICh2YWxzWzJdIDw8IDE2KSB8IHZhbHNbM10KICAgIHBy
aW50KCIgIFBIWSBJRCA9IDB4JTA4WCVzIiAlIChwaWQsICIgIDw9PSDmnInmlYgiIGlmIGlzX3Zh
bGlkKHBpZCkgZWxzZSAiICA8PT0g5peg5pWIL+aXoOW6lOetlCIpKQogICAgaWYgaXNfdmFsaWQo
cGlkKToKICAgICAgICBwcmludCgiICBPVUk9MHglMDZYICDlnovlj7c9MHglMDNYICDniYjmnKw9
JWQiICUgKAogICAgICAgICAgICAocGlkID4+IDEwKSAmIDB4RkZGRkZGLCAocGlkID4+IDQpICYg
MHgzRiwgcGlkICYgMHhGKSkKICAgICAgICBpZiAocGlkID4+IDEwKSAmIDB4RkZGRkZGID09IDB4
MDAxQ0MwOgogICAgICAgICAgICBwcmludCgiICBPVUkgMHgwMDFDQzAgPSBSZWFsdGVr77yM5LiO
5L2g5p2/5LiK55qEIFJUTDgyMDFGTiDlkLvlkIgiKQogICAgYm1zciA9IHZhbHNbMV0KICAgIGlm
IGlzX3ZhbGlkKHBpZCk6CiAgICAgICAgcHJpbnQoIiAgQk1TUjog6ZO+6LevPSVzIOiHquWNj+WV
huWujOaIkD0lcyAxME09JXMgMTAwTT0lcyIgJSAoCiAgICAgICAgICAgICJ1cCIgaWYgYm1zciAm
IDB4MDAwNCBlbHNlICJkb3duIiwKICAgICAgICAgICAgIuaYryIgaWYgYm1zciAmIDB4MDAyMCBl
bHNlICLlkKYiLAogICAgICAgICAgICAi5pSv5oyBIiBpZiBibXNyICYgMHgwODAwIGVsc2UgIuS4
jeaUr+aMgSIsCiAgICAgICAgICAgICLmlK/mjIEiIGlmIGJtc3IgJiAweDEwMDAgZWxzZSAi5LiN
5pSv5oyBIikpCiAgICByZXR1cm4gMAoKCmRlZiBjbWRfZHVtcChtZW0sIGFyZ3MpOgogICAgZm9y
IGIsIGJhc2UgaW4gZW51bWVyYXRlKEdQSU9fQkFTRSk6CiAgICAgICAgcHJpbnQoIkdQSU8lZCBi
YXNlPTB4JTA4WCBEUj0weCUwOFggRERSPTB4JTA4WCBFWFQ9MHglMDhYIiAlICgKICAgICAgICAg
ICAgYiwgYmFzZSwKICAgICAgICAgICAgbWVtLnJkKGJhc2UgKyBSRUdfRFIpLCBtZW0ucmQoYmFz
ZSArIFJFR19ERFIpLCBtZW0ucmQoYmFzZSArIFJFR19FWFQpKSkKICAgIHJldHVybiAwCgoKQ01E
UyA9IHsKICAgICJwaW4iOiBjbWRfcGluLAogICAgInNhZmUiOiBjbWRfc2FmZSwKICAgICJzY2Fu
IjogY21kX3NjYW4sCiAgICAic3dlZXAiOiBjbWRfc3dlZXAsCiAgICAiY3RsIjogY21kX2N0bCwK
ICAgICJob2xkIjogY21kX2hvbGQsCiAgICAiZnJlZSI6IGNtZF9mcmVlLAogICAgIndha2UiOiBj
bWRfd2FrZSwKICAgICJtdXgiOiBjbWRfbXV4LAogICAgInByb2JlIjogY21kX3Byb2JlLAogICAg
InJlZ3MiOiBjbWRfcmVncywKICAgICJyZCI6IGNtZF9yZCwKICAgICJzZXQiOiBjbWRfc2V0LAog
ICAgInBhZ2UiOiBjbWRfcGFnZSwKICAgICJkdW1wIjogY21kX2R1bXAsCn0KCgpkZWYgbWFpbigp
OgogICAgaWYgbGVuKHN5cy5hcmd2KSA8IDIgb3Igc3lzLmFyZ3ZbMV0gbm90IGluIENNRFM6CiAg
ICAgICAgcHJpbnQoX19kb2NfXyBvciAiIikKICAgICAgICBwcmludCgi5Y+v55So5ZG95Luk77ya
IiArICIgLyAiLmpvaW4oc29ydGVkKENNRFMpKSkKICAgICAgICByZXR1cm4gMgogICAgbWVtID0g
TWVtKCkKICAgIHIgPSBDTURTW3N5cy5hcmd2WzFdXShtZW0sIHN5cy5hcmd2WzI6XSkKICAgIGlm
IHIgaXMgTm9uZToKICAgICAgICByZXR1cm4gMAogICAgcmV0dXJuIDAgaWYgciA+PSAwIGVsc2Ug
MQoKCmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICBzeXMuZXhpdChtYWluKCkpCg==
MDIOSCAN_B64
chmod 755 /usr/local/bin/mdio-scan
if [ ! -x /usr/bin/python3 ] && [ ! -x /usr/local/bin/python3 ]; then
    echo "⚠️  rootfs 里没有 python3，mdio-scan 无法运行"
else
    echo "✅ 已安装 /usr/local/bin/mdio-scan（python3 版 MDIO 引脚探测工具）"
fi
