# AI_SKILL.md — papilio_wishbone_sdram

> For general Papilio development skills (tool setup, simulation, WB bus protocol),
> see `papilio_dev_tools/AI_SKILL.md`.

---

## Library Purpose

`papilio_wishbone_sdram` provides access to the 32 MB Winbond W9825G6KH-6
SDR SDRAM on the Papilio Retrocade board via the Wishbone bus.

Primary use cases (Phase 1):
1. Large buffer storage for logic analyzer capture
2. External framebuffer for HDMI output (Phase 2)
3. Shared memory between multiple peripherals

---

## File Map

```
src/PapilioSdram.h        — ESP32 API header (always compiled)
src/PapilioSdram.cpp      — ESP32 API implementation
src/PapilioSdramOS.h      — CLI plugin header (#ifdef ENABLE_PAPILIO_OS)
src/PapilioSdramOS.cpp    — CLI plugin implementation
gateware/papilio_sdram_ctrl.v   — Core SDRAM state machine
gateware/papilio_sdram_wb.v     — Wishbone slave wrapper + CDC
gateware/papilio_sdram_verify.v — Hardware verification engine
gateware/constraints/papilio_retrocade.cst — Pin assignments
tests/sim/sdram_model.v         — W9825G6KH-6 behavioral model
tests/sim/tb_sdram_ctrl.v       — Controller testbench
tests/sim/tb_sdram_wb.v         — WB wrapper testbench
tests/sim/run_all_sims.py       — Simulation runner
tests/hw/test/test_sdram.cpp    — Hardware unity tests
examples/SdramCLI/SdramCLI.ino — Example sketch
```

---

## Register Map (Wishbone, BASE_ADDR = 0x8000)

| Offset | Name      | Access | Bits        | Description                        |
|--------|----------|--------|-------------|-------------------------------------|
| 0x0000 | CSR       | R      | [0]         | init_done (1 = SDRAM ready)         |
| 0x0004 | PAGE_REG  | R/W    | [12:0]      | Current page number (0–8191)        |
| 0x0008 | DIR_ADDR  | R/W    | [23:0]      | Direct word address                 |
| 0x000C | DIR_DATA  | R/W    | [15:0]      | Write → SDRAM write; Read → read    |
| 0x0010 | VFY_CTRL  | R/W    | [1:0]=pat   | Pattern select                      |
|        |           |        | [7]=start   | Write 1 to begin verification       |
|        |           |        | [8]=done    | Read: 1 when verification finished  |
|        |           |        | [9]=pass    | Read: 1 when verification passed    |
| 0x0014 | VFY_START | R/W    | [23:0]      | Start word address of verify region |
| 0x0018 | VFY_SIZE  | R/W    | [23:0]      | Size of verify region in words      |
| 0x001C | VFY_FAIL  | R      | [23:0]      | First failure word address          |
| 0x0100–| PAGE_WIN  | R/W    | [15:0]      | 256-word paged window               |
| 0x01FF |           |        |             | WB offset → SDRAM col address       |

---

## SDRAM Addressing

```
Word address [23:0]:
  [23:22] = bank   (2 bits, 4 banks)
  [21:9]  = row    (13 bits, 8192 rows per bank)
  [8:0]   = column (9 bits, 512 columns per row)

Total words: 4 × 8192 × 512 = 16,777,216 = 16M words = 32 MB
```

---

## Common Operations

### Read CSR via raw WB
```python
# Python (via papilio_dev_tools WB helper)
csr = wb.read(0x8000)
init_done = (csr >> 0) & 1
```

### Single R/W via DIR_ADDR/DIR_DATA
```python
wb.write(0x8008, 0x001234)   # DIR_ADDR = word address 0x1234
wb.write(0x800C, 0xABCD)     # DIR_DATA write → triggers SDRAM write
wb.write(0x8008, 0x001234)   # DIR_ADDR = word address 0x1234
data = wb.read(0x800C)       # DIR_DATA read → triggers SDRAM read
```

### Start hardware verify
```python
wb.write(0x8014, 0)          # VFY_START = 0
wb.write(0x8018, 0x100000)   # VFY_SIZE = 1M words
wb.write(0x8010, 0x80)       # VFY_CTRL: start=1, pattern=walking-ones
while not (wb.read(0x8010) & 0x100):
    time.sleep(0.1)           # Wait for done
passed = (wb.read(0x8010) >> 9) & 1
```

### ESP32 API
```cpp
sdram.writeWord(0x001234, 0xABCD);
uint16_t v = sdram.readWord(0x001234);
sdram.fill(0, 4096, 0xFF00);
bool ok = sdram.verify(SDRAM_PAT_ADDR);
```

