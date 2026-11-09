# Phase 1 test report — Hsiao SEC-DED (72,64)

**Date:** 2026-11-09
**Status:** PASS
**Simulator:** Vivado XSim 2025.1 (`xvlog`/`xelab`/`xsim`)
**Golden model:** Python 3.12.10, `model/hsiao.py`

Reproduce:

```bash
python model/test_hsiao.py     # golden model, 26 checks
python model/test_gen_rtl.py   # generated sources not stale
bash sim/run_xsim.sh           # RTL, 106141 checks
```

Raw evidence, committed alongside this report:
[`phase1_golden_model.log`](phase1_golden_model.log),
[`phase1_sim_xsim.log`](phase1_sim_xsim.log).

---

## 1. Deliverable

| item | file |
|---|---|
| Encoder RTL | `rtl/secded_encoder.sv` |
| Decoder RTL | `rtl/secded_decoder.sv` |
| Parity matrix (generated) | `rtl/ecc_hsiao_pkg.sv` |
| Golden model | `model/hsiao.py` |
| Golden-model tests | `model/test_hsiao.py` |
| Generator + drift guard | `model/gen_rtl.py`, `model/test_gen_rtl.py` |
| Self-checking testbench | `tb/tb_secded.sv` |
| Sim script | `sim/run_xsim.sh` |
| Design rationale | `docs/phase1_secded.md` |
| Matrix dump | `docs/h_matrix.md` |

---

## 2. Code parameters

| parameter | value |
|---|---|
| data width `k` | 64 |
| check width `r` | 8 |
| code width `n` | 72 |
| rate `k/n` | 0.889 (12.5% overhead) |
| minimum distance `d_min` | **4** (≥4 proved from H1–H3, =4 by exhibited weight-4 codeword) |
| guarantee | correct 1 bit, detect 2 bits |
| encoder latency | **0 cycles** (combinational) |
| decoder latency | **0 cycles** (combinational) |

---

## 3. Parity-matrix metrics

Measured by `model/test_hsiao.py`, not asserted by hand.

| metric | value | significance |
|---|---|---|
| H1 all columns nonzero | ✅ | every single flip is visible |
| H2 all columns odd weight | ✅ | syndrome parity = error count mod 2 → DED for one XOR |
| H3 all columns distinct | ✅ | a flip is unambiguously locatable; location vector one-hot by construction |
| column weight histogram | `{1:8, 3:56, 5:8}` | **provably minimum** total weight (see §4 of design notes) |
| data-side weight | 208 | equals the proven lower bound `56·3 + 8·5` |
| total H weight | 216 | 208 + 8 identity |
| row weights | `[27,27,27,27,27,27,27,27]` | **perfectly balanced** → shallowest possible XOR trees |
| weight-4 codewords `A₄` | 8392 | pins `d_min = 4`; counted two independent ways |

---

## 4. RTL verification results

`bash sim/run_xsim.sh` — **ALL TESTS PASSED**, 106141 checks, 0 failures.

| test | scope | result |
|---|---|---|
| 1. Golden-model vector replay | 3221 vectors | **0 mismatches** |
| 2. Error-free round trip | 16 corner/random + all 64 one-hot words | **0 mismatches** |
| 3. Single-bit correction | **EXHAUSTIVE** — all 72 positions × 16 data words | **1152 / 1152 = 100.00%** |
| 4. Double-bit detection | **EXHAUSTIVE** — all 2556 pairs × 16 data words | **40896 / 40896 = 100%** flagged UE; 0 miscorrected, 0 silent |
| 5. Triple-bit detection | **EXHAUSTIVE** — all 59640 patterns | **0 silent**; 26072 flagged UE, 33568 miscorrected |
| 6. Syndrome independence | 72 positions × 16 data words | **0 mismatches** — `S = H·e`, not `H·r` |
| Decoder invariants | every one of 106141 stimuli | **0 violations** |

Phase 1 acceptance criteria, from the project brief:

- all single-bit errors corrected → **100%, exhaustive** ✅
- double-bit errors detected → **100%, exhaustive (not representative — every pair)** ✅

### Checks 3 and 4 verified per-position

Each of the 72 single-bit cases additionally confirms `syndrome == H_COL[p]`
and `err_pos` one-hot at `p`, so correction is verified *at the right bit*, not
merely "data came out right".

---

## 5. Golden-model verification

`python model/test_hsiao.py` — **26 / 26 checks passed**.

