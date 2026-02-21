# Simulation Tests — papilio_wishbone_sdram

## Overview

These simulation testbenches verify the SDRAM controller gateware using
Icarus Verilog and a behavioral SDRAM model.

## Prerequisites

- [Icarus Verilog](http://iverilog.icarus.com/) (`iverilog` and `vvp` in PATH)
- Python 3.6+

## Running Tests

```powershell
# Run all simulations
python run_all_sims.py

# Run a single simulation manually
iverilog -o tb_sdram_ctrl.vvp -stb_sdram_ctrl +define+INIT_WAIT=200 +define+SIM \
    tb_sdram_ctrl.v sdram_model.v ../../gateware/papilio_sdram_ctrl.v
vvp tb_sdram_ctrl.vvp
```

## Test Files

### `sdram_model.v`
Behavioral model of the Winbond W9825G6KH-6 SDR SDRAM. Validates:
- Correct timing of command sequences
- Bank state tracking
- CAS latency pipeline
- Read/write data integrity

### `tb_sdram_ctrl.v`
Controller testbench — 8 scenarios:
1. Initialization — `init_done` asserted after power-up sequence
2. Write + read same row — verify data integrity
3. Page-hit optimization — no PRECHARGE/ACTIVE for same-row access
4. Multiple banks — verify independent bank state tracking
5. Row miss — PRECHARGE + ACTIVE on row change
6. Back-to-back writes — verify no corruption between ops
7. Back-to-back reads  — verify pipelining
8. Verify engine — autonomous hardware pattern check

### `tb_sdram_wb.v`
Wishbone wrapper testbench — 8 scenarios:
1. CSR register — `init_done` readable via WB
2. PAGE_REG default
3. PAGE_REG write/read-back
4. DIR_ADDR/DIR_DATA direct write via WB
5. DIR_ADDR/DIR_DATA direct read via WB
6. Paged window write
7. Paged window read
8. VFY registers + verify trigger + wait for done

## Expected Output

```
TEST 1: init_done
  PASS: CSR.init_done (got 0x00000001)
...
=== RESULTS: 8 passed, 0 failed ===
ALL TESTS PASSED
```
