# Phase 1 — SECDED Hamming (72,64): design notes

This is the "why" document. It is written so that every decision in
`rtl/secded_encoder.sv`, `rtl/secded_decoder.sv` and `model/hsiao.py` can be
defended from first principles rather than cited.

---

## 1. The problem being solved

Data corrupts both in flight and at rest:

| mechanism | where | typical rate |
|---|---|---|
| DRAM particle strike / charge leak | memory array | ~1 fault per GB per hour scale, bursty |
| NAND charge loss, read disturb, wear | flash cells | rises with program/erase cycles |
| link crosstalk, SI, jitter | SerDes / bus | bit error rate specified per standard |

A server cannot stop and retry on every flipped bit, and in most of these
cases there is nothing to retry *from* — the stored copy **is** the corrupted
copy. So memory and connectivity silicon corrects in hardware, in the data
path, at line rate. "In-line" means the engine adds propagation delay, never a
stall cycle. That is why the Phase 1 core is purely combinational: zero-cycle
latency, no handshake, no backpressure.

Phase 1 targets the DRAM case: **single-bit correct, double-bit detect** over a
64-bit word with 8 check bits. 72/64 is not an arbitrary choice — it is the
width of a real ECC DIMM (eight ×8 DRAM chips of data, one more for check
bits).

---

## 2. Linear block codes in the only form you need

Protect `k` data bits with `r` check bits, transmit `n = k + r`.
Here `k = 64`, `r = 8`, `n = 72`.

The code is defined by a **parity-check matrix** `H`, of shape `r × n`, over
GF(2) — arithmetic mod 2, where addition is XOR and every element is its own
additive inverse. A vector `c` of `n` bits is a valid **codeword** iff

```
H · c = 0        (mod 2)
```

We use a **systematic** code, meaning `H = [ A | I_r ]`:

- columns `0 … k-1` are `A`, the data columns — **we get to choose these**, and
  that choice is the entire design;
- columns `k … n-1` are an `r × r` identity matrix, the check-bit columns.

Systematic matters practically: the data appears verbatim inside the codeword,
so a consumer that trusts the data can bypass the decoder entirely, and the
encoder only has to *append*.

### The encoder is a direct read-off

Row `i` of `H` asserts: *the XOR of all code bits selected by that row is zero*.
Because the check part is the identity, row `i` contains exactly one check bit —
check bit `i` — so the row rearranges (using `x + x = 0` over GF(2)) to

```
check[i] = XOR of data[j] over all j < k where H[i][j] = 1
```

That is the whole encoder: `r` independent XOR-reductions of fixed subsets of
the data. Row `i` of `H` *is* the bit mask that selects subset `i`. No state, no
sequencing — see `rtl/secded_encoder.sv`.

### The syndrome is a function of the error alone

Store `c`, read back `r = c + e`, where `e` is the **error vector** (a 1 in each
flipped position). The decoder computes the **syndrome**:

```
S = H · r = H · (c + e) = H·c + H·e = 0 + H·e = H · e
```

**The data cancels out identically.** This is the single fact the whole block
rests on. Consequences:

- `e = 0` → `S = 0`
- a single flip at position `p` → `S =` column `p` of `H`

So a nonzero `S` that equals column `p` means "bit `p` flipped" — flip it back.
That is Single Error Correct, and it needs nothing more than `n` equality
comparators against constants.

Test 6 in the testbench checks this property directly: the same error position
against 16 different data words must give byte-identical syndromes.

### Why plain Hamming is not enough

For SEC to be unambiguous, every column of `H` must be **nonzero** (a flip is
always visible) and **distinct** (a flip is locatable). Those are the classical
Hamming conditions and they give minimum distance `d_min = 3`.

With `d_min = 3` you may correct 1 error **or** detect 2 — not both at once.
A 2-bit error produces a syndrome identical to some 1-bit error's, so the
decoder confidently "corrects" it and emits a *third* wrong word with no flag
raised. That is **silent data corruption**, the single worst outcome a memory
system can produce: a detected fault can be retried, logged, or escalated; an
undetected one propagates into results.

