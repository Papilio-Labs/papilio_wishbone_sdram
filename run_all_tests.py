#!/usr/bin/env python3
"""
run_all_tests.py — Top-level test runner for papilio_wishbone_sdram
Runs simulation tests; hardware tests require manual setup.
"""

import subprocess
import sys
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SIM_RUNNER  = os.path.join(SCRIPT_DIR, "tests", "sim", "run_all_sims.py")


def section(title):
    width = 60
    print(f"\n{'='*width}")
    print(f"  {title}")
    print(f"{'='*width}")


def run_sims():
    section("Simulation Tests (Icarus Verilog)")
    if not os.path.exists(SIM_RUNNER):
        print(f"  ERROR: sim runner not found at {SIM_RUNNER}")
        return False

    result = subprocess.run(
        [sys.executable, SIM_RUNNER],
        cwd=os.path.dirname(SIM_RUNNER),
    )
    return result.returncode == 0


def main():
    print("papilio_wishbone_sdram — Full Test Suite")
    print(f"Library root: {SCRIPT_DIR}")

    results = {}
    results["simulation"] = run_sims()

    section("Hardware Tests")
    print("  Hardware tests require:")
    print("    1. Papilio Retrocade with SDRAM FPGA bitstream")
    print("    2. ESP32 connected via USB")
    print("  To run:")
    print(f"    cd {os.path.join(SCRIPT_DIR, 'tests', 'hw')}")
    print("    pio test -e esp32")
    print("  (Skipping hardware tests in automated run)")

    section("Summary")
    all_pass = True
    for name, ok in results.items():
        status = "PASS" if ok else "FAIL"
        print(f"  {status}  {name}")
        if not ok:
            all_pass = False

    if all_pass:
        print("\nAll automated tests passed.")
        sys.exit(0)
    else:
        print("\nSome tests FAILED.")
        sys.exit(1)


if __name__ == "__main__":
    main()
