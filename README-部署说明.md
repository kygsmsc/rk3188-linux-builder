# 修复文件部署说明（串口 ttyS2 / UART2，MMIO 0x20064000）

## 一、仓库目录结构（按脚本里的实际引用路径摆放）

```
你的 GitHub 仓库/
├── build.yml                  ← 用 fix/build.yml 整体替换
├── parameter.txt              ← 新增，放仓库根目录（fix/parameter.txt）
├── build_rootfs.sh            ← 原附件 build_rootfs.sh.txt 改名
├── configs/
│   └── rk3188_defconfig       ← 新增（Armbian rk3188 配置，作为 3188_defconfig）
├── lib/
│   ├── common.sh              ← 原附件 common.sh.txt 改名
│   ├── rootfs_inner.sh         ← 原附件 rootfs_inner.sh.txt 改名
│   └── mkkrnlimg.c            ← 已弃用，仅备查（workflow 不再调用）
├── dts/
│   └── rk3188-adesk-std.dts    ← 原附件 rk3188-adesk-std.dts.txt 改名放入
└── tools/
    └── inspect_rk_img.sh       ← 新增（镜像格式体检/对比脚本，仅 bash+python3）
```

> `build_rootfs.sh` 通过 `source "$SCRIPT_DIR/lib/common.sh"` 找 lib；
> `common.sh` 通过 `$LIB_DIR/rootfs_inner.sh` 找内部脚本，所以这两个 sh 都在 `lib/`。

## 二、本次需要替换 / 新增的文件

| 文件 | 处理方式 | 说明 |
|---|---|---|
| `build.yml` | **整体替换** | 步骤 7 用仓库 `configs/rk3188_defconfig`；步骤 8 用 Rockchip mkbootimg 打 Android boot image；产物附带未封装 zImage/zImage-dtb |
| `configs/rk3188_defconfig` | **新增到 `configs/`** | Armbian rk3188 调过的内核配置（定时器/时钟/GRF/RK808 PMIC/eMMC/以太网/DWC2 全套）；workflow 拷贝为 `arch/arm/configs/rk3188_defconfig` 后 `make rk3188_defconfig`，olddefconfig 适配 6.12 |
| `parameter.txt` | **新增到仓库根** | cmdline `root=/dev/mmcblk1p1` + `blkdevparts=mmcblk1:-@28M(rootfs)`（实测落点）+ `-@0x0000C000(rootfs)`（工具标称，工具会再+4MiB），console=`ttyS2`；mtdparts（烧写布局）与 dwc_driver 保留（loader/刷机工具需要，主线内核忽略） |
| `lib/mkkrnlimg.c` | **已弃用，仅备查** | KRNL tag 封装不被老 SDK loader 接受；workflow 改用 mkbootimg，此文件不再调用 |
| `tools/inspect_rk_img.sh` | **新增** | 对比原厂镜像与产物头结构，判断封装格式（详见诊断报告第四节） |

## 三、串口：ttyS2（UART2，MMIO 0x20064000）

实机 TTL 日志证据：earlycon 地址 `0x20064000`（= uart2），8250 probe 的 `0x10124000`（= uart0）；TTL 接在 uart2。设备树与 cmdline 三处对齐到 ttyS2：

- `aliases { serial2 = &uart2; }`（dtsi 默认 serial2→uart2，已显式列出）✓
- `chosen { stdout-path="serial2:..."；bootargs="console=ttyS2,115200 ..." }` ✓
- `&uart2 { status = "okay"; }` ✓

与 `parameter.txt` 的 `console=ttyS2,115200` 一致。（早期误改成 ttyS0/uart0，会导致 console 切到未接线的 uart0、后续日志全部丢失，表现为"切换后假死"。）

## 四、本次修复点对照（对照编译教程 + Armbian rk3188 config 复核）

