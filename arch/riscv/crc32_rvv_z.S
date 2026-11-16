/*
 * crc32_rvv_z.S -- CRC-32 folding using RISC-V Vector carry-less multiply (Zvbc)
 * for SpacemiT K3 (X100, VLEN=256, RVV 1.0 + Zvbb + Zvbc) and similar cores.
 *
 * Math (verified bit-exact against the table CRC over exhaustive lengths +
 * streaming splits, see gen_crc32.py):
 *   Q = 0x104C11DB7 (x^32 + ...). desc-word: bit i <-> x^(31-i).
 *   rev32(R_raw) = x^(8n)*rev32(~crc_in) + x^32*F  (mod Q), F = full
 *   bit-reversed message string. Fold state T (congruent mod Q, kept < 2^64):
 *     T_0      = rev32(~crc)
 *     per 64B: T = T*x^512 + sum_j f_j*x^(64(7-j)+32)  (f_j = rev64(chunk j))
 *     per 8B : T = T*x^64  + f*x^32
 *     per 1B : T = T*x^8   + rev8(b)*x^32
 *   x^k shifts of a 64-bit value v are done as:
 *     v*x^k mod Q = clmul(v, Ck) ^ clmul(clmulh(v, Ck), C64)
 *   Final: reduce T to deg<32 by repeated 32-bit folds, rev32, complement.
 *
 * unsigned long crc32_rvv_z(unsigned long crc, const unsigned char *buf,
 *                           z_size_t len);   (buf != NULL, len >= 64)
 */

    .text
    .align  2
    .globl  crc32_rvv_z
    .type   crc32_rvv_z,@function
crc32_rvv_z:
    /* a0 = crc, a1 = buf, a2 = len (>= 64) */
    not     a0, a0
    vsetivli zero, 4, e32, m1, ta, ma
    vmv.s.x v26, a0
    vbrev.v v26, v26
    vmv.x.s a0, v26
    slli    a0, a0, 32       /* vmv.x.s sign-extends on this core: zero upper */
    srli    a0, a0, 32       /* a0 = T = rev32(~crc) */

    li      t1, 0x567fddeb      /* C1024 = x^1024 mod Q */
    li      t2, 0x490d678d      /* C64  = x^64  mod Q */
    srli    a3, a2, 7           /* number of 128-byte groups */
    andi    a2, a2, 127         /* tail bytes */

    la      t0, .Lcrc_cm16
    vsetivli zero, 16, e64, m4, ta, ma
    vle64.v v24, (t0)           /* per-lane x^(64(15-j)+32) mod Q */
    la      t0, .Lcrc_c64
    vle64.v v28, (t0)           /* all lanes x^64 mod Q */
    vmv.v.i v20, 0              /* reduction seed (v20-v23) */
    beqz    a3, .Lcrc_tail      /* len < 128: no full group */

.Lcrc_loop:
    vle64.v   v4, (a1)          /* 16 LE qwords */
    vbrev.v   v4, v4            /* rev64 each lane -> poly values */
    vclmul.vv v8, v4, v24       /* P_lo = f (x) Cm_j */
    vclmulh.vv v12, v4, v24     /* P_hi */
    vclmul.vv v12, v12, v28     /* P_hi * C64 */
    vxor.vv   v8, v8, v12       /* f_j*x^(64(15-j)+32) mod Q, per lane */
    vredxor.vs v16, v8, v20     /* XOR-reduce 16 lanes */
    vmv.x.s   t3, v16
    clmul    t4, a0, t1         /* T*x^1024: clmul  part */
    clmulh   t5, a0, t1         /*         : clmulh part */
    clmul    t5, t5, t2
    xor      a0, t4, t5
    xor      a0, a0, t3
    addi     a1, a1, 128
    addi     a3, a3, -1
    bnez     a3, .Lcrc_loop

    /* tail: a2 bytes, up to 15 qwords + up to 7 single bytes */
.Lcrc_tail:
    srli    a3, a2, 3           /* 8-byte tail chunks */
    andi    a2, a2, 7
    beqz    a3, .Lcrc_tbyte
    la      t0, .Lcrc_c32
    vsetivli zero, 1, e64, m1, ta, ma
    vle64.v v6, (t0)            /* x^32 mod Q in lane 0 */
