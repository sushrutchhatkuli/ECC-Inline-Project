"""
Hsiao SEC-DED code -- golden reference model.
================================================

This module is the SINGLE SOURCE OF TRUTH for the ECC engine. The RTL parity
matrix is generated from here, and the testbench is checked against here.

--------------------------------------------------------------------------
1. WHAT A LINEAR BLOCK CODE IS
--------------------------------------------------------------------------
We protect k data bits with r check bits, transmitting n = k + r bits.
For DRAM-class ECC: k = 64, r = 8, n = 72  -> the classic "72/64" DIMM width.

The code is defined by a parity-check matrix H of shape (r x n) over GF(2)
(i.e. arithmetic mod 2, where + is XOR). A vector c of n bits is a valid
codeword iff

        H . c = 0        (all arithmetic mod 2)

We use a SYSTEMATIC code, meaning H = [ A | I_r ]:
  - columns 0 .. k-1  = A, the "data columns" (arbitrary, we get to choose them)
  - columns k .. n-1  = I_r, an r x r identity matrix (the check-bit columns)

Systematic => the data appears verbatim in the codeword, so a reader that
trusts the data can skip the decoder entirely. Every real memory ECC is
systematic for exactly this reason.

Row i of H says: XOR of all code bits j where H[i][j] == 1 must be 0.
Because the check-bit part is the identity, row i contains exactly one check
bit (check bit i), so that row rearranges to:

        check[i] = XOR of data[j] for all j<k where A[i][j] == 1

That IS the encoder. Nothing more.

--------------------------------------------------------------------------
2. THE SYNDROME, AND WHY IT POINTS AT THE BROKEN BIT
--------------------------------------------------------------------------
Say we store codeword c and read back r = c + e, where e is the error vector
(a 1 in every position that flipped). The decoder computes the SYNDROME:

        S = H . r = H . (c + e) = H.c + H.e = 0 + H.e = H . e

So the syndrome depends ONLY on the error, never on the data. That is the
whole trick. Now:

  - e = 0 (no error)        -> S = 0
  - e has a single 1 at p   -> S = column p of H

So if S is nonzero and equals some column p, the most likely explanation is
"bit p flipped" -> flip bit p back. Single Error Correct (SEC).

For this to be unambiguous every column of H must be distinct and nonzero.
That is exactly the classical Hamming condition, and it gives minimum
distance d_min = 3: correct 1 error, OR detect 2, but not both at once
(with d=3 a 2-bit error looks identical to some 1-bit error, so the decoder
"corrects" it into a third wrong word -- silent data corruption).

--------------------------------------------------------------------------
3. GETTING TO SEC-DED: THE HSIAO CONSTRUCTION
--------------------------------------------------------------------------
To correct 1 AND detect 2 we need d_min = 4. The textbook route is "extended
Hamming": take a d=3 Hamming code and bolt on one extra overall-parity bit.
Hsiao (IBM, 1970) found a better route that gives the same d_min = 4 with
strictly less hardware. His three rules:

    (H1) every column of H is nonzero
    (H2) every column of H has ODD weight   (odd number of 1s)
    (H3) all columns of H are distinct

Claim: (H1)+(H2)+(H3)  =>  d_min >= 4.

Proof. d_min >= 4 means no set of 1, 2 or 3 columns XORs to zero.
  - 1 column:  nonzero by (H1).
  - 2 columns: XOR to 0 only if equal; excluded by (H3).
  - 3 columns: weight-mod-2 is a linear functional over GF(2), so
        wt(a+b+c) mod 2 = (wt a + wt b + wt c) mod 2 = (1+1+1) mod 2 = 1
    An odd-weight vector cannot be zero. So no 3 columns sum to zero.
Hence d_min >= 4.  []

Note (H2) is stronger than we asked for: it kills EVERY odd-size error
pattern, not just size 3. Any odd number of flipped bits always produces a
nonzero syndrome, so an odd-weight error is NEVER silently accepted.

d_min is exactly 4 (not more): the four columns of weight 3
{0,1,2}, {0,1,3}, plus check columns {2}, {3} XOR to zero, and
verify_properties() below exhibits such a set explicitly.

--------------------------------------------------------------------------
4. WHY ODD COLUMN WEIGHT MAKES THE DECODER ALMOST FREE
--------------------------------------------------------------------------
Let p(S) = XOR of all r bits of the syndrome. Then

        p(S) = p(H.e) = sum over flipped positions of wt(column) mod 2
             = (number of flipped bits) mod 2        [because all wt are odd]

So ONE 8-input XOR tells us the parity of the error count. The decode rule:

        S == 0                       -> no error
        S != 0 and p(S) == 1         -> odd # errors; assume 1, find the
                                        column equal to S, flip that bit  (CE)
        S != 0 and p(S) == 0         -> even # errors (>=2) -> uncorrectable (UE)
        p(S) == 1 but no column      -> >=3 errors -> uncorrectable (UE)
                matches S

Compare with extended Hamming, which needs a separate overall-parity bit,
separate bookkeeping, and has wildly unbalanced column weights (1..7) that
blow up the XOR tree depth. Hsiao gets the DED flag for free out of the
syndrome itself.

--------------------------------------------------------------------------
5. CHOOSING THE DATA COLUMNS = CHOOSING THE AREA AND THE CRITICAL PATH
--------------------------------------------------------------------------
Rules H1-H3 leave us lots of freedom. Two hardware costs decide it:

  total weight of H       ~ total number of XOR gate inputs      ~ AREA
  max ROW weight of H     ~ fan-in of the widest parity tree     ~ DELAY
                            (depth = ceil(log_b(row weight)) for b-input XOR)

So: pick the LOWEST-weight legal columns (minimises area), and spread the 1s
EVENLY ACROSS ROWS (minimises the deepest XOR tree).

For r = 8 the odd-weight columns available are
    weight 1: C(8,1) =  8   <- reserved for the identity part I_8
    weight 3: C(8,3) = 56
    weight 5: C(8,5) = 56
    weight 7: C(8,7) =  8
                       ---
                       128  = 2^7, exactly half of all 256 vectors

We need 64 data columns of weight >= 3. Only 56 weight-3 columns exist, so at
least 64 - 56 = 8 columns must have weight >= 5. Therefore the minimum
possible data-side weight is

        56*3 + 8*5 = 168 + 40 = 208

and that bound is ACHIEVABLE -- this implementation hits it. 208 / 8 rows = 26,
and perfect balance is arithmetically possible: all 56 weight-3 columns
already contribute C(7,2) = 21 ones to every row, leaving 26 - 21 = 5 per row
to come from the 8 weight-5 columns, and 8 rows x 5 = 40 = 8 cols x 5 ones.
So we look for 8 weight-5 columns covering each row exactly 5 times.

Explicit construction: let T_i = {i, i+1, i+3} mod 8 for i = 0..7 and let
column C_i be the COMPLEMENT of T_i (weight 8-3 = 5). Row x lies in T_i for
exactly i in {x, x-1, x-3} -- three distinct values mod 8 -- so row x lies
OUTSIDE 8-3 = 5 of the T_i, i.e. inside exactly 5 of the C_i. Balanced.
The eight T_i are pairwise distinct, so the eight C_i are too.

Adding I_8 puts one more 1 in each row, so every row of the final 8x72 H has
weight exactly 27, and the full H has weight 216.

Encoder cost estimate: 8 parity bits, each the XOR of 26 data bits
= 8 * 25 = 200 two-input XOR gates. On a 6-input-LUT FPGA each 26-input XOR
needs ceil(26/6)=5 LUTs then 1 more to combine = 6 LUTs, 2 logic levels
-> ~48 LUTs and 2 levels for the whole encoder. Real numbers come from
synthesis in Phase 2; this is the back-of-envelope to check them against.
"""

