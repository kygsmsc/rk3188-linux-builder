#!/bin/bash
# lib/rootfs_inner.sh — 在 chroot 内执行的系统配置脚本
# 兼容 Ubuntu 20.04 (focal) / 22.04 (jammy) / 24.04 (noble)
#
# 关键修复：
#   [P1]  firstboot-password 正向判据 /etc/firstboot-pwd.txt
#   [P2]  WantedBy=multi-user.target + After=local-fs.target + Before=ssh.service
#   [P3]  chpasswd 失败保留密码文件重试
#   [P4]  printf + cat 管道读取密码（避开 bash 内建 $PWD）
#   [P5]  移除 modules-load.d（4.4 内核模块全内建）
#   [P6]  system.conf.d/99-old-kernel.conf 消除 hidepid 警告
#   [P7]  保留 apt lists + 99-no-translations（省 ~15MB，可直接 apt install）
#   [P8]  A 级精简 consolefonts/keymaps/hwdb.bin（省 ~17MB）
#   [P9]  精简不做 apt 操作（避免打断 systemd enable）
#   [P10] eth0 由 NetworkManager 管理（ifupdown 只处理 lo）
#   [P11] 删除 Ubuntu 默认 10-globally-managed-devices.conf（排除 eth0 的元凶）
#   [P12] 预装 iptables 并切换到 legacy 后端（解决 Docker 在 4.4 内核启动失败）
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C LANG=C
export SYSTEMD_OFFLINE=1

echo "==> [${MODE} 模式] 挂载 tmpfs"
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

CODENAME="${UBUNTU_CODENAME:-focal}"
echo "==> Ubuntu 代号: $CODENAME"
echo "==> 软件源: $MIRROR"

# ========== APT 源格式 ==========
if [ "$CODENAME" = "noble" ]; then
    echo "==> DEB822 格式软件源 (24.04+)"
    mkdir -p /etc/apt/sources.list.d
    cat > /etc/apt/sources.list.d/ubuntu.sources << SOURCES
Types: deb
URIs: $MIRROR
Suites: $CODENAME $CODENAME-updates $CODENAME-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: $MIRROR
Suites: $CODENAME-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
SOURCES
    > /etc/apt/sources.list
else
    echo "==> 传统格式软件源 (20.04 / 22.04)"
    cat > /etc/apt/sources.list << SOURCES
deb $MIRROR $CODENAME main restricted universe multiverse
deb $MIRROR $CODENAME-updates main restricted universe multiverse
deb $MIRROR $CODENAME-security main restricted universe multiverse
deb $MIRROR $CODENAME-backports main restricted universe multiverse
SOURCES
fi

apt-get update -qq
apt-get -f install -y -qq 2>&1 || true

# ============================================================
# 核心软件包
#   含 WiFi 依赖：file / network-manager / wpasupplicant / iw / rfkill
#   含 iptables：预装以便 Docker 兼容性处理（P12）
# ============================================================
echo "==> 安装核心软件包"
apt-get install -y -qq --no-install-recommends \
  systemd systemd-sysv systemd-timesyncd dbus udev \
  ifupdown isc-dhcp-client iproute2 net-tools iputils-ping iputils-arping ethtool procps \
  openssh-server ssh sudo \
  e2fsprogs ca-certificates \
  vim-tiny less htop wget curl cron rsyslog bash-completion \
  locales tzdata \
  file network-manager wpasupplicant iw rfkill \
  iptables

# ============================================================
# 【P12】iptables 切换到 legacy 后端
#   原因：4.4 内核与 iptables-nft 后端兼容性差（缺 addrtype match）
#   Docker 启动时无法添加 NAT 规则，报 Couldn't load match 'addrtype'
#   本段确保预装 iptables 后立即切换到 legacy
# ============================================================
echo "==> 配置 iptables 使用 legacy 后端（兼容旧内核的 Docker）"
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
  util-linux usbutils \
  dosfstools ntfs-3g exfat-fuse eject

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
ACTION="$1"
DEV="$2"
DEV_PATH="/dev/$DEV"
MOUNT_POINT="/media/$DEV"

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
    esac
    ;;
  remove)
    umount "$MOUNT_POINT" 2>/dev/null || umount -l "$MOUNT_POINT" 2>/dev/null || true
    rmdir "$MOUNT_POINT" 2>/dev/null || true
    ;;
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

