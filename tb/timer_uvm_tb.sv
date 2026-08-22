// timer_uvm_tb.sv - UVM env for timer_axi: driver, monitor, a golden
// reference model, a scoreboard, and functional coverage as distinct
// components, wired together in an agent/env the way a normal UVM
// testbench is structured. one file for compactness, but the components
// themselves aren't collapsed into each other.

import uvm_pkg::*;
`include "uvm_macros.svh"

// ---------------------------------------------------------------- item ---

class timer_item extends uvm_sequence_item;
  `uvm_object_utils(timer_item)

  rand bit        is_write;
  rand bit [3:0]  addr;
  rand bit [31:0] wdata;
  rand bit [1:0]  order;   // write only: 0=simultaneous 1=AW-first 2=W-first
       bit [31:0] rdata;
       bit [1:0]  mon_order; // filled in by the monitor, for coverage

  constraint c_addr  { addr  inside {4'h0, 4'h4, 4'h8, 4'hC}; }
  constraint c_order { order inside {2'd0, 2'd1, 2'd2}; }

  function new(string name = "timer_item");
    super.new(name);
  endfunction
endclass

// ------------------------------------------------------------- driver ---

class timer_driver extends uvm_driver #(timer_item);
  `uvm_component_utils(timer_driver)
  virtual timer_if vif;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual timer_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "driver: vif not set")
  endfunction

  // drives AW/W in whichever order the item asks for - this is what lets
  // a sequence target register-access ordering on purpose instead of
  // whatever a single fixed sequence happens to produce
  task do_write(timer_item req);
    case (req.order)
      2'd1: begin // AW first
        vif.awvalid <= 1; vif.awaddr <= req.addr; @(posedge vif.clk);
        vif.awvalid <= 0;
        vif.wvalid  <= 1; vif.wdata  <= req.wdata; @(posedge vif.clk);
        vif.wvalid  <= 0;
      end
      2'd2: begin // W first
        vif.wvalid  <= 1; vif.wdata  <= req.wdata; @(posedge vif.clk);
        vif.wvalid  <= 0;
        vif.awvalid <= 1; vif.awaddr <= req.addr; @(posedge vif.clk);
        vif.awvalid <= 0;
      end
      default: begin // simultaneous
        vif.awvalid <= 1; vif.awaddr <= req.addr;
        vif.wvalid  <= 1; vif.wdata  <= req.wdata;
        @(posedge vif.clk);
        vif.awvalid <= 0; vif.wvalid <= 0;
      end
    endcase
    while (!vif.bvalid) @(posedge vif.clk);
    vif.bready <= 1; @(posedge vif.clk); vif.bready <= 0;
  endtask

  task do_read(timer_item req);
    vif.arvalid <= 1; vif.araddr <= req.addr;
    @(posedge vif.clk);
    vif.arvalid <= 0;
    while (!vif.rvalid) @(posedge vif.clk);
    req.rdata = vif.rdata;
    vif.rready <= 1; @(posedge vif.clk); vif.rready <= 0;
  endtask

  task run_phase(uvm_phase phase);
    // wait for reset to actually deassert before driving anything - a real
    // EDA Playground run caught this the hard way: the sequence's first
    // item fires at time 0 while tb_top is still holding rst_n low, AW/W/AR
    // get asserted for exactly one cycle assuming that's always enough to
    // be accepted, but the DUT's accept logic is bypassed during reset (the
    // reset branch has priority every cycle), so that first transfer is
    // silently dropped and the driver hangs forever waiting for a response
    // that's never coming. same class of reset-race bug the full project
    // hit in its own driver, different symptom.
    @(posedge vif.clk iff vif.rst_n);
    forever begin
      timer_item req;
      seq_item_port.get_next_item(req);
      if (req.is_write) do_write(req);
      else               do_read(req);
      seq_item_port.item_done();
    end
  endtask
endclass

// ------------------------------------------------------------ monitor ---

// watches the bus passively, reconstructs completed transactions, and
// tags each write with which of AW/W was accepted first (or same cycle)
// so coverage can confirm all three orderings actually happened on the
// bus, not just that the driver asked for them.

class timer_monitor extends uvm_monitor;
  `uvm_component_utils(timer_monitor)
  virtual timer_if vif;
  uvm_analysis_port #(timer_item) ap;

  bit [3:0]  aw_addr_q;
  bit [31:0] w_data_q;
  bit [3:0]  ar_addr_q;
  bit [1:0]  order_q; // 0=none yet 1=AW-first 2=W-first 3=simultaneous

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    ap = new("ap", this);
    if (!uvm_config_db#(virtual timer_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "monitor: vif not set")
  endfunction

  task run_phase(uvm_phase phase);
    fork
      watch_aw_w();
      watch_b();
      watch_ar_r();
    join
  endtask

  task automatic watch_aw_w();
    bit aw_fire, w_fire;
    forever begin
      @(posedge vif.clk);
      aw_fire = vif.awvalid && vif.awready;
      w_fire  = vif.wvalid  && vif.wready;
      if (aw_fire) aw_addr_q = vif.awaddr;
      if (w_fire)  w_data_q  = vif.wdata;
      if (order_q == 0) begin
        if (aw_fire && w_fire) order_q = 2'd3;
        else if (aw_fire)      order_q = 2'd1;
        else if (w_fire)       order_q = 2'd2;
      end
    end
  endtask

  task automatic watch_b();
    forever begin
      @(posedge vif.clk);
      if (vif.bvalid && vif.bready) begin
        timer_item item = timer_item::type_id::create("mon_wr");
        item.is_write  = 1;
        item.addr      = aw_addr_q;
        item.wdata     = w_data_q;
        item.mon_order = order_q;
        order_q        = 0;
        ap.write(item);
      end
    end
  endtask

  task automatic watch_ar_r();
    forever begin
      @(posedge vif.clk);
      if (vif.arvalid && vif.arready) ar_addr_q = vif.araddr;
      if (vif.rvalid && vif.rready) begin
        timer_item item = timer_item::type_id::create("mon_rd");
        item.is_write = 0;
        item.addr     = ar_addr_q;
        item.rdata    = vif.rdata;
        ap.write(item);
      end
    end
  endtask
endclass

// --------------------------------------------------------- ref model ---

// independently derived from the register map, not copied from the RTL -
// watches the bus directly (not the monitor's transactions) so it tracks
// COUNT and MATCH cycle by cycle, the same reason the full project's ref
// model does this instead of only updating at transaction boundaries.

class timer_ref_model extends uvm_component;
  `uvm_component_utils(timer_ref_model)
  virtual timer_if vif;

  bit       en, mode, match;
  bit [7:0] count, target;
  bit       aw_seen, w_seen;
  bit [3:0] aw_addr_q;
  bit [31:0] w_data_q;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual timer_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "ref_model: vif not set")
  endfunction

  task run_phase(uvm_phase phase);
    forever begin
      @(posedge vif.clk);
      if (!vif.rst_n) begin
        en <= 0; mode <= 0; count <= 0; target <= '1; match <= 0;
        aw_seen <= 0; w_seen <= 0;
      end else begin
        bit match_comb = (count == target);
        bit hold_comb  = mode && match_comb;
        bit incr_comb  = en && !hold_comb;
        bit wr_fire    = aw_seen && w_seen;

        if (vif.awvalid && vif.awready) begin aw_seen <= 1; aw_addr_q <= vif.awaddr; end
        if (vif.wvalid  && vif.wready)  begin w_seen  <= 1; w_data_q  <= vif.wdata;  end

        if (incr_comb) count <= (count == 8'hFF) ? 8'h00 : count + 1'b1;

        if (wr_fire) begin
          aw_seen <= 0; w_seen <= 0;
          case (aw_addr_q[3:2])
            2'b00: begin en <= w_data_q[0]; mode <= w_data_q[1]; end
            2'b10: target <= w_data_q[7:0];
            default: ;
          endcase
        end

        if (wr_fire && aw_addr_q[3:2] == 3 && w_data_q[0] && !match_comb)
          match <= 0;
        else if (match_comb)
          match <= 1;
      end
    end
  endtask
endclass

// -------------------------------------------------------- scoreboard ---

class timer_scoreboard extends uvm_subscriber #(timer_item);
  `uvm_component_utils(timer_scoreboard)
  timer_ref_model ref_model;
  int match_cnt, mismatch_cnt;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void write(timer_item t);
    bit [31:0] exp;
    if (t.is_write) return;
    case (t.addr[3:2])
      2'b00: exp = {30'b0, ref_model.mode, ref_model.en};
      2'b01: exp = {24'b0, ref_model.count};
      2'b10: exp = {24'b0, ref_model.target};
      2'b11: exp = {31'b0, ref_model.match};
      default: exp = 0;
    endcase
    if (exp === t.rdata) match_cnt++;
    else begin
      mismatch_cnt++;
      `uvm_error("SCOREBOARD", $sformatf("addr %0h: exp %0h got %0h", t.addr, exp, t.rdata))
    end
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("SCOREBOARD",
      $sformatf("matched=%0d mismatched=%0d", match_cnt, mismatch_cnt), UVM_LOW)
  endfunction
endclass

// ----------------------------------------------------------- coverage ---

class timer_coverage extends uvm_subscriber #(timer_item);
  `uvm_component_utils(timer_coverage)
  bit [1:0] mode_sample, order_sample;
  bit       match_sample;

  covergroup cg;
    option.per_instance = 1;
    cp_mode:  coverpoint mode_sample  { bins fr = {0}; bins os = {1}; }
    cp_match: coverpoint match_sample { bins seen = {1}; }
    cp_order: coverpoint order_sample {
      bins aw_first     = {1};
      bins w_first      = {2};
      bins simultaneous = {3};
    }
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cg = new();
  endfunction

  function void write(timer_item t);
    if (t.is_write) begin
      if (t.addr[3:2] == 0) mode_sample = t.wdata[1];
      order_sample = t.mon_order;
    end else if (t.addr[3:2] == 3) begin
      match_sample = t.rdata[0];
    end
    cg.sample();
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("COVERAGE",
      $sformatf("total=%0.1f%% mode=%0.1f%% match=%0.1f%% order=%0.1f%%",
                cg.get_coverage(), cg.cp_mode.get_coverage(),
                cg.cp_match.get_coverage(), cg.cp_order.get_coverage()),
      UVM_LOW)
  endfunction
