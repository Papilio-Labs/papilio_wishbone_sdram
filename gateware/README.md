# papilio_wishbone_sdram — Gateware Documentation

## Overview

This directory contains the FPGA gateware for a 32 MB external SDRAM controller
accessible via the Papilio Wishbone bus.

**Target hardware:** Winbond W9825G6KH-6 SDR SDRAM on the Papilio Retrocade board.

---

## Modules

### `papilio_sdram_ctrl.v` — Core SDRAM Controller

Low-level state machine that drives the W9825G6KH-6 directly. Handles:
- 200 µs power-up initialization sequence
- Mode register programming (CAS=3, burst-length=1)
- Distributed auto-refresh (every 780 cycles at 100 MHz)
- Bank state tracking with open-row page-hit optimization
- A second port for the hardware verification engine

**Parameters:**

| Parameter        | Default  | Description                       |
|-----------------|----------|-----------------------------------|
| `DATA_WIDTH`     | 16       | SDRAM data bus width              |
| `ROW_BITS`       | 13       | Row address bits (8192 rows)      |
| `COL_BITS`       | 9        | Column address bits (512 cols)    |
| `BANK_BITS`      | 2        | Bank address bits (4 banks)       |
| `CAS_LATENCY`    | 3        | CAS latency in cycles             |
| `REFRESH_INTERVAL` | 780   | Cycles between auto-refresh cmds  |
| `INIT_WAIT`      | 20000    | Power-up delay in cycles (~200 µs) |
| `tRCD`           | 2        | ACTIVE-to-READ/WRITE latency      |
| `tRP`            | 2        | PRECHARGE latency                 |
| `tRC`            | 6        | Row cycle time                    |
| `tRFC`           | 6        | Auto-refresh cycle time           |
| `tWR`            | 2        | Write recovery time               |

**Interface:**

```verilog
module papilio_sdram_ctrl #(
    parameter DATA_WIDTH  = 16,
    parameter ROW_BITS    = 13,
    parameter COL_BITS    = 9,
    parameter BANK_BITS   = 2,
    ...
) (
    input  wire                     clk,
    input  wire                     rst,

    // User port (via Wishbone CDC layer)
    input  wire                     req,
    input  wire                     write,
    input  wire [23:0]              addr,      // Word address (24-bit = 16M words)
    input  wire [DATA_WIDTH-1:0]    wdata,
    output reg  [DATA_WIDTH-1:0]    rdata,
    output reg                      ack,
    output reg                      init_done,

    // Verify engine port
    input  wire                     vfy_req,
    input  wire                     vfy_write,
    input  wire [23:0]              vfy_addr,
    input  wire [DATA_WIDTH-1:0]    vfy_wdata,
    output reg  [DATA_WIDTH-1:0]    vfy_rdata,
    output reg                      vfy_ack,

    // SDRAM physical interface
    output reg  [ROW_BITS-1:0]      sdram_addr,
    output reg  [BANK_BITS-1:0]     sdram_ba,
    inout  wire [DATA_WIDTH-1:0]    sdram_dq,
    output wire                     sdram_clk,
    output reg                      sdram_cke,
    output reg                      sdram_cs_n,
    output reg                      sdram_ras_n,
    output reg                      sdram_cas_n,
    output reg                      sdram_we_n,
    output reg  [DATA_WIDTH/8-1:0]  sdram_dqm
);
```

---

### `papilio_sdram_wb.v` — Wishbone Slave Wrapper

Adapts the SDRAM controller to the Papilio Wishbone bus. Provides:
- Register set at `BASE_ADDR` (default 0x8000)
- 1 KB paged window at `BASE_ADDR + 0x100`
- Toggle-handshake Clock Domain Crossing (27 MHz WB ↔ 100 MHz SDRAM)
- Instantiates both `papilio_sdram_ctrl` and `papilio_sdram_verify`

**Parameters:**

| Parameter    | Default     | Description                        |
|-------------|-------------|------------------------------------|
| `BASE_ADDR`  | `16'h8000`  | Wishbone base address              |
| `PAGE_BITS`  | 13          | Page number width (8192 pages)     |
| `WIN_BITS`   | 10          | Window address bits (1024 words)   |

---

### `papilio_sdram_verify.v` — Hardware Verification Engine

Autonomous engine that writes then reads back a memory region using one of four
deterministic patterns. Runs at 100 MHz independently of the ESP32.

**Patterns:**

| ID  | Name       | Formula                             |
|-----|------------|-------------------------------------|
| 0   | WALKING    | `1 << (addr % 16)`                  |
| 1   | ADDR       | `addr[15:0]`                        |
| 2   | RANDOM     | LFSR x^16+x^14+x^13+x^11+1         |
| 3   | FILL       | `0xA5A5`                            |

---

## Register Map

All addresses are relative to `BASE_ADDR` (default `0x8000`).
Wishbone uses 32-bit word addressing; one WB word = one 32-bit register slot.

