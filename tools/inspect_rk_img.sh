#!/usr/bin/env bash
# ============================================================================
# inspect_rk_img.sh — Rockchip RK3188 启动镜像格式体检脚本
#
# 用途：
#   对比【原厂固件解出的 kernel/boot 镜像】与【本项目产物 boot.img】的头部格式，
#   判断 loader 期望的封装结构（Android boot.img / Rockchip KRNL 封装 / 裸镜像），
#   定位 “start_linux=====NNNNN 之后无 Starting kernel 行” 的封装修复依据。
#
# 用法：
#   ./inspect_rk_img.sh 原厂_kernel.img 产物_boot.img [更多镜像...]
#
# 无需 root，仅依赖 bash + python3。输出可整段复制回贴。
# ============================================================================
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "用法: $0 <镜像1> [镜像2] ..."
  exit 1
fi

python3 - "$@" <<'PYEOF'
import sys, struct, os

FDT_MAGIC = 0xD00DFEED
ANDROID_MAGIC = b"ANDROID!"

def hexdump(buf, base=0, limit=128):
    out = []
    n = min(len(buf), limit)
    for i in range(0, n, 16):
        chunk = buf[i:i+16]
        hexs = " ".join(f"{b:02x}" for b in chunk)
        asc = "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)
        out.append(f"  {base+i:08x}  {hexs:<47}  {asc}")
    return "\n".join(out)

def u32le(buf, off):
    return struct.unpack_from("<I", buf, off)[0]

def fdt_offsets(buf):
    res = []
    for i in range(0, len(buf) - 4):
        if struct.unpack_from(">I", buf, i)[0] == FDT_MAGIC:
            res.append(i)
            if len(res) >= 4:
                break
    return res

def inspect(path):
    print("=" * 78)
    print(f"镜像: {path}")
    if not os.path.isfile(path):
        print("  ❌ 文件不存在")
        return
    size = os.path.getsize(path)
    print(f"文件大小: {size} 字节 ({size/1024:.1f} KiB)")
    with open(path, "rb") as f:
        buf = f.read()

    # ---- 头部 hexdump ----
    print("\n[头部 128 字节]")
    print(hexdump(buf, 0, 128))

    # ---- 格式识别 ----
    magic4 = buf[:4]
    tag = struct.unpack("<I", magic4)[0]
    print("\n[格式识别]")

    if buf[:8] == ANDROID_MAGIC:
        print("  ✔ Android boot image（magic = 'ANDROID!'）")
        ks, ka = u32le(buf, 8),  u32le(buf, 12)
        rs, ra = u32le(buf, 16), u32le(buf, 20)
        ss, sa = u32le(buf, 24), u32le(buf, 28)
        tg, pg = u32le(buf, 32), u32le(buf, 36)
        ver    = u32le(buf, 40)
        name   = buf[48:64].rstrip(b"\x00").decode("ascii", "replace")
        cmdline= buf[64:576].rstrip(b"\x00").decode("ascii", "replace")
        print(f"    header_version = {ver}")
        print(f"    kernel_size   = {ks}  (0x{ks:x})   kernel_addr = 0x{ka:08x}")
        print(f"    ramdisk_size  = {rs}  (0x{rs:x})   ramdisk_addr= 0x{ra:08x}")
        print(f"    second_size   = {ss}  (0x{ss:x})   second_addr = 0x{sa:08x}")
        print(f"    tags_addr     = 0x{tg:08x}   page_size = {pg}")
        print(f"    name='{name}'")
        print(f"    cmdline='{cmdline}'")
        print("  → 若原厂是此格式，boot 分区必须用 mkbootimg 打包，而不是 KRNL 封装。")

    elif magic4 in (b"KRNL", b"KNRL", b"KERN", b"RKRN"):
        print(f"  ✔ Rockchip KRNL 封装（前 4 字节 = {magic4!r}, tag=0x{tag:08x}）")
        ulen = u32le(buf, 4)
        print(f"    [4..7] size 字段 = {ulen} 字节 (0x{ulen:x})")
        print(f"    文件总长 = {size}")
        # 校验几种 size 解释与尾部 crc 的位置
        print(f"    按 size=ulen 推算: 头8B + 镜像 + 尾4B CRC = {8 + ulen + 4}")
        print(f"    按 size=ulen 推算: 头12B + 镜像(CRC 在头内偏移8) = {12 + ulen}")
        tail = buf[-4:]
        crc = struct.unpack("<I", tail)[0]
        print(f"    尾部 4 字节 CRC = 0x{crc:08x}")
        print("  → 对照原厂镜像：size 字段是否等于真实内核长度、CRC 在头内还是尾部。")

    elif struct.unpack(">I", buf[:4])[0] == FDT_MAGIC:
        print("  ✔ 裸 FDT（DTB，magic 0xd00dfeed 在文件头）")
        totalsize = struct.unpack(">I", buf[4:8])[0]
        print(f"    fdt totalsize = {totalsize}")
    else:
        print(f"  · 未识别标准 magic，前 4 字节 = {magic4!r} (0x{tag:08x})")
        # ARM zImage 常见入口：0xEAxxxxxx (ARM 分支) 或头 0x016f2818
        print(f"    首指令字 = 0x{struct.unpack('<I', buf[:4])[0]:08x}（0xEA 开头为 ARM b 跳转，可能是裸 zImage）")

    # ---- DTB 拼接位置 ----
    fdt = fdt_offsets(buf)
    print("\n[FDT(DTB) 出现位置]")
    if fdt:
        for off in fdt:
            ts = struct.unpack(">I", buf[off+4:off+8])[0]
            print(f"  · 偏移 0x{off:x} ({off})，fdt totalsize={ts}（距文件尾 {size-off-ts} 字节）")
        print("  → 主线 appended-DTB 要求 dtb 紧跟 zImage 尾部；确认 fdt 偏移与 _end 对齐。")
    else:
        print("  · 文件内未找到 FDT magic 0xd00dfeed")

    # ---- 尾部 ----
    print("\n[尾部 32 字节]")
    print(hexdump(buf[-32:], max(0, size-32), 32))

    print()

for p in sys.argv[1:]:
    inspect(p)
PYEOF