from itertools import combinations


# ----------------------------------------------------------------------------
# Small bit helpers. A "column" is an int whose bit i means "row i has a 1".
# ----------------------------------------------------------------------------

def popcount(x: int) -> int:
    return bin(x).count("1")


def parity(x: int) -> int:
    """XOR-reduction of all bits of x (1 if x has an odd number of 1s)."""
    return popcount(x) & 1


def _odd_weight_columns(chk_w: int, weight: int):
    """All chk_w-bit values of exactly the given weight, in numeric order."""
    cols = []
    for positions in combinations(range(chk_w), weight):
        v = 0
        for p in positions:
            v |= 1 << p
        cols.append(v)
    return sorted(cols)


def _balanced_fill(chosen, need, candidates, chk_w):
    """
    Greedily add `need` more columns from `candidates`, each pick being the one
    that keeps the per-row 1-counts as flat as possible.

    Score of a candidate = (max row count after adding,
                            sum of squares of row counts after adding,
                            numeric value)
    Minimising max flattens the worst-case XOR tree; sum-of-squares is a
    smooth tie-break that also pushes toward flatness; numeric value makes
    the result deterministic.
    """
    row = [0] * chk_w
    for c in chosen:
        for i in range(chk_w):
            if (c >> i) & 1:
                row[i] += 1

    pool = list(candidates)
    for _ in range(need):
        best, best_score = None, None
        for cand in pool:
            trial = list(row)
            for i in range(chk_w):
                if (cand >> i) & 1:
                    trial[i] += 1
            score = (max(trial), sum(t * t for t in trial), cand)
            if best_score is None or score < best_score:
                best, best_score = cand, score
        pool.remove(best)
        chosen.append(best)
        for i in range(chk_w):
            if (best >> i) & 1:
                row[i] += 1
    return chosen


