/*
 * mkkrnlimg.c — Rockchip KRNL 内核镜像封装器（修正版）
 *
 * 用法:
 *   gcc mkkrnlimg.c -o mkkrnlimg
 *   ./mkkrnlimg zImage-dtb boot.img
 *
 * 镜像结构（与 Rockchip boot_rkimg.h 的 struct rockchip_image 一致）:
 *   [0..3]   tag   = 0x4C4E524B  ("KNRL" / 项目里写成 "KRNL" 的小端值)
 *   [4..7]   size  = 内核镜像字节数（不含 tag、size、尾部 crc）
 *   [8 .. 7+size]  原始内核（zImage-dtb）
 *   [尾部 4 字节]  crc32（标准 zlib/u-boot CRC32），计算范围 = 原始内核内容
 *
 * ============================================================================
 * 原 build.yml 内联版本的三处致命错误（本文件已修正）:
 *
 * 1) CRC 位置错误：原版把 crc 写到了头部 size 之后、内核之前（偏移 8），
 *    导致 bootloader 拷贝内核时，zImage 开头 4 字节被这 4 字节 CRC 覆盖；
 *    正确位置是文件末尾（image 之后）。
 *
 * 2) CRC 算法错误：原版用标准 CRC32 是对的（u-boot lib/crc32 同算法），
 *    但如果你的 loader 校验的是 Rockchip 自研 RKCRC（初值 0、左移、
 *    查表 0x04C11DB7），请把 rkcrc32() 替换为文末注释里的实现。
 *
 * 3) 头字段不完整：原版只写 12 字节头且没有尾部校验字段；bootloader
 *    按 size 读出的内容与实际镜像错位，内核入口被破坏 → 跳过后跑飞、
 *    串口无任何内核输出（即日志停在 start_linux=====51740 的现象）。
 *
 * 注意：本格式对应新版 Rockchip rockchip_image 封装。若你的原厂 loader
 * 使用 2KB "KERNEL" 头（老 RK30/RK31 Android 4.2 SDK mkkrnlimg），
 * 请优先使用原厂 SDK 自带的 mkkrnlimg 二进制封装，不要用本文件。
 * ============================================================================
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#define TAG_KERNEL 0x4C4E524Bu

static uint32_t crc_table[256];

static void make_crc_table(void)
{
    for (uint32_t n = 0; n < 256; n++) {
        uint32_t c = n;
        for (int k = 0; k < 8; k++)
            c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
        crc_table[n] = c;
    }
}

/* 标准 zlib / u-boot CRC32 */
static uint32_t crc32(uint32_t crc, const uint8_t *buf, size_t len)
{
    crc = crc ^ 0xFFFFFFFFu;
    while (len--)
        crc = crc_table[(crc ^ *buf++) & 0xFFu] ^ (crc >> 8);
    return crc ^ 0xFFFFFFFFu;
}

#if 0  /* 需要 RKCRC 时打开，并把 main 里的 crc 换成 rkcrc32() */
static uint32_t rk_table[256];
static void make_rk_table(void)
{
    for (uint32_t n = 0; n < 256; n++) {
        uint32_t c = n;
        for (int k = 0; k < 8; k++)
            c = (c & 0x80000000u) ? (c << 1) ^ 0x04C11DB7u : (c << 1);
        rk_table[n] = c;
    }
}
/* Rockchip 自研 CRC：初值 0，左移，不补余 */
static uint32_t rkcrc32(const uint8_t *buf, size_t len)
{
    uint32_t crc = 0;
    while (len--)
        crc = (crc << 8) ^ rk_table[((crc >> 24) ^ *buf++) & 0xFFu];
    return crc;
}
#endif

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "Usage: %s <input zImage-dtb> <output boot.img>\n", argv[0]);
        return 1;
    }

    make_crc_table();

    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror("fopen input"); return 1; }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);

    uint8_t *buf = malloc((size_t)size);
    if (!buf) { fprintf(stderr, "malloc failed\n"); fclose(f); return 1; }
    if (fread(buf, 1, (size_t)size, f) != (size_t)size) {
        perror("fread"); free(buf); fclose(f); return 1;
    }
    fclose(f);

    uint32_t tag  = TAG_KERNEL;
    uint32_t ulen = (uint32_t)size;
    uint32_t crc  = crc32(0, buf, (size_t)size);

    FILE *out = fopen(argv[2], "wb");
    if (!out) { perror("fopen output"); free(buf); return 1; }

    fwrite(&tag,  4, 1, out);   /* tag  */
    fwrite(&ulen, 4, 1, out);   /* size */
    fwrite(buf,   1, (size_t)size, out);
    fwrite(&crc,  4, 1, out);   /* CRC 在尾部（修正点 1） */

    fclose(out);
    free(buf);
    printf("packed %ld bytes -> %s (crc=0x%08x)\n", size, argv[2], crc);
    return 0;
}
