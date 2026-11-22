/* trap: an ebreak, which halts PicoRV32 with trap = 1 (spec 13.2). Used only by the SoC test that
 * proves testbench/sva/soc_bus_sva.sv fails a run on a trap. */
#include "soc.h"

int main(void) {
  GPIO(GPIO_MAILBOX) = 0x5A000001u;
  __asm__ volatile("ebreak");
  GPIO(GPIO_MAILBOX) = 0x600D0000u;
  for (;;) {
  }
}
