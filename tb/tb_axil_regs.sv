// ---------------------------------------------------------------------------
// tb_axil_regs.sv -- Phase 2b testbench: AXI4-Lite protocol + register file
//
// Two layers of checking:
//
//  (a) CONCURRENT SVA on the slave's own outputs, armed for the whole run.
//      These check the protocol rules rather than any particular transaction:
//      once BVALID/RVALID is asserted it must hold with a stable payload until
//      its READY arrives, the two response channels are mutually exclusive
//      (this slave is depth 1), and nothing is asserted out of reset. A
//      protocol violation is caught wherever it happens, including inside a
//      test that was looking at something else.
//
//  (b) DIRECTED TESTS driven by a small AXI4-Lite master BFM: reset values,
//      every register's access type, byte strobes, reserved-space SLVERR,
//      channel ordering, and response back-pressure.
//
// BFM TIMING -- AND THE BUG THAT MADE IT THIS WAY
// -----------------------------------------------
// A transfer happens at the posedge where VALID and READY are both high. The
// obvious BFM shortcut is to drive at the negedge and test READY at that same
// negedge, assuming it cannot change before the posedge. That shortcut is
// WRONG here, and it deadlocked test 17 on the first run.
//
// This slave's ARREADY combinationally depends on AWVALID and WVALID, because
// writes take priority (see axil_slave.sv). In test 17 the read and write
// branches run concurrently, so between the negedge and the posedge the write
// branch asserted AWVALID and pulled ARREADY back down. The read branch had
// already decided its handshake had succeeded, dropped ARVALID, and waited for
// a response that was never coming.
//
// The fix, used throughout below: every DUT output the BFM makes a decision on
// is first sampled into a flop on the POSEDGE, so the BFM evaluates exactly
// the value the DUT itself saw at the edge. A BFM may only test READY at the
// negedge if READY cannot change before the posedge -- and that is a property
// of the slave, not something a reusable BFM should assume.
//
// Each channel is driven by its own task, and a write runs AW, W and B
// concurrently via fork/join. That way AW and W may handshake on different
// cycles in either order, which is legal AXI and which tests 13 and 14
// exercise deliberately.
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_axil_regs;

  localparam int unsigned ADDR_W = 12;
  localparam int unsigned DATA_W = 32;
  localparam time         TCLK   = 10ns;

  localparam logic [1:0] RESP_OKAY   = 2'b00;
  localparam logic [1:0] RESP_SLVERR = 2'b10;

  // register byte offsets
  localparam logic [11:0] A_ID           = 12'h000;
  localparam logic [11:0] A_CTRL         = 12'h004;
  localparam logic [11:0] A_STATUS       = 12'h008;
  localparam logic [11:0] A_CE_COUNT     = 12'h00C;
  localparam logic [11:0] A_UE_COUNT     = 12'h010;
  localparam logic [11:0] A_ERR_ADDR     = 12'h014;
  localparam logic [11:0] A_ERR_SYND     = 12'h018;
  localparam logic [11:0] A_IRQ_EN       = 12'h01C;
  localparam logic [11:0] A_IRQ_STATUS   = 12'h020;
  localparam logic [11:0] A_INJ_ADDR     = 12'h024;
  localparam logic [11:0] A_INJ_MASK_LO  = 12'h028;
  localparam logic [11:0] A_INJ_MASK_HI  = 12'h02C;
  localparam logic [11:0] A_INJ_MASK_CHK = 12'h030;
  localparam logic [11:0] A_INJ_CTRL     = 12'h034;

  localparam logic [31:0] ID_VALUE = 32'hECC0_0200;

  // -- clock and reset ------------------------------------------------------
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #(TCLK/2) clk = ~clk;

  // -- AXI signals ----------------------------------------------------------
  logic [ADDR_W-1:0]   awaddr;
  logic [2:0]          awprot;
  logic                awvalid, awready;
  logic [DATA_W-1:0]   wdata;
  logic [DATA_W/8-1:0] wstrb;
  logic                wvalid, wready;
  logic [1:0]          bresp;
  logic                bvalid, bready;
  logic [ADDR_W-1:0]   araddr;
  logic [2:0]          arprot;
  logic                arvalid, arready;
  logic [DATA_W-1:0]   rdata;
  logic [1:0]          rresp;
  logic                rvalid, rready;
  logic                irq;

  ecc_axil_ctrl #(
    .ADDR_W    (ADDR_W),
    .DATA_W    (DATA_W),
    .MEM_DEPTH (256)
  ) dut (
    .clk           (clk),
    .rst_n         (rst_n),
    .s_axi_awaddr  (awaddr),
    .s_axi_awprot  (awprot),
    .s_axi_awvalid (awvalid),
    .s_axi_awready (awready),
    .s_axi_wdata   (wdata),
    .s_axi_wstrb   (wstrb),
    .s_axi_wvalid  (wvalid),
    .s_axi_wready  (wready),
    .s_axi_bresp   (bresp),
    .s_axi_bvalid  (bvalid),
    .s_axi_bready  (bready),
    .s_axi_araddr  (araddr),
    .s_axi_arprot  (arprot),
    .s_axi_arvalid (arvalid),
    .s_axi_arready (arready),
    .s_axi_rdata   (rdata),
    .s_axi_rresp   (rresp),
    .s_axi_rvalid  (rvalid),
    .s_axi_rready  (rready),
    .irq_o         (irq)
  );

  // -- posedge-sampled DUT outputs ------------------------------------------
  // These hold the value the DUT itself saw at the clock edge. The BFM makes
  // every handshake decision from these, never from the live combinational
  // signal -- see the header for the deadlock that motivated this.
  logic        awready_s, wready_s, arready_s;
  logic        bvalid_s,  rvalid_s;
  logic [1:0]  bresp_s,   rresp_s;
  logic [31:0] rdata_s;

  always_ff @(posedge clk) begin
    awready_s <= awready;
    wready_s  <= wready;
    arready_s <= arready;
    bvalid_s  <= bvalid;
    bresp_s   <= bresp;
    rvalid_s  <= rvalid;
    rdata_s   <= rdata;
    rresp_s   <= rresp;
  end

  // -- scoreboard -----------------------------------------------------------
  int unsigned checks_run = 0, checks_fail = 0, sva_fail = 0;

  function automatic void note_fail(string msg);
    checks_fail++;
    $display("    FAIL: %s", msg);
  endfunction

  function automatic void expect_eq32(string what, logic [31:0] got,
                                      logic [31:0] exp);
    checks_run++;
    if (got !== exp)
      note_fail($sformatf("%s: got 0x%08h expected 0x%08h", what, got, exp));
  endfunction

  function automatic void expect_resp(string what, logic [1:0] got,
                                      logic [1:0] exp);
    checks_run++;
    if (got !== exp)
      note_fail($sformatf("%s: resp got %b expected %b", what, got, exp));
  endfunction

  function automatic void expect_bit(string what, logic got, logic exp);
    checks_run++;
    if (got !== exp)
      note_fail($sformatf("%s: got %b expected %b", what, got, exp));
  endfunction

  // -- (a) protocol assertions ----------------------------------------------
  // Once a response VALID goes high it must stay high, with its payload
  // unchanged, until the master's READY retires it. A slave that drops VALID
  // early, or mutates RDATA while waiting, breaks any master that applies
  // back-pressure.
  a_b_hold: assert property (@(posedge clk) disable iff (!rst_n)
    (bvalid && !bready) |=> (bvalid && $stable(bresp)))
    else begin sva_fail++; $error("SVA: BVALID/BRESP not held until BREADY"); end

  a_r_hold: assert property (@(posedge clk) disable iff (!rst_n)
    (rvalid && !rready) |=> (rvalid && $stable(rdata) && $stable(rresp)))
    else begin sva_fail++; $error("SVA: RVALID/RDATA/RRESP not held until RREADY"); end

  // Depth 1: a read response and a write response can never be outstanding at
  // the same time.
  a_excl: assert property (@(posedge clk) disable iff (!rst_n)
    !(bvalid && rvalid))
    else begin sva_fail++; $error("SVA: BVALID and RVALID both asserted"); end

  // Reset must leave the slave silent.
  a_reset: assert property (@(posedge clk)
    (!rst_n) |=> (!bvalid && !rvalid))
    else begin sva_fail++; $error("SVA: response valid asserted during reset"); end

  // Depth 1 again, from the other side: no channel may be admitted while a
  // response is still pending.
  a_no_accept_while_resp: assert property (@(posedge clk) disable iff (!rst_n)
    (bvalid || rvalid) |-> (!awready && !wready && !arready))
    else begin sva_fail++; $error("SVA: channel READY asserted while a response is pending"); end

  // -- (b) master BFM -------------------------------------------------------
  task automatic bfm_reset();
    awaddr  = '0; awprot = 3'b000; awvalid = 1'b0;
    wdata   = '0; wstrb  = 4'hF;   wvalid  = 1'b0;
    bready  = 1'b0;
    araddr  = '0; arprot = 3'b000; arvalid = 1'b0;
    rready  = 1'b0;
  endtask

  // Each channel drives its own task. Hold VALID, then after every posedge
  // test the POSEDGE-SAMPLED ready to learn whether the transfer happened.
  task automatic aw_phase(input logic [11:0] addr);
    @(negedge clk);
    awaddr = addr; awvalid = 1'b1;
    forever begin
      @(posedge clk);
      @(negedge clk);
      if (awready_s) break;
    end
    awvalid = 1'b0;
  endtask

  task automatic w_phase(input logic [31:0] data, input logic [3:0] strb);
    @(negedge clk);
    wdata = data; wstrb = strb; wvalid = 1'b1;
    forever begin
      @(posedge clk);
      @(negedge clk);
      if (wready_s) break;
    end
    wvalid = 1'b0;
  endtask

  task automatic ar_phase(input logic [11:0] addr);
    @(negedge clk);
    araddr = addr; arvalid = 1'b1;
    forever begin
      @(posedge clk);
      @(negedge clk);
      if (arready_s) break;
    end
    arvalid = 1'b0;
  endtask

  // Response collectors. BREADY/RREADY may lead VALID, which is legal.
  task automatic b_phase(output logic [1:0] resp);
    @(negedge clk);
    bready = 1'b1;
    forever begin
      @(posedge clk);
      @(negedge clk);
      if (bvalid_s) break;
    end
    resp   = bresp_s;
    bready = 1'b0;
  endtask

  task automatic r_phase(output logic [31:0] data, output logic [1:0] resp);
    @(negedge clk);
    rready = 1'b1;
    forever begin
      @(posedge clk);
      @(negedge clk);
      if (rvalid_s) break;
    end
    data   = rdata_s;
    resp   = rresp_s;
    rready = 1'b0;
  endtask

  task automatic axil_write(input logic [11:0] addr, input logic [31:0] data,
                            input logic [3:0] strb, output logic [1:0] resp);
    logic [1:0] r;
    fork
      aw_phase(addr);
      w_phase(data, strb);
      b_phase(r);
    join
    resp = r;
  endtask

  task automatic axil_read(input logic [11:0] addr, output logic [31:0] data,
                           output logic [1:0] resp);
    logic [31:0] d;
    logic [1:0]  r;
    fork
      ar_phase(addr);
      r_phase(d, r);
    join
    data = d;
    resp = r;
  endtask

  // convenience wrappers (shared scratch vars -- never used inside a fork)
  logic [31:0] rd;
  logic [1:0]  rsp;

  task automatic wr_ok(input logic [11:0] a, input logic [31:0] d);
    axil_write(a, d, 4'hF, rsp);
    expect_resp($sformatf("write 0x%03h", a), rsp, RESP_OKAY);
  endtask

  task automatic rd_check(input logic [11:0] a, input logic [31:0] exp);
    axil_read(a, rd, rsp);
    expect_resp($sformatf("read 0x%03h", a), rsp, RESP_OKAY);
    expect_eq32($sformatf("read 0x%03h", a), rd, exp);
  endtask

  task automatic expect_slverr_rw(input logic [11:0] a);
    axil_read(a, rd, rsp);
    expect_resp($sformatf("read 0x%03h (reserved)", a), rsp, RESP_SLVERR);
    axil_write(a, 32'hDEAD_BEEF, 4'hF, rsp);
    expect_resp($sformatf("write 0x%03h (reserved)", a), rsp, RESP_SLVERR);
  endtask

  // -- test sequence --------------------------------------------------------
  string phase = "startup";

  initial begin
    bfm_reset();
    $display("======================================================================");
    $display("tb_axil_regs -- Phase 2b: AXI4-Lite slave + register file");
    $display("======================================================================");

    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    // 1. quiet after reset
    phase = "1 reset state";
    $display("\n 1. Reset state");
    expect_bit("bvalid after reset", bvalid, 1'b0);
    expect_bit("rvalid after reset", rvalid, 1'b0);
    expect_bit("irq after reset",    irq,    1'b0);

    // 2. identity
    phase = "2 ID";
    $display("\n 2. ID register");
    rd_check(A_ID, ID_VALUE);

    // 3. reset values
    phase = "3 reset values";
    $display("\n 3. Register reset values");
    rd_check(A_CTRL,         32'h0000_0003);   // EN=1, CORR_EN=1
    rd_check(A_STATUS,       32'h0000_0000);
    rd_check(A_CE_COUNT,     32'h0000_0000);
    rd_check(A_UE_COUNT,     32'h0000_0000);
    rd_check(A_ERR_ADDR,     32'h0000_0000);
    rd_check(A_ERR_SYND,     32'h0000_FF00);   // no position recorded
    rd_check(A_IRQ_EN,       32'h0000_0000);
    rd_check(A_IRQ_STATUS,   32'h0000_0000);
    rd_check(A_INJ_ADDR,     32'h0000_0000);
    rd_check(A_INJ_MASK_LO,  32'h0000_0000);
    rd_check(A_INJ_MASK_HI,  32'h0000_0000);
    rd_check(A_INJ_MASK_CHK, 32'h0000_0000);
    rd_check(A_INJ_CTRL,     32'h0000_0000);   // write-only reads 0

    // 4. CTRL read/write, and CLR_CNT self-clearing
    phase = "4 CTRL";
    $display("\n 4. CTRL read/write");
    wr_ok(A_CTRL, 32'h0000_0000);
    rd_check(A_CTRL, 32'h0000_0000);
    wr_ok(A_CTRL, 32'h0000_0002);              // CORR_EN only
    rd_check(A_CTRL, 32'h0000_0002);
    wr_ok(A_CTRL, 32'hFFFF_FFFF);              // reserved bits must not stick
    rd_check(A_CTRL, 32'h0000_0003);           // CLR_CNT self-cleared
    wr_ok(A_CTRL, 32'h0000_0003);

    // 5. RW registers
    phase = "5 RW registers";
    $display("\n 5. RW register read/write");
    wr_ok(A_INJ_ADDR,     32'h0000_00FF);
    rd_check(A_INJ_ADDR,  32'h0000_00FF);
    wr_ok(A_INJ_MASK_LO,  32'hA5A5_5A5A);
    rd_check(A_INJ_MASK_LO, 32'hA5A5_5A5A);
    wr_ok(A_INJ_MASK_HI,  32'hDEAD_BEEF);
    rd_check(A_INJ_MASK_HI, 32'hDEAD_BEEF);
    wr_ok(A_INJ_MASK_CHK, 32'hFFFF_FFFF);
    rd_check(A_INJ_MASK_CHK, 32'h0000_00FF);   // only [7:0] implemented
    wr_ok(A_IRQ_EN,       32'hFFFF_FFFF);
    rd_check(A_IRQ_EN,    32'h0000_0007);      // only 3 sources
    wr_ok(A_IRQ_EN,       32'h0000_0005);
    rd_check(A_IRQ_EN,    32'h0000_0005);

    // 6. byte strobes -- AXI4-Lite requires WSTRB support
    phase = "6 WSTRB";
    $display("\n 6. WSTRB byte-lane writes");
    wr_ok(A_INJ_MASK_LO, 32'h0000_0000);
    axil_write(A_INJ_MASK_LO, 32'hFFFF_FFFF, 4'b0010, rsp);
    expect_resp("strobed write", rsp, RESP_OKAY);
    rd_check(A_INJ_MASK_LO, 32'h0000_FF00);    // only lane 1 written
    axil_write(A_INJ_MASK_LO, 32'h1234_5678, 4'b1001, rsp);
    expect_resp("strobed write", rsp, RESP_OKAY);
    rd_check(A_INJ_MASK_LO, 32'h1200_FF78);    // lanes 0 and 3
    axil_write(A_INJ_MASK_LO, 32'hAAAA_AAAA, 4'b0000, rsp);
    expect_resp("zero-strobe write", rsp, RESP_OKAY);
    rd_check(A_INJ_MASK_LO, 32'h1200_FF78);    // nothing changed

    // 7. writes to read-only registers are ignored, not errors
    phase = "7 RO writes";
    $display("\n 7. Read-only registers ignore writes (OKAY, no change)");
    axil_write(A_ID, 32'hDEAD_BEEF, 4'hF, rsp);
    expect_resp("write ID", rsp, RESP_OKAY);
    rd_check(A_ID, ID_VALUE);
    axil_write(A_CE_COUNT, 32'hDEAD_BEEF, 4'hF, rsp);
    expect_resp("write CE_COUNT", rsp, RESP_OKAY);
    rd_check(A_CE_COUNT, 32'h0000_0000);
    axil_write(A_STATUS, 32'hFFFF_FFFF, 4'hF, rsp);
    expect_resp("write STATUS", rsp, RESP_OKAY);
    rd_check(A_STATUS, 32'h0000_0000);

    // 8. reserved register offsets
    phase = "8 reserved regs";
    $display("\n 8. Reserved register offsets return SLVERR");
    expect_slverr_rw(12'h038);
    expect_slverr_rw(12'h03C);
    expect_slverr_rw(12'h0FC);

    // 9. reserved region between registers and the data window
    phase = "9 reserved region";
    $display("\n 9. Reserved region 0x100-0x7FF returns SLVERR");
    expect_slverr_rw(12'h100);
    expect_slverr_rw(12'h400);
    expect_slverr_rw(12'h7FC);

    // 10. data window -- PROVISIONAL for Phase 2b only
    phase = "10 data window";
    $display("\n10. Data window 0x800-0xFFF returns SLVERR (PROVISIONAL)");
    $display("    Phase 2c implements the codeword RAM; this expectation");
    $display("    changes there. It is checked now so 2b has no silent gap.");
    expect_slverr_rw(12'h800);
    expect_slverr_rw(12'hFFC);

    // 11. IRQ status is W1C and stays 0 with no error sources in 2b
    phase = "11 IRQ W1C";
    $display("\n11. IRQ_STATUS write-1-to-clear");
    wr_ok(A_IRQ_EN, 32'h0000_0007);
    axil_write(A_IRQ_STATUS, 32'h0000_0007, 4'hF, rsp);
    expect_resp("W1C IRQ_STATUS", rsp, RESP_OKAY);
    rd_check(A_IRQ_STATUS, 32'h0000_0000);
    expect_bit("irq with no events", irq, 1'b0);
    wr_ok(A_IRQ_EN, 32'h0000_0000);

    // 12. CLR_CNT clears the sticky bits (no-op here, but the path is live)
    phase = "12 CLR_CNT";
    $display("\n12. CTRL.CLR_CNT");
    axil_write(A_CTRL, 32'h0000_0007, 4'hF, rsp);
    expect_resp("CLR_CNT write", rsp, RESP_OKAY);
    rd_check(A_STATUS,   32'h0000_0000);
    rd_check(A_CE_COUNT, 32'h0000_0000);
    rd_check(A_UE_COUNT, 32'h0000_0000);

    // 13. W channel before AW channel
    phase = "13 W before AW";
    $display("\n13. Channel ordering: W before AW");
    w_phase(32'h1111_2222, 4'hF);
    aw_phase(A_INJ_MASK_HI);
    b_phase(rsp);
    expect_resp("W-then-AW write", rsp, RESP_OKAY);
    rd_check(A_INJ_MASK_HI, 32'h1111_2222);

    // 14. AW channel before W channel
    phase = "14 AW before W";
    $display("\n14. Channel ordering: AW before W");
    aw_phase(A_INJ_MASK_HI);
    w_phase(32'h3333_4444, 4'hF);
    b_phase(rsp);
    expect_resp("AW-then-W write", rsp, RESP_OKAY);
    rd_check(A_INJ_MASK_HI, 32'h3333_4444);

    // 15. write response back-pressure: BVALID must hold while BREADY is low
    phase = "15 BREADY backpressure";
    $display("\n15. Response back-pressure: BREADY held low");
    bready = 1'b0;
    fork
      aw_phase(A_INJ_ADDR);
      w_phase(32'h0000_0042, 4'hF);
    join
    while (!bvalid) @(negedge clk);
    repeat (6) begin
      @(negedge clk);
      expect_bit("BVALID held while BREADY low", bvalid, 1'b1);
      expect_resp("BRESP stable while BREADY low", bresp, RESP_OKAY);
    end
    b_phase(rsp);
    expect_resp("delayed-BREADY write", rsp, RESP_OKAY);
    rd_check(A_INJ_ADDR, 32'h0000_0042);

    // 16. read response back-pressure
    phase = "16 RREADY backpressure";
    $display("\n16. Response back-pressure: RREADY held low");
    rready = 1'b0;
    ar_phase(A_ID);
    while (!rvalid) @(negedge clk);
    repeat (6) begin
      @(negedge clk);
      expect_bit("RVALID held while RREADY low", rvalid, 1'b1);
      expect_eq32("RDATA stable while RREADY low", rdata, ID_VALUE);
    end
    r_phase(rd, rsp);
    expect_resp("delayed-RREADY read", rsp, RESP_OKAY);
    expect_eq32("delayed-RREADY data", rd, ID_VALUE);

    // 17. simultaneous read and write: the write must win, both must complete
    phase = "17 concurrent R+W";
    $display("\n17. Simultaneous read and write (write has priority)");
    wr_ok(A_INJ_MASK_LO, 32'h0000_0000);
    begin : concurrent
      logic [31:0] cr_data;
      logic [1:0]  cw_resp, cr_resp;
      int unsigned b_time, r_time;
      b_time = 0;
      r_time = 0;
      fork
        begin
          axil_write(A_INJ_MASK_LO, 32'h7777_8888, 4'hF, cw_resp);
          b_time = $time;
        end
        begin
          axil_read(A_ID, cr_data, cr_resp);
          r_time = $time;
        end
      join
      expect_resp("concurrent write", cw_resp, RESP_OKAY);
      expect_resp("concurrent read",  cr_resp, RESP_OKAY);
      expect_eq32("concurrent read data", cr_data, ID_VALUE);
      // The slave gives writes priority, so the write response must retire
      // first. This is the arbitration policy, asserted rather than assumed.
      checks_run++;
      if (!(b_time < r_time))
        note_fail($sformatf("write did not win arbitration: b@%0d r@%0d",
                            b_time, r_time));
    end
    rd_check(A_INJ_MASK_LO, 32'h7777_8888);

    // 18. back-to-back traffic
    phase = "18 back-to-back";
    $display("\n18. Back-to-back transactions");
    for (int unsigned i = 0; i < 8; i++) begin
      axil_write(A_INJ_MASK_LO, 32'h1000_0000 + i, 4'hF, rsp);
      expect_resp("b2b write", rsp, RESP_OKAY);
    end
    rd_check(A_INJ_MASK_LO, 32'h1000_0007);
    for (int unsigned i = 0; i < 8; i++) begin
      axil_read(A_ID, rd, rsp);
      expect_resp("b2b read", rsp, RESP_OKAY);
      expect_eq32("b2b read data", rd, ID_VALUE);
    end

    // -- summary ------------------------------------------------------------
    phase = "done";
    repeat (4) @(posedge clk);
    $display("\n======================================================================");
    $display("SUMMARY");
    $display("  directed checks : %0d run, %0d failed", checks_run, checks_fail);
    $display("  SVA violations  : %0d", sva_fail);
    $display("======================================================================");

    if (checks_fail != 0 || sva_fail != 0) begin
      $display("*** TEST FAILED ***");
      $fatal(1, "tb_axil_regs FAILED");
    end
    $display("*** ALL TESTS PASSED ***");
    $finish;
  end

  // Watchdog. A protocol deadlock would otherwise hang the run forever, so it
  // dumps the full bus state and the slave's internal handshake flags -- which
  // is exactly what identified the BFM bug described in the header.
  initial begin
    #500us;
    $display("\n*** TIMEOUT -- bus appears deadlocked in phase '%s' ***", phase);
    $display("  aw: valid=%b ready=%b addr=0x%03h", awvalid, awready, awaddr);
    $display("  w : valid=%b ready=%b data=0x%08h strb=%b",
             wvalid, wready, wdata, wstrb);
    $display("  b : valid=%b ready=%b resp=%b", bvalid, bready, bresp);
    $display("  ar: valid=%b ready=%b addr=0x%03h", arvalid, arready, araddr);
    $display("  r : valid=%b ready=%b data=0x%08h resp=%b",
             rvalid, rready, rdata, rresp);
    $display("  slave: state=%0d aw_hs=%b w_hs=%b ar_hs=%b is_write=%b",
             dut.u_axil.state, dut.u_axil.aw_hs, dut.u_axil.w_hs,
             dut.u_axil.ar_hs, dut.u_axil.is_write_q);
    $display("  req: valid=%b write=%b addr=0x%03h done=%b err=%b",
             dut.req_valid, dut.req_write, dut.req_addr, dut.req_done,
             dut.req_err);
    $fatal(1, "tb_axil_regs TIMEOUT");
  end

endmodule : tb_axil_regs
