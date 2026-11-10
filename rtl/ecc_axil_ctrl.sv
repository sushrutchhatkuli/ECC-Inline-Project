// ---------------------------------------------------------------------------
// ecc_axil_ctrl.sv -- AXI4-Lite ECC controller
//
// PHASE 2b SCOPE: AXI4-Lite front end, address decode and the complete
// register file. The ECC datapath and codeword RAM arrive in Phase 2c.
//
// What is real in 2b:
//   - every register listed in docs/phase2_register_map.md, with correct
//     access type (RW / RO / WO / W1C), reset values and byte strobes
//   - address decode, including reserved-space SLVERR
//   - the counter / sticky-status / interrupt logic, in full
//
// What is deliberately inert in 2b:
//   - ce_event / ue_event are tied low, because nothing can observe an error
//     until the decoder is wired in. The counters, sticky bits, ERR_ADDR,
//     ERR_SYND and interrupt paths around them are fully built, so Phase 2c/2d
//     connect real events to existing logic rather than rewriting it.
//     Synthesis will fold the counters to constants until then -- that is
//     expected, and 2b's area number is not the Phase 2 area number.
//   - the data window at 0x800-0xFFF answers SLVERR. This is PROVISIONAL and
//     changes in 2c; the testbench marks that expectation as such.
//   - INJ_CTRL accepts the trigger write and does nothing with it yet.
// ---------------------------------------------------------------------------

