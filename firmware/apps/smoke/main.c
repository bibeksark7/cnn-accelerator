/* smoke: SoC bring-up firmware for the simulation test (testbench/system/test_soc.py).
 *
 * Checks the start-up code (an initialized variable has its initial value, .bss is zero, also
 * after a reset that follows a run which changed them), reads the accelerator's ID, runs the
 * preloaded network on IMG slot 0, and leaves the results in `results` for the test to read
 * from RAM. Progress and the outcome go to the GPIO MAILBOX:
 *   0x5A00_00nn  step nn in progress
 *   0x600D_0000  done; `results` is complete
 *   0xBAD0_00cc  failed check cc
 */
#include <stdint.h>

#include "accel.h"
#include "soc.h"

#define MB_STEP(n) (0x5A000000u | (n))
#define MB_PASS    0x600D0000u
#define MB_FAIL(c) (0xBAD00000u | (c))

#define BOOT_MARKER 0x12345678u

struct smoke_results {
  uint32_t magic;
  uint32_t sw;
  uint32_t status;
  uint32_t result;
  uint32_t cycles_e2e;
  uint32_t cyc_total;
  int32_t logits[ACCEL_NUM_LOGITS];
};

volatile uint32_t boot_marker = BOOT_MARKER; /* .data */
volatile uint32_t zeroed[4];                 /* .bss */
struct smoke_results results;

static void fail(uint32_t code) {
  GPIO(GPIO_MAILBOX) = MB_FAIL(code);
  for (;;) {
  }
}

int main(void) {
  GPIO(GPIO_MAILBOX) = MB_STEP(1);
  if (boot_marker != BOOT_MARKER) fail(1);
  for (uint32_t i = 0; i < 4; i++) {
    if (zeroed[i] != 0) fail(2);
  }
  /* Change both, so a run after a reset only passes if crt0.S restores them. */
  boot_marker = ~BOOT_MARKER;
  for (uint32_t i = 0; i < 4; i++) zeroed[i] = i + 1;

  GPIO(GPIO_MAILBOX) = MB_STEP(2);
  if (!accel_present()) fail(3);

  GPIO(GPIO_MAILBOX) = MB_STEP(3);
  results.sw = GPIO(GPIO_SW);
  uint32_t t0 = rdcycle();
  accel_start(0);
  results.status = accel_wait();
  results.result = accel_result();
  accel_read_logits(results.logits);
  results.cycles_e2e = rdcycle() - t0;
  results.cyc_total = accel_cycles();
  if (results.status & STATUS_ERROR) fail(4);

  GPIO(GPIO_HEX) = (HEX_BLANK << 25) | (HEX_BLANK << 20) | (HEX_BLANK << 15) | (HEX_BLANK << 10) |
                   (HEX_BLANK << 5) | (results.result & 0xFu);
  GPIO(GPIO_LEDR) = 0x2u;
  results.magic = MB_PASS;
  GPIO(GPIO_MAILBOX) = MB_PASS;
  for (;;) {
  }
}
