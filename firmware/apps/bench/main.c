/* bench: the speedup measurement of spec 13.9 (testbench/system/test_soc.py, scripts/
 * soc_speedup.py). For each embedded image, timed with rdcycle:
 *   software       cnn_sw_infer() on the image in RAM (cycles and instructions retired)
 *   upload         the 784 bytes into IMG slot 0 through the buffer window
 *   end to end     IMG_SEL + START, poll STATUS to DONE, read RESULT and the 10 logits
 * plus CYC_TOTAL, and both sets of logits, which the test checks against the golden model.
 * MAILBOX: 0x5A00_00nn image nn in progress, 0x600D_00nn done (nn images), 0xBAD0_00cc failed.
 */
#include <stdint.h>

#include "accel.h"
#include "cnn_sw.h"
#include "images.h"
#include "soc.h"

#define MB_STEP(n) (0x5A000000u | (n))
#define MB_PASS(n) (0x600D0000u | (n))
#define MB_FAIL(c) (0xBAD00000u | (c))

struct bench_entry {
  uint32_t sw_cycles;
  uint32_t sw_instret;
  uint32_t upload_cycles;
  uint32_t e2e_cycles;
  uint32_t cyc_total;
  uint32_t sw_class;
  uint32_t accel_class;
  uint32_t status;
  int32_t sw_logits[CNN_NUM_LOGITS];
  int32_t accel_logits[ACCEL_NUM_LOGITS];
};

struct bench_results {
  uint32_t magic;
  uint32_t count;
  struct bench_entry e[NUM_IMAGES];
};

struct bench_results results;

int main(void) {
  if (!accel_present()) {
    GPIO(GPIO_MAILBOX) = MB_FAIL(1);
    for (;;) {
    }
  }
  for (uint32_t i = 0; i < NUM_IMAGES; i++) {
    struct bench_entry *e = &results.e[i];
    GPIO(GPIO_MAILBOX) = MB_STEP(i);
    uint32_t n0 = rdinstret();
    uint32_t t0 = rdcycle();
    e->sw_class = cnn_sw_infer(images[i], e->sw_logits);
    uint32_t t1 = rdcycle();
    e->sw_instret = rdinstret() - n0;
    accel_upload_image(0, images[i]);
    uint32_t t2 = rdcycle();
    accel_start(0);
    e->status = accel_wait();
    e->accel_class = accel_result();
    accel_read_logits(e->accel_logits);
    uint32_t t3 = rdcycle();
    e->sw_cycles = t1 - t0;
    e->upload_cycles = t2 - t1;
    e->e2e_cycles = t3 - t2;
    e->cyc_total = accel_cycles();
    results.count = i + 1;
  }
  results.magic = MB_PASS(NUM_IMAGES);
  GPIO(GPIO_MAILBOX) = MB_PASS(NUM_IMAGES);
  for (;;) {
  }
}
