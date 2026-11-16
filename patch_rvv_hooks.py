#!/usr/bin/env python3
"""Idempotent patch: hook RVV kernels into zlib 1.4 crc32.c / adler32.c.
Safe to re-run; skips already-patched files."""
import sys

CRC_HOOK = """#ifdef HAVE_RVV
    if (len >= 64) {
        uLong rvv;
        extern int zlib_rvv_crc32(uLong, const unsigned char FAR *, z_size_t, uLong *);
        if (zlib_rvv_crc32(crc, buf, len, &rvv))
            return rvv;
    }
#endif
"""

ADLER_HOOK = """#ifdef HAVE_RVV
    if (len >= 64) {
        uLong rvv;
        extern int zlib_rvv_adler32(uLong, const Bytef *, z_size_t, uLong *);
        if (zlib_rvv_adler32(adler, buf, len, &rvv))
            return rvv;
    }
#endif

"""

def patch(path, marker, anchor, insert_after):
    s = open(path).read()
    if marker in s:
        print(f"{path}: already patched, skip")
        return
    if anchor not in s:
        print(f"{path}: ANCHOR NOT FOUND -- abort")
        sys.exit(1)
    s = s.replace(anchor, anchor + insert_after, 1)
    open(path, 'w').write(s)
    print(f"{path}: patched")

patch('crc32.c', 'zlib_rvv_crc32',
      """uLong ZEXPORT crc32_z(uLong crc, const unsigned char FAR *buf, z_size_t len) {
    /* Return initial CRC, if requested. */
    if (buf == Z_NULL) return 0;
""",
      "\n" + CRC_HOOK)

patch('adler32.c', 'zlib_rvv_adler32',
      """    /* do length NMAX blocks -- requires just one modulo operation */
""",
      ADLER_HOOK)