To correct 1 *and* detect 2 simultaneously we need `d_min = 4`.

---

## 3. Two routes to d_min = 4, and why we took Hsiao's

### Route A — extended Hamming (the textbook one)

Take a `d=3` Hamming code and append one **overall parity bit** covering every
other bit. That lifts `d_min` from 3 to 4. Decoding uses the syndrome *plus*
that extra bit as a separate signal:

| syndrome | overall parity | conclusion |
|---|---|---|
| 0 | even | clean |
| ≠0 | odd | single error at the syndrome's position |
| ≠0 | even | double error → uncorrectable |
| 0 | odd | the parity bit itself flipped |

It works, and it is easy to explain. Its costs:

- a separate parity bit to generate, store, read and check — extra bookkeeping
  in both encoder and decoder;
- the Hamming data columns are the **binary representations of the position
  indices**, so their weights run from 1 to 7 and the row weights are badly
  unbalanced. The widest parity tree sets the critical path for the whole
  block, and a lopsided `H` makes that tree much deeper than it needs to be.

### Route B — Hsiao (IBM, 1970) — what we built

Same `d_min = 4`, strictly less hardware, and the DED signal falls out for
free. Three rules on `H`:

- **H1** every column nonzero
- **H2** every column has **odd weight**
- **H3** all columns distinct

**Claim: H1 + H2 + H3 ⟹ `d_min ≥ 4`.**

`d_min ≥ 4` means no set of 1, 2 or 3 columns XORs to zero.

- *1 column:* nonzero by H1. ✔
- *2 columns:* XOR to zero only if equal; excluded by H3. ✔
- *3 columns:* weight-mod-2 is a **linear functional** over GF(2), so
  `wt(a+b+c) mod 2 = (wt a + wt b + wt c) mod 2 = (1+1+1) mod 2 = 1`.
  An odd-weight vector cannot be zero. ✔

∎

Note H2 proves far more than we asked for: it kills **every odd-size error
pattern**, not just size 3. Any odd number of flips always yields a nonzero
syndrome, so **an odd-weight error is never silently accepted** — at any
weight, 1 or 71.

`d_min` is exactly 4, not more: a weight-4 codeword exists, and
`verify_properties()` exhibits one (columns `(0, 64, 1, 2)`).

### The payoff: DED for one XOR gate

Let `p(S)` be the XOR-reduction of all `r` syndrome bits. Then

```
p(S) = p(H·e) = Σ over flipped positions of wt(column) mod 2
     = (number of flipped bits) mod 2          [every wt is odd, by H2]
```

**One 8-input XOR tells you the parity of the error count.** The full decode
rule:

| condition | meaning | action |
|---|---|---|
| `S == 0` | no detectable error | pass through |
| `^S == 1`, `S` matches a column | odd count; assume 1 | correct that bit (CE) |
| `^S == 1`, `S` matches nothing | ≥3 errors | flag uncorrectable (UE) |
| `^S == 0`, `S != 0` | even count, ≥2 | flag uncorrectable (UE) |

Compare with Route A: no extra parity bit to generate, store or check. The
double-error-detect signal is derived from the syndrome itself. That is the
whole reason Hsiao codes, not extended Hamming, are what DRAM ECC actually
uses.

Two further structural gifts:

- Since all columns are distinct, **at most one comparator can ever fire**, so
  the location vector is one-hot-or-zero *by construction* — no priority
  encoder.
- An even-parity syndrome can never equal an odd-weight column, so `match_any`
  already implies `^S == 1`. The decoder still ANDs them together: one LUT
  input buys graceful degradation if someone overrides the `H` parameter with a
  non-Hsiao matrix. That redundancy is itself asserted.

---

## 4. Choosing the 64 data columns = choosing area and critical path

H1–H3 leave enormous freedom. Two hardware costs pick the winner:

```
total weight of H    ≈ total XOR gate inputs           → AREA
max ROW weight of H  = fan-in of the widest parity tree → DELAY
                       (depth ≈ ceil(log_b(row weight)) for b-input XOR)
```

