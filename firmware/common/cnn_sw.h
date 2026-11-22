/* The network in software (docs/decisions.md D-044): bit-exact with model/golden.py and the
 * accelerator (spec 3), on the CPU alone. Used by the speedup measurement (spec 13.9) and the
 * board demo. Needs the generated net_params.h. */
#ifndef CNN_SW_H
#define CNN_SW_H

#include <stdint.h>

#define CNN_IMG_BYTES  784u
#define CNN_NUM_LOGITS 10u

/* Runs conv1, pool1, conv2, pool2, fc and argmax on one image of q bytes (28x28 row-major);
 * writes the 10 int32 logits and returns the class (lowest index of the maximum). */
uint32_t cnn_sw_infer(const int8_t img[CNN_IMG_BYTES], int32_t logits[CNN_NUM_LOGITS]);

#endif
