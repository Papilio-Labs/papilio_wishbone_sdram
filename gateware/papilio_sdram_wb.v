// papilio_sdram_wb.v
// Wishbone slave wrapper for papilio_sdram_ctrl
// Provides paged access to 32 MB SDRAM through an 8 KB extended-tier slot.
//
// Address map (relative to BASE_ADDR, which defaults to 0x8000):
//   0x0000 : CSR          [8]=init_done [7:0]=status
//   0x0004 : PAGE_REG     [12:0]=page number (13-bit → 8192 pages × 4 KB each = 32 MB)
//   0x0008 : DIR_ADDR     [23:0]=direct SDRAM word address
//   0x000C : DIR_DATA     [15:0]=direct data (write triggers SDRAM write; read triggers SDRAM read)
//   0x0010 : VFY_CTRL     write [7]=start, [1:0]=pattern; read [9]=pass, [8]=done, [7:0]=running
//   0x0014 : VFY_START    [23:0]=verify region start address (words)
//   0x0018 : VFY_SIZE     [23:0]=verify region size (words)
//   0x001C : VFY_FAIL     [23:0]=first fail address (RO)
//   0x0100-0x10FF : Paged window (2048 bytes = 1024 × 16-bit SDRAM words)
//     SDRAM word addr = {page_reg[12:0], (offset-0x100)[11:2]} (24-bit word address)
//     Each 32-bit WB access reads/writes the lower 16 bits as one SDRAM word.
//
// Clock domain crossing: WB runs at clk_wb (27 MHz), SDRAM ctrl at clk_sdram (100 MHz).
// Uses a toggle-handshake CDC for each Wishbone transaction.

