/* Accelerator driver: runs the preloaded network on an image in the IMG buffer (spec 9, 13.4).
 * Every function uses only full-word accesses (spec 13.3). Buffer-window functions must not be
 * called while the accelerator is busy (spec 13.4: they would wait for the run to end). */
#ifndef ACCEL_H
#define ACCEL_H

#include <stdint.h>

#define ACCEL_IMG_BYTES   784u /* one 28x28 image (spec 4) */
#define ACCEL_NUM_LOGITS  10u

/* accel_wait's limit in CPU cycles: 1,000,000 = 20 ms at 50 MHz, about 21 times one run of the
 * network (47,259 cycles, testbench/reports/perf_counters.md). Every run ends (spec 9), so the
 * limit only matters if the hardware is broken. Can be set at build time (-DACCEL_WAIT_CYCLES). */
#ifndef ACCEL_WAIT_CYCLES
#define ACCEL_WAIT_CYCLES 1000000u
#endif

int accel_present(void);                                   /* ID register reads "CNN1" */
void accel_upload_image(uint32_t slot, const int8_t *img); /* IMG slot <- 784 bytes */
void accel_download_image(uint32_t slot, int8_t *img);     /* 784 bytes <- IMG slot */
void accel_start(uint32_t slot);                           /* IMG_SEL = slot, then START */
/* Poll STATUS until DONE or until max_cycles (rdcycle) have passed since the call; returns the
 * last STATUS read: DONE clear means the wait timed out (the accelerator may still be busy). */
uint32_t accel_wait(uint32_t max_cycles);
void accel_read_logits(int32_t logits[ACCEL_NUM_LOGITS]);
uint32_t accel_result(void);
uint32_t accel_cycles(void);                               /* CYC_TOTAL of the last run */

#endif
