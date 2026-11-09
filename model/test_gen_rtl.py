"""
Drift guard for the generated sources.

rtl/ecc_hsiao_pkg.sv, tb/vectors/secded_vectors.txt and docs/h_matrix.md are
GENERATED from model/hsiao.py. They are checked into git (so the repo builds
without running Python first, and so changes to the parity matrix show up as a
reviewable diff), which creates exactly one hazard: somebody edits the
generated file by hand, or edits the model and forgets to regenerate. Then the
RTL and its own reference model silently describe different codes.

This test regenerates everything in memory and byte-compares. Run it in CI and
before every commit.

Run:  python model/test_gen_rtl.py
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_rtl
from hsiao import HsiaoCode

REPO = gen_rtl.REPO


def main():
    code = HsiaoCode(gen_rtl.DATA_W, gen_rtl.CHK_W)
    expected = {
        "rtl/ecc_hsiao_pkg.sv": gen_rtl.gen_pkg(code),
        "tb/vectors/secded_vectors.txt": gen_rtl.gen_vectors(code),
        "docs/h_matrix.md": gen_rtl.gen_h_doc(code),
    }

    failures = []
    for rel, want in expected.items():
        path = os.path.join(REPO, rel)
        if not os.path.exists(path):
            failures.append(f"{rel}: missing")
            print(f"  [FAIL] {rel}: missing")
            continue
        with open(path, newline="") as f:
            got = f.read().replace("\r\n", "\n")
        if got == want:
            print(f"  [PASS] {rel}: up to date ({len(want.splitlines())} lines)")
        else:
            # Report the first differing line so the cause is obvious.
            gl, wl = got.splitlines(), want.splitlines()
            where = "length differs"
            for i, (a, b) in enumerate(zip(gl, wl), 1):
                if a != b:
                    where = f"first diff at line {i}:\n    on disk: {a!r}\n    model  : {b!r}"
                    break
            failures.append(rel)
            print(f"  [FAIL] {rel}: STALE -- {where}")

    print()
    if failures:
        print("GENERATED SOURCES ARE STALE")
        print("Run:  python model/gen_rtl.py")
        sys.exit(1)
    print("All generated sources match the golden model.")


if __name__ == "__main__":
    print("Checking generated sources against model/hsiao.py")
    main()