# ========== root 密码 ==========
echo "==> 设置 root 密码（长度 ${#ROOT_PASSWORD} 字符）"
echo "root:$ROOT_PASSWORD" | chpasswd
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config

# ========== firstboot-password（正向判据防弹版） ==========
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
echo "✅ firstboot-password.service 已启用"

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
echo "✅ firstboot-apt-update.service 已启用"

# ============================================================
# 【P10/P11】网络：eth0 + wlan0 全由 NetworkManager 管理
# ============================================================
echo "==> 网络配置（eth0 + wlan0 全部由 NetworkManager 管理）"

rm -f /etc/network/interfaces.d/eth0
mkdir -p /etc/network/interfaces.d

cat > /etc/network/interfaces << 'NETIF'
# Loopback
auto lo
iface lo inet loopback

# eth0 / wlan0 全部由 NetworkManager 管理
# 禁止在此文件或 interfaces.d 下配置 eth0，否则 NM 会忽略 eth0
NETIF

# 【P11】删除 Ubuntu 默认 unmanaged-devices 配置（排除 eth0 的元凶）
rm -f /usr/lib/NetworkManager/conf.d/10-globally-managed-devices.conf

mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/10-globally-managed-devices.conf << 'NMOVERRIDE'
# 覆盖 Ubuntu Server/Base 默认配置
# 默认: unmanaged-devices=*,except:type:wifi,except:type:gsm,except:type:cdma
# 会排除所有 ethernet 设备（eth0），本文件将其清空
[keyfile]
unmanaged-devices=
NMOVERRIDE

cat > /etc/NetworkManager/conf.d/99-hinas.conf << 'NMCONF'
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
  echo "==> 自定义 eth0 MAC（NM cloned-mac-address）: $CUSTOM_MAC"
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
echo "✅ eth0 由 NetworkManager 管理（DHCP）"

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
      echo "❌ localedef 也失败，检查 /usr/share/i18n/locales/"
      ls -la /usr/share/i18n/locales/ 2>&1 | head -10
      exit 1
    fi
  fi
  echo "  ✅ $_loc -> $_dir"
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
echo "✅ locale 生成完成"

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
systemctl enable ssh networking systemd-timesyncd systemd-resolved 2>/dev/null || true
systemctl enable NetworkManager NetworkManager-dispatcher 2>/dev/null || true
systemctl mask motd-news.timer motd-news.service 2>/dev/null || true
systemctl mask apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl mask dpkg-db-backup.timer 2>/dev/null || true
systemctl mask networkd-dispatcher 2>/dev/null || true
systemctl set-default multi-user.target 2>/dev/null || true

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
    echo "==> systemd $SYSTEMD_VER >= 247，写入 logind + system 兼容配置"
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
else
    echo "==> systemd ${SYSTEMD_VER:-未知} < 247，跳过 logind 兼容配置"
fi

mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/99-dns.conf << 'DNS'
[Resolve]
DNS=223.5.5.5 223.6.6.6
FallbackDNS=119.29.29.29 1.1.1.1
DNSStubListener=yes
DNS

cat > /root/.bashrc << 'BASHRC'
[ -f /etc/bash.bashrc ] && . /etc/bash.bashrc
[ -f /etc/bash_completion ] && . /etc/bash_completion
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '
BASHRC

cat > /etc/resolv.conf << 'RESOLV'
nameserver 223.5.5.5
nameserver 223.6.6.6
RESOLV

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

