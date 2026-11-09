// ---------------------------------------------------------------------------
// secded_decoder.sv
//
// Hsiao SEC-DED decoder: corrects any single-bit error, flags any double-bit
// error as uncorrectable. Purely combinational, zero-cycle latency.
//
// FOUR STEPS, AND WHY EACH ONE IS CHEAP
// -------------------------------------
// 1. SYNDROME.  S = H . code_i.  For a stored codeword c corrupted by an
//    error vector e we read c+e, so
//        S = H.(c+e) = H.c + H.e = 0 + H.e = H.e
//    The syndrome is a function of the ERROR ALONE -- the data cancels out
//    identically. That is the one fact the whole block rests on. Same shape of
//    hardware as the encoder: CHK_W XOR trees, 27 inputs each here (26 data
//    bits + 1 check bit per row).
//
// 2. LOCATE.  A single flip at position p gives S = column p of H. So compare
//    S against all CODE_W columns in parallel; the match is the error position.
//    All columns are distinct, so at most one comparator can fire -- flip_vec
//    is one-hot-or-zero by construction, no priority encoder needed, and the
//    "decode" is really just CODE_W equality comparators feeding a mask.
//
// 3. CLASSIFY.  Because every H column has ODD weight, XOR-reducing the
//    syndrome gives the parity of the NUMBER of flipped bits:
//        ^S = sum over flipped positions of wt(column) mod 2 = (#errors) mod 2
//    One 8-input XOR separates odd-count from even-count errors. This is the
//    payoff of the Hsiao construction: the double-error-detect signal falls
//    out of the syndrome itself, with no extra overall-parity bit to generate,
//    store and check. Decision table:
//
//      S == 0                        -> clean
//      ^S == 1 and S matches a column-> exactly one error (most likely) -> CE
//      ^S == 1 and S matches nothing -> >=3 errors                      -> UE
//      ^S == 0 and S != 0            -> even error count, >=2           -> UE
//
// 4. CORRECT.  XOR the one-hot location mask into the word -- but only when
//    the error is correctable. On an uncorrectable error the data is passed
//    through UNMODIFIED and the flag is raised: inventing a "repair" from a
//    syndrome we know is lying would turn a detected fault into silent
//    corruption, which is the one outcome memory systems must never produce.
//
// WHAT THIS BLOCK CANNOT DO (state it, do not hide it)
// ---------------------------------------------------
// d_min = 4 exactly. Guaranteed: correct 1, detect 2. Beyond that:
//   - any ODD number of flips is always detected (odd syndrome parity => S!=0)
//   - 3-bit errors are never silent, but 56.3% of them alias onto a single-bit
//     column and get "corrected" into a third wrong value
//   - 8392 of the 1028790 weight-4 patterns ARE codewords, so they are
//     invisible: S = 0, no flag, wrong data
// Those numbers are measured exhaustively in model/test_hsiao.py. Needing
// better is exactly what motivates the BCH decoder in Phase 3.
// ---------------------------------------------------------------------------

module secded_decoder
  import ecc_hsiao_pkg::*;
