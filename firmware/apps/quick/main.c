/* quick: the quick subset through the accelerator, driven by firmware (testbench/system/
 * test_soc.py, spec 13.4). For each embedded image: upload it through the buffer window into an
 * IMG slot, run it, and record STATUS, RESULT, the logits and the cycle counts in `results`. The
 * test compares `results` (read from RAM) with the golden model. MAILBOX:
 *   0x5A00_00nn  image nn in progress
 *   0x600D_00nn  done, nn images in `results`
 *   0xBAD0_00cc  failed check cc
 */
#include <stdint.h>

#include "accel.h"
#include "images.h"
#include "soc.h"

#define MB_STEP(n) (0x5A000000u | (n))
#define MB_PASS(n) (0x600D0000u | (n))
#define MB_FAIL(c) (0xBAD00000u | (c))
#define IMG_SLOTS  16u

struct quick_entry {
  uint32_t status;
  uint32_t result;
  uint32_t upload_cycles; /* the 784 image bytes through the buffer window */
  uint32_t e2e_cycles;    /* IMG_SEL + START, poll to DONE, RESULT + 10 logits (spec 13.9) */
  uint32_t cyc_total;     /* CYC_TOTAL */
  int32_t logits[ACCEL_NUM_LOGITS];
};

struct quick_results {
  uint32_t magic;
  uint32_t count;
  struct quick_entry e[NUM_IMAGES];
};

struct quick_results results;

int main(void) {
  if (!accel_present()) {
    GPIO(GPIO_MAILBOX) = MB_FAIL(1);
    for (;;) {
    }
  }
  for (uint32_t i = 0; i < NUM_IMAGES; i++) {
    struct quick_entry *e = &results.e[i];
    uint32_t slot = i % IMG_SLOTS;
    GPIO(GPIO_MAILBOX) = MB_STEP(i);
    uint32_t t0 = rdcycle();
    accel_upload_image(slot, images[i]);
    uint32_t t1 = rdcycle();
    accel_start(slot);
    e->status = accel_wait();
    e->result = accel_result();
    accel_read_logits(e->logits);
    uint32_t t2 = rdcycle();
    e->upload_cycles = t1 - t0;
    e->e2e_cycles = t2 - t1;
    e->cyc_total = accel_cycles();
    results.count = i + 1;
  }
  results.magic = MB_PASS(NUM_IMAGES);
  GPIO(GPIO_MAILBOX) = MB_PASS(NUM_IMAGES);
  for (;;) {
  }
}
