#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# run_xsim.sh -- compile and run a testbench under Vivado XSim
#
# Usage (from Git Bash, anywhere in the repo):
#   sim/run_xsim.sh                 # default target: secded (Phase 1)
#   sim/run_xsim.sh secded          # Phase 1  SECDED encoder/decoder
#   sim/run_xsim.sh axil            # Phase 2b AXI4-Lite slave + registers
#   sim/run_xsim.sh all             # every target, stops at the first failure
#   sim/run_xsim.sh secded --wave   # elaborate with full debug for waveforms
#
#   VIVADO_HOME=/c/Xilinx/2025.1/Vivado sim/run_xsim.sh axil
#   XSIM_WORK=/c/tmp/mysim           sim/run_xsim.sh axil
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
# Moving the repo to a path without spaces or parentheses (e.g.
# C:/work/inline-ecc) removes the problem at source; this script exists so
# that is a choice rather than a requirement.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VIVADO_HOME="${VIVADO_HOME:-/c/Xilinx/2025.1/Vivado}"

# --- target table ------------------------------------------------------------
# Each target names its top module, its source list and any data files that
# must be staged next to the simulation.
TARGETS="secded axil"

target_top() {
  case "$1" in
    secded) echo "tb_secded" ;;
    axil)   echo "tb_axil_regs" ;;
    *)      echo "" ;;
  esac
}

target_sources() {
  case "$1" in
    secded)
      echo "rtl/ecc_hsiao_pkg.sv rtl/secded_encoder.sv rtl/secded_decoder.sv tb/tb_secded.sv"
      ;;
    axil)
      echo "rtl/axil_slave.sv rtl/ecc_axil_ctrl.sv tb/tb_axil_regs.sv"
      ;;
  esac
}

target_data() {
  case "$1" in
    secded) echo "tb/vectors/secded_vectors.txt" ;;
    axil)   echo "" ;;
  esac
}

# --- argument parsing --------------------------------------------------------
TARGET="secded"
WAVE=0
for arg in "$@"; do
  case "$arg" in
    --wave) WAVE=1 ;;
    -*)     echo "ERROR: unknown option $arg" >&2; exit 1 ;;
    *)      TARGET="$arg" ;;
  esac
done

if [[ "$TARGET" != "all" && -z "$(target_top "$TARGET")" ]]; then
  echo "ERROR: unknown target '$TARGET'" >&2
  echo "       valid targets: $TARGETS all" >&2
  exit 1
fi

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

# --- 8.3 short form of the repo, for the batch wrappers ----------------------
SHORT="$(cygpath -u "$(cygpath -w -s "$REPO")")"
if [[ "$SHORT" == *" "* || "$SHORT" == *"("* ]]; then
  echo "ERROR: could not get a short path free of spaces/parentheses for" >&2
  echo "       $REPO" >&2
  echo "       8.3 name creation is probably disabled on this volume. Move or" >&2
  echo "       rename the repo to a path with no spaces or parentheses," >&2
  echo "       e.g. C:/work/inline-ecc." >&2
  exit 1
fi

run_one() {
  local tgt="$1"
  local top; top="$(target_top "$tgt")"
  local simdir

  if [[ -n "${XSIM_WORK:-}" ]]; then
    simdir="$XSIM_WORK/$tgt"
  elif [[ -n "${LOCALAPPDATA:-}" ]]; then
    simdir="$(cygpath -u "$LOCALAPPDATA")/Temp/ecc_xsim/$tgt"
  else
    simdir="/c/tmp/ecc_xsim/$tgt"
  fi

  if [[ "$simdir" == *" "* || "$simdir" == *"("* ]]; then
    echo "ERROR: build directory contains a space or parenthesis: $simdir" >&2
    echo "       set XSIM_WORK to a clean path, e.g. XSIM_WORK=/c/tmp/ecc_sim" >&2
    return 1
  fi

  rm -rf "$simdir"
  mkdir -p "$simdir"

  # Stage data files next to the simulation so the testbench can open them
  # with a bare filename -- no host path has to survive quoting through the
  # cmd.exe batch wrappers.
  local df
  for df in $(target_data "$tgt"); do
    cp "$REPO/$df" "$simdir/$(basename "$df")"
  done

  echo
  echo "######################################################################"
  echo "# target : $tgt   (top: $top)"
  echo "# build  : $simdir"
  echo "######################################################################"

  local srcs=()
  local s
  for s in $(target_sources "$tgt"); do
    srcs+=("$SHORT/$s")
  done

  cd "$simdir"

  echo
  echo "== xvlog (analyse) =="
  xvlog.bat -sv -nolog "${srcs[@]}"

  echo
  echo "== xelab (elaborate) =="
  if [[ $WAVE -eq 1 ]]; then
    xelab.bat -nolog -debug all -timescale 1ns/1ps "$top" -s "${top}_sim"
  else
    xelab.bat -nolog -debug typical -O2 -timescale 1ns/1ps "$top" -s "${top}_sim"
  fi

  echo
  echo "== xsim (run) =="
  set +e
  xsim.bat "${top}_sim" -nolog -R 2>&1 | tee sim.log
  set -e

  mkdir -p "$REPO/sim/work"
  cp sim.log "$REPO/sim/work/${tgt}_sim.log"

  echo
  if grep -q "ALL TESTS PASSED" sim.log; then
    echo "RESULT [$tgt]: PASS   (log: sim/work/${tgt}_sim.log)"
    return 0
  else
    echo "RESULT [$tgt]: FAIL   (log: sim/work/${tgt}_sim.log)"
    return 1
  fi
}

if [[ "$TARGET" == "all" ]]; then
  rc=0
  for t in $TARGETS; do
    if ! run_one "$t"; then rc=1; break; fi
  done
  echo
  if [[ $rc -eq 0 ]]; then
    echo "==> ALL TARGETS PASS"
  else
    echo "==> FAILURE (stopped at first failing target)"
  fi
  exit $rc
else
  run_one "$TARGET"
fi
