# RK3188 杂牌盒子 Ubuntu 22.04 编译项目

本项目使用 GitHub Actions 自动从 kernel.org 下载 Linux 6.12.116 内核，结合定制的 `rk3188-adesk-std.dts` 设备树，以及 Ubuntu 22.04 (armhf) 根文件系统，打包生成瑞芯微刷机工具（RKDevTool）所需的镜像。

## 如何使用

1. **Fork 或新建仓库**：将这三个文件推送到你的 GitHub 仓库。
2. **运行构建**：点击仓库顶部的 `Actions` 标签页 -> 选择左侧的 `Build RK3188 Linux Boot & Rootfs` -> 点击右侧的 `Run workflow`。
3. **下载文件**：等待约 20 分钟构建完成。在对应的运行记录底部，找到 `Artifacts`，下载 `rk3188-linux-flash-package`。
4. **解压**，你会得到：
   - `boot.img` (已包含 DTB)
   - `rootfs.img` (Ubuntu 22.04 系统，大小 2GB)
   - `parameter.txt` (4G eMMC 最简分区表)
5. **刷机**：使用瑞芯微开发工具（RKDevTool），按要求分别选择 `Loader` (你的原厂 loader)、`parameter.txt`、`boot.img`、`rootfs.img`，勾选并执行即可。

## 默认配置

- **串口调试**：`ttyS0` 波特率 `115200`
- **登录账号**：`root` / `root`
- **网络**：DHCP 自动获取（网口 `eth0`）
- **SSH**：默认开启
