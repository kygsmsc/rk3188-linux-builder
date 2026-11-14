#!/bin/bash
# lib/rootfs_inner.sh — 在 chroot 内执行的系统配置脚本
# 兼容 Ubuntu 20.04 (focal) / 22.04 (jammy) / 24.04 (noble)
#
# 移植自 hi3798 项目，针对 rk3188 + Linux 6.12 适配：
#   [P1]  firstboot-password 正向判据 /etc/firstboot-pwd.txt
#   [P2]  WantedBy=multi-user.target + After=local-fs.target + Before=ssh.service
#   [P3]  chpasswd 失败保留密码文件重试
#   [P4]  printf + cat 管道读取密码
#   [P5]  ❌ 已删除（6.12 有 =m 模块，modules-load.d 必须保留）
#   [P6]  system.conf.d/99-old-kernel.conf 消除 hidepid 警告
#   [P7]  保留 apt lists + 99-no-translations
#   [P8]  A 级精简 consolefonts/keymaps/hwdb.bin
#   [P9]  精简不做 apt 操作
#   [P10] eth0 由 NetworkManager 管理
#   [P11] 删除 Ubuntu 默认 10-globally-managed-devices.conf
#   [P12] 预装 iptables 并切换 legacy 后端
#   [R1]  enable serial-getty@ttyS2（rk3188 console=ttyS2）
#   [R2]  /etc/fstab 用 LABEL=rootfs 兜底
#   [R3]  depmod -a（模块索引，6.12 必做）
#   [R4]  MINIMAL_MODE=yes 时 C 级精简（rsyslog/net-tools/ethtool）
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
Acquire::IndexTargets::deb::DEP-