endclass

// -------------------------------------------------------- agent / env ---

class timer_agent extends uvm_agent;
  `uvm_component_utils(timer_agent)
  timer_driver                drv;
  uvm_sequencer #(timer_item) sqr;
  timer_monitor                mon;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    drv = timer_driver::type_id::create("drv", this);
    sqr = uvm_sequencer#(timer_item)::type_id::create("sqr", this);
    mon = timer_monitor::type_id::create("mon", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass

class timer_env extends uvm_env;
  `uvm_component_utils(timer_env)
  timer_agent      agent;
  timer_ref_model  ref_model;
  timer_scoreboard sb;
  timer_coverage   cov;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    agent     = timer_agent::type_id::create("agent", this);
    ref_model = timer_ref_model::type_id::create("ref_model", this);
    sb        = timer_scoreboard::type_id::create("sb", this);
    cov       = timer_coverage::type_id::create("cov", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    agent.mon.ap.connect(sb.analysis_export);
    agent.mon.ap.connect(cov.analysis_export);
    sb.ref_model = ref_model;
  endfunction
endclass

// ----------------------------------------------------------- sequences ---

// directed: reset readback, free-running vs one-shot mode transition, a
// best-effort attempt at the MATCH/W1C race (formal is what actually
// proves that one, this just exercises it functionally), and one write
// per AW/W ordering so ordering is hit on purpose, not just by chance.
class directed_seq extends uvm_sequence #(timer_item);
  `uvm_object_utils(directed_seq)

  function new(string name = "directed_seq");
    super.new(name);
  endfunction

  task wr(bit [3:0] addr, bit [31:0] data, bit [1:0] order = 0);
    timer_item it = timer_item::type_id::create("it");
    start_item(it);
    it.is_write = 1; it.addr = addr; it.wdata = data; it.order = order;
    finish_item(it);
  endtask

  task rd(bit [3:0] addr);
    timer_item it = timer_item::type_id::create("it");
    start_item(it);
    it.is_write = 0; it.addr = addr;
    finish_item(it);
  endtask

  // same as rd(), but hands the read-back value out - needed to pick a
  // TARGET that's actually reachable from wherever COUNT currently is,
  // instead of guessing a fixed value
  task rd_data(bit [3:0] addr, output bit [31:0] data);
    timer_item it = timer_item::type_id::create("it");
    start_item(it);
    it.is_write = 0; it.addr = addr;
    finish_item(it);
    data = it.rdata;
  endtask

  task body();
    bit [31:0] cur_count; // declared up front - VCS requires all block
                          // declarations before any statements, so this
                          // can't sit down at the point it's first used

    // reset readback
    rd(4'h0); rd(4'h4); rd(4'h8); rd(4'hC);

    // free-running: EN=1, MODE=0
    wr(4'h0, 32'h1, 1);
    repeat (5) rd(4'h4);

    // mode transition: switch to one-shot with a nearby TARGET. two real
    // EDA Playground runs caught the same underlying mistake twice: this
    // RTL's CTRL register only ever implements EN (bit0) and MODE (bit1) -
    // there's no CLEAR/self-clearing bit, writing one just gets silently
    // ignored by the hardware. so a fixed TARGET=6 written after the
    // free-running phase has already run COUNT well past 6 can never
    // match without a full wraparound (~250 more cycles), and "clearing"
    // COUNT via a CTRL bit that doesn't exist doesn't help either. the
    // real fix: read COUNT back first and pick a TARGET a few counts
    // ahead of wherever it actually is right now.
    rd_data(4'h4, cur_count);
    wr(4'h8, (cur_count[7:0] + 8'd5), 2);
    wr(4'h0, 32'h3, 0); // EN=1, MODE=1
    repeat (10) rd(4'h4);
    rd(4'hC); // expect MATCH set once COUNT reaches TARGET

    // W1C vs hardware-set race: clear MATCH right as a fresh one-shot
    // cycle is set up to re-hit TARGET immediately
    wr(4'hC, 32'h1, 0);
    wr(4'h8, 32'h6, 0);
    rd(4'hC);

    // one explicit write per AW/W ordering
    wr(4'h8, 32'h10, 1); // AW first
    wr(4'h8, 32'h20, 2); // W first
    wr(4'h8, 32'h30, 0); // simultaneous
  endtask
endclass

class random_seq extends uvm_sequence #(timer_item);
  `uvm_object_utils(random_seq)
  rand int num = 60;

  function new(string name = "random_seq");
    super.new(name);
  endfunction

  task body();
    repeat (num) begin
      timer_item it = timer_item::type_id::create("it");
      start_item(it);
      assert(it.randomize());
      finish_item(it);
    end
  endtask
endclass

// ---------------------------------------------------------------- test ---

class timer_test extends uvm_test;
  `uvm_component_utils(timer_test)
  timer_env env;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    env = timer_env::type_id::create("env", this);
  endfunction

  task run_phase(uvm_phase phase);
    directed_seq d_seq = directed_seq::type_id::create("d_seq");
    random_seq   r_seq = random_seq::type_id::create("r_seq");
    phase.raise_objection(this);
    d_seq.start(env.agent.sqr);
    r_seq.start(env.agent.sqr);
    phase.drop_objection(this);
  endtask
endclass

// ------------------------------------------------------------------ tb ---

interface timer_if(input logic clk);
  logic        rst_n;
  logic        awvalid, awready; logic [3:0] awaddr;
  logic        wvalid, wready;   logic [31:0] wdata;
  logic        bvalid, bready;
  logic        arvalid, arready; logic [3:0] araddr;
  logic        rvalid, rready;   logic [31:0] rdata;
endinterface

module tb_top;
  logic clk = 0;
  always #5 clk = ~clk;

  timer_if vif(clk);

  timer_axi #(.WIDTH(8)) dut (
    .clk(clk), .rst_n(vif.rst_n),
    .awvalid(vif.awvalid), .awready(vif.awready), .awaddr(vif.awaddr),
    .wvalid(vif.wvalid),   .wready(vif.wready),   .wdata(vif.wdata),
    .bvalid(vif.bvalid),   .bready(vif.bready),
    .arvalid(vif.arvalid), .arready(vif.arready), .araddr(vif.araddr),
    .rvalid(vif.rvalid),   .rready(vif.rready),   .rdata(vif.rdata)
  );

  initial begin
    vif.rst_n = 0;
    repeat (3) @(posedge clk);
    vif.rst_n = 1;
  end

  initial begin
    uvm_config_db#(virtual timer_if)::set(null, "*", "vif", vif);
    run_test("timer_test");
  end
endmodule
