// ---------------------------------------------------------------------------
// secded_encoder.sv
//
// Hsiao SEC-DED encoder. Purely combinational: zero-cycle latency, which is
// what "in-line" ECC means -- the engine sits in the write path and adds
// propagation delay, never a stall cycle.
//
// THE ENTIRE ENCODER IN ONE LINE OF MATH
// --------------------------------------
// A codeword satisfies H . c = 0 (mod 2). Because the code is systematic,
// H = [ A | I_r ], parity equation i reads
//
//     ( XOR of data[j] over all j where A[i][j]=1 )  XOR  check[i]  =  0
//
// and the identity block means check bit i appears in equation i and nowhere
// else. Rearranging over GF(2) (where XOR is its own inverse):
//
//     check[i] = XOR of data[j] over all j where H[i][j] = 1
//
// So each check bit is one XOR-reduction of a fixed subset of the data bits.
// Row i of H literally IS the bit mask selecting that subset. Hardware:
// r independent XOR trees, no state, no sequencing.
//
// COST
// ----
// Row weights of H are all 27 (see ecc_hsiao_pkg). Each row covers 26 data
// bits plus its own check bit, so each tree XOR-reduces 26 data bits:
//   2-input XOR gates : 8 * 25 = 200
//   6-input LUTs      : ceil(26/6)=5, +1 to combine = 6 per bit -> ~48 LUTs
//   logic levels      : 2
// Balanced rows matter here: with extended Hamming the row weights would be
// lopsided and the slowest tree would set the critical path for all of them.
// ---------------------------------------------------------------------------

module secded_encoder
  import ecc_hsiao_pkg::*;
#(
  parameter int unsigned DATA_W = ECC_DATA_W,
  parameter int unsigned CHK_W  = ECC_CHK_W,
  // The parity-check matrix, one CHK_W-bit column per code bit. Defaults to
  // the generated Hsiao matrix; overridable so the module is not welded to
  // one code. H[j] is the column for code bit j.
  parameter logic [DATA_W+CHK_W-1:0][CHK_W-1:0] H = H_COL
) (
  input  logic [DATA_W-1:0]          data_i,
  output logic [CHK_W-1:0]           chk_o,    // generated check bits
  output logic [DATA_W+CHK_W-1:0]    code_o    // {chk, data} -- what you store
);

  localparam int unsigned CODE_W = DATA_W + CHK_W;

  // Transpose the column-major H into one data-bit mask per parity equation.
  // Done at elaboration time, so this is pure wiring, not logic.
  typedef logic [CHK_W-1:0][DATA_W-1:0] row_mask_t;

  function automatic row_mask_t build_row_masks();
    row_mask_t m;
    for (int unsigned i = 0; i < CHK_W; i++) begin
      m[i] = '0;
      for (int unsigned j = 0; j < DATA_W; j++) begin
        m[i][j] = H[j][i];
      end
    end
    return m;
  endfunction

  localparam row_mask_t ROW_MASK = build_row_masks();

  // check[i] = XOR-reduce( data AND row-mask i ).
  // The mask is a constant, so synthesis drops the AND entirely and leaves an
  // XOR tree over exactly the 26 selected data bits.
  for (genvar i = 0; i < int'(CHK_W); i++) begin : g_parity
    assign chk_o[i] = ^(data_i & ROW_MASK[i]);
  end

  assign code_o = {chk_o, data_i};

endmodule : secded_encoder
