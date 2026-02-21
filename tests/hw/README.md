# Hardware Tests — papilio_wishbone_sdram

## Overview

These tests validate the firmware API and FPGA gateware integration on real hardware.

## Hardware Requirements

- Papilio Retrocade board
- FPGA programmed with correct bitstream (including `papilio_sdram_wb`)
- ESP32 connected via USB
- Serial monitor at 115200 baud

## Running Tests

```powershell
# From this directory
pio test -e esp32

# Or, if using workspace platformio.ini:
pio test -e hw_sdram
```

## Test Coverage

| Test                     | Description                              |
|--------------------------|------------------------------------------|
| `test_sdram_init_done`   | CSR.init_done asserts after power-up     |
| `test_sdram_write_read`  | Single-word write + read                 |
| `test_sdram_fill`        | Fill region, verify spot-check           |
| `test_sdram_block_xfer`  | Block write + read (256 words)           |
| `test_sdram_page_boundary`| Block transfer crossing page boundary  |
| `test_sdram_verify_pass` | Hardware verify (walking, small region)  |
| `test_sdram_verify_fail` | Corrupt one word, verify detects FAIL    |
| `test_sdram_all_banks`   | Address all 4 banks                      |

## Expected Output

```
Running test suite...

TEST: test_sdram_init_done
    PASS

TEST: test_sdram_write_read
    PASS
...
8 Tests 0 Failures 0 Ignored
OK
```