So: take the **lowest-weight legal columns** (minimises area) and spread the
ones **evenly across rows** (minimises the deepest tree).

For `r = 8` the odd-weight columns available are:

| weight | count | note |
|---|---|---|
| 1 | `C(8,1) = 8` | **reserved** for the identity block |
| 3 | `C(8,3) = 56` | |
| 5 | `C(8,5) = 56` | |
| 7 | `C(8,7) = 8` | |
| **total** | **128** | `= 2^7`, exactly half of all 256 vectors |

We need 64 data columns of weight ≥ 3. Only 56 weight-3 columns exist, so at
least `64 − 56 = 8` must have weight ≥ 5. Therefore

```
minimum possible data-side weight = 56·3 + 8·5 = 168 + 40 = 208
```

**and this implementation achieves that bound.** Perfect row balance is also
arithmetically possible, which is not obvious and worth checking:

- `208 / 8 rows = 26` ones per row.
- All 56 weight-3 columns together put `C(7,2) = 21` ones in **every** row
  (fix a row, choose the other 2 positions from the remaining 7) — automatic,
  independent of ordering.
- So the 8 weight-5 columns must supply `26 − 21 = 5` ones per row.
  Check: `8 rows × 5 = 40 = 8 columns × 5 ones`. ✔ Consistent.

An explicit construction exists. Let `T_i = {i, i+1, i+3} mod 8` for
`i = 0…7`, and let column `C_i` be the **complement** of `T_i` (weight
`8−3 = 5`). Row `x` lies in `T_i` for exactly `i ∈ {x, x−1, x−3}` — three
distinct values mod 8 — so row `x` lies *outside* `8−3 = 5` of the `T_i`, i.e.
inside exactly 5 of the `C_i`. Balanced. The eight `T_i` are pairwise distinct,
hence so are the `C_i`.

`model/hsiao.py` reaches the same optimum with a greedy balanced fill
(minimise max row count, tie-break on sum-of-squares then numeric value), and
the test asserts the result rather than trusting it. Measured:

```
column weight histogram : {1: 8, 3: 56, 5: 8}      ← the proven optimum
row weights             : [27,27,27,27,27,27,27,27] ← perfectly flat
total H weight          : 216                       ← 208 data + 8 identity
```

Each row of the final `8 × 72` `H` has weight 27: 26 data bits plus its own
check bit.

### Cost estimate (analytic — synthesis numbers come in Phase 2)

Encoder: 8 parity bits, each an XOR of 26 data bits.

- 2-input XOR gates: `8 × 25 = 200`
- 6-input LUTs: `ceil(26/6) = 5` LUTs, `+1` to combine → **6 LUTs per bit**,
  **2 logic levels** → ≈ **48 LUTs** total
- flip-flops: **0** (combinational)

Decoder: 8 syndrome trees over 27 inputs each, plus 72 eight-bit equality
comparators, plus the correction XOR layer and 3 flag gates.

These are the back-of-envelope figures to check Phase 2's real Vivado report
against. They are **estimates and labelled as such** — no synthesis was run in
Phase 1.

---

## 5. What this block cannot do

Stating the limits precisely is part of the design, not an apology for it.
`d_min = 4` guarantees exactly: **correct 1, detect 2**. Beyond that, measured
exhaustively (`model/test_hsiao.py`):

| error weight | outcome | number |
|---|---|---|
| 1 | corrected | **100%** — all 72 patterns |
| 2 | flagged uncorrectable | **100%** — all 2556 pairs, 0 miscorrected |
| 3 | never silent | 0 of 59640 undetected |
| 3 | …but aliased onto a single-bit column | 33568 / 59640 = **56.28%** miscorrected |
| 4 | **invisible** when the error *is* a codeword | 8392 of 1028790 = **0.8157%** |
| any odd weight | always detected | guaranteed by H2 |
| uniform random | undetected | → `2^-8 = 0.3906%` (measured 0.3800% / 200k trials) |

Two of those rows deserve emphasis because they are where an interview goes:

