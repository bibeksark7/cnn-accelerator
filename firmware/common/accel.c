#include "accel.h"

#include "soc.h"

int accel_present(void) { return ACCEL_CSR(ACCEL_ID) == ACCEL_ID_VALUE; }

void accel_upload_image(uint32_t slot, const int8_t *img) {
  uint32_t base = slot * ACCEL_IMG_BYTES;
  for (uint32_t i = 0; i < ACCEL_IMG_BYTES; i++) {
    ACCEL_BUFW(BUF_IMG, base + i, 0) = (uint8_t)img[i]; /* low-half write: one byte */
  }
}

void accel_download_image(uint32_t slot, int8_t *img) {
  uint32_t base = slot * ACCEL_IMG_BYTES;
  for (uint32_t i = 0; i < ACCEL_IMG_BYTES; i++) {
    img[i] = (int8_t)(uint8_t)ACCEL_BUFW(BUF_IMG, base + i, 0);
  }
}

void accel_start(uint32_t slot) {
  ACCEL_CSR(ACCEL_IMG_SEL) = slot;
  ACCEL_CSR(ACCEL_CTRL) = 1u;
}

uint32_t accel_wait(uint32_t max_cycles) {
  uint32_t t0 = rdcycle();
  uint32_t status;
  do {
    status = ACCEL_CSR(ACCEL_STATUS);
  } while (!(status & STATUS_DONE) && rdcycle() - t0 < max_cycles);
  return status;
}

void accel_read_logits(int32_t logits[ACCEL_NUM_LOGITS]) {
  for (uint32_t i = 0; i < ACCEL_NUM_LOGITS; i++) {
    logits[i] = (int32_t)ACCEL_CSR(ACCEL_LOGIT + 4u * i);
  }
}

uint32_t accel_result(void) { return ACCEL_CSR(ACCEL_RESULT) & 0xFFu; }

uint32_t accel_cycles(void) { return ACCEL_CSR(ACCEL_CYC_TOTAL); }
