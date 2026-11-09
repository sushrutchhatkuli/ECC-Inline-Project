#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# run_xsim.sh -- compile and run the Phase 1 SECDED testbench under Vivado XSim
#
# Usage (from Git Bash, anywhere in the repo):
#   sim/run_xsim.sh                 # run the testbench
#   sim/run_xsim.sh --wave          # elaborate with full debug for waveforms
#   VIVADO_HOME=/c/Xilinx/2025.1/Vivado sim/run_xsim.sh
#   XSIM_WORK=/c/tmp/mysim sim/run_xsim.sh
#
# WHY THE BUILD RUNS OUTSIDE THE REPO
# -----------------------------------
# Vivado's command-line tools on Windows are cmd.exe batch wrappers
# (xvlog.bat, xelab.bat, xsim.bat). cmd.exe batch parsing treats '(' and ')'
# as grouping characters, and the wrappers interpolate the CURRENT DIRECTORY
# (%CD%) into their own commands. This repo lives in
#   .../inline ECC (error-correcting code) engine for a memorybus interface
# whose parentheses make the wrapper die with
#   "... was unexpected at this time".
# Passing 8.3 short paths for the SOURCES is not enough, because the failure
# comes from the working directory, and Git Bash's `cd` to a short path still
# leaves Windows' %CD% as the long name. So the simulator is run from a scratch
# directory that has no spaces or parentheses, sources are handed over as 8.3
# short paths, and sim.log is copied back into sim/work/ afterwards.
#
# The alternative is to rename the project directory to something like
# C:/work/inline-ecc, which removes the problem at the source. This script
# exists so that is a choice rather than a requirement.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VIVADO_HOME="${VIVADO_HOME:-/c/Xilinx/2025.1/Vivado}"
TOP=tb_secded

WAVE=0
[[ "${1:-}" == "--wave" ]] && WAVE=1

if [[ ! -f "$VIVADO_HOME/bin/xvlog.bat" ]]; then
  echo "ERROR: Vivado not found at $VIVADO_HOME" >&2
  echo "       set VIVADO_HOME to your Vivado install directory, e.g." >&2
  echo "       VIVADO_HOME=/c/Xilinx/2025.1/Vivado sim/run_xsim.sh" >&2
  exit 1
fi
export PATH="$VIVADO_HOME/bin:$PATH"

# --- the golden model owns the generated sources -----------------------------
# Regenerate first, so a stale generated file can never be the reason a run
# passes or fails.
echo "== regenerating generated sources from the golden model =="
python "$REPO/model/gen_rtl.py"

# --- scratch build directory, free of spaces and parentheses -----------------
if [[ -n "${XSIM_WORK:-}" ]]; then
  SIMDIR="$XSIM_WORK"
elif [[ -n "${LOCALAPPDATA:-}" ]]; then
  SIMDIR="$(cygpath -u "$LOCALAPPDATA")/Temp/ecc_phase1_xsim"
else
  SIMDIR="/c/tmp/ecc_phase1_xsim"
fi

if [[ "$SIMDIR" == *" "* || "$SIMDIR" == *"("* ]]; then
  echo "ERROR: build directory still contains a space or parenthesis:" >&2
  echo "       $SIMDIR" >&2
  echo "       set XSIM_WORK to a clean path, e.g. XSIM_WORK=/c/tmp/ecc_sim" >&2
  exit 1
fi

rm -rf "$SIMDIR"
mkdir -p "$SIMDIR"

# 8.3 short form of the repo, for handing source paths to the batch wrappers.
SHORT="$(cygpath -u "$(cygpath -w -s "$REPO")")"
if [[ "$SHORT" == *" "* || "$SHORT" == *"("* ]]; then
  echo "ERROR: could not get a short path free of spaces/parentheses for" >&2
  echo "       $REPO" >&2
  echo "       8.3 name creation is probably disabled on this volume. Move or" >&2
  echo "       rename the repo to a path with no spaces or parentheses," >&2
  echo "       e.g. C:/work/inline-ecc." >&2
  exit 1
fi

# Stage the generated vectors next to the simulation so the testbench can open
# them with a bare filename -- no host path has to survive quoting through the
# cmd.exe batch wrappers (which also mangle "-testplusarg NAME=C:/path").
cp "$REPO/tb/vectors/secded_vectors.txt" "$SIMDIR/secded_vectors.txt"

cd "$SIMDIR"

echo "   build dir : $SIMDIR"
echo "   sources   : $SHORT"

echo
echo "== xvlog (analyse) =="
xvlog.bat -sv -nolog \
  "$SHORT/rtl/ecc_hsiao_pkg.sv" \
  "$SHORT/rtl/secded_encoder.sv" \
  "$SHORT/rtl/secded_decoder.sv" \
  "$SHORT/tb/tb_secded.sv"

echo
echo "== xelab (elaborate) =="
if [[ $WAVE -eq 1 ]]; then
  xelab.bat -nolog -debug all -timescale 1ns/1ps "$TOP" -s "${TOP}_sim"
else
  xelab.bat -nolog -debug typical -O2 -timescale 1ns/1ps "$TOP" -s "${TOP}_sim"
fi

echo
echo "== xsim (run) =="
set +e
xsim.bat "${TOP}_sim" -nolog -R 2>&1 | tee sim.log
set -e

# Keep the log with the repo even though the build happened elsewhere.
mkdir -p "$REPO/sim/work"
cp sim.log "$REPO/sim/work/sim.log"

echo
if grep -q "ALL TESTS PASSED" sim.log; then
  echo "RESULT: PASS   (log copied to sim/work/sim.log)"
  exit 0
else
  echo "RESULT: FAIL   (log copied to sim/work/sim.log)"
  exit 1
fi
