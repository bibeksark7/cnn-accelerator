// accel_defs: constants of the accelerator's AXI4-Lite slave as the spec defines them (§1, §8,
// §10.2, §13.4). Shared by the register model, the scoreboard, coverage and the sequences.

// Build-time parameters (spec §1) and the CSR values derived from them.
localparam int N = 8, DATA_W = 8, ACC_W = 32, DESC_DEPTH = 8, DESC_WORDS = 4 * DESC_DEPTH;
localparam int LOGIT_DEPTH = 16, N_CLASSES = 10, IMG_SIZE = 784, IMG_SLOTS = 16;
localparam bit [31:0] ID_VALUE = 32'h434E_4E31;  // "CNN1"
localparam bit [31:0] CONFIG_VALUE = {8'(DESC_DEPTH), 8'(ACC_W), 8'(DATA_W), 8'(N)};

// CSR byte offsets (spec §10.2).
localparam bit [11:0] CSR_ID = 12'h000, CSR_CONFIG = 12'h004, CSR_CTRL = 12'h010,
    CSR_STATUS = 12'h014, CSR_IMG_SEL = 12'h018, CSR_RESULT = 12'h01C,
    CSR_CYC_TOTAL = 12'h020, CSR_CYC_MAC = 12'h024, CSR_BUF_RD = 12'h028,
    CSR_BUF_WR = 12'h02C, CSR_LAYER_CYC = 12'h040, CSR_LOGIT = 12'h080, CSR_DESC = 12'h100;
localparam bit [31:0] STATUS_BUSY = 32'h1, STATUS_DONE = 32'h2, STATUS_ERROR = 32'h4;

// Register classes, for prediction and coverage.
typedef enum int {
  R_ID,
  R_CONFIG,
  R_CTRL,
  R_STATUS,
  R_IMG_SEL,
  R_RESULT,
  R_CYC_TOTAL,
  R_CYC_MAC,
  R_BUF_RD,
  R_BUF_WR,
  R_LAYER_CYC,
  R_LOGIT,
  R_DESC,
  R_UNMAPPED
} csr_e;

// Buffer selects (spec §10.3) and depths in words (spec §5).
localparam int SEL_IMG = 0, SEL_ACT0 = 1, SEL_ACT1 = 2, SEL_WGT = 3, SEL_PARAM = 4;
localparam int N_BUFS = 5;
localparam int BUF_DEPTH[N_BUFS] = '{16384, 8192, 8192, 1024, 64};

// Accelerator region offsets (spec §13.4): CSR window below 4 KB, a DECERR hole up to 4 MB, the
// buffer window above.
localparam bit [22:0] BUF_WINDOW = 23'h40_0000;

// Spec §13.4: CSR accesses are never held for a run. A generous upper bound for one register
// access (or a WHI write, an error response, or an idle buffer access) from the cycle the slave
// could start serving it to its response; not an expected latency.
localparam int ACCESS_BOUND = 32;

// Descriptor fields (spec §8).
localparam int OP_CONV = 0, OP_POOL = 1, OP_FC = 2, OP_ARGMAX = 3;
localparam int BUF_IMG = 0, BUF_ACT0 = 1, BUF_ACT1 = 2, BUF_LOGIT = 3;

// Run outcomes the descriptor checker predicts (spec §9 errors), also coverage bins.
typedef enum int {
  RUN_OK,
  ERR_RESERVED_OP,
  ERR_DST_IMG_OR_LOGIT,
  ERR_SRC_EQ_DST,
  ERR_SRC_LOGIT,
  ERR_FC_DST,
  ERR_ARGMAX_SRC,
  ERR_NO_LAST,
  RUN_UNKNOWN
} run_outcome_e;

function automatic bit [22:0] buf_addr(int sel, int word, bit half);
  return BUF_WINDOW | 23'(sel) << 19 | 23'(word & 16'hFFFF) << 3 | 23'(half) << 2;
endfunction

function automatic csr_e csr_kind(bit [11:0] off);
  bit [11:0] o = off & 12'hFFC;
  case (o)
    CSR_ID: return R_ID;
    CSR_CONFIG: return R_CONFIG;
    CSR_CTRL: return R_CTRL;
    CSR_STATUS: return R_STATUS;
    CSR_IMG_SEL: return R_IMG_SEL;
    CSR_RESULT: return R_RESULT;
    CSR_CYC_TOTAL: return R_CYC_TOTAL;
    CSR_CYC_MAC: return R_CYC_MAC;
    CSR_BUF_RD: return R_BUF_RD;
    CSR_BUF_WR: return R_BUF_WR;
    default: begin
      if (o >= CSR_LAYER_CYC && o < CSR_LAYER_CYC + 4 * DESC_DEPTH) return R_LAYER_CYC;
      if (o >= CSR_LOGIT && o < CSR_LOGIT + 4 * LOGIT_DEPTH) return R_LOGIT;
      if (o >= CSR_DESC && o < CSR_DESC + 4 * DESC_WORDS) return R_DESC;
      return R_UNMAPPED;
    end
  endcase
endfunction
