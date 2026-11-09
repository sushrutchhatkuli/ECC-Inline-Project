// ---------------------------------------------------------------------------
// tb_secded.sv -- self-checking testbench for the Hsiao SEC-DED (72,64) core
//
// VERIFICATION STRATEGY
// ---------------------
// Two independent kinds of checking, because they catch different bugs:
//
//  (a) GOLDEN-MODEL REPLAY (test 1). Replays vectors emitted by the Python
//      model: data, expected codeword, error mask, expected data/syndrome/
//      flags. This pins the RTL to the model's EXACT parity matrix. A
//      different-but-still-valid Hsiao matrix in the RTL would pass every
//      self-consistency check below while silently being a different code --
//      only comparing against the model catches that.
//
//  (b) SELF-CHECKING EXHAUSTIVE INJECTION (tests 2-5). Encodes a word, flips
//      bits, and demands that what comes out equals what went in. This needs
//      no reference at all: it checks the PROPERTY ("a single flip is always
//      repaired") rather than agreement with another implementation, so it
//      would still catch a bug that had been copied into the model.
//
// Exhaustive means exhaustive. With a 72-bit block there are only 72 single-bit
// and 2556 double-bit error patterns, so we enumerate every one rather than
// sampling -- "100% of single-bit errors corrected" is a complete statement
// over the error space, not a confidence interval.
//
// The DUTs are purely combinational, so there is no clock. Inputs are driven,
// then #1 lets the time step settle (which is also when the DUT's deferred
// assertions evaluate) before outputs are sampled.
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_secded;

  import ecc_hsiao_pkg::*;

  localparam int unsigned DATA_W = ECC_DATA_W;
  localparam int unsigned CHK_W  = ECC_CHK_W;
  localparam int unsigned CODE_W = ECC_CODE_W;

  // sim/run_xsim.sh stages the generated vector file into the simulator's
  // working directory, so a bare filename is enough and no host path ever has
  // to survive quoting through Vivado's cmd.exe batch wrappers.
  // Override with +VECTORS=<path> for other flows.
  localparam string DEFAULT_VECTOR_FILE = "secded_vectors.txt";
  string vector_file;

  // -- DUTs -----------------------------------------------------------------
  logic [DATA_W-1:0] enc_data;
  logic [CHK_W-1:0]  enc_chk;
  logic [CODE_W-1:0] enc_code;

  secded_encoder u_enc (
    .data_i (enc_data),
    .chk_o  (enc_chk),
    .code_o (enc_code)
  );

  logic [CODE_W-1:0] dec_code;
  logic [DATA_W-1:0] dec_data;
  logic [CHK_W-1:0]  dec_syn;
  logic              dec_det, dec_cor, dec_unc;
  logic [CODE_W-1:0] dec_pos;

  secded_decoder u_dec (
    .code_i              (dec_code),
    .data_o              (dec_data),
    .syndrome_o          (dec_syn),
    .err_detected_o      (dec_det),
    .err_corrected_o     (dec_cor),
    .err_uncorrectable_o (dec_unc),
    .err_pos_o           (dec_pos)
  );

  // -- scoreboard -----------------------------------------------------------
  int unsigned checks_run  = 0;
  int unsigned checks_fail = 0;
  int unsigned fail_report = 0;          // failures printed so far
  localparam int unsigned MAX_FAIL_PRINT = 20;

  // per-test tallies
  int unsigned n_vec, n_vec_fail;
  int unsigned n_clean, n_clean_fail;
  int unsigned n_sec, n_sec_fixed;
  int unsigned n_ded, n_ded_flagged, n_ded_miscorrect, n_ded_silent;
  int unsigned n_tri, n_tri_flagged, n_tri_miscorrect, n_tri_silent;

  function automatic void note_fail(string msg);
    checks_fail++;
    if (fail_report < MAX_FAIL_PRINT) begin
      fail_report++;
      $display("    FAIL: %s", msg);
    end else if (fail_report == MAX_FAIL_PRINT) begin
      fail_report++;
      $display("    ... further failures suppressed");
    end
  endfunction

  // -- structural invariants of the decoder output ---------------------------
  // These duplicate the assertions inside secded_decoder.sv on purpose: those
  // are written as deferred assertions (`assert #0`), and Vivado XSim 2025.1
  // silently IGNORES deferred assertions. Checking them here -- on settled
  // values, after the #1 -- means the properties are genuinely exercised in
  // this flow rather than only looking like they are.
  int unsigned n_inv, n_inv_fail;

  task automatic check_invariants();
    n_inv++;
    // Correction must be unambiguous: the located position is one-hot or zero.
    if (!$onehot0(dec_pos)) begin
      n_inv_fail++;
      note_fail($sformatf("invariant: err_pos not one-hot0 (%0d bits) s=%h",
                          $countones(dec_pos), dec_syn));
    end
    // The three outcomes partition the space.
    if (dec_cor === 1'b1 && dec_unc === 1'b1) begin
      n_inv_fail++;
      note_fail($sformatf("invariant: CE and UE both set, s=%h", dec_syn));
    end
    if (dec_det !== (dec_cor | dec_unc)) begin
      n_inv_fail++;
      note_fail($sformatf("invariant: detected != CE|UE, s=%h", dec_syn));
    end
    // "Detected" must mean exactly "syndrome nonzero".
    if (dec_det !== (dec_syn !== '0)) begin
      n_inv_fail++;
      note_fail($sformatf("invariant: detected != (syndrome!=0), s=%h", dec_syn));
    end
    // A correction may only happen on an odd-parity syndrome, and must name a
    // position; no correction means no position touched.
    if (dec_cor === 1'b1 && (^dec_syn) !== 1'b1) begin
      n_inv_fail++;
      note_fail($sformatf("invariant: corrected on even-parity syndrome %h", dec_syn));
    end
    if (dec_cor === 1'b1 && $countones(dec_pos) != 1) begin
      n_inv_fail++;
      note_fail($sformatf("invariant: corrected but err_pos=%h", dec_pos));
    end
    if (dec_cor !== 1'b1 && dec_pos !== '0) begin
      n_inv_fail++;
      note_fail($sformatf("invariant: err_pos=%h without correction", dec_pos));
    end
  endtask

  // Drive the decoder and let the combinational cone settle.
  task automatic apply_code(input logic [CODE_W-1:0] cw);
    dec_code = cw;
    #1;
    check_invariants();
  endtask

  task automatic apply_data(input logic [DATA_W-1:0] d);
    enc_data = d;
    #1;
  endtask

  // -- test 1: golden-model vector replay -----------------------------------
  task automatic test_vectors();
    int                     fd, nf, rc;
    string                  line;
    logic [DATA_W-1:0]      v_data, v_exp_data;
    logic [CODE_W-1:0]      v_code, v_err;
    logic [CHK_W-1:0]       v_exp_syn;
    logic                   v_det, v_cor, v_unc;

    $display("\n1. Golden-model vector replay (%s)", vector_file);
    fd = $fopen(vector_file, "r");
    if (fd == 0) begin
      $display("    FAIL: cannot open vector file -- run: python model/gen_rtl.py");
      checks_fail++;
      return;
    end

    while (!$feof(fd)) begin
      line = "";
      rc = $fgets(line, fd);
      if (rc <= 0) break;
      // Comment and blank lines simply fail to parse 8 fields, so the count
      // check is also the comment filter.
      nf = $sscanf(line, "%h %h %h %h %h %b %b %b",
                   v_data, v_code, v_err, v_exp_data, v_exp_syn,
                   v_det, v_cor, v_unc);
      if (nf != 8) continue;

      n_vec++;
      checks_run++;

      // (i) encoder must produce the model's codeword, bit for bit.
      apply_data(v_data);
      if (enc_code !== v_code) begin
        n_vec_fail++;
        note_fail($sformatf("enc data=%h got code=%h exp=%h",
                            v_data, enc_code, v_code));
        continue;
      end

      // (ii) decoder must reproduce the model's data, syndrome and flags.
      apply_code(v_code ^ v_err);
      if (dec_data !== v_exp_data || dec_syn !== v_exp_syn ||
          dec_det !== v_det || dec_cor !== v_cor || dec_unc !== v_unc) begin
        n_vec_fail++;
        note_fail($sformatf(
          "dec code=%h err=%h | got d=%h s=%h det=%b cor=%b unc=%b | exp d=%h s=%h det=%b cor=%b unc=%b",
          v_code, v_err, dec_data, dec_syn, dec_det, dec_cor, dec_unc,
          v_exp_data, v_exp_syn, v_det, v_cor, v_unc));
      end
    end
    $fclose(fd);

    $display("    %0d vectors replayed, %0d mismatches", n_vec, n_vec_fail);
    if (n_vec == 0) begin
      $display("    FAIL: vector file parsed 0 vectors");
      checks_fail++;
    end
  endtask

  // -- test 2: error-free path ----------------------------------------------
  task automatic test_clean(const ref logic [DATA_W-1:0] pats[]);
    $display("\n2. Error-free encode/decode round trip");
    foreach (pats[i]) begin
      apply_data(pats[i]);
      apply_code(enc_code);
      n_clean++;
      checks_run++;
      if (dec_data !== pats[i] || dec_syn !== '0 ||
          dec_det !== 1'b0 || dec_cor !== 1'b0 || dec_unc !== 1'b0) begin
        n_clean_fail++;
        note_fail($sformatf("clean data=%h got d=%h s=%h det=%b cor=%b unc=%b",
                            pats[i], dec_data, dec_syn, dec_det, dec_cor, dec_unc));
      end
    end
    // Every one-hot data word too -- catches a swapped or dropped H column
    // that random patterns can mask.
    for (int unsigned j = 0; j < DATA_W; j++) begin
      apply_data(DATA_W'(1) << j);
      apply_code(enc_code);
      n_clean++;
      checks_run++;
      if (dec_data !== (DATA_W'(1) << j) || dec_det !== 1'b0) begin
        n_clean_fail++;
        note_fail($sformatf("clean one-hot bit %0d got d=%h det=%b",
                            j, dec_data, dec_det));
      end
    end
    $display("    %0d clean words, %0d mismatches", n_clean, n_clean_fail);
  endtask

  // -- test 3: EXHAUSTIVE single-bit correction ------------------------------
  task automatic test_sec(const ref logic [DATA_W-1:0] pats[]);
    logic [CODE_W-1:0] cw;
    $display("\n3. Single-bit errors: EXHAUSTIVE (all %0d positions x %0d data words)",
             CODE_W, pats.size());
    foreach (pats[i]) begin
      apply_data(pats[i]);
      cw = enc_code;
      for (int unsigned p = 0; p < CODE_W; p++) begin
        apply_code(cw ^ (CODE_W'(1) << p));
        n_sec++;
        checks_run++;
        if (dec_data === pats[i] && dec_cor === 1'b1 && dec_det === 1'b1 &&
            dec_unc === 1'b0 && dec_pos === (CODE_W'(1) << p) &&
            dec_syn === H_COL[p]) begin
          n_sec_fixed++;
        end else begin
          note_fail($sformatf(
            "SEC data=%h flip=%0d got d=%h s=%h det=%b cor=%b unc=%b pos=%h",
            pats[i], p, dec_data, dec_syn, dec_det, dec_cor, dec_unc, dec_pos));
        end
      end
    end
    $display("    corrected %0d/%0d  (%0d.%02d%%)", n_sec_fixed, n_sec,
             (100 * n_sec_fixed) / n_sec,
             ((10000 * n_sec_fixed) / n_sec) % 100);
    if (n_sec_fixed != n_sec) checks_fail++;
  endtask

  // -- test 4: EXHAUSTIVE double-bit detection -------------------------------
  task automatic test_ded(const ref logic [DATA_W-1:0] pats[]);
    logic [CODE_W-1:0] cw, bad;
    $display("\n4. Double-bit errors: EXHAUSTIVE (all %0d pairs x %0d data words)",
             (CODE_W * (CODE_W - 1)) / 2, pats.size());
    foreach (pats[i]) begin
      apply_data(pats[i]);
      cw = enc_code;
      for (int unsigned a = 0; a < CODE_W - 1; a++) begin
        for (int unsigned b = a + 1; b < CODE_W; b++) begin
          bad = cw ^ (CODE_W'(1) << a) ^ (CODE_W'(1) << b);
          apply_code(bad);
          n_ded++;
          checks_run++;
          if (dec_unc === 1'b1 && dec_det === 1'b1 && dec_cor === 1'b0) begin
            n_ded_flagged++;
            // On a UE the decoder must PASS THE WORD THROUGH UNTOUCHED, so the
            // reference here is the CORRUPTED data field, not the original.
            // Comparing against the original would be demanding a repair the
            // code cannot make -- a d_min=4 code has no way to undo 2 flips,
            // and inventing one is exactly the silent corruption the UE flag
            // exists to prevent.
            if (dec_data !== bad[DATA_W-1:0]) begin
              note_fail($sformatf(
                "DED altered the word on UE: a=%0d b=%0d got d=%h exp passthrough %h",
                a, b, dec_data, bad[DATA_W-1:0]));
            end
          end else if (dec_cor === 1'b1) begin
            n_ded_miscorrect++;
            note_fail($sformatf("DED MISCORRECTED a=%0d b=%0d data=%h s=%h",
                                a, b, pats[i], dec_syn));
          end else begin
            n_ded_silent++;
            note_fail($sformatf("DED SILENT a=%0d b=%0d data=%h s=%h",
                                a, b, pats[i], dec_syn));
          end
        end
      end
    end
    $display("    flagged uncorrectable %0d/%0d  (miscorrected %0d, silent %0d)",
             n_ded_flagged, n_ded, n_ded_miscorrect, n_ded_silent);
    if (n_ded_flagged != n_ded) checks_fail++;
  endtask

  // -- test 5: EXHAUSTIVE triple-bit -- must never be silent -----------------
  task automatic test_triple(input logic [DATA_W-1:0] d);
    logic [CODE_W-1:0] cw;
    $display("\n5. Triple-bit errors: EXHAUSTIVE (all %0d patterns)",
             (CODE_W * (CODE_W - 1) * (CODE_W - 2)) / 6);
    apply_data(d);
    cw = enc_code;
    for (int unsigned a = 0; a < CODE_W - 2; a++) begin
      for (int unsigned b = a + 1; b < CODE_W - 1; b++) begin
        for (int unsigned c = b + 1; c < CODE_W; c++) begin
          apply_code(cw ^ (CODE_W'(1) << a) ^ (CODE_W'(1) << b)
                        ^ (CODE_W'(1) << c));
          n_tri++;
          checks_run++;
          if (dec_det !== 1'b1) begin
            n_tri_silent++;
            note_fail($sformatf("TRIPLE SILENT %0d,%0d,%0d s=%h", a, b, c, dec_syn));
          end else if (dec_cor === 1'b1) begin
            n_tri_miscorrect++;      // expected for d_min=4, not a failure
          end else begin
            n_tri_flagged++;
          end
        end
      end
    end
    $display("    detected %0d/%0d (0 silent required)", n_tri - n_tri_silent, n_tri);
    $display("    split: %0d flagged UE, %0d miscorrected, %0d silent",
             n_tri_flagged, n_tri_miscorrect, n_tri_silent);
    $display("    NOTE miscorrection of 3-bit errors is EXPECTED at d_min=4");
    $display("         (guarantee is correct-1/detect-2). Silent escapes must");
    $display("         be zero, and are, because every H column has odd weight.");
    if (n_tri_silent != 0) checks_fail++;
  endtask

  // -- test 6: syndrome must not depend on the data --------------------------
  task automatic test_syndrome_independence(const ref logic [DATA_W-1:0] pats[]);
    logic [CHK_W-1:0] ref_syn;
    int unsigned fails = 0;
    $display("\n6. Syndrome depends only on the error (S = H.e, not H.r)");
    for (int unsigned p = 0; p < CODE_W; p++) begin
      ref_syn = H_COL[p];
      foreach (pats[i]) begin
        apply_data(pats[i]);
        apply_code(enc_code ^ (CODE_W'(1) << p));
        checks_run++;
        if (dec_syn !== ref_syn) begin
          fails++;
          note_fail($sformatf("syndrome varied with data: pos=%0d data=%h s=%h exp=%h",
                              p, pats[i], dec_syn, ref_syn));
        end
      end
    end
    $display("    %0d positions x %0d data words, %0d mismatches",
             CODE_W, pats.size(), fails);
    if (fails != 0) checks_fail++;
  endtask

  // -- main -----------------------------------------------------------------
  logic [DATA_W-1:0] patterns[];

  initial begin
    if (!$value$plusargs("VECTORS=%s", vector_file))
      vector_file = DEFAULT_VECTOR_FILE;

    patterns = new[16];
    // Corner patterns first: all-zero and all-one are where mask/polarity and
    // reduction-initialisation bugs live.
    patterns[0]  = 64'h0000_0000_0000_0000;
    patterns[1]  = 64'hFFFF_FFFF_FFFF_FFFF;
    patterns[2]  = 64'hAAAA_AAAA_AAAA_AAAA;
    patterns[3]  = 64'h5555_5555_5555_5555;
    patterns[4]  = 64'h0000_0000_FFFF_FFFF;
    patterns[5]  = 64'hFFFF_FFFF_0000_0000;
    patterns[6]  = 64'h0123_4567_89AB_CDEF;
    patterns[7]  = 64'hDEAD_BEEF_CAFE_BABE;
    patterns[8]  = 64'h0000_0000_0000_0001;
    patterns[9]  = 64'h8000_0000_0000_0000;
    patterns[10] = 64'hFFFF_0000_FFFF_0000;
    patterns[11] = 64'h0F0F_0F0F_0F0F_0F0F;
    patterns[12] = 64'h1234_5678_9ABC_DEF0;
    patterns[13] = 64'hA5A5_A5A5_5A5A_5A5A;
    patterns[14] = 64'h7FFF_FFFF_FFFF_FFFE;
    patterns[15] = 64'hC0FF_EE00_1234_5678;

    $display("======================================================================");
    $display("tb_secded -- Hsiao SEC-DED (%0d,%0d) self-checking testbench",
             CODE_W, DATA_W);
    $display("======================================================================");

    test_vectors();
    test_clean(patterns);
    test_sec(patterns);
    test_ded(patterns);
    test_triple(64'h0123_4567_89AB_CDEF);
    test_syndrome_independence(patterns);

    $display("\n======================================================================");
    $display("SUMMARY");
    $display("  vector replay        : %0d run, %0d mismatch", n_vec, n_vec_fail);
    $display("  clean round trip     : %0d run, %0d mismatch", n_clean, n_clean_fail);
    $display("  single-bit corrected : %0d / %0d", n_sec_fixed, n_sec);
    $display("  double-bit flagged UE: %0d / %0d", n_ded_flagged, n_ded);
    $display("  triple-bit detected  : %0d / %0d  (silent: %0d)",
             n_tri - n_tri_silent, n_tri, n_tri_silent);
    $display("  decoder invariants   : %0d samples, %0d violations", n_inv, n_inv_fail);
    $display("  total checks         : %0d", checks_run);
    $display("======================================================================");

    if (checks_fail != 0) begin
      $display("*** TEST FAILED: %0d failing checks ***", checks_fail);
      $fatal(1, "tb_secded FAILED");
    end
    $display("*** ALL TESTS PASSED ***");
    $finish;
  end

endmodule : tb_secded