# ========== A 级精简（零影响） ==========
echo "==> 精简 A 级（零影响）"
rm -rf /usr/share/consolefonts 2>/dev/null || true
rm -rf /usr/share/keymaps 2>/dev/null || true
rm -f /etc/udev/hwdb.bin 2>/dev/null || true
echo "  ✅ 已移除 consolefonts / keymaps / hwdb.bin（~17MB）"

if [ "${MINIMAL_MODE:-no}" = "yes" ]; then
    echo "==> 精简 B 级（纯文件删除）"
    rm -rf /usr/bin/htop 2>/dev/null || true
    rm -rf /usr/share/bash-completion 2>/dev/null || true
    echo "  ✅ 已移除 htop / bash-completion（~4MB）"
fi

# 精简后重新 enable（保证 systemd 符号链接存在）
echo "==> 重新 enable 服务"
systemctl enable firstboot-password.service 2>/dev/null || true
systemctl enable firstboot-apt-update.service 2>/dev/null || true
systemctl enable ssh networking NetworkManager systemd-timesyncd systemd-resolved 2>/dev/null || true
systemctl enable rfkill-unblock-wifi.service 2>/dev/null || true

# ========== 防御性清理 ==========
find /root -mindepth 1 -maxdepth 1 \
    ! -name '.bashrc' ! -name '.profile' ! -name '.bash_logout' \
    ! -name '.cache' ! -name '.local' \
    -exec rm -rf {} + 2>/dev/null || true
find /tmp  -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
find /home -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
rm -rf /root/work /root/original_usb /root/tmp 2>/dev/null || true
for f in /mv100*.zip /www_raw.ext4 /backup-32.gz /sdat2img.py \
         /simg2img.py /sparse_info.py /p9-rootfs.img /p8-backup.img; do
  rm -f "$f" 2>/dev/null || true
done

# ============================================================
# 审计
# ============================================================
echo "========== rootfs 审计 =========="
echo "--- Ubuntu 代号 ---"
echo "$CODENAME"

echo "--- APT 源 ---"
if [ "$CODENAME" = "noble" ]; then
    cat /etc/apt/sources.list.d/ubuntu.sources
else
    cat /etc/apt/sources.list
fi

echo "--- APT lists（应非空）---"
du -sh /var/lib/apt/lists/ 2>/dev/null || echo "(MISSING!)"

echo "--- /root ---"
ls -la /root/
echo "--- /tmp ---"
ls -la /tmp/ 2>/dev/null || echo "(empty)"
echo "--- /home ---"
ls -la /home/
echo "--- locale 数据 ---"
ls /usr/lib/locale/ 2>/dev/null
echo "--- WiFi / NM 命令检查 ---"
for c in file nmtui nmtui-connect nmcli iw rfkill wpa_supplicant; do
  printf '  %-18s ' "$c"
  command -v "$c" 2>/dev/null || echo "(MISSING!)"
done

# ============================================================
# 【P12】iptables 后端检查
# ============================================================
echo "--- iptables 后端检查（Docker 兼容性关键）---"
echo -n "  iptables-legacy 存在: "
if [ -x /usr/sbin/iptables-legacy ]; then
    echo "✅ 存在"
else
    echo "❌ 缺失（Docker 在老内核上会启动失败）"
    exit 1
fi
echo -n "  iptables 当前后端: "
IPT_VER=$(iptables --version 2>/dev/null || echo "未安装")
echo "$IPT_VER"
case "$IPT_VER" in
  *legacy*) echo "  ✅ 已切换到 legacy 后端" ;;
  *nf_tables*) echo "  ❌ 仍为 nf_tables 后端（Docker 会失败）"; exit 1 ;;
  *) echo "  ⚠️ 无法识别后端" ;;
esac

# ============================================================
# 【P11】网络管理检查（eth0 → NM）
# ============================================================
echo "--- 网络管理检查（eth0 → NM）---"
echo -n "  /etc/network/interfaces.d/eth0: "
if [ -f /etc/network/interfaces.d/eth0 ]; then
    echo "❌ 存在（ifupdown 会抢占 eth0）"
    exit 1
