/*
 * adler32_rvv_z.S -- vectorized Adler-32 for RVV 1.0 (VLEN=256)
 *
 * Processes 64 bytes per iteration (2x the r1 32B version):
 *   B     = sum of the 64 bytes                    (vwredsumu, u8->u16)
 *   wsum  = sum_j (64-j)*b_j                       (vwaddu + vmul + vwredsumu)
 *   s2   += 64*s1 + wsum ; s1 += B                (exact recurrence)
 * s1/s2 reduced mod 65521 every 64 blocks (4KB), overflow-safe in u32.
 *
 * X100 hardware quirks avoided:
 *   - vzext.vf2 at SEW=8 SIGILLs -> use vwaddu.vx vd, vs, zero
 *   - vsetvli zero,zero AVL SIGILLs at SEW<64 -> use register AVL (t6)
 *   - vmv.x.s sign-extends at SEW=32 -> s1/s2/reduce values always < 2^31
 *
 * unsigned long adler32_rvv_z(unsigned long adler, const unsigned char *buf,
 *                             z_size_t len);   (buf != NULL, len >= 64)
 */

    .text
    .align  2
    .globl  adler32_rvv_z
    .type   adler32_rvv_z,@function
adler32_rvv_z:
    /* a0 = adler, a1 = buf, a2 = len (>= 64) */
    srli    a3, a0, 16
    slli    a3, a3, 48
    srli    a3, a3, 48         /* a3 = s2 */
    slli    a0, a0, 48
    srli    a0, a0, 48         /* a0 = s1 */
    srli    a4, a2, 6           /* 64-byte block count */
    andi    a2, a2, 63          /* tail bytes */
    li      a5, 65521           /* BASE */
    li      a6, 64              /* blocks between reductions (64*64B=4KB) */
    beqz    a4, .Lad_tail       /* len < 64: no full block */

    la      t0, .Lad_w
    li      t6, 64                 /* AVL: e8m2 & e16m4 both VL=64 */
    vsetvli zero, t6, e16, m4, ta, ma
    vle16.v v8, (t0)            /* weights [64,63,...,1] (v8-v11) */
    vsetvli zero, t6, e8, m2, ta, ma
    vmv.v.i v26, 0              /* reduction seed (e8m2 group v26-v27) */

.Lad_loop:
    vsetvli zero, t6, e8, m2, ta, ma
    vle8.v  v0, (a1)            /* 64 bytes (v0-v1) */
    vwredsumu.vs v16, v0, v26   /* B (u16) in v16[0] (dest e16m4 v16-v19) */
    vwaddu.vx v4, v0, zero      /* widen u8->u16 (v4-v7); vzext.vf2 e8 SIGILLs */
    vsetvli zero, t6, e16, m4, ta, ma
    vmv.x.s t0, v16             /* t0 = B */
    vmul.vv v12, v4, v8         /* (64-j)*b_j (v12-v15) */
    vwredsumu.vs v20, v12, v26  /* wsum (u32) in v20[0] (dest e32m8 v20-v27) */
    vsetivli zero, 4, e32, m1, ta, ma
    vmv.x.s t1, v20             /* t1 = wsum */
    slli    t2, a0, 6           /* 64*s1 */
    add     a3, a3, t2
    add     a3, a3, t1
    add     a0, a0, t0
    addi    a1, a1, 64
    addi    a4, a4, -1
    beqz    a4, .Lad_tail
    addi    a6, a6, -1
    bnez    a6, .Lad_loop
    remu    a0, a0, a5          /* periodic mod, overflow-safe */
    remu    a3, a3, a5
    li      a6, 64
    j       .Lad_loop

.Lad_tail:
    beqz    a2, .Lad_end
.Lad_tbl:
    lbu     t0, 0(a1)
    add     a0, a0, t0
    add     a3, a3, a0
    addi    a1, a1, 1
    addi    a2, a2, -1
    bnez    a2, .Lad_tbl
.Lad_end:
    remu    a0, a0, a5
    remu    a3, a3, a5
    slli    a3, a3, 16
    or      a0, a0, a3
    ret
    .size   adler32_rvv_z, .-adler32_rvv_z

    .section .rodata
    .align 3
.Lad_w:
    .half 64, 63, 62, 61, 60, 59, 58, 57, 56, 55, 54, 53, 52, 51, 50, 49
    .half 48, 47, 46, 45, 44, 43, 42, 41, 40, 39, 38, 37, 36, 35, 34, 33
    .half 32, 31, 30, 29, 28, 27, 26, 25, 24, 23, 22, 21, 20, 19, 18, 17
    .half 16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1