#(
  parameter int unsigned DATA_W = ECC_DATA_W,
  parameter int unsigned CHK_W  = ECC_CHK_W,
  parameter logic [DATA_W+CHK_W-1:0][CHK_W-1:0] H = H_COL
) (
  input  logic [DATA_W+CHK_W-1:0]  code_i,      // word as read back
  output logic [DATA_W-1:0]        data_o,      // corrected data (raw if UE)
  output logic [CHK_W-1:0]         syndrome_o,
  output logic                     err_detected_o,      // any error at all
  output logic                     err_corrected_o,     // CE: single, repaired
  output logic                     err_uncorrectable_o, // UE/DUE: not repaired
  output logic [DATA_W+CHK_W-1:0]  err_pos_o            // one-hot repaired bit
);

  localparam int unsigned CODE_W = DATA_W + CHK_W;

  // -- step 1: syndrome -----------------------------------------------------
  // Same transpose trick as the encoder, but over all CODE_W bits so the
  // stored check bits are folded in too.
  typedef logic [CHK_W-1:0][CODE_W-1:0] syn_mask_t;

  function automatic syn_mask_t build_syn_masks();
    syn_mask_t m;
    for (int unsigned i = 0; i < CHK_W; i++) begin
      m[i] = '0;
      for (int unsigned j = 0; j < CODE_W; j++) begin
        m[i][j] = H[j][i];
      end
    end
    return m;
  endfunction

  localparam syn_mask_t SYN_MASK = build_syn_masks();

  logic [CHK_W-1:0] syndrome;
  for (genvar i = 0; i < int'(CHK_W); i++) begin : g_syndrome
    assign syndrome[i] = ^(code_i & SYN_MASK[i]);
  end
  assign syndrome_o = syndrome;

  // -- step 2: locate -------------------------------------------------------
  logic [CODE_W-1:0] flip_vec;
  for (genvar j = 0; j < int'(CODE_W); j++) begin : g_locate
    assign flip_vec[j] = (syndrome == H[j]);
  end

  // -- step 3: classify -----------------------------------------------------
  logic s_nonzero, s_odd, match_any, correctable;

  assign s_nonzero = |syndrome;
  assign s_odd     = ^syndrome;          // = (number of flipped bits) mod 2
  assign match_any = |flip_vec;

  // For a valid Hsiao H, match_any already implies s_odd: an even-parity
  // syndrome cannot equal an odd-weight column. The AND is therefore
  // logically redundant -- it is kept deliberately so that an H overridden
  // via the parameter with a non-Hsiao matrix degrades to "flag it" rather
  // than to silent miscorrection. Cost is one LUT input. The redundancy is
  // checked by an assertion below.
  assign correctable = s_odd & match_any;

  assign err_detected_o      = s_nonzero;
  assign err_corrected_o     = correctable;
  assign err_uncorrectable_o = s_nonzero & ~correctable;

  // -- step 4: correct ------------------------------------------------------
  logic [CODE_W-1:0] code_fixed;
  assign err_pos_o   = correctable ? flip_vec : '0;
  assign code_fixed  = code_i ^ err_pos_o;
  assign data_o      = code_fixed[DATA_W-1:0];

  // -- structural assertions (simulation only) ------------------------------
`ifndef SYNTHESIS
  // These are DEFERRED immediate assertions (`assert #0`). A plain immediate
  // assertion inside always_comb re-evaluates on every delta cycle, so it can
  // fire on a half-settled intermediate value of a purely combinational block
  // and report a failure that never exists in real time. Deferring to the end
  // of the time step evaluates them once, on settled values.
  //
  // TOOL LIMITATION: Vivado XSim 2025.1 does not implement deferred
  // assertions. It elaborates them with
  //   WARNING [XSIM 43-4455] 'Deferred Assertion is not supported'. It will
  //   be ignored.
  // so under XSim these checks DO NOT RUN. They are kept because they are
  // correct SystemVerilog and do run on Questa/VCS, but the same invariants
  // are additionally enforced from tb_secded.sv (task check_invariants), which
  // samples settled values and therefore works on every simulator. Do not
  // treat these as the coverage for those properties under XSim.
  always_comb begin
    // At most one comparator may fire: guarantees flip_vec needs no priority
    // encode and that correction is unambiguous.
    assert #0 ($countones(flip_vec) <= 1)
      else $error("secded_decoder: H columns not distinct, %0d matches for S=%h",
                  $countones(flip_vec), syndrome);
    // The redundancy claim above.
    assert #0 (!match_any || s_odd)
      else $error("secded_decoder: even-parity syndrome %h matched a column -- H is not a valid Hsiao matrix", syndrome);
    // The three outcomes are mutually exclusive and cover everything.
    assert #0 ($onehot0({err_corrected_o, err_uncorrectable_o}))
      else $error("secded_decoder: CE and UE both asserted");
    assert #0 (err_detected_o == (err_corrected_o | err_uncorrectable_o))
      else $error("secded_decoder: detected/CE/UE inconsistent");
  end
`endif

endmodule : secded_decoder