else
    echo "✅ 不存在"
fi

echo -n "  /usr/lib/NetworkManager/conf.d/10-globally-managed-devices.conf: "
if [ -f /usr/lib/NetworkManager/conf.d/10-globally-managed-devices.conf ]; then
    echo "❌ 存在（Ubuntu 默认排除 eth0，本应删除）"
    exit 1
else
    echo "✅ 已删除"
fi

echo -n "  /etc/NetworkManager/conf.d/10-globally-managed-devices.conf: "
if [ -f /etc/NetworkManager/conf.d/10-globally-managed-devices.conf ]; then
    if grep -q '^unmanaged-devices=$' /etc/NetworkManager/conf.d/10-globally-managed-devices.conf; then
        echo "✅ 存在且正确覆盖"
    else
        echo "❌ 存在但内容不正确"
        exit 1
    fi
else
    echo "❌ 缺失"
    exit 1
fi

echo -n "  /etc/NetworkManager/system-connections/eth0.nmconnection: "
if [ -f /etc/NetworkManager/system-connections/eth0.nmconnection ]; then
    PERM=$(stat -c '%a %U:%G' /etc/NetworkManager/system-connections/eth0.nmconnection)
    if [ "$PERM" = "600 root:root" ]; then
        echo "✅ 存在且权限正确 (600 root:root)"
    else
        echo "❌ 权限异常: $PERM"
        exit 1
    fi
else
    echo "❌ 缺失"
    exit 1
fi

# ============================================================
# firstboot-password 检查
# ============================================================
echo "--- firstboot-password 检查（关键）---"
echo -n "  /etc/firstboot-pwd.txt: "
if [ -f /etc/firstboot-pwd.txt ]; then
    echo "存在 (size=$(stat -c%s /etc/firstboot-pwd.txt) bytes)"
else
    echo "❌ 缺失！首次启动不会重置密码"
    exit 1
fi
echo -n "  /usr/local/sbin/firstboot-password.sh: "
if [ -x /usr/local/sbin/firstboot-password.sh ]; then
    echo "存在且可执行"
else
    echo "❌ 缺失或不可执行"
    exit 1
fi
echo -n "  systemd enable: "
systemctl is-enabled firstboot-password.service 2>/dev/null || { echo "❌ 未 enable"; exit 1; }
echo "  service 的 ConditionPathExists:"
grep '^ConditionPathExists' /etc/systemd/system/firstboot-password.service
if grep -q '^ConditionPathExists=!' /etc/systemd/system/firstboot-password.service; then
    echo "  ❌ 检测到反向判据（!）"
    exit 1
fi

echo "--- /etc/shadow 中 root 行（前 40 字符）---"
grep '^root:' /etc/shadow | cut -c1-40
if ! grep -q '^root:\$' /etc/shadow; then
    echo "  ❌ shadow 中 root 行结构异常"
    exit 1
fi

echo "--- shadow/passwd 权限 ---"
stat -c '    %A %U:%G %n' /etc/passwd /etc/shadow /etc/group /etc/gshadow

echo "--- 精简 A 级验证（应全部不存在）---"
for p in /usr/share/consolefonts /usr/share/keymaps /etc/udev/hwdb.bin; do
  if [ -e "$p" ]; then
    echo "  ⚠️  $p 仍存在"
  else
    echo "  ✅ $p 已清除"
  fi
done

echo "--- SSH 主机密钥 comment ---"
for k in /etc/ssh/ssh_host_*_key.pub; do
  [ -f "$k" ] && ssh-keygen -lf "$k" 2>/dev/null
done

echo "--- rootfs 总计 ---"
du -sh --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run --exclude=/tmp / 2>/dev/null | awk '{print "  " $1 "  总计"}' || true

echo "========== 审计结束 =========="
echo "✅ Chroot 内配置完成"