module ecc_axil_ctrl #(
  parameter int unsigned ADDR_W    = 12,   // 4 KB aperture
  parameter int unsigned DATA_W    = 32,   // AXI4-Lite data width
  parameter int unsigned MEM_DEPTH = 256   // protected 64-bit words
) (
  input  logic                  clk,
  input  logic                  rst_n,

  // -- AXI4-Lite slave port -------------------------------------------------
  input  logic [ADDR_W-1:0]     s_axi_awaddr,
  input  logic [2:0]            s_axi_awprot,
  input  logic                  s_axi_awvalid,
  output logic                  s_axi_awready,
  input  logic [DATA_W-1:0]     s_axi_wdata,
  input  logic [DATA_W/8-1:0]   s_axi_wstrb,
  input  logic                  s_axi_wvalid,
  output logic                  s_axi_wready,
  output logic [1:0]            s_axi_bresp,
  output logic                  s_axi_bvalid,
  input  logic                  s_axi_bready,
  input  logic [ADDR_W-1:0]     s_axi_araddr,
  input  logic [2:0]            s_axi_arprot,
  input  logic                  s_axi_arvalid,
  output logic                  s_axi_arready,
  output logic [DATA_W-1:0]     s_axi_rdata,
  output logic [1:0]            s_axi_rresp,
  output logic                  s_axi_rvalid,
  input  logic                  s_axi_rready,

  // -- interrupt ------------------------------------------------------------
  output logic                  irq_o
);

  // -- identity -------------------------------------------------------------
  // Read first by software to confirm it is talking to this IP, and which
  // revision, before touching anything else.
  localparam logic [31:0] ID_VALUE = 32'hECC0_0200;

  // -- register offsets, as word indices (byte offset / 4) ------------------
  localparam logic [5:0] R_ID           = 6'h00;  // 0x00
  localparam logic [5:0] R_CTRL         = 6'h01;  // 0x04
  localparam logic [5:0] R_STATUS       = 6'h02;  // 0x08
  localparam logic [5:0] R_CE_COUNT     = 6'h03;  // 0x0C
  localparam logic [5:0] R_UE_COUNT     = 6'h04;  // 0x10
  localparam logic [5:0] R_ERR_ADDR     = 6'h05;  // 0x14
  localparam logic [5:0] R_ERR_SYND     = 6'h06;  // 0x18
  localparam logic [5:0] R_IRQ_EN       = 6'h07;  // 0x1C
  localparam logic [5:0] R_IRQ_STATUS   = 6'h08;  // 0x20
  localparam logic [5:0] R_INJ_ADDR     = 6'h09;  // 0x24
  localparam logic [5:0] R_INJ_MASK_LO  = 6'h0A;  // 0x28
  localparam logic [5:0] R_INJ_MASK_HI  = 6'h0B;  // 0x2C
  localparam logic [5:0] R_INJ_MASK_CHK = 6'h0C;  // 0x30
  localparam logic [5:0] R_INJ_CTRL     = 6'h0D;  // 0x34
  localparam logic [5:0] R_LAST         = R_INJ_CTRL;

  localparam int unsigned IRQ_W = 3;

  // -- AXI front end --------------------------------------------------------
  logic                  req_valid, req_write, req_done, req_err;
  logic [ADDR_W-1:0]     req_addr;
  logic [DATA_W-1:0]     req_wdata, req_rdata;
  logic [DATA_W/8-1:0]   req_wstrb;

  axil_slave #(
    .ADDR_W (ADDR_W),
    .DATA_W (DATA_W)
  ) u_axil (
    .clk           (clk),
    .rst_n         (rst_n),
    .s_axi_awaddr  (s_axi_awaddr),
    .s_axi_awprot  (s_axi_awprot),
    .s_axi_awvalid (s_axi_awvalid),
    .s_axi_awready (s_axi_awready),
    .s_axi_wdata   (s_axi_wdata),
    .s_axi_wstrb   (s_axi_wstrb),
    .s_axi_wvalid  (s_axi_wvalid),
    .s_axi_wready  (s_axi_wready),
    .s_axi_bresp   (s_axi_bresp),
    .s_axi_bvalid  (s_axi_bvalid),
    .s_axi_bready  (s_axi_bready),
    .s_axi_araddr  (s_axi_araddr),
    .s_axi_arprot  (s_axi_arprot),
    .s_axi_arvalid (s_axi_arvalid),
    .s_axi_arready (s_axi_arready),
    .s_axi_rdata   (s_axi_rdata),
    .s_axi_rresp   (s_axi_rresp),
    .s_axi_rvalid  (s_axi_rvalid),
    .s_axi_rready  (s_axi_rready),
    .req_valid     (req_valid),
    .req_write     (req_write),
    .req_addr      (req_addr),
    .req_wdata     (req_wdata),
    .req_wstrb     (req_wstrb),
    .req_done      (req_done),
    .req_rdata     (req_rdata),
    .req_err       (req_err)
  );

  // -- address decode -------------------------------------------------------
  // 0x000-0x0FF registers, 0x100-0x7FF reserved, 0x800-0xFFF data window.
  // addr[1:0] is ignored: AXI4-Lite byte lanes are expressed through WSTRB,
  // not through the low address bits.
  wire               sel_data = req_addr[ADDR_W-1];
  wire               sel_reg  = !req_addr[ADDR_W-1] && (req_addr[10:8] == 3'b000);
  wire [5:0]         reg_idx  = req_addr[7:2];
  wire               reg_bad  = sel_reg && (reg_idx > R_LAST);
  wire               rsvd     = (!sel_data && !sel_reg) || reg_bad;

  // -- control / status storage ---------------------------------------------
  logic              ctrl_en;        // CTRL[0]
  logic              ctrl_corr_en;   // CTRL[1]
  logic              clr_cnt;        // CTRL[2], write-only self-clearing pulse

  logic              ce_sticky, ue_sticky;
  logic [31:0]       ce_count, ue_count;
  logic [31:0]       err_addr_q;
  logic [7:0]        err_synd_q;
  logic [7:0]        err_pos_q;
  logic              err_unc_q;

  logic [IRQ_W-1:0]  irq_en, irq_status;

  logic [31:0]       inj_addr, inj_mask_lo, inj_mask_hi;
  logic [7:0]        inj_mask_chk;

  // Error events. Tied low in Phase 2b -- see the header. Phase 2c/2d drive
  // these from the decoder; everything downstream is already built.
  logic              ce_event, ue_event;
  logic [7:0]        ev_synd, ev_pos;
  logic [31:0]       ev_addr;
  assign ce_event = 1'b0;
  assign ue_event = 1'b0;
  assign ev_synd  = '0;
  assign ev_pos   = '0;
  assign ev_addr  = '0;

  wire busy = 1'b0;   // no multi-cycle operation exists yet (2c adds RMW)

  // -- register write helpers -----------------------------------------------
  // AXI4-Lite mandates WSTRB support, so a write merges per byte lane rather
  // than replacing the whole word.
  function automatic logic [31:0] wr_merge(
      input logic [31:0] old_val,
      input logic [31:0] new_val,
      input logic [3:0]  strb);
    logic [31:0] r;
    for (int unsigned i = 0; i < 4; i++) begin
      r[i*8 +: 8] = strb[i] ? new_val[i*8 +: 8] : old_val[i*8 +: 8];
    end
    return r;
  endfunction

  wire reg_wr = req_valid && req_write && sel_reg && !reg_bad;
  wire [31:0] merged_ctrl     = wr_merge({29'b0, clr_cnt, ctrl_corr_en, ctrl_en},
                                         req_wdata, req_wstrb);
  wire [31:0] merged_irq_en   = wr_merge({{(32-IRQ_W){1'b0}}, irq_en},
                                         req_wdata, req_wstrb);
  wire [31:0] merged_inj_addr = wr_merge(inj_addr,     req_wdata, req_wstrb);
  wire [31:0] merged_inj_lo   = wr_merge(inj_mask_lo,  req_wdata, req_wstrb);
  wire [31:0] merged_inj_hi   = wr_merge(inj_mask_hi,  req_wdata, req_wstrb);
  wire [31:0] merged_inj_chk  = wr_merge({24'b0, inj_mask_chk},
                                         req_wdata, req_wstrb);
  // W1C: a 1 written to a bit clears it. Only lane 0 carries IRQ bits.
  wire [IRQ_W-1:0] irq_w1c = (req_wstrb[0] ? req_wdata[IRQ_W-1:0]
                                           : {IRQ_W{1'b0}});

  // Interrupt set/clear terms, built combinationally so the sequential block
  // stays a plain loop (declarations inside an unnamed begin/end are not
  // portable across simulators).
  //   bit 0 UE     : an uncorrectable error was detected
  //   bit 1 CE     : a correctable error was detected and repaired
  //   bit 2 CE_OVF : the CE counter saturated
  wire [IRQ_W-1:0] irq_set = {
    (ce_event && (ce_count == 32'hFFFF_FFFF)),
    ce_event,
    ue_event
  };
  wire [IRQ_W-1:0] irq_clr =
    (reg_wr && (reg_idx == R_IRQ_STATUS)) ? irq_w1c : {IRQ_W{1'b0}};

  // -- register file --------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ctrl_en      <= 1'b1;        // enabled out of reset: protection is the
      ctrl_corr_en <= 1'b1;        // default, opting out must be deliberate
      clr_cnt      <= 1'b0;
      ce_sticky    <= 1'b0;
      ue_sticky    <= 1'b0;
      ce_count     <= '0;
      ue_count     <= '0;
      err_addr_q   <= '0;
      err_synd_q   <= '0;
      err_pos_q    <= 8'hFF;       // 0xFF = "no position recorded"
      err_unc_q    <= 1'b0;
      irq_en       <= '0;
      irq_status   <= '0;
      inj_addr     <= '0;
      inj_mask_lo  <= '0;
      inj_mask_hi  <= '0;
      inj_mask_chk <= '0;
    end else begin
      clr_cnt <= 1'b0;             // self-clearing: it is a pulse, not state

      if (reg_wr) begin
        unique case (reg_idx)
          R_CTRL: begin
            ctrl_en      <= merged_ctrl[0];
            ctrl_corr_en <= merged_ctrl[1];
            clr_cnt      <= merged_ctrl[2];
          end
          R_IRQ_EN:       irq_en       <= merged_irq_en[IRQ_W-1:0];
          R_IRQ_STATUS:   ;          // handled below so a set in the same
                                     // cycle is not lost
          R_INJ_ADDR:     inj_addr     <= merged_inj_addr;
          R_INJ_MASK_LO:  inj_mask_lo  <= merged_inj_lo;
          R_INJ_MASK_HI:  inj_mask_hi  <= merged_inj_hi;
          R_INJ_MASK_CHK: inj_mask_chk <= merged_inj_chk[7:0];
          R_INJ_CTRL:     ;          // trigger consumed in Phase 2d
          default:        ;          // RO registers ignore writes (BRESP OKAY)
        endcase
      end

      // -- interrupt status: set by events, cleared by W1C -------------------
      // Set beats clear. If an event arrives in the same cycle the handler
      // clears the bit, the bit stays set and irq_o stays high, so the event
      // is not lost. Dropping an interrupt is far worse than taking a
      // redundant one.
      for (int unsigned b = 0; b < IRQ_W; b++) begin
        if (irq_set[b])      irq_status[b] <= 1'b1;
        else if (irq_clr[b]) irq_status[b] <= 1'b0;
      end

      // -- counters: saturate, do not wrap -----------------------------------
      // A wrapped counter can read as zero after a storm of errors, which is
      // indistinguishable from a healthy part. Saturation is monotonic and
      // cannot lie in that direction.
      if (clr_cnt) begin
        ce_count  <= '0;
        ue_count  <= '0;
        ce_sticky <= 1'b0;
        ue_sticky <= 1'b0;
      end else begin
        if (ce_event) begin
          ce_sticky <= 1'b1;
          if (ce_count != 32'hFFFF_FFFF) ce_count <= ce_count + 32'd1;
        end
        if (ue_event) begin
          ue_sticky <= 1'b1;
          if (ue_count != 32'hFFFF_FFFF) ue_count <= ue_count + 32'd1;
        end
      end

      // -- last-error capture: UE wins, it is the more serious event ---------
      if (ue_event || ce_event) begin
        err_addr_q <= ev_addr;
        err_synd_q <= ev_synd;
        err_pos_q  <= ue_event ? 8'hFF : ev_pos;
        err_unc_q  <= ue_event;
      end
    end
  end

  // -- read mux -------------------------------------------------------------
  logic [31:0] reg_rdata;
  always_comb begin
    reg_rdata = '0;
    unique case (reg_idx)
      R_ID:           reg_rdata = ID_VALUE;
      R_CTRL:         reg_rdata = {29'b0, 1'b0, ctrl_corr_en, ctrl_en};
      R_STATUS:       reg_rdata = {29'b0, busy, ue_sticky, ce_sticky};
      R_CE_COUNT:     reg_rdata = ce_count;
      R_UE_COUNT:     reg_rdata = ue_count;
      R_ERR_ADDR:     reg_rdata = err_addr_q;
      R_ERR_SYND:     reg_rdata = {15'b0, err_unc_q, err_pos_q, err_synd_q};
      R_IRQ_EN:       reg_rdata = {{(32-IRQ_W){1'b0}}, irq_en};
      R_IRQ_STATUS:   reg_rdata = {{(32-IRQ_W){1'b0}}, irq_status};
      R_INJ_ADDR:     reg_rdata = inj_addr;
      R_INJ_MASK_LO:  reg_rdata = inj_mask_lo;
      R_INJ_MASK_HI:  reg_rdata = inj_mask_hi;
      R_INJ_MASK_CHK: reg_rdata = {24'b0, inj_mask_chk};
      R_INJ_CTRL:     reg_rdata = '0;             // write-only
      default:        reg_rdata = '0;
    endcase
  end

  // -- response ------------------------------------------------------------
  // Every Phase 2b access is a register access and completes in one cycle.
  // Phase 2c replaces this with a datapath FSM that can hold req_done low for
  // several cycles; axil_slave already supports that, so only this line and
  // the data-window branch below change.
  assign req_done  = req_valid;
  assign req_rdata = sel_reg ? reg_rdata : 32'h0;

  // SLVERR on reserved space, and -- provisionally, until Phase 2c -- on the
  // data window. Writes to read-only registers are NOT an error: they are
  // silently ignored and answered OKAY, which is the usual convention for a
  // masked field write.
  assign req_err = rsvd | sel_data;

  // -- interrupt ------------------------------------------------------------
  // Level-sensitive, not a pulse: a pulse can be missed by a slow interrupt
  // controller or lost across a clock-domain crossing, and level semantics
  // make the handler's read-act-clear sequence race-free.
  assign irq_o = |(irq_status & irq_en);

  // -- intentionally unused in Phase 2b -------------------------------------
  // AWPROT/ARPROT are accepted and ignored: this block has no privilege or
  // security model, so there is nothing to enforce. MEM_DEPTH sizes the RAM
  // that Phase 2c adds. ctrl_en and ctrl_corr_en are stored and readable now
  // and gate the datapath in 2c.
  wire _unused = &{1'b0, s_axi_awprot, s_axi_arprot, 1'b0};

endmodule : ecc_axil_ctrl
