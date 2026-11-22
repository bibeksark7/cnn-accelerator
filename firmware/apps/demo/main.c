/* demo: the board demo (spec 13.8). The accelerator holds 16 preloaded images; SW[3:0] picks one.
 *
 *   idle      HEX1 shows the label of image SW[3:0] (until the first run), other digits blank
 *   KEY[0]    LEDR[0] on; the accelerator runs image SW[3:0] (timed end to end, spec 13.9); the
 *             image is copied from IMG into RAM (not timed) and the software CNN runs on it
 *             (timed); the two sets of logits are compared. Then LEDR[1] on (LEDR[2] if the
 *             accelerator reported ERROR or the logits differ), HEX0 = the predicted digit, HEX1 =
 *             the image's label, HEX5..HEX2 = the speedup in decimal (SW[9] = 0) or
 *             min(CYC_TOTAL >> 4, 0xFFFF) in hex (SW[9] = 1). Presses during a run are ignored.
 *   MAILBOX   number of completed runs (for the simulation test)
 */
#include <stdint.h>

#include "accel.h"
#include "cnn_sw.h"
#include "labels.h"
#include "soc.h"

#define LED_BUSY  0x1u
#define LED_DONE  0x2u
#define LED_ERROR 0x4u

struct demo_state {
  uint32_t runs;
  uint32_t slot;
  uint32_t result;
  uint32_t status;
  uint32_t mismatch;
  uint32_t sw_cycles;
  uint32_t e2e_cycles;
  uint32_t cyc_total;
  uint32_t speedup;
};

struct demo_state demo; /* read by the simulation test */
static int8_t image[CNN_IMG_BYTES];
static int32_t hw_logits[ACCEL_NUM_LOGITS];
static int32_t sw_logits[CNN_NUM_LOGITS];

static uint32_t hex_codes(const uint32_t digit[6]) {
  uint32_t v = 0;
  for (uint32_t d = 0; d < 6; d++) v |= (digit[d] & 0x1Fu) << (5u * d);
  return v;
}

static void show_idle(uint32_t sw) {
  uint32_t d[6] = {HEX_BLANK, slot_label[sw & 0xFu], HEX_BLANK, HEX_BLANK, HEX_BLANK, HEX_BLANK};
  GPIO(GPIO_HEX) = hex_codes(d);
}

static void show_result(uint32_t sw) {
  uint32_t d[6];
  d[0] = (demo.status & STATUS_ERROR) ? HEX_E : (demo.result & 0xFu);
  d[1] = slot_label[demo.slot];
  if (sw & 0x200u) { /* SW[9]: CYC_TOTAL >> 4 in hex, as in the Milestone 1 demo */
    uint32_t c = demo.cyc_total >> 4;
    if (c > 0xFFFFu) c = 0xFFFFu;
    for (uint32_t i = 0; i < 4; i++) d[2 + i] = (c >> (4u * i)) & 0xFu;
  } else { /* speedup in decimal, leading zeros blank */
    uint32_t v = demo.speedup;
    for (uint32_t i = 0; i < 4; i++) {
      d[2 + i] = (i == 0 || v != 0) ? v % 10u : HEX_BLANK;
      v /= 10u;
    }
  }
  GPIO(GPIO_HEX) = hex_codes(d);
}

static void run(uint32_t slot) {
  GPIO(GPIO_LEDR) = LED_BUSY;
  GPIO(GPIO_HEX) = hex_codes((uint32_t[6]){HEX_DASH, slot_label[slot], HEX_BLANK, HEX_BLANK,
                                           HEX_BLANK, HEX_BLANK});
  uint32_t t0 = rdcycle();
  accel_start(slot);
  demo.status = accel_wait();
  demo.result = accel_result();
  accel_read_logits(hw_logits);
  uint32_t t1 = rdcycle();
  demo.e2e_cycles = t1 - t0;
  demo.cyc_total = accel_cycles();

  accel_download_image(slot, image);
  uint32_t t2 = rdcycle();
  uint32_t sw_class = cnn_sw_infer(image, sw_logits);
  uint32_t t3 = rdcycle();
  demo.sw_cycles = t3 - t2;

  demo.mismatch = sw_class != demo.result;
  for (uint32_t i = 0; i < ACCEL_NUM_LOGITS; i++) demo.mismatch |= sw_logits[i] != hw_logits[i];
  uint32_t speedup = demo.e2e_cycles ? demo.sw_cycles / demo.e2e_cycles : 0;
  demo.speedup = speedup > 9999u ? 9999u : speedup;
  demo.slot = slot;
  demo.runs++;
  uint32_t err = (demo.status & STATUS_ERROR) || demo.mismatch;
  GPIO(GPIO_LEDR) = LED_DONE | (err ? LED_ERROR : 0u);
}

int main(void) {
  GPIO(GPIO_KEY_EVT) = 1u; /* ignore a press from before the firmware started */
  uint32_t shown = 0xFFFFFFFFu;
  for (;;) {
    uint32_t sw = GPIO(GPIO_SW);
    if (GPIO(GPIO_KEY_EVT) & 1u) {
      GPIO(GPIO_KEY_EVT) = 1u;
      run(sw & 0xFu);
      GPIO(GPIO_KEY_EVT) = 1u; /* presses during the run are ignored */
      GPIO(GPIO_MAILBOX) = demo.runs;
      shown = 0xFFFFFFFFu;
    }
    uint32_t view = demo.runs ? (sw & 0x200u) : (sw & 0xFu);
    if (view != shown) {
      if (demo.runs) show_result(sw);
      else show_idle(sw);
      shown = view;
    }
  }
}
