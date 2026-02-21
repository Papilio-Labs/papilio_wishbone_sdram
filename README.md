# papilio_wishbone_sdram

External 32 MB SDRAM controller for the Papilio Retrocade FPGA board, accessible
via the Papilio Wishbone bus. Designed for HDMI framebuffer memory, logic analyzer
capture buffers, and general-purpose large storage.

---

## Features

- **32 MB** — Winbond W9825G6KH-6 (4 banks × 8192 rows × 512 cols × 16-bit)
- **100 MHz SDRAM clock** — dedicated rPLL from 27 MHz system clock
- **Zero CPU stall design** — toggle-handshake CDC between 27 MHz WB and 100 MHz SDRAM
- **Open-row page-hit optimization** — consecutive accesses to same row skip ACTIVE
- **Hardware memory verification** — 4 test patterns run autonomously in FPGA
- **Paged window access** — 256-word sliding window for streaming transfers
- **Dual CLI + programmatic API** — works standalone or with `papilio_os`

---

## Hardware Requirements

- Papilio Retrocade board (Gowin GW2A-LV18PG256C8/I7)
- Winbond W9825G6KH-6 SDRAM (soldered, on-board)
- FPGA bitstream with `papilio_sdram_wb` instantiated in `top.v`

---

## Installation

Add to your `platformio.ini`:
```ini
lib_deps =
    papilio_wishbone_sdram
```

For CLI support, define `ENABLE_PAPILIO_OS` and link with `papilio_os`.

---

## Quick Start

```cpp
#include <WishboneSPI.h>
#include <PapilioSdram.h>

WishboneSPI wb(/*cs=*/5);
PapilioSdram sdram(&wb);

void setup() {
    wb.begin();

    // Wait for SDRAM initialization (~200 µs after FPGA power-up)
    while (!sdram.isReady()) delay(1);

    // Write and read a word
    sdram.writeWord(0x000000, 0xBEEF);
    uint16_t val = sdram.readWord(0x000000);  // → 0xBEEF

    // Fill a region
    sdram.fill(0x010000, 1024, 0x0000);

    // Block transfer (handles page boundaries automatically)
    uint16_t buf[512];
    sdram.readBlock(0x008000, buf, 512);
}
```

---

## Programmatic API

### Initialization

```cpp
PapilioSdram sdram(&wb, 0x8000);  // base address optional, default 0x8000
sdram.begin();                     // optional: re-checks init_done
bool ready = sdram.isReady();
```

### Single-Word Access

```cpp
sdram.writeWord(uint32_t addr, uint16_t data);
uint16_t data = sdram.readWord(uint32_t addr);
```

Addresses are **word addresses** (0 = first word, 1 = second word, etc.).
Maximum address: `0xFFFFFF` (16,777,215 words = 32 MB).

### Block Access

```cpp
// Write/read blocks (handles page boundaries internally)
sdram.writeBlock(uint32_t startAddr, const uint16_t* buf, uint32_t count);
sdram.readBlock (uint32_t startAddr, uint16_t* buf,       uint32_t count);
```

### Fill

```cpp
sdram.fill(uint32_t startAddr, uint32_t count, uint16_t value);
```

### Hardware Verification

```cpp
// Non-blocking
sdram.startVerify(SDRAM_PAT_WALKING, 0, SDRAM_TOTAL_WORDS);
while (sdram.verifyRunning()) delay(10);
bool ok = sdram.verifyPassed();
uint32_t failAt = sdram.verifyFailAddress();  // valid only when !passed

// Blocking helper
bool ok = sdram.verify(SDRAM_PAT_ADDR, 0x100000, 4096);
```

**Patterns:**

| Constant             | Description               |
|---------------------|---------------------------|
| `SDRAM_PAT_WALKING`  | Walking ones              |
| `SDRAM_PAT_ADDR`     | Address-as-data           |
| `SDRAM_PAT_RANDOM`   | LFSR pseudo-random        |
| `SDRAM_PAT_FILL`     | Fixed value 0xA5A5        |

---

## CLI Interface (requires `ENABLE_PAPILIO_OS`)

```cpp
#include <PapilioSdram.h>
#include <PapilioSdramOS.h>

PapilioSdram   sdram(&wb);
PapilioSdramOS sdramOS(&sdram);  // auto-registers all commands
```

