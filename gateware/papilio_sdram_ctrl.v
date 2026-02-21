// papilio_sdram_ctrl.v
// Parameterized SDR SDRAM controller
// Default parameters: Winbond W9825G6KH-6 at 100 MHz (SDRAM clock domain)
//
// Register Interface (internal, connected via papilio_sdram_wb):
//   Caller presents:  req, we, addr[24:0], wdata[15:0]
//   Controller returns: ack, rdata[15:0], init_done, busy
//
// Timing defaults (W9825G6KH-6 at 100 MHz, all in clock cycles):
//   tRCD=2, tRP=2, tRC=6, tRFC=6, tWR=2, CAS=3
//   Refresh interval: 780 cycles (64ms/8192 rows @ 100MHz)
//   Init wait: 20000 cycles (200µs @ 100MHz)
//
// Address mapping:
//   addr[24:23] = bank (BA1:BA0)
//   addr[22:10] = row  (A12:A0)
//   addr[9:1]   = col  (A8:A0), A10=0 (no auto-precharge)
//   addr[0]     = byte select (used by wrapper for 16-bit->32-bit packing)

`default_nettype none

module papilio_sdram_ctrl #(
    // Memory organization (W9825G6KH-6 defaults)
    parameter ROW_BITS    = 13,   // 8192 rows
    parameter COL_BITS    = 9,    // 512 columns
    parameter BANK_BITS   = 2,    // 4 banks
    parameter DATA_WIDTH  = 16,

    // Timing in SDRAM clock cycles (100 MHz defaults)
    parameter tRCD        = 2,    // RAS to CAS delay (18ns)
    parameter tRP         = 2,    // Precharge time (18ns)
    parameter tRC         = 6,    // Active to active same bank (60ns)
    parameter tRFC        = 6,    // Auto-refresh cycle time (60ns)
    parameter tWR         = 2,    // Write recovery (12ns)
    parameter CAS_LATENCY = 3,    // CAS latency

    // Refresh interval (64ms / 8192 rows @ 100MHz = ~780 cycles)
    parameter REFRESH_INTERVAL = 780,

    // Init wait: 200µs @ 100 MHz
    parameter INIT_WAIT   = 20000
) (
    input  wire                         clk,       // SDRAM clock (100 MHz)
    input  wire                         rst,

    // Request interface (from Wishbone wrapper, already CDC'd)
    input  wire                         req,       // pulse: request valid
    input  wire                         we,        // 1=write, 0=read
    input  wire [ROW_BITS+COL_BITS+BANK_BITS-1:0] addr,  // byte-word address
    input  wire [DATA_WIDTH-1:0]        wdata,     // write data
    output reg                          ack,       // pulse: operation complete
    output reg  [DATA_WIDTH-1:0]        rdata,     // read data (valid on ack)

    // Status
    output reg                          init_done,
    output wire                         busy,

    // Verify engine interface (direct port access)
    input  wire                         vfy_req,
    input  wire                         vfy_we,
    input  wire [ROW_BITS+COL_BITS+BANK_BITS-1:0] vfy_addr,
    input  wire [DATA_WIDTH-1:0]        vfy_wdata,
    output reg                          vfy_ack,
    output reg  [DATA_WIDTH-1:0]        vfy_rdata,

    // SDRAM physical pins
    output reg  [ROW_BITS-1:0]          sdram_addr,
    output reg  [BANK_BITS-1:0]         sdram_ba,
    inout  wire [DATA_WIDTH-1:0]        sdram_dq,
    output wire                         sdram_clk,
    output reg                          sdram_cke,
    output reg                          sdram_cs_n,
    output reg                          sdram_ras_n,
    output reg                          sdram_cas_n,
    output reg                          sdram_we_n,
    output reg  [DATA_WIDTH/8-1:0]      sdram_dqm
);

// ============================================================
// SDRAM command encoding (CS=0, RAS, CAS, WE)
// ============================================================
localparam CMD_NOP        = 4'b0111;
localparam CMD_ACTIVE     = 4'b0011;
localparam CMD_READ       = 4'b0101;
localparam CMD_WRITE      = 4'b0100;
localparam CMD_PRECHARGE  = 4'b0010;
localparam CMD_AUTO_REF   = 4'b0001;
localparam CMD_LOAD_MODE  = 4'b0000;
localparam CMD_DESELECT   = 4'b1000;

// Mode register: CL=3, sequential burst, full page burst (but we use burst len=1)
// Burst length=1 (bits[2:0]=000), sequential, CL=3 (bits[6:4]=011)
localparam MODE_REG = 13'b0_00_011_0_000;  // A12:0

// ============================================================
// Internal signals
// ============================================================
reg  [DATA_WIDTH-1:0] dq_out;
reg                   dq_oe;

// Open row tracking per bank
reg [ROW_BITS-1:0]    open_row  [0:(1<<BANK_BITS)-1];
reg                   row_open  [0:(1<<BANK_BITS)-1];

// Refresh counter
reg [$clog2(REFRESH_INTERVAL+1)-1:0] refresh_cnt;
reg                                  need_refresh;

// Timer for wait states
reg [14:0] timer;

// Current request
reg                               cur_we;
reg [ROW_BITS+COL_BITS+BANK_BITS-1:0] cur_addr;
reg [DATA_WIDTH-1:0]              cur_wdata;
reg                               cur_vfy;   // 1 = from verify engine

// Address breakdown helpers (from cur_addr)
wire [BANK_BITS-1:0] cur_bank = cur_addr[ROW_BITS+COL_BITS+BANK_BITS-1 : ROW_BITS+COL_BITS];
wire [ROW_BITS-1:0]  cur_row  = cur_addr[ROW_BITS+COL_BITS-1 : COL_BITS];
wire [COL_BITS-1:0]  cur_col  = cur_addr[COL_BITS-1:0];

// CAS pipeline for read latency
reg [CAS_LATENCY:0]  cas_pipe;

// State machine
localparam S_RESET           = 5'd0;
localparam S_INIT_WAIT       = 5'd1;
localparam S_INIT_PRECHARGE  = 5'd2;
localparam S_INIT_PC_WAIT    = 5'd3;
localparam S_INIT_REF1       = 5'd4;
localparam S_INIT_REF1_WAIT  = 5'd5;
localparam S_INIT_REF2       = 5'd6;
localparam S_INIT_REF2_WAIT  = 5'd7;
localparam S_INIT_MODE       = 5'd8;
localparam S_INIT_MODE_WAIT  = 5'd9;
localparam S_IDLE            = 5'd10;
localparam S_REFRESH         = 5'd11;
localparam S_REFRESH_WAIT    = 5'd12;
localparam S_ACTIVE          = 5'd13;
localparam S_ACTIVE_WAIT     = 5'd14;
localparam S_READ            = 5'd15;
localparam S_READ_CL         = 5'd16;
localparam S_READ_DATA       = 5'd17;
localparam S_WRITE           = 5'd18;
localparam S_WRITE_WAIT      = 5'd19;
localparam S_PRECHARGE       = 5'd20;
localparam S_PRECHARGE_WAIT  = 5'd21;

reg [4:0] state;

assign busy = (state != S_IDLE);

// ============================================================
// SDRAM clock: pass through (phase shift handled externally via PLL)
// ============================================================
assign sdram_clk = clk;

// ============================================================
// Tristate DQ
// ============================================================
assign sdram_dq = dq_oe ? dq_out : {DATA_WIDTH{1'bz}};

// Issue command helper task (combinational assignment via always block)
task issue_cmd;
    input [3:0] cmd;
    input [ROW_BITS-1:0] a;
    input [BANK_BITS-1:0] ba;
    begin
        sdram_cs_n  <= cmd[3];
        sdram_ras_n <= cmd[2];
        sdram_cas_n <= cmd[1];
        sdram_we_n  <= cmd[0];
        sdram_addr  <= a;
        sdram_ba    <= ba;
    end
endtask

// ============================================================
// Main state machine
// ============================================================
integer i;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state      <= S_RESET;
        init_done  <= 1'b0;
        ack        <= 1'b0;
        vfy_ack    <= 1'b0;
        dq_oe      <= 1'b0;
        dq_out     <= {DATA_WIDTH{1'b0}};
        sdram_cke  <= 1'b0;
        sdram_cs_n <= 1'b1;
        sdram_ras_n<= 1'b1;
        sdram_cas_n<= 1'b1;
        sdram_we_n <= 1'b1;
        sdram_addr <= {ROW_BITS{1'b0}};
        sdram_ba   <= {BANK_BITS{1'b0}};
        sdram_dqm  <= {(DATA_WIDTH/8){1'b0}};
        refresh_cnt<= {$clog2(REFRESH_INTERVAL+1){1'b0}};
        need_refresh<= 1'b0;
        timer      <= 15'd0;
        cas_pipe   <= {(CAS_LATENCY+1){1'b0}};
        rdata      <= {DATA_WIDTH{1'b0}};
        vfy_rdata  <= {DATA_WIDTH{1'b0}};
        for (i = 0; i < (1<<BANK_BITS); i = i+1) begin
            row_open[i] <= 1'b0;
            open_row[i] <= {ROW_BITS{1'b0}};
        end
    end else begin
        // Default: NOP, DQ not driven, clear pulses
        issue_cmd(CMD_NOP, {ROW_BITS{1'b0}}, {BANK_BITS{1'b0}});
        dq_oe   <= 1'b0;
        ack     <= 1'b0;
        vfy_ack <= 1'b0;
        sdram_dqm <= {(DATA_WIDTH/8){1'b0}};

        // Refresh counter
        if (refresh_cnt == REFRESH_INTERVAL - 1) begin
            refresh_cnt  <= 0;
            need_refresh <= 1'b1;
        end else begin
            refresh_cnt <= refresh_cnt + 1'b1;
        end

        // CAS latency pipeline (shift each cycle)
        cas_pipe <= {cas_pipe[CAS_LATENCY-1:0], 1'b0};

        case (state)
            // --------------------------------------------------------
            S_RESET: begin
                sdram_cke <= 1'b1;
                timer     <= INIT_WAIT - 1;
                state     <= S_INIT_WAIT;
            end

            // --------------------------------------------------------
            S_INIT_WAIT: begin
                if (timer == 0)
                    state <= S_INIT_PRECHARGE;
                else
                    timer <= timer - 1'b1;
            end

            // --------------------------------------------------------
            // Precharge all banks
            S_INIT_PRECHARGE: begin
                issue_cmd(CMD_PRECHARGE, {{(ROW_BITS-11){1'b0}}, 1'b1, {10{1'b0}}}, {BANK_BITS{1'b0}});
                timer <= tRP - 2;
                state <= S_INIT_PC_WAIT;
            end

            S_INIT_PC_WAIT: begin
                if (timer == 0) state <= S_INIT_REF1;
                else timer <= timer - 1'b1;
            end

            // --------------------------------------------------------
            // Two auto-refreshes
            S_INIT_REF1: begin
                issue_cmd(CMD_AUTO_REF, {ROW_BITS{1'b0}}, {BANK_BITS{1'b0}});
                timer <= tRFC - 2;
                state <= S_INIT_REF1_WAIT;
            end

            S_INIT_REF1_WAIT: begin
                if (timer == 0) state <= S_INIT_REF2;
                else timer <= timer - 1'b1;
            end

            S_INIT_REF2: begin
                issue_cmd(CMD_AUTO_REF, {ROW_BITS{1'b0}}, {BANK_BITS{1'b0}});
                timer <= tRFC - 2;
                state <= S_INIT_REF2_WAIT;
            end

            S_INIT_REF2_WAIT: begin
                if (timer == 0) state <= S_INIT_MODE;
                else timer <= timer - 1'b1;
            end

            // --------------------------------------------------------
            // Load mode register
            S_INIT_MODE: begin
                issue_cmd(CMD_LOAD_MODE, MODE_REG[ROW_BITS-1:0], {BANK_BITS{1'b0}});
                timer <= 3 - 2;  // tMRD = 3 cycles
                state <= S_INIT_MODE_WAIT;
            end

            S_INIT_MODE_WAIT: begin
                if (timer == 0) begin
                    init_done <= 1'b1;
                    need_refresh <= 1'b0;
                    refresh_cnt  <= 0;
                    state <= S_IDLE;
                end else
                    timer <= timer - 1'b1;
            end

            // --------------------------------------------------------
            S_IDLE: begin
                if (need_refresh) begin
                    // Must close all open rows before refresh
                    need_refresh <= 1'b0;
                    // Precharge all
                    issue_cmd(CMD_PRECHARGE, {{(ROW_BITS-11){1'b0}}, 1'b1, {10{1'b0}}}, {BANK_BITS{1'b0}});
                    for (i = 0; i < (1<<BANK_BITS); i = i+1)
                        row_open[i] <= 1'b0;
                    timer <= tRP - 2;
                    state <= S_REFRESH;
                end else if (vfy_req) begin
                    cur_we    <= vfy_we;
                    cur_addr  <= vfy_addr;
                    cur_wdata <= vfy_wdata;
                    cur_vfy   <= 1'b1;
                    state     <= S_ACTIVE;
                end else if (req) begin
                    cur_we    <= we;
                    cur_addr  <= addr;
                    cur_wdata <= wdata;
                    cur_vfy   <= 1'b0;
                    state     <= S_ACTIVE;
                end
            end

            // --------------------------------------------------------
            S_REFRESH: begin
                if (timer == 0) begin
                    issue_cmd(CMD_AUTO_REF, {ROW_BITS{1'b0}}, {BANK_BITS{1'b0}});
                    timer <= tRFC - 2;
                    state <= S_REFRESH_WAIT;
                end else
                    timer <= timer - 1'b1;
            end

            S_REFRESH_WAIT: begin
                if (timer == 0)
                    state <= S_IDLE;
                else
                    timer <= timer - 1'b1;
            end

            // --------------------------------------------------------
            // Activate: open the target row (if not already open)
            S_ACTIVE: begin
                if (row_open[cur_bank] && open_row[cur_bank] == cur_row) begin
                    // Page hit — row already open, skip ACTIVE
                    if (cur_we)
                        state <= S_WRITE;
                    else
                        state <= S_READ;
                end else begin
                    // Need to precharge first if a different row is open
                    if (row_open[cur_bank]) begin
                        issue_cmd(CMD_PRECHARGE,
                            {{(ROW_BITS-11){1'b0}}, 1'b0, {10{1'b0}}},
                            cur_bank);
                        row_open[cur_bank] <= 1'b0;
                        timer <= tRP - 2;
                        state <= S_PRECHARGE_WAIT;
                    end else begin
                        issue_cmd(CMD_ACTIVE, cur_row, cur_bank);
                        row_open[cur_bank] <= 1'b1;
                        open_row[cur_bank] <= cur_row;
                        timer <= tRCD - 2;
                        state <= S_ACTIVE_WAIT;
                    end
                end
            end

            S_ACTIVE_WAIT: begin
                if (timer == 0) begin
                    if (cur_we)
                        state <= S_WRITE;
                    else
                        state <= S_READ;
                end else
                    timer <= timer - 1'b1;
            end

            // --------------------------------------------------------
            // Read
            S_READ: begin
                // Issue CAS read (A10=0: no auto-precharge)
                issue_cmd(CMD_READ,
                    {{(ROW_BITS-COL_BITS-1){1'b0}}, 1'b0, cur_col},
                    cur_bank);
                cas_pipe <= {{(CAS_LATENCY-1){1'b0}}, 1'b1, 1'b0};  // data valid in CAS_LATENCY cycles
                timer <= CAS_LATENCY - 1;
                state <= S_READ_CL;
            end

            S_READ_CL: begin
                if (timer == 0)
                    state <= S_READ_DATA;
                else
                    timer <= timer - 1'b1;
            end

            S_READ_DATA: begin
                rdata <= sdram_dq;
                if (cur_vfy) begin
                    vfy_rdata <= sdram_dq;
                    vfy_ack   <= 1'b1;
                end else begin
                    ack <= 1'b1;
                end
                state <= S_IDLE;
            end

            // --------------------------------------------------------
            // Write
            S_WRITE: begin
                // Issue CAS write (A10=0: no auto-precharge)
                issue_cmd(CMD_WRITE,
                    {{(ROW_BITS-COL_BITS-1){1'b0}}, 1'b0, cur_col},
                    cur_bank);
                dq_oe  <= 1'b1;
                dq_out <= cur_wdata;
                sdram_dqm <= {(DATA_WIDTH/8){1'b0}};
                timer <= tWR - 1;
                state <= S_WRITE_WAIT;
            end

            S_WRITE_WAIT: begin
                dq_oe <= 1'b0;
                if (timer == 0) begin
                    if (cur_vfy)
                        vfy_ack <= 1'b1;
                    else
                        ack <= 1'b1;
                    state <= S_IDLE;
                end else
                    timer <= timer - 1'b1;
            end

            // --------------------------------------------------------
            // Precharge (forced — different row in same bank)
            S_PRECHARGE: begin
                issue_cmd(CMD_PRECHARGE,
                    {{(ROW_BITS-11){1'b0}}, 1'b0, {10{1'b0}}},
                    cur_bank);
                row_open[cur_bank] <= 1'b0;
                timer <= tRP - 2;
                state <= S_PRECHARGE_WAIT;
            end

            S_PRECHARGE_WAIT: begin
                if (timer == 0) begin
                    // Now issue ACTIVE for the new row
                    issue_cmd(CMD_ACTIVE, cur_row, cur_bank);
                    row_open[cur_bank] <= 1'b1;
                    open_row[cur_bank] <= cur_row;
                    timer <= tRCD - 2;
                    state <= S_ACTIVE_WAIT;
                end else
                    timer <= timer - 1'b1;
            end

            default: state <= S_IDLE;
        endcase
    end
end

`default_nettype wire

endmodule
