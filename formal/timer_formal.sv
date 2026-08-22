// timer_formal.sv - SVA properties for timer_axi, bound directly onto the
// DUT so they see its internal registers without needing a separate
// harness or checker copies of that state.
//
// note on tooling: a real run on oss-cad-suite (yosys 0.68+118) found
// that its `read_slang` frontend - needed for `assert property` /
// `disable iff` / `bind` at all, since the classic non-slang frontend
// only parses plain-procedural assertions inside always blocks - doesn't
// yet support the |-> / |=> implication operators. every property below
// is written without them: |=> (next-cycle implication) becomes
// $past(antecedent) -> consequent, and |-> (same-cycle implication,
// since there's no ##N delay in any of these) becomes plain ->. disable
// iff parsed fine as-is, but $stable() didn't - also unsupported in this
// build - so $stable(x) is spelled out as x == $past(x). cover
// properties are plain booleans and were never affected by any of this.

module timer_checker(
  input logic clk, rst_n,
  input logic en, mode, match,
  input logic [7:0] count, target,
  input logic wr_fire, aw_seen, w_seen,
  input logic [3:0] aw_addr_q,
  input logic [31:0] w_data_q,
  input logic awvalid, awready, wvalid, wready
);

  logic match_comb;
  assign match_comb = (count == target);

  // BMC otherwise starts from a totally unconstrained state at step 0 -
  // nothing says the design actually powers up in reset the way real
  // hardware does, so the solver was free to pick a step-0 state where
  // rst_n/en/mode/count/target are all just whatever's convenient to
  // break a property, which isn't a real bug, just a missing assumption.
  // this pins step 0 to reset asserted, matching how the DUT actually
  // starts. two things this build's slang doesn't support ruled out the
  // usual ways to say that: `initial assume (!rst_n)` fails because
  // reading a net inside `initial` isn't allowed during elaboration, and
  // `$initstate` isn't implemented at all. so this hand-rolls the same
  // idea with a local variable (not a net, so its own initial value is
  // fine) that's only true before the first clock edge.
  logic first_cycle;
  initial first_cycle = 1'b1;
  always @(posedge clk) begin
    if (first_cycle) assume (!rst_n);
    first_cycle <= 1'b0;
  end

  // reset values
  a_reset_en:    assert property (@(posedge clk) $past(!rst_n) -> !en);
  a_reset_match: assert property (@(posedge clk) $past(!rst_n) -> !match);

  // CTRL holds when not written - disable iff covers both "last cycle was
  // a reset" and "this cycle is a reset", so a reset landing mid-write
  // can't be mistaken for a spurious CTRL change
  a_ctrl_hold: assert property (
    @(posedge clk) disable iff (!rst_n)
    $past(!(wr_fire && aw_addr_q[3:2] == 0)) ->
      ((en == $past(en)) && (mode == $past(mode)))
  );

  // a write only ever fires once both AW and W have actually landed
  a_write_needs_both: assert property (
    @(posedge clk) disable iff (!rst_n) wr_fire -> (aw_seen && w_seen)
  );

  // one-shot never overshoots TARGET once it lands on it - compares
  // against the *previous* TARGET, not the current one, since TARGET can
  // get rewritten the same cycle COUNT is legitimately holding there
  a_no_overshoot: assert property (
    @(posedge clk) disable iff (!rst_n)
    $past(mode && en && count == target) -> (count == $past(target))
  );

  // a real MATCH event the same cycle as a W1C clear attempt is never lost
  a_race_no_drop: assert property (
    @(posedge clk) disable iff (!rst_n)
    $past(wr_fire && aw_addr_q[3:2] == 3 && w_data_q[0] && match_comb) -> match
  );

  // reachability - MATCH, the one-shot hold, and all three AW/W arrival
  // orderings actually happen, these aren't vacuous properties
  c_match_reached: cover property (@(posedge clk) match);
  c_hold_reached:  cover property (@(posedge clk) mode && en && count == target);
  c_aw_first:      cover property (@(posedge clk) (awvalid && awready) && !(wvalid && wready));
  c_w_first:       cover property (@(posedge clk) (wvalid && wready) && !(awvalid && awready));
  c_aw_w_together: cover property (@(posedge clk) (awvalid && awready) && (wvalid && wready));

endmodule

bind timer_axi timer_checker u_checker(
  .clk(clk), .rst_n(rst_n),
  .en(en), .mode(mode), .match(match),
  .count(count), .target(target),
  .wr_fire(wr_fire), .aw_seen(aw_seen), .w_seen(w_seen),
  .aw_addr_q(aw_addr_q), .w_data_q(w_data_q),
  .awvalid(awvalid), .awready(awready), .wvalid(wvalid), .wready(wready)
);