**3-bit errors get miscorrected 56% of the time.** They are always *detected*
(odd weight ⇒ nonzero syndrome), but if the syndrome happens to coincide with
some column, the decoder flips an innocent bit and reports a clean correction.
Unavoidable at `d_min = 4` — the decoder cannot distinguish "1 error here" from
"3 errors there" when both produce the same syndrome.

**4-bit errors can be completely invisible.** Since `d_min = 4`, weight-4
codewords exist — 8392 of them. If the error vector *is* one of those, then
`S = H·e = 0`: no flag, wrong data, nothing to log. This is not a bug to fix,
it is the definition of `d_min = 4`, and it is precisely why NAND-class storage
(where multi-bit errors are the norm, not the exception) needs the BCH
multi-bit corrector of Phase 3.

An early version of the test asserted "no silent corruption for 4–8 bit
errors". It failed, correctly — the assertion was mathematically impossible.
It was replaced with the exact measurement above, cross-checked two
independent ways (direct enumeration of all `C(72,4)` patterns, and an
algebraic count of 4-sets of columns XORing to zero, which must be divided by 3
because each 4-set splits into disjoint pairs in three ways). Both give 8392.

---

## 6. Verification strategy

Two independent kinds of checking, because they catch different bugs.

**(a) Golden-model replay** — `tb` test 1. Replays 3221 vectors emitted by the
Python model: data, expected codeword, error mask, expected
data/syndrome/flags. This pins the RTL to the model's *exact* parity matrix. A
different-but-still-valid Hsiao matrix in the RTL would pass every
self-consistency check while silently being a different code; only comparison
against the model catches that.

**(b) Self-checking exhaustive injection** — `tb` tests 2–6. Encode, flip bits,
demand that what comes out equals what went in. Needs no reference: it checks
the *property* rather than agreement with another implementation, so it would
still catch a bug that had been copied into the model.

Plus a third layer: **decoder invariants** sampled on every one of the 106141
stimuli (one-hot-or-zero error position; CE and UE mutually exclusive;
`detected == CE | UE`; `detected == (S != 0)`; correction only on odd-parity
syndromes). These are written as deferred assertions (`assert #0`) inside
`secded_decoder.sv` *and* duplicated in the testbench, because **Vivado XSim
2025.1 does not implement deferred assertions** — it drops them with
`WARNING [XSIM 43-4455] 'Deferred Assertion is not supported'`. Relying on the
in-RTL versions alone would have meant zero actual coverage of those
properties under this toolchain. Checking them from the testbench, on settled
values after the `#1`, makes them real on every simulator.

"Exhaustive" is used literally. A 72-bit block has only 72 single-bit and 2556
double-bit error patterns, so every one is enumerated — "100% of single-bit
errors corrected" is a complete statement over the error space, not a
confidence interval.

---

## 7. Toolchain notes worth keeping

Two things cost real time and will recur in later phases.

**Vivado's `.bat` wrappers break on parentheses in paths.** `xvlog.bat` and
friends interpolate the current directory into their own cmd.exe commands, and
cmd treats `(` `)` as grouping characters. This repo's own directory name
contains parentheses, which produced
`"... was unexpected at this time"`. Passing 8.3 short paths for the *sources*
is not sufficient, because the failure comes from the **working directory** —
and Git Bash's `cd` into a short path still leaves Windows' `%CD%` as the long
name. `sim/run_xsim.sh` therefore runs the simulator from a scratch directory
with no spaces or parentheses, hands sources over as 8.3 short paths, stages
the vector file next to the simulation, and copies the log back. Renaming the
project directory to e.g. `C:/work/inline-ecc` would remove the problem at
source.

**SystemVerilog has no C-style adjacent string-literal concatenation.**
`$error("a" "b", x)` is a syntax error; use one literal or `{"a","b"}`.

**RTL files deliberately carry no `` `timescale ``.** It is a simulation-only
directive and baking it into synthesisable source invites mismatches between
units. The global timescale is supplied at elaboration instead
(`xelab -timescale 1ns/1ps`).