1. **boot.img 打包格式**（致命）：教程用 Rockchip mkbootimg 打 **Android boot image**（`ANDROID!` header，kernel_addr=0x60408000）；项目原来自写 KRNL tag 封装，老 SDK loader 按 Android boot header 解析会错位，卡在加载阶段。步骤 8 已改为 clone `neo-technologies/rockchip-mkbootimg` 编译并调用 `mkbootimg --kernel zImage-dtb -o boot.img`。
2. **内核配置**（重要）：教程直接用 Armbian rk3188 config 作为 defconfig。项目原来用 `multi_v7_defconfig` + 零散补项，缺定时器、时钟、GRF、RK808 PMIC MFD、IOMMU、DWC2、以太网等。步骤 7 已改为把 `configs/rk3188_defconfig` 拷为 `arch/arm/configs/rk3188_defconfig`，`make rk3188_defconfig` 后 `olddefconfig` 适配 6.12；再显式锁定 APPENDED_DTB / ATAG_COMPAT / EARLYCON / FROM_BOOTLOADER。
3. **dtb 编译不再吞错**：去掉 `2>/dev/null || true`，DTS 报错会让 CI 直接失败；找不到本机 dtb 直接退出，不再回退到别的板子的 dtb。
4. **根分区挂载**（第五轮修正 / 第八轮把起点改为 24MiB）：eMMC 上**根本没有分区表**（老 SDK 按 parameter 绝对扇区裸写，扇区 0 就是 loader，没有 MBR/GPT；第五轮日志 `unknown-block(179,1)` + 分区列表只有整盘即为此证）。因此"擦 MBR 让 loader 重建分区表"不成立，改由内核自己建分区：cmdline 加 `blkdevparts=mmcblk1:-@24M(rootfs)`（6.12 `block/partitions/cmdline.c`，源码注释原文即"for fixed block (eMMC) embedded devices. It has no MBR"），在 mmcblk1 上从 28MiB 到盘尾建 1 个 rootfs 分区，即 `/dev/mmcblk1p1`。只建 rootfs 一个分区（不建 boot），分区号天然是 p1，`root=` 无需改成 p2。依赖 `CONFIG_PARTITION_ADVANCED=y` + `CONFIG_CMDLINE_PARTITION=y`，步骤 6 已强制校验并在产物里附 `kernel.config`。
5. **dtb 选择**：按型号精确匹配 `dtb_out/*rk3188*.dtb`。

## 五、刷机后看串口的判断标准

对照同一代 RK3188 loader 的成功日志，正常顺序是：

```
start_linux=====28658
4419477 Starting kernel...@0x60408000   ← 跳转前这一行必须出现
[ 0.000000] Booting Linux on physical CPU ...
```

- `start_linux` 之后出现 `Starting kernel...@0x60408000` → loader 已完成加载；再出现 `Booting Linux on physical CPU` 即封装问题已解决。
- **只到 `start_linux=====...`、没有 `Starting kernel...` 这一行** → 卡在 loader 解析头/拷贝内核阶段：先用 `tools/inspect_rk_img.sh` 对比原厂镜像头格式（诊断报告第四节），对齐封装格式。
- 有 `Starting kernel...` 但仍无内核日志 → loader(ATAG) 与主线内核(DTB) 跨代兼容问题，可打开 `build.yml` 步骤 7 的 DEBUG_LL 注释块观察解压输出，最终方案是换 mainline U-Boot。
- 内核日志正常但最后报 `unknown-block(179,x)` / 找不到根分区 → eMMC 无标准分区表，且 cmdline 里没有 `blkdevparts`（或内核没编 `CONFIG_CMDLINE_PARTITION`）。正确表现是先打印 `mmcblk1: p1`，再 `EXT4-fs (mmcblk1p1): mounted filesystem`（详见诊断报告第十节、第十三节）。

## 六、本地体检产物镜像

```bash
chmod +x tools/inspect_rk_img.sh
tools/inspect_rk_img.sh 原厂_kernel.img 产物/boot.img 产物/unpacked/zImage-dtb
```

脚本输出每个镜像的 magic、size 字段、CRC 位置、fdt 偏移与头尾 hexdump，用于判断 loader 期望的
封装格式（Android boot.img / KRNL 封装 / 老 SDK 2KB 头）。

## 七、备查：旧 KRNL 封装器（已弃用，workflow 不调用）

`lib/mkkrnlimg.c` 仅留作格式对照；boot.img 由步骤 8 的 Rockchip mkbootimg 打包。
如需本地编译备查：

```bash
gcc lib/mkkrnlimg.c -o mkkrnlimg
# ./mkkrnlimg zImage-dtb boot.img   # 旧 KRNL 格式，本项目不再使用
```

旧格式结构：`tag(4) + size(4) + 内核内容 + CRC(4)`，CRC 为标准 zlib/u-boot CRC32。

---

## 第八轮结论（ttl-rz8 救援 init 实测）

救援 init 用 `dd` 逐偏移读 ext4 超级块，唯一命中在 **24MiB（25165824 字节）**：

```
25165824 字节 (= 24 MiB) : ext4 ✅ 卷标=[rootfs]
20971520 字节 (= 20 MiB) : 无 ext4 (magic=0000)   ← 前 64 字节是 "ANDROID!"（残留 boot.img 头）
```