.Lcrc_t8:
    vle64.v   v4, (a1)          /* 1 qword */
    vbrev.v   v4, v4
    vclmul.vv v8, v4, v6        /* f * x^32 */
    vclmulh.vv v12, v4, v6
    vclmul.vv v12, v12, v28     /* P_hi * C64 (lane 0) */
    vxor.vv   v8, v8, v12
    vmv.x.s   t3, v8
    clmul    t4, a0, t2         /* T*x^64 */
    clmulh   t5, a0, t2
    clmul    t5, t5, t2
    xor      a0, t4, t5
    xor      a0, a0, t3
    addi     a1, a1, 8
    addi     a3, a3, -1
    bnez     a3, .Lcrc_t8
.Lcrc_tbyte:
    beqz    a2, .Lcrc_reduce
    li      t1, 0x100           /* C8  = x^8 mod Q */
    li      t6, 0x4c11db7       /* C32 = x^32 canonical mod Q; t2 keeps C64 */
.Lcrc_tbl:
    lbu     t3, 0(a1)
    la      t0, .Lcrc_brev8
    add     t0, t0, t3
    lbu     t0, 0(t0)          /* rev8(b) */
    clmul   t4, a0, t1         /* T*x^8 */
    clmulh  t5, a0, t1
    clmul   t5, t5, t2         /* t2 = C64 */
    xor     a0, t4, t5
    clmul   t4, t0, t6         /* rev8(b) * x^32 */
    xor     a0, a0, t4
    addi    a1, a1, 1
    addi    a2, a2, -1
    bnez    a2, .Lcrc_tbl
.Lcrc_reduce:
    li      t2, 0x4c11db7
1:
    srli    t3, a0, 32
    beqz    t3, 2f
    slli    a0, a0, 32
    srli    a0, a0, 32
    clmul   t3, t3, t2
    xor     a0, a0, t3
    j       1b
2:
    vsetivli zero, 4, e32, m1, ta, ma
    vmv.s.x v26, a0
    vbrev.v v26, v26
    vmv.x.s a0, v26          /* rev32(r) */
    not     a0, a0
    slli    a0, a0, 32
    srli    a0, a0, 32
    ret
    .size   crc32_rvv_z, .-crc32_rvv_z

    .section .rodata
    .align 3
.Lcrc_cm:
    .quad 0x00000000d3504ec7   /* x^480 mod Q (lane 0, first qword) */
    .quad 0x00000000766f1b78   /* x^416 */
    .quad 0x00000000c053585d   /* x^352 */
    .quad 0x00000000ab40b71e   /* x^288 */
    .quad 0x00000000cd8c54b5   /* x^224 */
    .quad 0x0000000017d3315d   /* x^160 */
    .quad 0x00000000f200aa66   /* x^96  */
    .quad 0x0000000100000000   /* x^32  */
.Lcrc_cm16:
    .quad 0x00000000022ffca5   /* x^992 */
    .quad 0x00000000fcd922af   /* x^928 */
    .quad 0x000000006ac7e7d7   /* x^864 */
    .quad 0x000000008762c1f6   /* x^800 */
    .quad 0x0000000034e45a63   /* x^736 */
    .quad 0x0000000054f2d5c7   /* x^672 */
    .quad 0x000000005395a0ea   /* x^608 */
    .quad 0x0000000057a84455   /* x^544 */
    .quad 0x00000000d3504ec7   /* x^480 */
    .quad 0x00000000766f1b78   /* x^416 */
    .quad 0x00000000c053585d   /* x^352 */
    .quad 0x00000000ab40b71e   /* x^288 */
    .quad 0x00000000cd8c54b5   /* x^224 */
    .quad 0x0000000017d3315d   /* x^160 */
    .quad 0x00000000f200aa66   /* x^96 */
    .quad 0x0000000100000000   /* x^32 */
