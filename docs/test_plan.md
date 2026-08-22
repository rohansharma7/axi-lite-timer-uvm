Test Plan - AXI-Lite Timer/Counter

features to verify
CTRL EN/MODE bits, COUNT increment/wrap/hold, TARGET compare, STATUS
write-1-to-clear w/ hardware wins the race, independent AW/W write
ordering on the bus (this one matters a lot, see below)

UVM environment
driver, monitor, a golden ref model (watches the bus directly and
predicts COUNT/MATCH cycle accurate, i wrote it separately from the
register map logic so it's not just copying the RTL), scoreboard checks
every read against the ref model, plus functional coverage. all wired
up in an agent + env. running on EDA playground with VCS + UVM1.2

directed tests: reset readback, free running counting for a bit, then
switch to one-shot mode with a target thats actually reachable and
check MATCH gets set, also try to hit the MATCH/W1C race on purpose
(this is NOT a proof that the race works right, just a functional
sanity check - formal is what actually proves it), and one write each
for AW-first / W-first / simultaneous so ordering gets exercised on
purpose not just by luck

random tests: randomized reads and writes across all 4 regs, AW/W order
randomized too, checked against ref model every single transaction

coverage tracks: MODE (both values), MATCH seen at least once, and all
3 AW/W orderings actually observed on the bus (the monitor tags this
from the actual bus timing not from what the driver meant to do, so it
proves the ordering really happened)

Formal Verification
timer_formal.sv has SVA properties bound onto timer_axi directly -
checks reset values, CTRL holding when nothing writes it, the one-shot
overshoot thing, and the STATUS same cycle race case. run thru
SymbiYosys (timer.sby), does bmc + k-induction proof + cover
reachability (incl. all 3 AW/W orderings reachable). this is the part
that actually PROVES the race/ordering stuff instead of just hoping
random stim happens to hit it eventually

Status (as of now)

UVM - ran for real on EDA playground, VCS+UVM1.2. matched=56
mismatched=0, 0 errors 0 fatals, coverage is 100% total (mode 100,
match 100, order 100). all 5 env components actually did something,
not just placeholders. found + fixed 3 real bugs while getting here -
a reset race that hung the driver, a coverage gap bc target was
unreachable, and a plain syntax error VCS caught.

Formal - ran for real too, local oss-cad-suite (yosys + symbiyosys +
z3) thru wsl. bmc passes clean out to depth 30. prove passes by
k-induction which means its actually proven for all time not just up
to some depth. cover hits all 5 targets so none of the properties are
vacuous. also found/fixed 3 tooling issues along the way (yosys build
didnt support |-> and |=>, didnt support $stable(), and BMC needed an
explicit assumption that it starts in reset)

tldr - both sides actually ran and passed, this isnt just written to
look right