`losetup -o 25165824 /dev/loop0 /dev/mmcblk1` + `mount -t ext4` 成功挂载，
`df -h` 显示 973.4M 总容量 / 288.8M 已用，与 CI 打印的 `rootfs 实际 289MB` 吻合
→ **盘上那份就是本包的 rootfs.img，且内容完整**。

由此确定：前七轮 "No filesystem could mount root, tried: ext4" 的根因不是镜像、
不是 DTS、也不是分区表机制，而是 **工具把 rootfs 写在了 24MiB，内核却去 20MiB 找**。
20MiB 不是 8MiB 对齐点，24MiB 是它之后最近的 8MiB 边界（RK 烧写工具按分区粒度对齐）。

本轮三处同步改为 24MiB：`blkdevparts ... @24M`、`mtdparts ... -@0x0000C000(rootfs)`、
DTS `bootargs` 同一份 CMDLINE；CI 增加"两处偏移必须一致"的硬校验。

另外修掉救援 init 的两个误判：

1. `mount -o rw,loop,offset=$FO` 在 busybox 下把 `offset` 当 ext4 选项传给内核
   （日志里 `ext4: Unknown parameter 'offset'`），改为优先 `losetup -o` 再 mount；
   若找到的起点等于 p1 起点（`/sys/class/block/mmcblk1p1/start`），直接挂 p1。
2. `[ -e /newroot/sbin/init ]` 是误判：Ubuntu 的 `/sbin` 是指向 `/usr/sbin` 的绝对软链，
   未 chroot 时按 initramfs 的 `/` 解析必然失败。改为检查 `/newroot/etc/os-release`
   与 `/newroot/usr/lib/systemd/systemd`（不带软链的实体文件）。

---

## 第九轮结论（ttl-rz9 已能进救援 init，但挂载失败）

```
mmcblk1: p1(rootfs)
[rescue]  25165824 字节 (= 24 MiB) : ext4 超级块 ✅ 卷标=[rootfs]
[rescue]  29360128 字节 (= 28 MiB) : ext4 超级块 ✅ 卷标=[rootfs]
JBD2: no valid journal superblock found
EXT4-fs (mmcblk1p1): Could not load journal inode
mount: mounting /dev/mmcblk1p1 on /newroot failed: Invalid argument
```

盘上出现两份 rootfs 头（相差 4MiB）。ext4 备份超级块按 128MiB 分组，
4MiB 间隔只能是两份拷贝 → 24MiB 是旧拷贝（超级块还在、日志区被后一次写入覆盖，
所以挂不上），新写入落在 28MiB。

规律（两轮实测吻合）：**工具写盘位置 = parameter 里 rootfs 偏移 + boot 偏移 4MiB**
（0xA000→24MiB，0xC000→28MiB）。

本轮改动：

1. `blkdevparts=mmcblk1:-@28M(rootfs)`，mtdparts 仍写 `0xC000`（差值 4MiB 是正常配置）。
2. rescue init 判定标准从 "magic=53ef" 改为 **"能真正挂上 + 有 /etc/os-release"**，
   旧拷贝挂不上自动跳过，选可用那份 switch_root。
3. CI 增加按上述规则自动推导的硬校验（`blkdevparts = mtdparts ×512 + 4MiB`）。

用户看到的 `/ #` 是 initramfs 里的 BusyBox ash（`sh: can't access tty` 即为其特征），
不是 Ubuntu 系统提示符 —— 所以没有登录提示、没有密码输入。进系统后才会出现
`Ubuntu 22.04 ... login:`。

---

## 第十轮（对照教程截图后的修正）

教程（`rk3188自行编译linux刷机包教程.txt`）第 7 步打包方式：

```
./mkbootimg --kernel ../3188/kernel-dtb -o ../3188/boot.img
```

**没有 --ramdisk，也没有 --cmdline**。教程 TTL 截图里的启动路径是：

```
mmcblk0: p1
EXT4-fs (mmcblk0p1): mounted filesystem 7c...
Freeing unused kernel image (initmem) memory: 1024K
Run /sbin/init as init process
systemd[1]: systemd 247.3-7+deb11u4 running in system mode
Welcome to Debian GNU/Linux 11 (bullseye)!
```

即：**内核自己挂 `/dev/mmcblk0p1`，自己 exec `/sbin/init`，中间没有任何脚本**。

