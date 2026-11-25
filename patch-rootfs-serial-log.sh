#!/bin/bash
# =====================================================================
# patch-rootfs-serial-log.sh —— 把 systemd 的日志强制打到串口（永久生效）
#
# 为什么需要：ttl-rz11 的日志在 "Hostname set to <rk3188>" 之后突然全静默。
#   systemd 早期用 kmsg 打日志（能看到 systemd[1]: 那些行），一旦 journald
#   起来，日志就改投 journal（写内存/磁盘），串口上自然就没声音了；
#   "[  OK  ]" 那种状态行还要求 show_status 打开。于是"卡住"和"只是不显示"
#   在串口上长得一模一样，没法区分。
#
# 这个补丁改的是 rootfs 内部配置，不依赖内核 CMDLINE（loader 会截断 CMDLINE，
# 所以走 CMDLINE 的路子不可靠），重建一次 rootfs 之后永久有效。
#
# 用法：把下面【内核片段】整段粘到 rootfs_inner.sh 里
#       systemctl enable serial-getty@ttyS2.service 那一行之后（chroot 内执行）。
# =====================================================================

# ------------------------- 【内核片段】开始 -------------------------
mkdir -p /etc/systemd/system.conf.d /etc/systemd/journald.conf.d

# 1) PID1 的日志同时写一份到 console（= /dev/console = 串口 ttyS2）
cat > /etc/systemd/system.conf.d/99-serial-log.conf << 'SYSLOG'
[Manager]
LogTarget=console
LogLevel=info
ShowStatus=yes
SYSLOG

# 2) journald 也转发一份到 kmsg，避免日志只进内存就"消失"
cat > /etc/systemd/journald.conf.d/99-serial-log.conf << 'JLOG'
[Journal]
ForwardToKMsg=yes
Storage=volatile
JLOG

# 3) 内置的 getty 也保证在 ttyS2 上（双保险，systemctl enable 已做一次）
mkdir -p /etc/systemd/system/getty.target.wants 2>/dev/null || true
ln -sf /lib/systemd/system/serial-getty@.service \
       /etc/systemd/system/getty.target.wants/serial-getty@ttyS2.service 2>/dev/null || true
# ------------------------- 【内核片段】结束 -------------------------
