// timer_axi.sv - AXI-Lite programmable timer/counter
//
// registers (word addressed, addr[3:2] selects):
//   0x0 CTRL   bit0 EN, bit1 MODE (0=free-running, 1=one-shot)
//   0x4 COUNT  read-only, current count
//   0x8 TARGET read-write, compare value
//   0xC STATUS bit0 MATCH, write-1-to-clear - a real hardware match the
//              same cycle software tries to clear it wins the race, the
//              clear is dropped and MATCH stays set
//
// AW and W are accepted independently and in any order - each gets its own
// "seen" latch, and the write only fires once both have arrived. that's
// what lets a UVM test drive AW before W, W before AW, or both together
// and exercise real ordering behavior, not just a single fixed sequence.

module timer_axi #(
  parameter int WIDTH = 8
)(
  input  logic         clk,
  input  logic         rst_n,

  input  logic         awvalid,
  output logic         awready,
  input  logic  [3:0]  awaddr,

  input  logic         wvalid,
  output logic         wready,
  input  logic [31:0]  wdata,

  output logic         bvalid,
  input  logic         bready,

  input  logic         arvalid,
  output logic         arready,
  input  logic  [3:0]  araddr,

  output logic         rvalid,
  input  logic         rready,
  output logic [31:0]  rdata
);

  logic               en, mode, match;
  logic [WIDTH-1:0]    count, target;

  logic               match_comb, hold_comb, incr_comb;
  assign match_comb = (count == target);
  assign hold_comb  = mode && match_comb;
  assign incr_comb  = en && !hold_comb;

  // write side - AW/W accepted independently, write fires once both seen
  logic        aw_seen, w_seen;
  logic [3:0]  aw_addr_q;
  logic [31:0] w_data_q;
  logic        wr_fire;

  assign awready = !aw_seen;
  assign wready  = !w_seen;
  assign wr_fire = aw_seen && w_seen && !bvalid;

  // read side - kept simple, single outstanding read
  logic        rd_pending;
  logic [3:0]  rd_addr_q;

  assign arready = !rd_pending;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      en         <= 1'b0;
      mode       <= 1'b0;
      count      <= '0;
      target     <= '1;
      match      <= 1'b0;
      aw_seen    <= 1'b0;
      w_seen     <= 1'b0;
      bvalid     <= 1'b0;
      rd_pending <= 1'b0;
      rvalid     <= 1'b0;
    end else begin

      if (awvalid && awready) begin aw_seen <= 1'b1; aw_addr_q <= awaddr; end
      if (wvalid  && wready)  begin w_seen  <= 1'b1; w_data_q  <= wdata;  end

      // COUNT - increments while running, holds at TARGET in one-shot,
      // wraps in free-running mode
      if (incr_comb) begin
        if (count == {WIDTH{1'b1}}) count <= '0;
        else                        count <= count + 1'b1;
      end

      // CTRL / TARGET writes, once AW+W have both landed
      if (wr_fire) begin
        case (aw_addr_q[3:2])
          2'b00:   begin en <= w_data_q[0]; mode <= w_data_q[1]; end
          2'b10:   target <= w_data_q[WIDTH-1:0];
          default: ;
        endcase
      end

      // STATUS - W1C, hardware setting MATCH this same cycle beats a
      // software clear attempted the same cycle
      if (wr_fire && aw_addr_q[3:2] == 2'b11 && w_data_q[0] && !match_comb)
        match <= 1'b0;
      else if (match_comb)
        match <= 1'b1;

      // B response - clears aw_seen/w_seen once the master takes it
      if (wr_fire && !bvalid) bvalid <= 1'b1;
      else if (bvalid && bready) begin
        bvalid  <= 1'b0;
        aw_seen <= 1'b0;
        w_seen  <= 1'b0;
      end

      // R response
      if (arvalid && arready) begin
        rd_pending <= 1'b1;
        rd_addr_q  <= araddr;
      end
      if (rd_pending && !rvalid) rvalid <= 1'b1;
      else if (rvalid && rready) begin
        rvalid     <= 1'b0;
        rd_pending <= 1'b0;
      end
    end
  end

  always_comb begin
    case (rd_addr_q[3:2])
      2'b00:   rdata = {30'b0, mode, en};
      2'b01:   rdata = {{(32-WIDTH){1'b0}}, count};
      2'b10:   rdata = {{(32-WIDTH){1'b0}}, target};
      2'b11:   rdata = {31'b0, match};
      default: rdata = 32'b0;
    endcase
  end

endmodule