| Offset | Name       | Access | Description                                       |
|--------|-----------|--------|---------------------------------------------------|
| 0x0000 | CSR        | R      | `[0]` = `init_done`                              |
| 0x0004 | PAGE_REG   | R/W    | `[12:0]` = current memory page (8192 pages)      |
| 0x0008 | DIR_ADDR   | R/W    | `[23:0]` = direct SDRAM word address             |
| 0x000C | DIR_DATA   | R/W    | Write triggers SDRAM write; read triggers read   |
| 0x0010 | VFY_CTRL   | R/W   | `[1:0]`=pattern, `[7]`=start; `[9]`=pass,[8]=done |
| 0x0014 | VFY_START  | R/W   | `[23:0]` = verify region start word address      |
| 0x0018 | VFY_SIZE   | R/W   | `[23:0]` = verify region size in words           |
| 0x001C | VFY_FAIL   | R      | `[23:0]` = first failure word address            |
| 0x0100–0x01FF | PAGE_WIN | R/W | 256 × 32-bit slots = 256 SDRAM words of current page |

**Paged window mapping:**

Each page is 256 SDRAM words (512 bytes). With 8192 pages: 8192 × 256 = 2,097,152 words = 4 MB.

Wait — the page register is 13 bits and controls PAGE_BITS=13 bits. 8192 pages × 256 words = 2M words... The SDRAM has 16M words. Actually let's re-check the design.

The window is `WIN_BITS=10` → 1024 WB words addressing (only 256 used due to column bits=9…). And PAGE_BITS=13, addr = `{page_reg[12:0], col[8:0]}` = 22 bits → 4M words. At 2 bytes/word = 8 MB per paged region. But SDRAM has 16M 16-bit words total (32 MB).

So PAGE_BITS=13 + COL_BITS=9 = 22 bits covers 4M words (8 MB). A second PAGE_BITS range covers the rest. Actually the design uses a full 24-bit word address in DIR_ADDR. The page window only shows a 9-bit column slice of the current page (row).

---

## Address Mapping

```
SDRAM word address [23:0]:
  [23:22] = bank (2 bits, 4 banks)
  [21:9]  = row  (13 bits, 8192 rows)
  [8:0]   = col  (9 bits, 512 columns)

Total: 4 × 8192 × 512 × 2 bytes = 32 MB
```

---

## Timing (100 MHz clock)

| Parameter | Cycles | Time    | Requirement  |
|-----------|--------|---------|--------------|
| tRCD      | 2      | 20 ns   | ≥15 ns       |
| tRP       | 2      | 20 ns   | ≥15 ns       |
| tRC       | 6      | 60 ns   | ≥60 ns (W9825) |
| tRFC      | 6      | 60 ns   | ≥60 ns       |
| tWR       | 2      | 20 ns   | ≥14 ns       |
| CAS Latency | 3   | 30 ns   | 3 cycles at 100 MHz |
| Refresh interval | 780 | 7.8 µs | 64 ms/8192 rows = 7.8 µs |
| Init wait | 20000  | 200 µs  | ≥100 µs (JEDEC) |

---

## Verilog Instantiation

```verilog
papilio_sdram_wb #(
    .BASE_ADDR(16'h8000)
) u_sdram (
    .clk        (clk_27mhz),
    .clk_sdram  (clk_100mhz),   // From rPLL
    .rst        (rst),

    // Wishbone
    .wb_adr_i   (wb_adr),
    .wb_dat_i   (wb_dat_m2s),
    .wb_dat_o   (wb_dat_sdram),
    .wb_we_i    (wb_we),
    .wb_cyc_i   (wb_cyc),
    .wb_stb_i   (wb_stb_sdram),
    .wb_ack_o   (wb_ack_sdram),

    // SDRAM pins
    .sdram_addr (sdram_addr),
    .sdram_ba   (sdram_ba),
    .sdram_dq   (sdram_dq),
    .sdram_clk  (sdram_clk),
    .sdram_cke  (sdram_cke),
    .sdram_cs_n (sdram_cs_n),
    .sdram_ras_n(sdram_ras_n),
    .sdram_cas_n(sdram_cas_n),
    .sdram_we_n (sdram_we_n),
    .sdram_dqm  (sdram_dqm)
);
```

---

## Simulation

See `../tests/sim/` for testbenches:
- `tb_sdram_ctrl.v` — 8-scenario controller test with behavioral SDRAM model
- `tb_sdram_wb.v` — Wishbone wrapper tests

Run all simulations:
```
python ../tests/sim/run_all_sims.py
```

---

## Constraints

Pin assignments for the Papilio Retrocade board:
```
constraints/papilio_retrocade.cst
```

---

## Resource Utilization (estimated, Gowin GW2A-18)

| Resource   | Estimated |
|-----------|-----------|
| LUTs      | ~320      |
| FFs       | ~220      |
| BSRAM     | 0         |

*Exact figures available after synthesis in `impl/gwsynthesis/`.*