.Lcrc_c64:
    .quad 0x00000000490d678d
    .quad 0x00000000490d678d
    .quad 0x00000000490d678d
    .quad 0x00000000490d678d
    .quad 0x00000000490d678d
    .quad 0x00000000490d678d
    .quad 0x00000000490d678d
    .quad 0x00000000490d678d
    .quad 0x00000000490d678d
    .quad 0x00000000490d678d
    .quad 0x00000000490d678d
    .quad 0x00000000490d678d
    .quad 0x00000000490d678d
    .quad 0x00000000490d678d
    .quad 0x00000000490d678d
    .quad 0x00000000490d678d
.Lcrc_c32:
    .quad 0x0000000100000000   /* x^32 (33-bit representative) */
.Lcrc_brev8:
    .byte 0x00, 0x80, 0x40, 0xc0, 0x20, 0xa0, 0x60, 0xe0, 0x10, 0x90, 0x50, 0xd0, 0x30, 0xb0, 0x70, 0xf0
    .byte 0x08, 0x88, 0x48, 0xc8, 0x28, 0xa8, 0x68, 0xe8, 0x18, 0x98, 0x58, 0xd8, 0x38, 0xb8, 0x78, 0xf8
    .byte 0x04, 0x84, 0x44, 0xc4, 0x24, 0xa4, 0x64, 0xe4, 0x14, 0x94, 0x54, 0xd4, 0x34, 0xb4, 0x74, 0xf4
    .byte 0x0c, 0x8c, 0x4c, 0xcc, 0x2c, 0xac, 0x6c, 0xec, 0x1c, 0x9c, 0x5c, 0xdc, 0x3c, 0xbc, 0x7c, 0xfc
    .byte 0x02, 0x82, 0x42, 0xc2, 0x22, 0xa2, 0x62, 0xe2, 0x12, 0x92, 0x52, 0xd2, 0x32, 0xb2, 0x72, 0xf2
    .byte 0x0a, 0x8a, 0x4a, 0xca, 0x2a, 0xaa, 0x6a, 0xea, 0x1a, 0x9a, 0x5a, 0xda, 0x3a, 0xba, 0x7a, 0xfa
    .byte 0x06, 0x86, 0x46, 0xc6, 0x26, 0xa6, 0x66, 0xe6, 0x16, 0x96, 0x56, 0xd6, 0x36, 0xb6, 0x76, 0xf6
    .byte 0x0e, 0x8e, 0x4e, 0xce, 0x2e, 0xae, 0x6e, 0xee, 0x1e, 0x9e, 0x5e, 0xde, 0x3e, 0xbe, 0x7e, 0xfe
    .byte 0x01, 0x81, 0x41, 0xc1, 0x21, 0xa1, 0x61, 0xe1, 0x11, 0x91, 0x51, 0xd1, 0x31, 0xb1, 0x71, 0xf1
    .byte 0x09, 0x89, 0x49, 0xc9, 0x29, 0xa9, 0x69, 0xe9, 0x19, 0x99, 0x59, 0xd9, 0x39, 0xb9, 0x79, 0xf9
    .byte 0x05, 0x85, 0x45, 0xc5, 0x25, 0xa5, 0x65, 0xe5, 0x15, 0x95, 0x55, 0xd5, 0x35, 0xb5, 0x75, 0xf5
    .byte 0x0d, 0x8d, 0x4d, 0xcd, 0x2d, 0xad, 0x6d, 0xed, 0x1d, 0x9d, 0x5d, 0xdd, 0x3d, 0xbd, 0x7d, 0xfd
    .byte 0x03, 0x83, 0x43, 0xc3, 0x23, 0xa3, 0x63, 0xe3, 0x13, 0x93, 0x53, 0xd3, 0x33, 0xb3, 0x73, 0xf3
    .byte 0x0b, 0x8b, 0x4b, 0xcb, 0x2b, 0xab, 0x6b, 0xeb, 0x1b, 0x9b, 0x5b, 0xdb, 0x3b, 0xbb, 0x7b, 0xfb
    .byte 0x07, 0x87, 0x47, 0xc7, 0x27, 0xa7, 0x67, 0xe7, 0x17, 0x97, 0x57, 0xd7, 0x37, 0xb7, 0x77, 0xf7
    .byte 0x0f, 0x8f, 0x4f, 0xcf, 0x2f, 0xaf, 0x6f, 0xef, 0x1f, 0x9f, 0x5f, 0xdf, 0x3f, 0xbf, 0x7f, 0xff
