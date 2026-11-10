# In-line ECC engine for a memory/bus interface

A synthesisable error-correcting-code engine that sits in a memory or bus data
path and repairs corruption at line rate, built from single-bit (DRAM-class)
through multi-bit (NAND-class) correction, with a Python golden reference model
and self-checking testbenches at every step.

---

## The problem

Data corrupts both in flight and at rest: DRAM bit flips from particle strikes
and charge leakage, NAND charge loss and read disturb, crosstalk and jitter on
high-speed links. A server cannot stop and retry on every flipped bit — and
usually there is nothing to retry *from*, because the stored copy **is** the
corrupted copy. So memory and connectivity silicon corrects in hardware, in the
data path, without stalling.

**In-line** means the engine adds propagation delay, never a stall cycle. The
cores here are combinational: zero-cycle latency, no handshake, no backpressure.

The outcome that must never happen is **silent data corruption** — wrong data
delivered with no flag raised. A detected fault can be retried, logged or
escalated; an undetected one propagates into results. Every design decision in
this repo is ultimately about that distinction.

---

## Architecture

| phase | architecture | status |
|---|---|---|
| **1** | **Hsiao SEC-DED (72,64)** — correct 1 bit, detect 2. DRAM-class. | **complete** |
| 2 | AXI4-Lite slave wrapper: register map, error counters, UE interrupt. Artix-7 Fmax + area. | in progress — [2a spec](docs/phase2_register_map.md) and 2b slave done |
| 3 | BCH multi-bit corrector — GF(2^m), syndromes, Berlekamp-Massey, Chien search. `t=2`, `t=4`. | planned |
| 4 | UVM environment: constrained-random data and error injection, scoreboard, functional coverage, SVA. | planned |
| 5 | Characterisation: BER sweeps, latency, throughput, Fmax, correction-strength vs. area. | planned |
| 6 | Silicon/physical: OpenLane (Sky130) gate count, or live Artix-7 error-injection demo. | stretch |

---

## Phase 1 results — Hsiao SEC-DED (72,64)

Full report: [`docs/results/phase1_report.md`](docs/results/phase1_report.md).
Design rationale: [`docs/phase1_secded.md`](docs/phase1_secded.md).

| metric | result |
|---|---|
| Single-bit errors corrected | **100%** — all 72 positions × 16 data words, **exhaustive** |
| Double-bit errors detected | **100%** — all 2556 pairs × 16 data words, **exhaustive**; 0 miscorrected |
| Triple-bit errors silently undetected | **0** of 59640, exhaustive |
| Total RTL checks | **106141**, 0 failures |
| Golden-model checks | **26 / 26** |
| `d_min` | 4 (proved ≥4 from Hsiao's rules; =4 by exhibited weight-4 codeword) |
| Parity matrix | column weights `{1:8, 3:56, 5:8}` — **provably minimum** total weight |
| | row weights all **27** — perfectly balanced, shallowest possible XOR trees |
| Latency | **0 cycles** (combinational encoder and decoder) |
| Overhead | 8 check bits per 64 data bits = 12.5% |

Honest limits, measured exhaustively rather than glossed: 3-bit errors are
always detected but **miscorrected 56.28%** of the time, and **0.8157%** of
4-bit errors are *invisible* (those error vectors are themselves codewords, so
the syndrome is zero). Both are what `d_min = 4` means, and both are the
quantified motivation for the BCH decoder in Phase 3.

Area and Fmax are **not** measured yet — no synthesis has been run. That is a
Phase 2 deliverable.

---

## Why Hsiao rather than extended Hamming

Both give `d_min = 4`. Hsiao's construction requires every column of the
parity-check matrix to be **nonzero, odd-weight and distinct**, which yields
`d_min ≥ 4` in three lines (weight-mod-2 is linear over GF(2), so three
odd-weight columns cannot XOR to zero). The payoff: because every column has
odd weight, the XOR-reduction of the syndrome equals the *parity of the error
count*, so double-error detection falls out of the syndrome itself — no extra
overall-parity bit to generate, store and check. Choosing the lowest-weight
legal columns minimises XOR area, and balancing the ones across rows minimises
the deepest parity tree.

Worked out in full, with the proofs and the cost arithmetic, in
[`docs/phase1_secded.md`](docs/phase1_secded.md).

---

## Repository layout

```
rtl/      synthesisable SystemVerilog
          ecc_hsiao_pkg.sv     parity-check matrix (GENERATED - do not hand-edit)
          secded_encoder.sv    combinational encoder
          secded_decoder.sv    combinational decoder: syndrome, locate, classify, correct
          axil_slave.sv        generic AXI4-Lite front end -> request/response
          ecc_axil_ctrl.sv     address decode + register file (ECC datapath in 2c)
tb/       self-checking testbenches
          tb_secded.sv         golden-model replay + exhaustive error injection
          tb_axil_regs.sv      AXI4-Lite protocol SVA + register directed tests
          vectors/             generated test vectors
model/    Python golden reference - the source of truth
          hsiao.py             the code itself, with the theory in the docstring
          test_hsiao.py        exhaustive verification of the model
          gen_rtl.py           emits the RTL package, vectors and matrix doc
          test_gen_rtl.py      fails if generated files drift from the model
sim/      run scripts
          run_xsim.sh          compile + run under Vivado XSim
docs/     phase1_secded.md     design rationale and coding theory
          h_matrix.md          human-readable H (GENERATED)
          results/             per-phase reports and raw logs
```

### The golden model owns the parity matrix

`rtl/ecc_hsiao_pkg.sv`, `tb/vectors/secded_vectors.txt` and `docs/h_matrix.md`
are **generated** from `model/hsiao.py`. If the RTL built its own matrix in
SystemVerilog, a disagreement between design and reference would be a silent
bug in *both*. Generating from one source removes that failure mode; the
generated files are committed so the repo builds without Python and so matrix
changes appear as reviewable diffs, and `model/test_gen_rtl.py` fails the build
if they ever drift. Phase 3 needs the same discipline for its GF(2^m) tables.

---

## Toolchain

| tool | required | notes |
|---|---|---|
| Vivado 2025.1 (XSim + synthesis) | yes | `C:\Xilinx\2025.1\Vivado`; Artix-7 `xc7a35t`/`xc7a100t` device data present; UVM 1.2 ships with it for Phase 4 |
| Python 3.12+ | yes | no third-party packages |
| Git Bash | yes | the run scripts are bash |
| Icarus Verilog / Verilator | optional | faster iteration; Verilator also gives line/toggle coverage |
| Yosys | optional | vendor-independent gate counts |
| GTKWave | optional | Vivado's own waveform viewer works |

### Running it

```bash
python model/test_hsiao.py
```

```bash
python model/test_gen_rtl.py
```

```bash
bash sim/run_xsim.sh all
```

Individual targets: `secded` for the Phase 1 core, `axil` for the Phase 2b bus
interface. Override the Vivado location if yours differs:

```bash
VIVADO_HOME=/c/Xilinx/2025.1/Vivado bash sim/run_xsim.sh all
```

### One Windows gotcha

Vivado's command-line tools are `cmd.exe` batch wrappers that interpolate the
current directory into their own commands, and `cmd` treats `(` and `)` as
grouping characters. Any path containing parentheses — **including this
project's own directory name** — makes them fail with
`"... was unexpected at this time"`. `sim/run_xsim.sh` works around it by
running the simulator from a scratch directory and passing 8.3 short paths.
Moving the repo to a path with no spaces or parentheses (e.g.
`C:/work/inline-ecc`) removes the problem at source.