| error weight | enumeration | corrected | detected | silent |
|---|---|---|---|---|
| 0 | 16 words + 64 one-hot | n/a | n/a | 0 |
| 1 | all 72 × 16 words = 1152 | **1152 (100%)** | 1152 | 0 |
| 2 | all 2556 × 16 words = 40896 | 0 (correctly refused) | **40896 (100%)** | 0 |
| 3 | all 59640 | 33568 *mis*corrected | 59640 | **0** |
| 4 | all 1028790 | — | 1020398 | **8392 (0.8157%)** |
| 5, 7 | 5000 random | — | all | **0** |
| uniform random | 200000 | — | — | 0.3800% (theory `2^-8` = 0.3906%) |

The RTL's triple-bit split (26072 flagged / 33568 miscorrected) matches the
Python model's exactly — an independent cross-check, since the two compute the
syndrome by different methods (row-mask XOR trees in RTL, column XOR in Python).

---

## 6. Honest limits

What this core provably **cannot** do:

- **3-bit errors are miscorrected 56.28% of the time** (33568 / 59640). Always
  detected, never silent — but when the 3-bit syndrome coincides with a column,
  the decoder flips an innocent bit and reports a clean correction.
- **4-bit errors are invisible 0.8157% of the time** (8392 / 1028790). Those
  error vectors *are* codewords, so `S = 0`: no flag, wrong data.
- A **uniformly random** error escapes with probability `2^-8 ≈ 0.39%`.

None of these is a defect. They are what `d_min = 4` means, and they are the
quantified motivation for Phase 3's BCH multi-bit corrector.

---

## 7. Area / timing

**Not measured in Phase 1 — no synthesis was run.** Area and Fmax on Artix-7
are Phase 2 deliverables. The analytic estimates below exist only so Phase 2's
real Vivado numbers can be sanity-checked against them, and must not be quoted
as results:

| quantity | estimate | basis |
|---|---|---|
| encoder 2-input XOR gates | 200 | `8 rows × 25` (26-input tree) |
| encoder LUT6 | ≈48 | `ceil(26/6)+1 = 6` per parity bit × 8 |
| encoder logic levels | 2 | LUT6 tree depth for 26 inputs |
| flip-flops | 0 | purely combinational |

---

## 8. Known toolchain issues (resolved, worth carrying forward)

| issue | resolution |
|---|---|
| Vivado `.bat` wrappers fail on `(` `)` in paths — including the repo's own directory name — with `"... was unexpected at this time"`. Short paths for sources are insufficient; the failure comes from the working directory, and Git Bash's `cd` leaves Windows `%CD%` as the long name. | `sim/run_xsim.sh` runs the simulator from a clean scratch directory, passes 8.3 short source paths, stages the vector file locally, copies the log back. Renaming the repo to a path without spaces/parens would remove the issue entirely. |
| **XSim 2025.1 does not support deferred assertions** (`assert #0`) — silently dropped with `WARNING [XSIM 43-4455]`. The decoder's structural assertions therefore do not execute under XSim. | Same invariants re-implemented in `tb_secded.sv` (`check_invariants`), sampled on settled values after `#1`, and run on all 106141 stimuli. The in-RTL assertions are kept for Questa/VCS. |
| SystemVerilog has no C-style adjacent string-literal concatenation. | Single literals in `$error`/`$display`. |
| XSim errors if the top has a `timescale` and submodules do not. | Global `xelab -timescale 1ns/1ps`; RTL deliberately carries no `` `timescale `` (sim-only directive, keeps synthesisable source clean). |

---

## 9. Toolchain inventory

| tool | status | used for |
|---|---|---|
| Vivado 2025.1 (`C:\Xilinx\2025.1\Vivado`) | ✅ installed | XSim simulation now; Artix-7 synthesis in Phase 2 |
| Artix-7 device data (`xc7a35t`, `xc7a100t`) | ✅ installed | Phase 2 target |
| UVM 1.2 (`data/system_verilog/uvm_1.2`) | ✅ present | Phase 4 |
| Python 3.12.10 | ✅ installed | golden model, generators |
| git 2.x (Git Bash) | ✅ installed | version control, run scripts |
| Icarus Verilog | ❌ not installed | optional: faster iteration than XSim |
| Verilator | ❌ not installed | optional: fast sim + line/toggle coverage |
| Yosys | ❌ not installed | optional: vendor-independent gate counts |
| GTKWave | ❌ not installed | optional: VCD viewing (Vivado's own viewer works) |

Nothing in the "not installed" list blocks Phases 1–4.
