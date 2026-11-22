/* Software CNN, plain C over the same integer parameters as the accelerator (spec 3, 4):
 * direct 3x3 convolutions on HWC tensors, requantization y*M + 2^(S-1) >>> S with saturation and
 * ReLU, 2x2 max pooling, a fully connected layer and argmax. Compiled with the same -O2 flags as
 * the rest of the firmware; the RV32M multiplier does the products. */
#include "cnn_sw.h"

#include "net_params.h"

#define C1 8
#define C2 16
#define H0 28
#define H1 26 /* conv1 output */
#define H2 13 /* pool1 output */
#define H3 11 /* conv2 output */
#define H4 5  /* pool2 output */
#define FC_K (H4 * H4 * C2)

static int8_t a1[H1 * H1 * C1];
static int8_t p1[H2 * H2 * C1];
static int8_t a2[H3 * H3 * C2];
static int8_t p2[FC_K];

/* sat8((y * M + 2^(S-1)) >>> S), then ReLU: the same as clamping to [0, 127]. */
static int8_t requant_relu(int32_t y, uint32_t m, uint32_t s) {
  int64_t p = (int64_t)y * (int64_t)m;
  int64_t r = (p + ((int64_t)1 << (s - 1))) >> s; /* arithmetic shift (GCC) */
  if (r > 127) return 127;
  if (r < 0) return 0;
  return (int8_t)r;
}

/* 3x3 convolution, stride 1, no padding: in [h][w][cin] -> out [h-2][w-2][cout]. */
static void conv3x3(const int8_t *in, int h, int w, int cin, const int8_t *wt, const int32_t *bias,
                    const uint16_t *m, const uint8_t *s, int cout, int8_t *out) {
  int ho = h - 2, wo = w - 2;
  for (int oy = 0; oy < ho; oy++) {
    for (int ox = 0; ox < wo; ox++) {
      int8_t *o = out + (oy * wo + ox) * cout;
      for (int co = 0; co < cout; co++) {
        const int8_t *wc = wt + co * 9 * cin;
        int32_t acc = bias[co];
        for (int ky = 0; ky < 3; ky++) {
          for (int kx = 0; kx < 3; kx++) {
            const int8_t *px = in + ((oy + ky) * w + (ox + kx)) * cin;
            const int8_t *wk = wc + (ky * 3 + kx) * cin;
            for (int ci = 0; ci < cin; ci++) acc += (int32_t)px[ci] * (int32_t)wk[ci];
          }
        }
        o[co] = requant_relu(acc, m[co], s[co]);
      }
    }
  }
}

/* 2x2 max pool, stride 2, floor: in [h][w][c] -> out [h/2][w/2][c]. */
static void maxpool2(const int8_t *in, int h, int w, int c, int8_t *out) {
  int ho = h / 2, wo = w / 2;
  for (int oy = 0; oy < ho; oy++) {
    for (int ox = 0; ox < wo; ox++) {
      const int8_t *r0 = in + ((2 * oy) * w + 2 * ox) * c;
      const int8_t *r1 = r0 + w * c;
      int8_t *o = out + (oy * wo + ox) * c;
      for (int ch = 0; ch < c; ch++) {
        int8_t v = r0[ch];
        if (r0[c + ch] > v) v = r0[c + ch];
        if (r1[ch] > v) v = r1[ch];
        if (r1[c + ch] > v) v = r1[c + ch];
        o[ch] = v;
      }
    }
  }
}

uint32_t cnn_sw_infer(const int8_t img[CNN_IMG_BYTES], int32_t logits[CNN_NUM_LOGITS]) {
  conv3x3(img, H0, H0, 1, &conv1_w[0][0][0][0], conv1_b, conv1_m, conv1_s, C1, a1);
  maxpool2(a1, H1, H1, C1, p1);
  conv3x3(p1, H2, H2, C1, &conv2_w[0][0][0][0], conv2_b, conv2_m, conv2_s, C2, a2);
  maxpool2(a2, H3, H3, C2, p2);
  uint32_t best = 0;
  for (uint32_t n = 0; n < CNN_NUM_LOGITS; n++) {
    int32_t acc = fc_b[n];
    const int8_t *wn = fc_w[n];
    for (int k = 0; k < FC_K; k++) acc += (int32_t)p2[k] * (int32_t)wn[k];
    logits[n] = acc;
    if (acc > logits[best]) best = n; /* strictly greater: ties keep the lowest index */
  }
  return best;
}