前几轮我们把救援 initramfs 塞进 `boot.img`，内核就不会自己挂根了，全部交给
`/init`；它挂不上就落进 BusyBox（`sh: can't access tty`），于是用户看到
"`/ #` 提示符、没有登录提示"。这不是登录被禁用，是**根本没进系统**。

据此本版改正：

| 产物 | 内容 | 用途 |
|---|---|---|
| `boot.img` | 纯内核 + dtb，无 ramdisk | **主刷件**（教程路线，内核自己挂根） |
| `boot-rescue.img` | 带救援 initramfs | 仅诊断：需要看 eMMC 里哪段有 ext4 时刷它 |

同时保留上一轮的 `blkdevparts=mmcblk1:-@28M(rootfs)`（数据实测落在 28MiB）
与救援 init 的"试挂"判定（挂得上 + 有 /etc/os-release 才认）。

差异说明（教程设备 vs 本机）：

| 项 | 教程盒子 | 本机 |
|---|---|---|
| eMMC 设备名 | `mmcblk0`（mmc0） | `mmcblk1`（mmc1，1021c000.mmc） |
| 分区表 | 有 `p1`（原厂 GPT/MBR 还在） | **无** MBR/GPT，必须 `blkdevparts` 现造 p1 |
| 根分区 | `/dev/mmcblk0p1` | `/dev/mmcblk1p1`（内核按 blkdevparts 建） |
| boot.img | 无 ramdisk | 本版同样改为无 ramdisk |

---

## 第十一轮：本机没有 SD/TF 卡槽 → 关掉 &mmc0

`ttl-rz9` 里这一行就是空探测：

```
[    2.555985] mmc_host mmc0: Bus speed (slot 0) = 31821429Hz (slot req 400000Hz ...)
```

之后没有任何 `mmc0: new SD card` —— 因为板子没有卡槽。这不是启动失败原因，
但保持 `status="okay"` 有两个副作用：每次启动多注册一个不可能有卡的 host；
并且 pinctrl 会把 `sd0_clk/cmd/d0~d3/cd` 那组脚按 SD 功能配置掉，若这块
瘦客户机把这些脚复用成了别的用途，就是潜在冲突。所以本轮：

```diff
 &mmc0 {
 	...
-	status = "okay";
+	status = "disabled";
 };
```

**关键：关掉 mmc0 不会让 eMMC 变成 mmcblk0。** mmc 控制器编号不是按 probe
顺序，而是按 aliases（本地核过 v6.12 源码 `drivers/mmc/core/host.c`）：

```c
alias_id = of_alias_get_id(dev->of_node, "mmc");
if (alias_id >= 0) index = alias_id;
```

dts 里 `aliases { mmc1 = &emmc; }` 保留，eMMC 就固定是 `mmc1` → `/dev/mmcblk1`，
`parameter.txt` 的 `root=/dev/mmcblk1p1` 继续有效。CI 已加守卫：`&mmc0` 必须
disabled、`&emmc` 必须 okay+non-removable、`mmc1 = &emmc` 必须存在，任一不满足
直接失败，避免"编号漂移 → 刷完挂不上根"这种要烧一次 eMMC 才能发现的错。

---

## 第十二轮：教程日志里的 4MiB 是什么，偏移能不能"对齐"

### 1. 教程日志那两个 `4.00 MiB` 与本偏移无关
```
mmcblk0boot0: mmc0:0001 Biwin 4.00 MiB
mmcblk0boot1: mmc0:0001 Biwin 4.00 MiB
```
这是 eMMC 的**两个硬件 boot 分区**（Boot Partition 1/2，给 SoC 当备用启动区用）。
教程那片 Biwin 是 4MiB 一片；本机 004GA1 是 **2.00 MiB** 一片
（`mmcblk1boot0/1 2.00 MiB`）。它们是独立的硬件分区，不在 `mmcblk1`（user area）
的地址空间里，rootfs 写读完全不经过它们 —— 所以**不需要"对齐"，也不构成问题**。

### 2. 与偏移真正相关的那个 4MiB 是 `0x2000`
RK 的 parameter 用**扇区**记地址：`0x2000 × 512 = 4 MiB`。这一块是加载器
（loader + parameter）自家占的地盘，所以：

| 区间 | 扇区 | 大小 |
|---|---|---|
| loader / parameter | `0x0000 ~ 0x2000` | 0 ~ 4 MiB |
| boot.img | `0x2000` 起，长 `0x8000` | 4 ~ 20 MiB（容量 16 MiB） |
| rootfs | 教程写 `0xA000` | 从 20 MiB 起，**紧接 boot 结束，无空洞** |

