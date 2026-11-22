/* buserr: a store to an unmapped address (spec 13.3: DECERR). Used only by the SoC test that
 * proves testbench/sva/soc_bus_sva.sv fails a run on an error response. */
#include "soc.h"

int main(void) {
  GPIO(GPIO_MAILBOX) = 0x5A000001u;
  REG32(0x30000000u) = 1u; /* no slave owns 0x3000_0000 */
  GPIO(GPIO_MAILBOX) = 0x600D0000u;
  for (;;) {
  }
}
