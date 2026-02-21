#!/usr/bin/env python3
"""
run_all_sims.py — Run all papilio_wishbone_sdram simulation testbenches
Requires: iverilog and vvp in PATH
"""

import subprocess
import sys
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
GATEWARE   = os.path.join(SCRIPT_DIR, "..", "..", "gateware")

SIMS = [
    {
        "name":     "tb_sdram_ctrl",
        "top":      "tb_sdram_ctrl",
        "sources":  [
            os.path.join(SCRIPT_DIR, "tb_sdram_ctrl.v"),
            os.path.join(SCRIPT_DIR, "sdram_model.v"),
            os.path.join(GATEWARE,   "papilio_sdram_ctrl.v"),
        ],
        "defines":  [
            "+define+INIT_WAIT=200",
            "+define+SIM",
        ],
    },
    {
        "name":     "tb_sdram_wb",
        "top":      "tb_sdram_wb",
        "sources":  [
            os.path.join(SCRIPT_DIR, "tb_sdram_wb.v"),
            os.path.join(SCRIPT_DIR, "sdram_model.v"),
            os.path.join(GATEWARE,   "papilio_sdram_ctrl.v"),
            os.path.join(GATEWARE,   "papilio_sdram_wb.v"),
            os.path.join(GATEWARE,   "papilio_sdram_verify.v"),
        ],
        "defines":  [
            "+define+INIT_WAIT=200",
            "+define+SIM",
        ],
    },
]

def run_sim(sim):
    name    = sim["name"]
    out_vvp = os.path.join(SCRIPT_DIR, f"{name}.vvp")

    print(f"\n{'='*60}")
    print(f"  Compiling: {name}")
    print(f"{'='*60}")

    cmd_compile = ["iverilog", "-o", out_vvp, f"-s{sim['top']}"]
    cmd_compile += sim.get("defines", [])
    cmd_compile += sim["sources"]

    result = subprocess.run(cmd_compile, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"  COMPILE ERROR:\n{result.stderr}")
        return False

    print(f"  Running: {name}")
    result = subprocess.run(["vvp", out_vvp], capture_output=True, text=True, timeout=60)
    output = result.stdout + result.stderr
    print(output)

    passed = "ALL TESTS PASSED" in output or "PASS" in output
    failed = "FAIL" in output or result.returncode != 0
    if failed and not passed:
        print(f"  *** {name}: FAILED ***")
        return False
    print(f"  {name}: PASSED")
    return True


def main():
    print("papilio_wishbone_sdram — Simulation Test Suite")
    print(f"Working directory: {SCRIPT_DIR}")

    results = {}
    for sim in SIMS:
        results[sim["name"]] = run_sim(sim)

    print(f"\n{'='*60}")
    print("  SUMMARY")
    print(f"{'='*60}")
    all_pass = True
    for name, ok in results.items():
        status = "PASS" if ok else "FAIL"
        print(f"  {status}  {name}")
        if not ok:
            all_pass = False

    if all_pass:
        print("\nAll simulations passed.")
        sys.exit(0)
    else:
        print("\nSome simulations FAILED.")
        sys.exit(1)


if __name__ == "__main__":
    main()
