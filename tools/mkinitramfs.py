#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
mkinitramfs.py —— 纯 Python 生成 / 校验 Linux initramfs（newc cpio + gzip）

为什么不用 cpio 命令：
    上一轮 CI 里 `gzip -dc initramfs.cpio.gz | cpio -it | grep -qx './init'`
    把整个 workflow 判失败（报 "initramfs 里没有 /init"），但归档大小
    868606 字节说明内容其实打进去了 —— 是 cpio 列表输出的形态/退出码问题。
    GitHub runner 上 cpio 是否安装、`-t` 往 stdout 还是 stderr 都不稳定，
    所以这里用纯 Python 直接写、直接读 newc 归档，零外部依赖。

newc 格式（内核 initramfs 唯一通用格式）：
    每个条目 = 110 字节 ASCII 头 + 文件名（含结尾 NUL，补到 4 字节）
              + 文件数据（补到 4 字节）
    头字段依次为 8 位十六进制：magic(070701) ino mode uid gid nlink mtime
                             filesize devmajor devminor rdevmajor rdevminor
                             namesize check
    结尾固定为一条 name="TRAILER!!!"、filesize=0 的条目。

用法：
    python3 mkinitramfs.py --create <源目录> <输出文件.cpio.gz>
    python3 mkinitramfs.py --verify <文件.cpio.gz> [必须存在的路径...]
"""
import gzip
import io
import os
import stat
import sys

MAGIC = b"070701"
HDR_LEN = 110
TRAILER = "TRAILER!!!"


def _pad4(buf: bytearray) -> None:
    """把缓冲区补到 4 字节对齐（newc 要求名字与数据都 4 字节对齐）"""
    while len(buf) % 4:
        buf.append(0)


def _entry(name: str, data: bytes, mode: int, ino: int) -> bytes:
    name_bytes = name.encode("utf-8") + b"\x00"
    fields = [
        MAGIC,
        "%08X" % ino,
        "%08X" % (mode & 0xFFFFFFFF),
        "%08X" % 0,           # uid
        "%08X" % 0,           # gid
        "%08X" % (2 if stat.S_ISDIR(mode) else 1),   # nlink
        "%08X" % 0,           # mtime 固定 0，产物可复现
        "%08X" % len(data),
        "%08X" % 0,           # devmajor
        "%08X" % 0,           # devminor
        "%08X" % 0,           # rdevmajor
        "%08X" % 0,           # rdevminor
        "%08X" % len(name_bytes),
        "%08X" % 0,           # check
    ]
    out = bytearray()
    for f in fields:
        out += f if isinstance(f, bytes) else f.encode("ascii")
    assert len(out) == HDR_LEN, "newc 头长度必须正好 110 字节"
    out += name_bytes
    _pad4(out)
    out += data
    _pad4(out)
    return bytes(out)


def create(src_dir: str, out_path: str) -> None:
    entries = []
    for root, dirs, files in os.walk(src_dir):
        dirs.sort()
        files.sort()
        for d in dirs:
            p = os.path.join(root, d)
            rel = "/" + os.path.relpath(p, src_dir)
            entries.append((rel, p, True))
        for f in files:
            p = os.path.join(root, f)
            rel = "/" + os.path.relpath(p, src_dir)
            entries.append((rel, p, False))

    buf = bytearray()
    ino = 1
    # 目录必须先于其内容出现，os.walk 的顺序天然满足（父目录先被列出）
    for rel, path, is_dir in entries:
        st = os.lstat(path)
        if is_dir:
            buf += _entry(rel, b"", stat.S_IFDIR | (st.st_mode & 0o7777), ino)
        elif stat.S_ISLNK(st.st_mode):
            buf += _entry(rel, os.readlink(path).encode("utf-8"),
                          stat.S_IFLNK | 0o777, ino)
        else:
            with open(path, "rb") as fh:
                data = fh.read()
            buf += _entry(rel, data, stat.S_IFREG | (st.st_mode & 0o7777), ino)
        ino += 1

    buf += _entry(TRAILER, b"", 0, 0)
    raw = bytes(buf)
    with open(out_path, "wb") as fh:
        with gzip.GzipFile(fileobj=fh, mode="wb", compresslevel=9, mtime=0) as gz:
            gz.write(raw)
    print("initramfs: %d 个条目, 未压缩 %d 字节, 压缩后 %d 字节"
          % (len(entries), len(raw), os.path.getsize(out_path)))


def parse(raw: bytes):
    """解析 newc，返回 [(name, mode, size, data_offset)]，顺带做格式校验"""
    items = []
    off = 0
    while True:
        assert raw[off:off + 6] == MAGIC, "偏移 %d 处不是 070701 magic（归档不是 newc）" % off
        hdr = raw[off:off + HDR_LEN]
        assert len(hdr) == HDR_LEN, "归档在头处被截断"
        try:
            vals = [int(hdr[6 + i * 8:14 + i * 8], 16) for i in range(13)]
        except ValueError:
            raise AssertionError("头字段不是十六进制：%r" % hdr)
        ino, mode, uid, gid, nlink, mtime, size = vals[0:7]
        namesize = vals[11]
        name = raw[off + HDR_LEN:off + HDR_LEN + namesize - 1].decode("utf-8", "replace")
        data_off = off + HDR_LEN + namesize
        data_off += (-data_off) % 4
        data = raw[data_off:data_off + size]
        assert len(data) == size, "条目 %s 的数据被截断" % name
        if name == TRAILER:
            break
        items.append((name, mode, size, data))
        off = data_off + size
        off += (-off) % 4
    return items


def verify(path: str, required) -> None:
    with gzip.open(path, "rb") as fh:
        raw = fh.read()
    items = parse(raw)
    print("initramfs 条目（%d 个）：" % len(items))
    for name, mode, size, data in items:
        kind = "d" if stat.S_ISDIR(mode) else ("l" if stat.S_ISLNK(mode) else "-")
        print("  %s %s %8d  %s" % (kind, oct(mode & 0o777), size, name))

    names = {}
    for name, mode, size, data in items:
        names[name] = (mode, data)

    for want in required:
        want = want if want.startswith("/") else "/" + want
        assert want in names, "initramfs 里缺少 %s" % want
        mode, data = names[want]
        if want == "/init":
            assert stat.S_ISREG(mode), "/init 不是普通文件"
            assert mode & 0o111, "/init 没有可执行位（内核会 exec 失败）"
            assert data.startswith(b"#!"), "/init 第一行不是 shebang"
            print("  ✅ /init 可执行、以 %r 开头"
                  % data.split(b"\n")[0].decode("utf-8", "replace"))

    for name, mode, size, data in items:
        if name == "/init":
            if b"/bin/busybox sh" not in data[:64]:
                print("  ⚠️ /init 第一行不是 #!/bin/busybox sh（确认 busybox 路径正确）")
            break
    print("✅ initramfs 校验通过（%d 条目，含 %s）" % (len(items), "、".join(required)))


def main(argv) -> int:
    if len(argv) < 3:
        print(__doc__)
        return 2
    mode = argv[1]
    if mode == "--create":
        create(argv[2], argv[3])
        return 0
    if mode == "--verify":
        verify(argv[2], argv[3:] or ["/init"])
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