教程的 `mtdparts` 就是 `...,-@0x0000A000(rootfs)`，与 boot 首尾相接。

### 3. 我们为什么会错位：声明被叠了两次 4MiB
前一轮为了躲开"数据不在声明处"的现象，把声明挪到了 `0xC000`(24MiB)：

```
声明 0xA000(20MiB) → 实测数据落 24MiB   （ttl-rz8，且 mount 成功 df 973.4M）
声明 0xC000(24MiB) → 实测数据落 28MiB   （ttl-rz9，从未挂载验证过）
```

规律是死的：**工具写盘位置 = 声明 + 0x2000 扇区(4MiB)**。也就是说
"改声明 → 数据跟着跑"，靠调声明永远追不上，反而把中间的空档越撑越大。

### 4. 本轮：三处数字固定成一条线
```
boot        0x2000 .. 0xA000    4 ~ 20 MiB，16 MiB 容量
rootfs 声明  0xA000 (20 MiB)  →  工具 +4 MiB  →  实际落 24 MiB
内核 blkdevparts @24M         →  p1 起点 = 24 MiB = 数据起点
```

- **对齐是成立的**：p1 起点 24 MiB 正好是数据的起点，也是 4 MiB 整数倍，
  对 eMMC 擦除块/页大小都是对齐的；
- 声明区间 20 ~ 24 MiB 那 4 MiB 是工具叠加出来的空档，文件系统不使用它，
  内核直接从 24 MiB 开始读 —— 视觉上有 4 MiB 空隙，功能上无影响；
- 24 MiB 是**唯一被实机成功挂载过**的偏移（rz8：`losetup -o 25165824` +
  `mount -t ext4` 成功，`df` 报 973.4M 总 / 288.8M 已用），比 28 MiB 可靠。

### 5. 想彻底消掉这 4 MiB 空档，只有一条路
必须让"谁来挂根"这件事不依赖绝对偏移 —— 也就是 initramfs 自动探测后
`switch_root`（本包的 `boot-rescue.img` 就是这个思路，它会试挂 24/28/20/32 MiB
并直接进系统）。代价是内核不再自己挂根，一旦所有候选都挂不上就落到 BusyBox。
所以推荐：**正常启动用纯内核 `boot.img` + 24 MiB 对齐**，`boot-rescue.img`
只当诊断件。

### 6. 本轮必须整段重刷 rootfs
上一轮写入落在 28 MiB，把 24 MiB 那份的日志区碾坏了（`JBD2: no valid journal
superblock found`）。现在内核指向 24 MiB，只有重新写一份到 24 MiB 才是干净的：

| 行 | 地址 | 文件 |
|---|---|---|
| #1 Loader | `0x00000000` | 原厂 loader（不动） |
| #2 Parameter | `0x00000000` | 本包 `parameter.txt` |
| #3 boot | `0x00002000` | 本包 `boot.img`（纯内核） |
| #4 rootfs | `0x0000A000` | 本包 `rootfs.img`（约 1GiB，1~3 分钟） |

---

## 第十三轮：`rootfs_size` 输入项此前是死的，已接回

现象：workflow 里明明有 `rootfs_size`（默认 `2G`），但产物永远是 ~1GiB。

原因：该输入只被导出成环境变量 `ROOTFS_SIZE: ${{ inputs.rootfs_size }}`，
**全文件没有任何步骤读它**；镜像大小实际由步骤 7 自己算：

```sh
IMG_MB=$(( ROOTFS_MB * 130 / 100 ))   # 内容 ×130%
[ "$IMG_MB" -lt 1024 ] && IMG_MB=1024  # 硬压下限 1024
```

所以填 2G / 3G 都不生效，等于写死 1024MiB（E1 自检里那句
`assert size_mb >= 1024` 也是硬编码，反而掩盖了这个问题）。

现在改成：

```
镜像 = max(内容×1.3, 你填的 rootfs_size)，仍保留 1024MiB 硬下限
单位：1G / 1536M / 1024（纯数字按 MiB）/ 留空 = 只用自动值
```

- 输入非法（如 `abc`）直接构建失败并提示正确写法；
- 填得比 1024M 小（如 `512M`）会打印告警并按 1024 处理（内容 289MB，再小装不下）；
- E1 自检改为对比"本步骤算出的 IMG_MB"，不再硬编码 1024，避免输入失效时还"校验通过"；
- 默认值从 `2G` 改成 `1G`，与你之前接受的"镜像 1024MiB"保持一致；需要更大就填 `2G`/`3G`。

---

