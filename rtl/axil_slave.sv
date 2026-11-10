// ---------------------------------------------------------------------------
// axil_slave.sv
//
// Generic AXI4-Lite slave front end. Converts the five-channel AXI4-Lite
// handshake into a single request/response pair that a register file or memory
// can serve without knowing anything about AXI:
//
//     req_valid / req_write / req_addr / req_wdata / req_wstrb   (out)
//     req_done  / req_rdata / req_err                            (in)
//
// req_valid is asserted and HELD until the core answers with req_done. The
// core may take as many cycles as it likes, which is what Phase 2c needs: a
// partial write there becomes a 4-cycle read-modify-write, and nothing in this
// module has to change to accommodate it. That is the reason the AXI front end
// is a separate module from the register file.
//
// THE HANDSHAKE RULE THIS MODULE IS BUILT AROUND
// ----------------------------------------------
// AXI's one asymmetric rule:
//
//     a source MUST NOT wait for READY before asserting VALID
//     a destination MAY wait for VALID before asserting READY
//
// So VALID must never combinationally depend on READY -- that closes a
// combinational loop between master and slave and deadlocks the bus. READY
// depending on VALID is explicitly legal.
//
// Every VALID this module drives (BVALID, RVALID) is therefore a flip-flop
// output that never looks at BREADY/RREADY in the same cycle. Every READY it
// drives (AWREADY, WREADY, ARREADY) is combinational and may inspect the
// incoming VALIDs. Once asserted, a VALID holds and its payload stays stable
// until the handshake completes.
//
// DEPTH AND ARBITRATION
// ---------------------
// One transaction in flight, no pipelining. For a control interface that is
// the right trade: it removes a whole class of ordering bugs, and the
// throughput that matters is the data path, not the register path.
//
// AW and W may arrive in either order; the write is issued once both are in.
// If a read and a write are offered at the same time the WRITE WINS, because a
// write has already consumed two channels and completing it frees the most
// resources. With a single master and depth 1 there is no starvation risk; a
// multi-master system in front of this would need a fair arbiter instead.
// ---------------------------------------------------------------------------

module axil_slave #(
  parameter int unsigned ADDR_W = 12,
  parameter int unsigned DATA_W = 32
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

  // -- simple request/response to the core ----------------------------------
  output logic                  req_valid,
  output logic                  req_write,
  output logic [ADDR_W-1:0]     req_addr,
  output logic [DATA_W-1:0]     req_wdata,
  output logic [DATA_W/8-1:0]   req_wstrb,
  input  logic                  req_done,
  input  logic [DATA_W-1:0]     req_rdata,
  input  logic                  req_err
);

  // AXI response encodings. EXOKAY (2'b01) is AXI4 exclusive-access only and
  // has no meaning in AXI4-Lite.
  localparam logic [1:0] RESP_OKAY   = 2'b00;
  localparam logic [1:0] RESP_SLVERR = 2'b10;

  typedef enum logic [1:0] {
    ST_IDLE,    // collecting AW/W, or waiting for AR
    ST_REQ,     // request presented to the core, waiting for req_done
    ST_RESP_B,  // driving BVALID
    ST_RESP_R   // driving RVALID
  } state_e;

  state_e state;

  // Channel-captured flags. Each goes high when its channel handshakes and
  // stays high until the transaction retires.
  logic aw_hs, w_hs, ar_hs;

  logic [ADDR_W-1:0]   addr_q;
  logic [DATA_W-1:0]   wdata_q;
  logic [DATA_W/8-1:0] wstrb_q;
  logic                is_write_q;

  // -- READY generation -----------------------------------------------------
  // Combinational, and allowed to look at the incoming VALIDs. The ar_hs /
  // aw_hs / w_hs terms are what enforce depth 1: once any channel of a
  // transaction has been captured, the other direction is closed off.
  assign s_axi_awready = (state == ST_IDLE) && !aw_hs && !ar_hs;
  assign s_axi_wready  = (state == ST_IDLE) && !w_hs  && !ar_hs;
  // Write priority: a read is only admitted when no write is pending or being
  // offered. Depends on AWVALID/WVALID, which is legal (READY may depend on
  // VALID) and creates no loop, since the master's VALIDs cannot depend on
  // these READYs.
  assign s_axi_arready = (state == ST_IDLE) && !ar_hs && !aw_hs && !w_hs
                         && !s_axi_awvalid && !s_axi_wvalid;

  wire aw_accept = s_axi_awvalid && s_axi_awready;
  wire w_accept  = s_axi_wvalid  && s_axi_wready;
  wire ar_accept = s_axi_arvalid && s_axi_arready;

  // A write may start as soon as both halves are in -- either already captured
  // or being captured in this very cycle.
  wire start_write = (aw_hs || aw_accept) && (w_hs || w_accept);
  wire start_read  = (ar_hs || ar_accept);

  // -- request to the core --------------------------------------------------
  assign req_valid = (state == ST_REQ);
  assign req_write = is_write_q;
  assign req_addr  = addr_q;
  assign req_wdata = wdata_q;
  assign req_wstrb = wstrb_q;

  // -- main FSM -------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state        <= ST_IDLE;
      aw_hs        <= 1'b0;
      w_hs         <= 1'b0;
      ar_hs        <= 1'b0;
      is_write_q   <= 1'b0;
      addr_q       <= '0;
      wdata_q      <= '0;
      wstrb_q      <= '0;
      s_axi_bvalid <= 1'b0;
      s_axi_bresp  <= RESP_OKAY;
      s_axi_rvalid <= 1'b0;
      s_axi_rresp  <= RESP_OKAY;
      s_axi_rdata  <= '0;
    end else begin
      // Channel capture. The READY terms above guarantee AW and AR can never
      // handshake in the same cycle, so addr_q has exactly one writer.
      if (aw_accept) begin
        aw_hs  <= 1'b1;
        addr_q <= s_axi_awaddr;
      end
      if (w_accept) begin
        w_hs    <= 1'b1;
        wdata_q <= s_axi_wdata;
        wstrb_q <= s_axi_wstrb;
      end
      if (ar_accept) begin
        ar_hs  <= 1'b1;
        addr_q <= s_axi_araddr;
      end

      case (state)
        ST_IDLE: begin
          if (start_write) begin
            is_write_q <= 1'b1;
            state      <= ST_REQ;
          end else if (start_read) begin
            is_write_q <= 1'b0;
            state      <= ST_REQ;
          end
        end

        ST_REQ: begin
          if (req_done) begin
            if (is_write_q) begin
              s_axi_bresp  <= req_err ? RESP_SLVERR : RESP_OKAY;
              s_axi_bvalid <= 1'b1;
              state        <= ST_RESP_B;
            end else begin
              s_axi_rdata  <= req_rdata;
              s_axi_rresp  <= req_err ? RESP_SLVERR : RESP_OKAY;
              s_axi_rvalid <= 1'b1;
              state        <= ST_RESP_R;
            end
          end
        end

        // BVALID/RVALID are registered and do NOT consult BREADY/RREADY to
        // decide whether to assert -- only when to drop. That is the AXI rule.
        ST_RESP_B: begin
          if (s_axi_bready) begin
            s_axi_bvalid <= 1'b0;
            aw_hs        <= 1'b0;
            w_hs         <= 1'b0;
            state        <= ST_IDLE;
          end
        end

        ST_RESP_R: begin
          if (s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
            ar_hs        <= 1'b0;
            state        <= ST_IDLE;
          end
        end

        default: state <= ST_IDLE;
      endcase
    end
  end

endmodule : axil_slave
