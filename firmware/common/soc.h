/* SoC address map and registers (spec 13.3, 13.4, 13.6; accelerator CSRs spec 10.2). */
#ifndef SOC_H
#define SOC_H

#include <stdint.h>

#define REG32(addr) (*(volatile uint32_t *)(uintptr_t)(addr))

/* Regions. */
#define RAM_BASE   0x00000000u
#define ACCEL_BASE 0x10000000u /* CSR window */
#define ACCEL_BUF  0x10400000u /* buffer window */
#define GPIO_BASE  0x20000000u

/* Accelerator CSRs (spec 10.2). */
#define ACCEL_ID        0x000u
#define ACCEL_CONFIG    0x004u
#define ACCEL_CTRL      0x010u
#define ACCEL_STATUS    0x014u
#define ACCEL_IMG_SEL   0x018u
#define ACCEL_RESULT    0x01Cu
#define ACCEL_CYC_TOTAL 0x020u
#define ACCEL_CYC_MAC   0x024u
#define ACCEL_BUF_RD    0x028u
#define ACCEL_BUF_WR    0x02Cu
#define ACCEL_LAYER_CYC 0x040u
#define ACCEL_LOGIT     0x080u
#define ACCEL_DESC      0x100u
#define ACCEL_CSR(off)  REG32(ACCEL_BASE + (off))

#define ACCEL_ID_VALUE  0x434E4E31u /* "CNN1" */
#define STATUS_BUSY     0x1u
#define STATUS_DONE     0x2u
#define STATUS_ERROR    0x4u

/* Buffer window (spec 13.4): word `word` of buffer `sel`, half 0 = bits [31:0], 1 = [63:32]. */
#define BUF_IMG   0u
#define BUF_ACT0  1u
#define BUF_ACT1  2u
#define BUF_WGT   3u
#define BUF_PARAM 4u
#define ACCEL_BUF_ADDR(sel, word, half) \
  (ACCEL_BUF + ((uint32_t)(sel) << 19) + ((uint32_t)(word) << 3) + ((uint32_t)(half) << 2))
#define ACCEL_BUFW(sel, word, half) REG32(ACCEL_BUF_ADDR(sel, word, half))

/* GPIO (spec 13.6). */
#define GPIO_LEDR    0x000u
#define GPIO_HEX     0x004u
#define GPIO_SW      0x008u
#define GPIO_KEY     0x00Cu
#define GPIO_KEY_EVT 0x010u
#define GPIO_MAILBOX 0x014u
#define GPIO(off)    REG32(GPIO_BASE + (off))

/* hex7seg display codes (spec 13.6). */
#define HEX_BLANK 16u
#define HEX_DASH  17u
#define HEX_E     18u

/* Cycle counter (32 bits, spec 13.2): differences are taken modulo 2^32. */
static inline uint32_t rdcycle(void) {
  uint32_t c;
  __asm__ volatile("rdcycle %0" : "=r"(c));
  return c;
}

#endif