# ----------------------------------------------------------------------------
# The code itself
# ----------------------------------------------------------------------------

class HsiaoCode:
    """
    A systematic Hsiao SEC-DED code.

    Bit numbering convention used EVERYWHERE in this project (RTL included):

        code bit j      for j in 0 .. data_w-1   is data bit j
        code bit data_w+i                        is check bit i

    so as an integer, codeword = (check << data_w) | data.

    self.h[j] is the parity-check column for code bit j, packed as an int
    whose bit i is H[i][j].
    """

    def __init__(self, data_w: int = 64, chk_w: int = 8):
        self.data_w = data_w
        self.chk_w = chk_w
        self.n = data_w + chk_w
        self.h = self._build_h()
        # syndrome value -> code bit position, for the single-error lookup
        self.syndrome_to_pos = {col: j for j, col in enumerate(self.h)}

    # -- construction ------------------------------------------------------

    def _build_h(self):
        chk_w, data_w = self.chk_w, self.data_w

        # Minimum-weight legal columns first: weight 3, then 5, then 7, ...
        # Weight 1 is reserved for the identity (check-bit) columns.
        data_cols = []
        weight = 3
        while len(data_cols) < data_w:
            if weight > chk_w:
                raise ValueError(
                    f"cannot build a Hsiao code with data_w={data_w}, "
                    f"chk_w={chk_w}: not enough odd-weight columns"
                )
            tier = _odd_weight_columns(chk_w, weight)
            remaining = data_w - len(data_cols)
            if len(tier) <= remaining:
                # Take the whole tier -- no choice to make, and taking a whole
                # weight-w tier is automatically row-balanced by symmetry.
                data_cols.extend(tier)
            else:
                # Partial tier: choose which ones, balancing the rows.
                data_cols = _balanced_fill(data_cols, remaining, tier, chk_w)
            weight += 2

        # Systematic: append the identity columns (weight 1 -> odd, distinct).
        chk_cols = [1 << i for i in range(chk_w)]
        return data_cols + chk_cols

    # -- encode / decode ---------------------------------------------------

    def check_bits(self, data: int) -> int:
        """check[i] = XOR of data[j] over all j where H[i][j] == 1."""
        chk = 0
        for i in range(self.chk_w):
            acc = 0
            for j in range(self.data_w):
                if (self.h[j] >> i) & 1:
                    acc ^= (data >> j) & 1
            chk |= acc << i
        return chk

    def encode(self, data: int) -> int:
        """data -> n-bit codeword  (check << data_w) | data."""
        assert 0 <= data < (1 << self.data_w)
        return (self.check_bits(data) << self.data_w) | data

    def syndrome(self, code: int) -> int:
        """
        S = H . code.  Zero for every valid codeword.

        Computed column-wise: a matrix-vector product over GF(2) is just the
        XOR of the columns selected by the 1 bits of the vector. Same answer as
        the row-wise definition (syndrome_rowwise below, kept as an independent
        cross-check in the tests) but ~r times faster.
        """
        s = 0
        j = 0
        while code:
            if code & 1:
                s ^= self.h[j]
            code >>= 1
            j += 1
        return s

    def syndrome_rowwise(self, code: int) -> int:
        """
        Literal transcription of "row i of H dotted with code", used only to
        cross-check syndrome(). Two independent implementations agreeing is
        worth more than one implementation we stared at.
        """
        s = 0
        for i in range(self.chk_w):
            acc = 0
            for j in range(self.n):
                if (self.h[j] >> i) & 1:
                    acc ^= (code >> j) & 1
            s |= acc << i
        return s

    def error_syndrome(self, positions) -> int:
        """Syndrome produced by flipping exactly the given code-bit positions."""
        s = 0
        for p in positions:
            s ^= self.h[p]
        return s

    def decode(self, code: int) -> dict:
        """
        Decode a possibly-corrupted n-bit word.

        Returns:
          data        : data field after correction (uncorrected if UE)
          syndrome    : the raw syndrome
          detected    : any error seen at all (syndrome != 0)
          corrected   : a single-bit error was located and repaired (CE)
          uncorrectable: an error was seen but could not be repaired (UE/DUE)
          flip_pos    : code-bit position repaired, or None
        """
        s = self.syndrome(code)
        s_nonzero = s != 0
        s_odd = parity(s) == 1          # odd # of errors, since all cols odd
        pos = self.syndrome_to_pos.get(s) if s_odd else None

        corrected = pos is not None
        fixed = code ^ (1 << pos) if corrected else code

        return {
            "data": fixed & ((1 << self.data_w) - 1),
            "syndrome": s,
            "detected": s_nonzero,
            "corrected": corrected,
            "uncorrectable": s_nonzero and not corrected,
            "flip_pos": pos,
        }

    # -- introspection used by the tests and the report --------------------

    def row_weights(self):
        return [sum(1 for c in self.h if (c >> i) & 1) for i in range(self.chk_w)]

    def col_weights(self):
        return [popcount(c) for c in self.h]

    def total_weight(self):
        return sum(self.col_weights())

    def verify_properties(self) -> dict:
        """
        Check Hsiao's three rules directly, and exhibit a weight-4 codeword to
        pin d_min at exactly 4 (rules H1-H3 only prove d_min >= 4).
        """
        cols = self.h
        all_nonzero = all(c != 0 for c in cols)
        all_odd = all(popcount(c) & 1 for c in cols)
        all_distinct = len(set(cols)) == len(cols)

        # Find 4 columns XORing to 0 -> a weight-4 codeword -> d_min <= 4.
        # Search is cheap because a + b must equal c + d; hash the pair sums.
        pair_sum = {}
        witness = None
        for a, b in combinations(range(len(cols)), 2):
            s = cols[a] ^ cols[b]
            if s in pair_sum:
                c, d = pair_sum[s]
                if len({a, b, c, d}) == 4:
                    witness = (c, d, a, b)
                    break
            else:
                pair_sum[s] = (a, b)

        return {
            "h1_all_nonzero": all_nonzero,
            "h2_all_odd_weight": all_odd,
            "h3_all_distinct": all_distinct,
            "d_min_ge_4": all_nonzero and all_odd and all_distinct,
            "d_min_le_4_witness": witness,
            "row_weights": self.row_weights(),
            "total_weight": self.total_weight(),
            "col_weight_histogram": {
                w: self.col_weights().count(w) for w in sorted(set(self.col_weights()))
            },
        }


if __name__ == "__main__":
    code = HsiaoCode(64, 8)
    props = code.verify_properties()
    print(f"Hsiao SEC-DED ({code.n},{code.data_w})")
    print(f"  H1 columns nonzero      : {props['h1_all_nonzero']}")
    print(f"  H2 columns odd weight   : {props['h2_all_odd_weight']}")
    print(f"  H3 columns distinct     : {props['h3_all_distinct']}")
    print(f"  => d_min >= 4           : {props['d_min_ge_4']}")
    print(f"  weight-4 codeword cols  : {props['d_min_le_4_witness']}  => d_min == 4")
    print(f"  column weight histogram : {props['col_weight_histogram']}")
    print(f"  row weights             : {props['row_weights']}")
    print(f"  total H weight          : {props['total_weight']}")
