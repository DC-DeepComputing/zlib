/* riscv.c -- runtime detection + dispatch for the RVV kernels.
 * Selected at build time with -DHAVE_RVV; harmless without it. */
#include "zutil.h"
#include <stdio.h>
#include <string.h>

int zlib_rvv_enabled = -1;      /* -1: not probed, 0: off, 1: on */

unsigned long crc32_rvv_z(unsigned long crc, const unsigned char *buf,
                          z_size_t len);
unsigned long adler32_rvv_z(unsigned long adler, const unsigned char *buf,
                            z_size_t len);

static void zlib_rvv_probe(void) {
    FILE *f;
    char line[8192];
    int have_zvbc = 0, have_zvbb = 0;

    zlib_rvv_enabled = 0;
    f = fopen("/proc/cpuinfo", "r");
    if (f == NULL)
        return;
    while (fgets(line, sizeof line, f) != NULL) {
        if (strncmp(line, "isa", 3) == 0) {
            if (strstr(line, "_zvbc") != NULL) have_zvbc = 1;
            if (strstr(line, "_zvbb") != NULL) have_zvbb = 1;
            break;                  /* one CPU is enough (homogeneous ISA) */
        }
    }
    fclose(f);
    if (have_zvbc && have_zvbb)
        zlib_rvv_enabled = 1;
}

int zlib_rvv_crc32(uLong crc, const unsigned char FAR *buf, z_size_t len,
                   uLong *out) {
    if (zlib_rvv_enabled < 0)
        zlib_rvv_probe();
    if (zlib_rvv_enabled && len >= 64) {
        *out = crc32_rvv_z(crc, buf, len);
        return 1;
    }
    return 0;
}

int zlib_rvv_adler32(uLong adler, const Bytef FAR *buf, z_size_t len,
                     uLong *out) {
    if (zlib_rvv_enabled < 0)
        zlib_rvv_probe();
    if (zlib_rvv_enabled && len >= 32) {
        *out = adler32_rvv_z(adler, buf, len);
        return 1;
    }
    return 0;
}