## 第十四轮：ttl-rz10 的 panic —— 根分区根本没被挂载，是 `initrd=` 惹的

日志关键段（`ttl-rz10.txt`）：

```
Kernel command line: ... initrd=0x62000000,0x00030000 ...
Trying to unpack rootfs image as initramfs...
Initramfs unpacking failed: junk within compressed archive
Freeing initrd memory: 192K
mmcblk1: p1(rootfs)
Run /init as init process
Failed to execute /init (error -2)
Run /sbin/init as init process
Kernel panic - not syncing: Requested init /sbin/init failed (error -2).
```

逐句翻译：

| 日志 | 含义 |
|---|---|
| `initrd=0x62000000,0x00030000` | loader 在 0x62000000 交了一段 **192K** 的"initrd"，但主刷 boot.img 没有 ramdisk，这 192K 是**残留垃圾** |
| `Trying to unpack rootfs image as initramfs` | 内核以为有早期用户态，去解这段 cpio/gz |
| `junk within compressed archive` | 果然是垃圾，解包失败 |
| `Freeing initrd memory: 192K` | 失败后释放 |
| `mmcblk1: p1(rootfs)` | 分区本身建对了（blkdevparts 生效） |
| 没有 `EXT4-fs ... mounted` | **根分区从头到尾没被尝试挂载** |
| `Run /init` → `error -2` → `Run /sbin/init` → panic | 空 ramfs 里没有 /init，也没有 /sbin/init（ENOENT），直接 panic |

**所以这不是 rootfs 数据坏，是内核在挂根之前就 panic 了。** 触发点就是 CMDLINE 里
那条 `initrd=`：有它，内核就走"解 initramfs + 不挂根"的路；没了它，内核才会执行
`prepare_namespace()` 去挂 `/dev/mmcblk1p1`。

### 本轮改动

| 文件 | 改动 |
|---|---|
| `parameter.txt` | CMDLINE **删掉** `initrd=0x62000000,0x00800000`（251 → 222 字节） |
| `parameter-rescue.txt`（新增） | 与主参数唯一差别：保留 `initrd=`，只给 `boot-rescue.img` 用 |
| `dts/rk3188-adesk-std.dts` | 兜底 `bootargs` 同步去掉 `initrd=`（loader 不传 ATAG 时的路径） |
| `build.yml` | CI 改成**禁止**主参数带 `initrd=`（带了直接失败并提示改用救援参数）；新增校验 `parameter-rescue.txt` 必须存在且带 `initrd=`；救援参数一起进产物与 `MANIFEST.sha256` |

### 这次怎么刷

| 行 | 地址 | 文件 |
|---|---|---|
| #2 Parameter | `0x00000000` | `parameter.txt`（已去 initrd） |
| #3 boot | `0x00002000` | `boot.img`（纯内核） |

rootfs 先不用刷：rz10 里内核没挂根就 panic，24MiB 那份到底好不好还没被验证过。
刷完只看一行：`EXT4-fs (mmcblk1p1): mounted filesystem ...` 出现即说明根挂上了。
若它报 `JBD2`/`EXT4-fs ... Could not load journal inode` 之类，再整段刷一次 rootfs。

### 顺带确认的好消息

`ttl-rz10` 里已经**没有** `mmc_host mmc0` 那几行了 —— 说明"无 SD/TF 卡槽 → `&mmc0`
改成 disabled"的 DTS 改动生效了，而且 `mmcblk1` 依然是 `mmcblk1`（aliases 那条
`mmc1 = &emmc` 起作用），`root=/dev/mmcblk1p1` 没漂移。

---

## 第十五轮：ttl-rz11 —— 内核这一层全部通了，卡点搬到了用户态

这一轮的日志是**分水岭**：从 loader 到 `systemd` 一整条链路第一次全部走通。

```
Machine model: aDesk-STD-200H-s RK3188 TV Box
Kernel command line: ... root=/dev/mmcblk1p1 ... blkdevparts=mmcblk1:-@24M(rootfs) ...   ← 无 initrd=
mmcblk1: mmc1:0001 004GA1 3.69 GiB
 mmcblk1: p1(rootfs)                                          ← 分区建对
EXT4-fs (mmcblk1p1): mounted filesystem c1d9a817-... r/w ...  ← ★根分区挂上了
VFS: Mounted root (ext4 filesystem) on device 179:1
devtmpfs: mounted
Freeing unused kernel image (initmem) memory: 1024K
Run /sbin/init as init process                                ← ★内核把系统交给 systemd
systemd[1]: systemd 249.11-0ubuntu3.23 running in system mode
systemd[1]: Detected architecture arm.
systemd[1]: Hostname set to <rk3188>.
                                                              ← 到这里之后静默
```

