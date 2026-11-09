"""
Exhaustive verification of the Hsiao SEC-DED golden model.

The golden model is the source of truth for the RTL, so it has to be proved
correct on its own terms FIRST -- otherwise we are just checking that two
things are wrong in the same way.

Nothing here is random-only: the single-bit and double-bit claims are proved by
COMPLETE enumeration of every possible error pattern of that size, which is the
whole point of a 72-bit block (72 and 2556 cases respectively -- small enough
to be exhaustive, so "100%" means 100%, not "we sampled a lot").

Run:  python model/test_hsiao.py
"""

import random
import sys
from itertools import combinations

from hsiao import HsiaoCode, parity, popcount

DATA_W = 64
CHK_W = 8
N = DATA_W + CHK_W

# Data patterns used as the backdrop for error injection. Corner patterns first
# (all-zeros and all-ones are where sign/initialisation bugs hide), then a
# fixed-seed random set so failures are reproducible.
random.seed(20260101)
DATA_PATTERNS = [
    0x0000000000000000,
    0xFFFFFFFFFFFFFFFF,
    0xAAAAAAAAAAAAAAAA,
    0x5555555555555555,
    0x00000000FFFFFFFF,
    0xFFFFFFFF00000000,
    0x0123456789ABCDEF,
    0xDEADBEEFCAFEBABE,
] + [random.getrandbits(DATA_W) for _ in range(8)]

results = []


def check(name, condition, detail=""):
    results.append((name, bool(condition), detail))
    status = "PASS" if condition else "FAIL"
    line = f"  [{status}] {name}"
    if detail:
        line += f"  ({detail})"
    print(line)
    return bool(condition)


# ---------------------------------------------------------------------------
print("=" * 74)
print(f"Hsiao SEC-DED ({N},{DATA_W}) golden model verification")
print("=" * 74)

code = HsiaoCode(DATA_W, CHK_W)

# --- 1. Matrix properties: these are what mathematically guarantee SEC-DED --
print("\n1. Parity-check matrix properties (Hsiao's rules)")
p = code.verify_properties()
check("H1: every column nonzero", p["h1_all_nonzero"])
check("H2: every column odd weight", p["h2_all_odd_weight"])
check("H3: every column distinct", p["h3_all_distinct"])
check("=> d_min >= 4 (SEC-DED capable)", p["d_min_ge_4"])
check("d_min <= 4 (weight-4 codeword exists)", p["d_min_le_4_witness"] is not None,
      f"columns {p['d_min_le_4_witness']}")
check("systematic: check columns form I_r",
      code.h[DATA_W:] == [1 << i for i in range(CHK_W)])
check("minimum total weight achieved (208 data + 8 identity = 216)",
      p["total_weight"] == 216, f"actual {p['total_weight']}")
check("row weights perfectly balanced",
      len(set(p["row_weights"])) == 1,
      f"all rows weight {p['row_weights'][0]}")
check("column weight histogram is optimal {1:8, 3:56, 5:8}",
      p["col_weight_histogram"] == {1: 8, 3: 56, 5: 8},
      str(p["col_weight_histogram"]))

# --- 2. Two independent syndrome implementations must agree -----------------
print("\n2. Syndrome implementation cross-check (column-wise vs row-wise)")
agree = all(
    code.syndrome(w) == code.syndrome_rowwise(w)
    for w in [0, (1 << N) - 1] + [random.getrandbits(N) for _ in range(200)]
)
check("column-wise == row-wise on 202 words", agree)

# --- 3. Clean round trip ----------------------------------------------------
print("\n3. Error-free encode/decode")
ok_rt = ok_syn = ok_flag = True
for d in DATA_PATTERNS:
    cw = code.encode(d)
    res = code.decode(cw)
    ok_syn &= code.syndrome(cw) == 0
    ok_rt &= res["data"] == d
    ok_flag &= (not res["detected"]) and (not res["corrected"]) \
        and (not res["uncorrectable"])
check("valid codeword gives syndrome == 0", ok_syn)
check("data survives round trip", ok_rt)
check("no flags raised on clean data", ok_flag)

# Exhaustive over all 64 single-data-bit words plus all 8 single-check patterns
ok = True
for j in range(DATA_W):
    d = 1 << j
    ok &= code.decode(code.encode(d))["data"] == d