`default_nettype none

module papilio_sdram_wb #(
    parameter BASE_ADDR  = 16'h8000,
    parameter ROW_BITS   = 13,
    parameter COL_BITS   = 9,
    parameter BANK_BITS  = 2,
    parameter DATA_WIDTH = 16,

    // Paged window parameters
    parameter PAGE_BITS  = 13,     // 2^13 = 8192 pages
    parameter WIN_BITS   = 10,     // 2^10 = 1024 words per page (2 KB per page)
    // Total: 13+10 = 23 bits = 8M words... hmm

    // Timing (passed through to papilio_sdram_ctrl)
    parameter tRCD        = 2,
    parameter tRP         = 2,
    parameter tRC         = 6,
    parameter tRFC        = 6,
    parameter tWR         = 2,
    parameter CAS_LATENCY = 3,
    parameter REFRESH_INTERVAL = 780,
    parameter INIT_WAIT   = 20000
) (
    // Wishbone interface (27 MHz domain)
    input  wire        clk_wb,
    input  wire        rst,

    input  wire [15:0] wb_adr_i,
    input  wire [31:0] wb_dat_i,
    output reg  [31:0] wb_dat_o,
    input  wire        wb_we_i,
    input  wire        wb_cyc_i,
    input  wire        wb_stb_i,
    output reg         wb_ack_o,

    // SDRAM clock (100 MHz, from PLL in top-level)
    input  wire        clk_sdram,

    // SDRAM physical pins
    output wire [ROW_BITS-1:0]   sdram_addr,
    output wire [BANK_BITS-1:0]  sdram_ba,
    inout  wire [DATA_WIDTH-1:0] sdram_dq,
    output wire                  sdram_clk,
    output wire                  sdram_cke,
    output wire                  sdram_cs_n,
    output wire                  sdram_ras_n,
    output wire                  sdram_cas_n,
    output wire                  sdram_we_n,
    output wire [DATA_WIDTH/8-1:0] sdram_dqm
);

// ============================================================
// Address decode helpers
// ============================================================
localparam ADDR_WIDTH = ROW_BITS + COL_BITS + BANK_BITS;  // 24 bits

wire [15:0] local_addr = wb_adr_i - BASE_ADDR;
wire        in_regs    = (local_addr < 16'h0100);
wire        in_window  = (local_addr >= 16'h0100) && (local_addr <= 16'h04FF);

// ============================================================
// Registers (WB clock domain)
// ============================================================
reg [PAGE_BITS-1:0]  page_reg;
reg [ADDR_WIDTH-1:0] dir_addr_reg;

// Verify engine control
reg        vfy_start;
reg [1:0]  vfy_pattern;
reg [ADDR_WIDTH-1:0] vfy_start_addr;
reg [ADDR_WIDTH-1:0] vfy_size;

// ============================================================
// CDC: WB domain → SDRAM domain
// ============================================================
// Request side: WB latches op, toggles req_tog
reg                   req_tog_wb;        // WB domain
reg [ADDR_WIDTH-1:0]  cdc_addr_wb;
reg [DATA_WIDTH-1:0]  cdc_wdata_wb;
reg                   cdc_we_wb;
reg                   cdc_pending_wb;    // WB waiting for ack

// SDRAM domain synchronisers (2FF)
reg req_tog_s1, req_tog_s2, req_tog_s3;
wire req_edge_sdram = req_tog_s2 ^ req_tog_s3;

// Ack side: SDRAM toggles ack_tog when done
reg                   ack_tog_sdram;     // SDRAM domain
reg [DATA_WIDTH-1:0]  cdc_rdata_sdram;

// Back into WB domain (2FF)
reg ack_tog_s1, ack_tog_s2, ack_tog_s3;
wire ack_edge_wb = ack_tog_s2 ^ ack_tog_s3;

// Latched read data in WB domain
reg [DATA_WIDTH-1:0]  cdc_rdata_wb;

// ============================================================
// SDRAM side: capture request, issue to ctrl, return ack
// ============================================================
reg [ADDR_WIDTH-1:0]  sdram_req_addr;
reg [DATA_WIDTH-1:0]  sdram_req_wdata;
reg                   sdram_req_we;
reg                   ctrl_req;          // single-cycle pulse to controller

wire                  ctrl_ack;
wire [DATA_WIDTH-1:0] ctrl_rdata;
wire                  ctrl_init_done;
wire                  ctrl_busy;

// Verify engine wires
wire                  vfy_ctrl_req;
wire                  vfy_ctrl_we;
wire [ADDR_WIDTH-1:0] vfy_ctrl_addr;
wire [DATA_WIDTH-1:0] vfy_ctrl_wdata;
wire                  vfy_ctrl_ack;
wire [DATA_WIDTH-1:0] vfy_ctrl_rdata;
wire                  vfy_running;
wire                  vfy_done;
wire                  vfy_pass;
wire [ADDR_WIDTH-1:0] vfy_fail_addr;

// ============================================================
// Controller and verify engine instantiation
// ============================================================
// Route SDRAM domain requests: WB CDC has priority; verify engine uses vfy_* ports on ctrl
papilio_sdram_ctrl #(
    .ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS), .BANK_BITS(BANK_BITS),
    .DATA_WIDTH(DATA_WIDTH),
    .tRCD(tRCD), .tRP(tRP), .tRC(tRC), .tRFC(tRFC), .tWR(tWR),
    .CAS_LATENCY(CAS_LATENCY),
    .REFRESH_INTERVAL(REFRESH_INTERVAL),
    .INIT_WAIT(INIT_WAIT)
) u_ctrl (
    .clk       (clk_sdram),
    .rst       (rst),
    .req       (ctrl_req),
    .we        (sdram_req_we),
    .addr      (sdram_req_addr),
    .wdata     (sdram_req_wdata),
    .ack       (ctrl_ack),
    .rdata     (ctrl_rdata),
    .init_done (ctrl_init_done),
    .busy      (ctrl_busy),
    // Verify engine port
    .vfy_req   (vfy_ctrl_req),
    .vfy_we    (vfy_ctrl_we),
    .vfy_addr  (vfy_ctrl_addr),
    .vfy_wdata (vfy_ctrl_wdata),
    .vfy_ack   (vfy_ctrl_ack),
    .vfy_rdata (vfy_ctrl_rdata),
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

papilio_sdram_verify #(
    .ADDR_WIDTH(ADDR_WIDTH),
    .DATA_WIDTH(DATA_WIDTH)
) u_verify (
    .clk        (clk_sdram),
    .rst        (rst),
    // Control interface (WB clock domain — single-bit signals, synchronised inside)
    .start      (vfy_start),
    .pattern    (vfy_pattern),
    .start_addr (vfy_start_addr),
    .size       (vfy_size),
    .running    (vfy_running),
    .done       (vfy_done),
    .pass       (vfy_pass),
    .fail_addr  (vfy_fail_addr),
    // Controller port
    .ctrl_req   (vfy_ctrl_req),
    .ctrl_we    (vfy_ctrl_we),
    .ctrl_addr  (vfy_ctrl_addr),
    .ctrl_wdata (vfy_ctrl_wdata),
    .ctrl_ack   (vfy_ctrl_ack),
    .ctrl_rdata (vfy_ctrl_rdata)
);

// ============================================================
// SDRAM domain: sync req_tog, issue ctrl_req, toggle ack
// ============================================================
always @(posedge clk_sdram or posedge rst) begin
    if (rst) begin
        req_tog_s1  <= 1'b0;
        req_tog_s2  <= 1'b0;
        req_tog_s3  <= 1'b0;
        ack_tog_sdram <= 1'b0;
        ctrl_req    <= 1'b0;
        sdram_req_addr  <= {ADDR_WIDTH{1'b0}};
        sdram_req_wdata <= {DATA_WIDTH{1'b0}};
        sdram_req_we    <= 1'b0;
    end else begin
        // 2FF synchroniser + edge detect
        req_tog_s1 <= req_tog_wb;
        req_tog_s2 <= req_tog_s1;
        req_tog_s3 <= req_tog_s2;
        ctrl_req   <= 1'b0;

        if (req_edge_sdram) begin
            // Capture the request (WB side holds stable until ack)
            sdram_req_addr  <= cdc_addr_wb;
            sdram_req_wdata <= cdc_wdata_wb;
            sdram_req_we    <= cdc_we_wb;
            ctrl_req        <= 1'b1;
        end

        if (ctrl_ack) begin
            cdc_rdata_sdram <= ctrl_rdata;
            ack_tog_sdram   <= ~ack_tog_sdram;
        end
    end
end

// ============================================================
// WB domain: sync ack_tog, complete wb_ack_o
// ============================================================
always @(posedge clk_wb or posedge rst) begin
    if (rst) begin
        ack_tog_s1     <= 1'b0;
        ack_tog_s2     <= 1'b0;
        ack_tog_s3     <= 1'b0;
        cdc_rdata_wb   <= {DATA_WIDTH{1'b0}};
        req_tog_wb     <= 1'b0;
        cdc_pending_wb <= 1'b0;
        wb_ack_o       <= 1'b0;
        wb_dat_o       <= 32'h0;
        page_reg       <= {PAGE_BITS{1'b0}};
        dir_addr_reg   <= {ADDR_WIDTH{1'b0}};
        vfy_start      <= 1'b0;
        vfy_pattern    <= 2'b0;
        vfy_start_addr <= {ADDR_WIDTH{1'b0}};
        vfy_size       <= {ADDR_WIDTH{1'b0}};
    end else begin
        // 2FF synchroniser + edge detect
        ack_tog_s1 <= ack_tog_sdram;
        ack_tog_s2 <= ack_tog_s1;
        ack_tog_s3 <= ack_tog_s2;

        wb_ack_o   <= 1'b0;
        vfy_start  <= 1'b0;

        // Receive ack from SDRAM domain
        if (ack_edge_wb && cdc_pending_wb) begin
            cdc_rdata_wb   <= cdc_rdata_sdram;
            cdc_pending_wb <= 1'b0;
            // wb_ack_o is deasserted until bus cycle drives it below
        end

        // Wishbone transaction handling
        if (wb_cyc_i && wb_stb_i && !wb_ack_o) begin
            if (in_regs) begin
                // Register access — immediate response (no SDRAM needed)
                wb_ack_o <= 1'b1;
                if (!wb_we_i) begin
                    // Read
                    case (local_addr[5:2])
                        4'h0: wb_dat_o <= {23'b0, ctrl_init_done, 8'b0};
                        4'h1: wb_dat_o <= {{(32-PAGE_BITS){1'b0}}, page_reg};
                        4'h2: wb_dat_o <= {{(32-ADDR_WIDTH){1'b0}}, dir_addr_reg};
                        4'h3: wb_dat_o <= {{(32-DATA_WIDTH){1'b0}}, cdc_rdata_wb};
                        4'h4: wb_dat_o <= {22'b0, vfy_pass, vfy_done, 6'b0, vfy_running};
                        4'h5: wb_dat_o <= {{(32-ADDR_WIDTH){1'b0}}, vfy_start_addr};
                        4'h6: wb_dat_o <= {{(32-ADDR_WIDTH){1'b0}}, vfy_size};
                        4'h7: wb_dat_o <= {{(32-ADDR_WIDTH){1'b0}}, vfy_fail_addr};
                        default: wb_dat_o <= 32'hDEADBEEF;
                    endcase
                end else begin
                    // Write
                    case (local_addr[5:2])
                        4'h1: page_reg <= wb_dat_i[PAGE_BITS-1:0];
                        4'h2: dir_addr_reg <= wb_dat_i[ADDR_WIDTH-1:0];
                        4'h4: begin
                            vfy_pattern <= wb_dat_i[1:0];
                            if (wb_dat_i[7]) vfy_start <= 1'b1;
                        end
                        4'h5: vfy_start_addr <= wb_dat_i[ADDR_WIDTH-1:0];
                        4'h6: vfy_size <= wb_dat_i[ADDR_WIDTH-1:0];
                        default: ;
                    endcase
                end

                // Special: direct data register write/read triggers SDRAM access
                if (local_addr[5:2] == 4'h3 && !cdc_pending_wb) begin
                    cdc_addr_wb   <= dir_addr_reg;
                    cdc_wdata_wb  <= wb_dat_i[DATA_WIDTH-1:0];
                    cdc_we_wb     <= wb_we_i;
                    cdc_pending_wb<= 1'b1;
                    req_tog_wb    <= ~req_tog_wb;
                    wb_ack_o      <= 1'b0;  // Wait for SDRAM ack
                end

            end else if (in_window && !cdc_pending_wb) begin
                // Paged window — SDRAM access required
                // SDRAM word addr = { page_reg[12:0], word_index[9:0] }
                // word_index = (local_addr - 0x100) >> 2  (WB is 32-bit)
                cdc_addr_wb   <= {page_reg[PAGE_BITS-1:0],
                                  local_addr[11:2] - 10'd64};  // -64 = subtract 0x100>>2
                cdc_wdata_wb  <= wb_dat_i[DATA_WIDTH-1:0];
                cdc_we_wb     <= wb_we_i;
                cdc_pending_wb<= 1'b1;
                req_tog_wb    <= ~req_tog_wb;
            end

            // If paged/direct access was already pending: wait for ack_edge_wb
            if (!cdc_pending_wb && (in_window)) begin
                // Already issued above — nothing
            end
        end

        // Deferred ack for paged/direct access
        if (!cdc_pending_wb && !wb_ack_o && wb_cyc_i && wb_stb_i && (in_window || (in_regs && local_addr[5:2] == 4'h3))) begin
            // We got the ack from SDRAM (cdc_pending cleared above)
            wb_dat_o <= {{(32-DATA_WIDTH){1'b0}}, cdc_rdata_wb};
            wb_ack_o <= 1'b1;
        end
    end
end

`default_nettype wire

endmodule