---

## Timing Reference (100 MHz)

| Parameter | Cycles | Requirement   |
|-----------|--------|---------------|
| tRCD      | 2      | ≥ 15 ns       |
| tRP       | 2      | ≥ 15 ns       |
| tRC       | 6      | ≥ 60 ns       |
| tRFC      | 6      | ≥ 60 ns       |
| tWR       | 2      | ≥ 14 ns       |
| CL        | 3      | CAS latency 3 |
| Refresh   | 780    | 64ms/8192 rows |
| Init wait | 20000  | ≥ 100 µs      |

---

## CDC Design (Toggle-Handshake)

The Wishbone domain runs at 27 MHz; the SDRAM domain runs at 100 MHz.

```
WB side:
  req_tog_wb ──/toggle/──▶ 2FF sync ──▶ req_edge_sdram ──▶ ctrl_req pulse
                                                              ↓
                                                         SDRAM R/W
                                                              ↓
  ack_tog_sdram ◀──/toggle/── ack on completion
  ack_edge_wb ──▶ wb_ack_o
```

**Never** drive SDRAM pins directly from 27 MHz clock domain code.

---

## Adding Features

### New CLI command
1. Add static handler prototype to `PapilioSdramOS.h`
2. Implement handler in `PapilioSdramOS.cpp`
3. Register with `PapilioOS.registerCommand("sdram", "cmd", ...)` in `registerCommands()`

### New verify pattern
1. Add `PAT_NEW = 4` to the enum in `PapilioSdram.h`
2. Add `4'b0100` case to `papilio_sdram_verify.v` FSM write/read pattern logic
3. Update `patternName()` and `parsePattern()` in `PapilioSdramOS.cpp`

### New register
1. Add `#define SDRAM_REG_NEW 0x0020` to `PapilioSdram.h`
2. Add decode in `papilio_sdram_wb.v` register read/write block
3. Document in register map tables (README.md, gateware/README.md, AI_SKILL.md)

---

## Troubleshooting

| Symptom                   | Likely Cause                              | Fix                                          |
|--------------------------|-------------------------------------------|----------------------------------------------|
| `isReady()` never true    | FPGA bitstream not loaded                 | Upload bitstream; check PLL lock             |
| All reads return 0xFFFF   | SDRAM pins not connected in constraints   | Verify `papilio_retrocade.cst` is included   |
| Verify always fails       | CAS latency mismatch                      | Check CAS_LATENCY=3 in `papilio_sdram_ctrl`  |
| Sporadic wrong data       | CDC timing violation                      | Confirm `clk_sdram` is stable 100 MHz        |
| Write has no effect        | Page boundary not set                     | Set PAGE_REG before paged window writes      |

---

## Pin Assignments (Papilio Retrocade)

From `gateware/constraints/papilio_retrocade.cst`:

| Signal         | Pin  | Signal         | Pin  |
|---------------|------|---------------|------|
| sdram_addr[0]  | N15  | sdram_dq[0]    | K13  |
| sdram_addr[1]  | R16  | sdram_dq[1]    | K12  |
| sdram_addr[2]  | P15  | sdram_dq[2]    | K11  |
| sdram_addr[3]  | P16  | sdram_dq[3]    | L13  |
| sdram_addr[4]  | H13  | sdram_dq[4]    | H15  |
| sdram_addr[5]  | G14  | sdram_dq[5]    | G16  |
| sdram_addr[6]  | G15  | sdram_dq[6]    | H14  |
| sdram_addr[7]  | F14  | sdram_dq[7]    | H16  |
| sdram_addr[8]  | F16  | sdram_dq[8]    | C12  |
| sdram_addr[9]  | E15  | sdram_dq[9]    | B12  |
| sdram_addr[10] | N16  | sdram_dq[10]   | E15  |
| sdram_addr[11] | D14  | sdram_dq[11]   | F15  |
| sdram_addr[12] | A15  | sdram_dq[12]   | D16  |
| sdram_ba[0]    | L16  | sdram_dq[13]   | E10  |
| sdram_ba[1]    | N14  | sdram_dq[14]   | D10  |
| sdram_clk      | A14  | sdram_dq[15]   | D11  |
| sdram_cke      | B14  | sdram_dqm[0]   | J15  |
| sdram_cs_n     | T9   | sdram_dqm[1]   | B13  |
| sdram_ras_n    | K15  |                |      |
| sdram_cas_n    | K14  |                |      |
| sdram_we_n     | K16  |                |      |
