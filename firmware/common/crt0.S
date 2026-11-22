/* Start-up code (docs/decisions.md D-042): runs after every reset.
 *   1. sp = top of RAM (PicoRV32 also sets it, spec 13.2; set here so the code does not depend
 *      on that).
 *   2. Copy .data from its load image, so a reset restarts from the initial values.
 *   3. Zero .bss.
 *   4. Call main(); if it returns, spin (the CPU stays in a known loop; nothing traps).
 * Firmware is built with -mno-relax, so gp is not used and not set.
 */
  .section .text.start, "ax"
  .globl _start
_start:
  la    sp, __stack_top

  la    t0, __data_load
  la    t1, __data_start
  la    t2, __data_end
1:
  bgeu  t1, t2, 2f
  lw    t3, 0(t0)
  sw    t3, 0(t1)
  addi  t0, t0, 4
  addi  t1, t1, 4
  j     1b
2:
  la    t1, __bss_start
  la    t2, __bss_end
3:
  bgeu  t1, t2, 4f
  sw    zero, 0(t1)
  addi  t1, t1, 4
  j     3b
4:
  call  main
5:
  j     5b