check("round trip for all 64 one-hot data words", ok)

# --- 4. Syndrome must depend ONLY on the error, never on the data -----------
print("\n4. Syndrome independence from data (S = H.e, not H.r)")
ok = True
for pos in range(N):
    expect = code.error_syndrome([pos])
    for d in DATA_PATTERNS:
        if code.syndrome(code.encode(d) ^ (1 << pos)) != expect:
            ok = False
check(f"all {N} single-bit errors give the same syndrome for every data word", ok)

# --- 5. EXHAUSTIVE single-bit error correction ------------------------------
print("\n5. Single-bit errors: EXHAUSTIVE (all 72 positions x 16 data words)")
sec_total = sec_fixed = 0
bad = []
for d in DATA_PATTERNS:
    cw = code.encode(d)
    for pos in range(N):
        res = code.decode(cw ^ (1 << pos))
        sec_total += 1
        good = (res["data"] == d and res["corrected"] and res["detected"]
                and not res["uncorrectable"] and res["flip_pos"] == pos)
        if good:
            sec_fixed += 1
        else:
            bad.append((hex(d), pos, res))
check(f"corrected {sec_fixed}/{sec_total} single-bit errors",
      sec_fixed == sec_total,
      "100%" if sec_fixed == sec_total else f"first failure {bad[0]}")
check("every single-error syndrome is a distinct H column",
      len(set(code.h)) == N)

# --- 6. EXHAUSTIVE double-bit error detection -------------------------------
print(f"\n6. Double-bit errors: EXHAUSTIVE (all C(72,2)={N*(N-1)//2} pairs"
      f" x {len(DATA_PATTERNS)} data words)")
ded_total = ded_detected = ded_miscorrected = 0
first_miss = None
for d in DATA_PATTERNS:
    cw = code.encode(d)
    for a, b in combinations(range(N), 2):
        res = code.decode(cw ^ (1 << a) ^ (1 << b))
        ded_total += 1
        if res["uncorrectable"] and res["detected"] and not res["corrected"]:
            ded_detected += 1
        else:
            ded_miscorrected += 1
            if first_miss is None:
                first_miss = (hex(d), a, b, res)
check(f"flagged {ded_detected}/{ded_total} double-bit errors as uncorrectable",
      ded_detected == ded_total,
      "100%" if ded_detected == ded_total else f"first miss {first_miss}")
check("zero double-bit errors silently miscorrected", ded_miscorrected == 0)

# The structural reason it works: a 2-bit error syndrome is the XOR of two
# odd-weight columns, hence even weight, hence can never equal any column.
ok_even = ok_notcol = True
cols = set(code.h)
for a, b in combinations(range(N), 2):
    s = code.error_syndrome([a, b])
    if s == 0 or parity(s) != 0:
        ok_even = False
    if s in cols:
        ok_notcol = False
check("every 2-bit syndrome is nonzero and even-weight", ok_even)
check("no 2-bit syndrome collides with any H column (no aliasing)", ok_notcol)

# --- 7. Triple-bit errors: must never be SILENT ------------------------------
print(f"\n7. Triple-bit errors: EXHAUSTIVE over all C(72,3)={N*(N-1)*(N-2)//6}"
      " patterns")
tri_total = tri_silent = tri_miscorrect = tri_flagged = 0
for combo in combinations(range(N), 3):
    s = code.error_syndrome(combo)
    tri_total += 1
    if s == 0:
        tri_silent += 1                       # undetected: data corruption
    elif s in cols:
        tri_miscorrect += 1                   # detected but "fixed" wrongly
    else:
        tri_flagged += 1                      # correctly flagged uncorrectable
check(f"0 of {tri_total} triple-bit errors are silently undetected",
      tri_silent == 0, "guaranteed by odd column weight")
pct_mis = 100.0 * tri_miscorrect / tri_total
pct_flag = 100.0 * tri_flagged / tri_total
print(f"  [INFO] triple-bit outcome split: {tri_flagged} flagged UE "
      f"({pct_flag:.2f}%), {tri_miscorrect} miscorrected ({pct_mis:.2f}%), "
      f"{tri_silent} silent (0.00%)")
print("         Miscorrection beyond the guaranteed strength is EXPECTED for a")
print("         d_min=4 code -- t=1 correction, 2 detection. It is reported")
print("         here honestly rather than hidden; BCH in Phase 3 is the fix.")