**Commands:**

```
sdram status                        — show init_done and memory size
sdram read <addr>                   — read word (hex address)
sdram write <addr> <data>           — write word
sdram fill <addr> <count> <value>   — fill region
sdram dump <addr> [count=16]        — hex dump
sdram verify [pattern] [start] [size]  — hardware verification
sdram tutorial                      — interactive guided walkthrough
sdram help                          — show all commands
```

---

## Gateware

### Register Map

Base address: `0x8000` (Wishbone extended tier).

| Offset | Name      | Access | Description                                          |
|--------|----------|--------|------------------------------------------------------|
| 0x0000 | CSR       | R      | `[0]` = `init_done`                                 |
| 0x0004 | PAGE_REG  | R/W    | `[12:0]` = page number (0–8191)                     |
| 0x0008 | DIR_ADDR  | R/W    | `[23:0]` = direct word address for single R/W       |
| 0x000C | DIR_DATA  | R/W    | Write = write to DIR_ADDR; Read = read from DIR_ADDR |
| 0x0010 | VFY_CTRL  | R/W    | `[1:0]`=pattern; `[7]`=start; `[9]`=pass, `[8]`=done |
| 0x0014 | VFY_START | R/W    | `[23:0]` = verify region start (word address)       |
| 0x0018 | VFY_SIZE  | R/W    | `[23:0]` = verify region size (words)               |
| 0x001C | VFY_FAIL  | R      | `[23:0]` = first failure address                    |
| 0x0100–0x01FF | PAGE_WIN | R/W | 256-word sliding window into current page      |

### Integration in `top.v`

```verilog
// Declare SDRAM ports in top module
output wire [12:0] sdram_addr,
output wire [1:0]  sdram_ba,
inout  wire [15:0] sdram_dq,
output wire        sdram_clk,
output wire        sdram_cke,
output wire        sdram_cs_n,
output wire        sdram_ras_n,
output wire        sdram_cas_n,
output wire        sdram_we_n,
output wire [1:0]  sdram_dqm,

// Add rPLL for 100 MHz SDRAM clock
rPLL #(.FCLKIN("27"), .IDIV_SEL(0), .FBDIV_SEL(2), .ODIV_SEL(8))
    pll_sdram (.CLKIN(clk), .CLKOUT(clk_sdram), .LOCK(pll_lock));

// Instantiate in EXT_SLOT_CONNECT
`define EXT_SLOT_SDRAM papilio_sdram_wb #(.BASE_ADDR(16'h8000)) u_sdram ( \
    .clk(clk), .clk_sdram(clk_sdram), .rst(rst),                          \
    .wb_adr_i(wb_adr), .wb_dat_i(wb_dat_m2s), .wb_dat_o(wb_dat_sdram),   \
    .wb_we_i(wb_we), .wb_cyc_i(wb_cyc), .wb_stb_i(wb_stb_sdram),         \
    .wb_ack_o(wb_ack_sdram),                                               \
    .sdram_addr(sdram_addr), .sdram_ba(sdram_ba), .sdram_dq(sdram_dq),    \
    .sdram_clk(sdram_clk), .sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n),\
    .sdram_ras_n(sdram_ras_n), .sdram_cas_n(sdram_cas_n),                 \
    .sdram_we_n(sdram_we_n), .sdram_dqm(sdram_dqm));
```

---

## Supported Boards

| Board              | Constraint File                              |
|-------------------|----------------------------------------------|
| Papilio Retrocade  | `gateware/constraints/papilio_retrocade.cst` |

---

## Testing

### Simulation

```powershell
cd tests/sim
python run_all_sims.py
```

Requires Icarus Verilog (`iverilog`) in PATH.

### Hardware Tests

```powershell
cd tests/hw
pio test -e esp32
```

Requires an FPGA with the correct bitstream and a USB connection to the ESP32.

### Full Test Suite

```powershell
python run_all_tests.py
```

---

## Development

See [gateware/README.md](gateware/README.md) for module architecture, timing tables,
and resource utilization.

See [AI_SKILL.md](AI_SKILL.md) for AI assistant guidance on this library.

---

## License

MIT — see `library.json` for details.
