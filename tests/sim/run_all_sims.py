#!/usr/bin/env python3
"""
run_all_sims.py — Run all papilio_wishbone_sdram simulation testbenches
Requires: iverilog and vvp in PATH
"""

import subprocess
import sys
import os
import platform

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
GATEWARE   = os.path.join(SCRIPT_DIR, "..", "..", "gateware")

# On Windows (oss-cad-suite), iverilog needs environment.bat to load its DLLs.
OSS_ENV_BAT = r"C:\oss-cad-suite\environment.bat"

def _quote(path):
    return f'"{path}"' if " " in str(path) else str(path)

def iverilog_cmd(args):
    """Return a shell=True command string that runs iverilog."""
    if platform.system() == "Windows" and os.path.exists(OSS_ENV_BAT):
        arg_str = " ".join(_quote(a) for a in args)
        return f'call "{OSS_ENV_BAT}" && iverilog {arg_str}', True
    return "iverilog " + " ".join(_quote(a) for a in args), False

def vvp_cmd(vvp_file):
    if platform.system() == "Windows" and os.path.exists(OSS_ENV_BAT):
        return f'call "{OSS_ENV_BAT}" && vvp "{vvp_file}"', True
    return f'vvp "{vvp_file}"', False

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
            "-DINIT_WAIT=200",
            "-DSIM",
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
            "-DINIT_WAIT=200",
            "-DSIM",
        ],
    },
]

def run_sim(sim):
    name    = sim["name"]
    out_vvp = os.path.join(SCRIPT_DIR, f"{name}.vvp")

    print(f"\n{'='*60}")
    print(f"  Compiling: {name}")
    print(f"{'='*60}")

    iverilog_args = ["-o", out_vvp, f"-s{sim['top']}"]
    iverilog_args += sim.get("defines", [])
    iverilog_args += sim["sources"]

    cmd_compile, shell = iverilog_cmd(iverilog_args)
    result = subprocess.run(cmd_compile, capture_output=True, text=True, shell=shell)
    if result.returncode != 0:
        print(f"  COMPILE ERROR:\n{result.stderr or result.stdout}")
        return False

    print(f"  Running: {name}")
    cmd_run, shell = vvp_cmd(out_vvp)
    result = subprocess.run(cmd_run, capture_output=True, text=True, timeout=60, shell=shell)
    output = result.stdout + result.stderr
    print(output)

    passed = "ALL TESTS PASSED" in output or ("PASS" in output and "FAIL" not in output)
    if not passed:
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