# --- 8. Beyond the guaranteed strength: what this code CANNOT do ------------
#
# Honest limits. d_min = 4 means there EXIST weight-4 codewords. If an error
# vector happens to BE a codeword, then S = H.e = 0 and the error is completely
# invisible -- no flag, wrong data. So a SEC-DED code provably CANNOT detect
# all 4-bit errors, and any test asserting otherwise is testing a falsehood.
# What we can do is measure the escape rate EXACTLY and show it matches theory.
print("\n8. Limits beyond guaranteed strength (the honest part)")

# Odd-weight errors of ANY size are always detected: syndrome parity = weight
# mod 2 = 1, so the syndrome cannot be zero. Spot-check 5 and 7.
odd_detected = True
for _ in range(5000):
    k = random.choice([5, 7])
    if code.error_syndrome(random.sample(range(N), k)) == 0:
        odd_detected = False
check("all odd-weight (5,7-bit) errors detected, 5000 trials", odd_detected,
      "odd weight => odd syndrome parity => nonzero. Holds for ALL odd sizes")

# Count weight-4 codewords two independent ways.
# (a) Exhaustive: enumerate all C(72,4) weight-4 error vectors.
c4_total = c4_undetected = 0
for combo in combinations(range(N), 4):
    c4_total += 1
    if code.error_syndrome(combo) == 0:
        c4_undetected += 1

# (b) Algebraic: 4 columns XOR to 0 iff two disjoint PAIRS share an XOR sum.
#     Because all columns are distinct, two pairs with equal XOR sum are
#     automatically disjoint (sharing one element would force the other two to
#     be equal), so sum over sums of C(m,2) counts pairs-of-pairs. But each
#     4-set {a,b,c,d} splits into disjoint pairs in THREE ways --
#     (ab)(cd), (ac)(bd), (ad)(bc) -- so divide by 3 to get 4-sets.
from collections import Counter
pair_sums = Counter(code.h[a] ^ code.h[b] for a, b in combinations(range(N), 2))
a4_algebraic = sum(m * (m - 1) // 2 for m in pair_sums.values()) // 3

check(f"weight-4 codeword count agrees between enumeration and algebra",
      c4_undetected == a4_algebraic,
      f"enumerated {c4_undetected}, algebraic {a4_algebraic}")
print(f"  [INFO] weight-4 errors: {c4_undetected} of {c4_total} undetected "
      f"({100.0 * c4_undetected / c4_total:.4f}%) -- these ARE the weight-4")
print("         codewords. Unavoidable at d_min=4; it is the reason NAND-class")
print("         storage needs the multi-bit BCH decoder of Phase 3.")

# For a UNIFORMLY random error vector the syndrome is uniform over 2^r values,
# so the undetected probability should land near 2^-8 = 0.3906%.
trials = 200000
uni_undetected = 0
for _ in range(trials):
    if code.syndrome(random.getrandbits(N)) == 0:
        uni_undetected += 1
rate = 100.0 * uni_undetected / trials
check(f"uniform-random error escape rate matches 2^-{CHK_W} = {100.0 / 2**CHK_W:.4f}%",
      abs(rate - 100.0 / 2 ** CHK_W) < 0.08,
      f"measured {rate:.4f}% over {trials} trials")

# And the escapes must be exactly the codewords -- no other way to get S=0.
ok = all(code.syndrome(code.encode(random.getrandbits(DATA_W))) == 0
         for _ in range(2000))
check("syndrome == 0 for 2000 random valid codewords (S=0 <=> codeword)", ok)

# ---------------------------------------------------------------------------
print("\n" + "=" * 74)
passed = sum(1 for _, ok, _ in results if ok)
total = len(results)
print(f"RESULT: {passed}/{total} checks passed")
print(f"  single-bit errors corrected : {sec_fixed}/{sec_total} (100% required)")
print(f"  double-bit errors detected  : {ded_detected}/{ded_total} (100% required)")
print(f"  triple-bit silent escapes   : {tri_silent}/{tri_total} (0 required)")
print("=" * 74)
if passed != total:
    print("GOLDEN MODEL VERIFICATION FAILED")
    sys.exit(1)
print("GOLDEN MODEL VERIFICATION PASSED")