对照前十四轮，这次一次性补齐了四件事：

1. `initrd=` 去掉了 → 日志里**再没有** `Trying to unpack rootfs image as initramfs` /
   `junk within compressed archive`（全文 `initramfs` 出现 0 次）；
2. `rootfs.img` 被内核真正挂上了，UUID `c1d9a817-...`（新一轮构建），r/w 挂载；
3. 内核自己 `exec /sbin/init`，不再靠我们的救援 `/init`；
4. `systemd` 进 system mode、认出 arm、设好 hostname —— 也就是 Ubuntu Base 22.04
   这套用户态**本身是完好的**。

### 现在卡在哪：`Hostname set to <rk3188>` 之后没有下文

`Hostname set` 之后 systemd 正常会紧接着打：

```
systemd[1]: Created slice system-modprobe.slice.
systemd[1]: Created slice system-getty.slice.
...（几十条 [  OK  ] ...）
```
然后 `serial-getty@ttyS2` 打出 `login:`。这一轮这些**一条都没有**，说明卡点在
systemd 内部（unit 加载 / journald / udev）或者串口输出在中途停了 —— 两者表现一样，
得用更细的日志区分。

### 三种可能，按可能性排

| # | 可能 | 判断方法 |
|---|---|---|
| 1 | 某个 unit 等 90 秒 job 超时（常见：`dev-`/`sys-`/网络类 unit 等设备出现） | 静默后再等 **120 秒**，若出现 `Job ... timed out` 或 `[ TIME ] Timed out`，名字就是元凶 |
| 2 | `systemd-journald` / `systemd-udevd` 没起来，整个后续 unit 全堵住 | 用 `parameter-debug.txt` 抓日志，会看到最后一条停在哪个 unit |
| 3 | 串口输出中途丢了（`/etc/issue` 式的半行、之后其实在继续跑） | 按回车、等一会儿；若打出 `login:` 就是纯粹没显示全 |

### 本轮新增：`parameter-debug.txt`

与 `parameter.txt` **唯一差别**是 CMDLINE 末尾多了：

```
systemd.log_level=debug systemd.log_target=kmsg
```

这样 systemd 会把每一条 unit 的加载/依赖/job 都写进内核日志，也就等于写到串口。
**最后一条日志停在哪，卡的就是那一步** —— 这是最快、最便宜的定位手段（只刷
Parameter 一行，20KB，不用重刷 rootfs）。

用法：`#2 Parameter` 选 `parameter-debug.txt`，`#3 boot` 选 `boot.img`，抓
3~5 分钟日志后改回 `parameter.txt` 正式启动。

---

## 第十五轮补：debug 参数没变化 → 先排除"参数没写进去 / 被 loader 截断"

现象：换上 `parameter-debug.txt` 后日志与 rz11 一模一样。两个可能，都要先排掉：

1. **Parameter 行没真正写进去**。RKDevTool 的「下载镜像」模式下，Parameter 行里的
   文件路径是"上一次选中的"，换文件后必须**重新点选一次**，并且该行要打勾；
   有些版本还会缓存路径。
2. **loader 截断了 CMDLINE 尾部**。RK31 loader 对 CMDLINE 有自己的长度上限，
   把调试项加在**末尾**时可能被截掉，等于没加。

因此本版把 `systemd.log_level=debug` 与 `systemd.log_target=kmsg` **挪到 CMDLINE
的最前面**（紧跟 `earlyprintk`），只要开头能进去，就一定生效：

```
earlyprintk systemd.log_level=debug systemd.log_target=kmsg console=ttyS2,115200 ...
```

**刷完第一件事**：看日志里 `Kernel command line:` 那一行有没有 `systemd.log_level=debug`。
看不到 → 就是参数没写进去，不是 systemd 的问题。

### 同时给出 `parameter-shell.txt`：绕过 systemd 的断点测试

把 `init=/sbin/init` 换成 `init=/bin/sh`（CMDLINE 219 字节）。

- 如果出现 `#` 提示符 → 内核挂根、执行用户态、串口输出**三件事全好**，问题 100% 在
  systemd；在 shell 里依次跑 `mount -t proc proc /proc`、`mount -t sysfs sysfs /sys`、
  `cat /proc/cmdline`、`exec /sbin/init`，看它卡前最后打哪条。
- 如果连 `#` 都没有、照样静默 → 问题不在 systemd，而在更早的地方（串口输出或
  挂根后的执行），方向完全变了，届时把日志发我。

---

## 第十六轮：ttl-rz12 —— `#` 提示符出来了，范围缩到 systemd

`parameter-shell.txt`（`init=/bin/sh`）生效了，CMDLINE 完整传进来（`init=/bin/sh`
那一项清楚可见），并且：

```
EXT4-fs (mmcblk1p1): recovery complete
EXT4-fs (mmcblk1p1): mounted filesystem c1d9a817-... r/w ...
VFS: Mounted root (ext4 filesystem) on device 179:1
devtmpfs: mounted
Run /bin/sh as init process
/bin/sh: 0: can't access tty; job control turned off
#
```

**`#` 出现 = 内核挂根 + 执行用户态 + 串口输出 三件事全部正常**，而且
`recovery complete` 说明 ext4 日志回放正常、文件系统健康。

所以问题 **100% 在 systemd**，不在内核、不在 rootfs 数据、不在分区偏移。
（`can't access tty; job control turned off` 是 PID1 没有控制终端的正常提示，
 不代表出错。）

### 上一轮 `parameter-debug.txt` 为什么"没变化"

rz12 的 CMDLINE 长度约 264 字节（219 + loader 追加的 bootver/firmware_ver），完整
通过了；而旧的 debug 版是 270 + 45 ≈ 315 字节，`systemd.log_level=debug` 加在
**末尾**，被 loader 的长度上限截掉了 —— 等于没加。新版已把它挪到 CMDLINE 最前面。

### 两个并行动作

1. **再刷一次新版 `parameter-debug.txt`**（调试项在开头，不会再被截），会看到
   systemd 逐条 unit 的日志，最后停在哪条就是元凶。
2. **就现在这个 `#` 提示符**，粘贴 `diagnose-in-shell.txt` 里的命令，先拿 8 组事实
   （`/sbin/init` 指向、machine-id、fstab、启用的 unit、/dev/console 等）。

### 如果确认是"日志被 journald 吃了"而不是真卡

给 `patch-rootfs-serial-log.sh`：在 rootfs 里写两个配置，让 systemd 的日志
**永远**同时打到 console（串口），下次重建 rootfs 后持久生效，不再依赖 CMDLINE。

---

## 第十七轮：ttl-rz13 —— debug 参数根本没被写进机器

把机器实际收到的 CMDLINE 与两份文件逐字对比：

```
机器实际收到（rz13 第 39 行）:
earlyprintk console=ttyS2,115200 ... blkdevparts=... mtdparts=... dwc_driver=2

parameter.txt（交付件）:
earlyprintk console=ttyS2,115200 ... blkdevparts=... mtdparts=... dwc_driver=2      ← 完全一致

parameter-debug.txt（v3 交付件）:
earlyprintk ignore_loglevel systemd.log_level=debug systemd.log_target=kmsg console=...   ← 不在机器里
```

证据链：机器的 CMDLINE 里**还有 `dwc_driver=2`**（v3 特意删掉了它），
**没有 `systemd.log_level=debug`**。所以这次写进 flash 的仍然是 `parameter.txt`，
不是 `parameter-debug.txt` —— 刷机工具那一行没真正换成新文件。

对比 `ttl-rz12` 是反证：那一次机器 CMDLINE 里明确出现了 `init=/bin/sh`，
说明"只刷 Parameter 行"这个操作本身是可行的，问题只在"选没选中对的文件"。

### 判定方法（刷完第一眼就要看）

TTL 日志里 `Kernel command line:` 那一行：

- 有 `systemd.log_level=debug` → 参数进去了，接着看最后一条日志停在哪个 unit；
- 没有 → 参数没进去，跟 systemd 无关，重刷 Parameter 行（确认路径显示
  `parameter-debug.txt`，并确认该行打勾）。

### 兜底路线（绕开刷机工具选文件的问题）

上一轮 `parameter-shell.txt` 是**确认能写进去**的（rz12 的 CMDLINE 有 `init=/bin/sh`）。
所以：

1. 刷 `parameter-shell.txt` + `boot.img`，启动到 `#`；
2. 整段粘贴 `shell-once.txt`：先采集 6 组事实（init 指向 / machine-id / fstab /
   已启用 unit / 设备节点 / 空间），再把 debug 配置直接写进 rootfs，最后 `exec /sbin/init`。

这样 debug 就**不经过 loader 的 CMDLINE**，刷机工具选错文件这个变量被彻底消掉。
