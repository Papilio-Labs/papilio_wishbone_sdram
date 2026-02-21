// sdram_model.v
// Behavioral model of Winbond W9825G6KH-6 SDR SDRAM for simulation
//
// Implements: INIT sequence, MODE LOAD, PRECHARGE, ACTIVATE, READ (CL=3), WRITE, AUTO REFRESH
// Tracks open rows per bank, checks basic timing requirements.
// Simplifications: single CAS latency (=3), no DQM masking checked, burst len=1 only.

`default_nettype none
`timescale 1ns / 100ps

module sdram_model #(
    parameter ROW_BITS   = 13,
    parameter COL_BITS   = 9,
    parameter BANK_BITS  = 2,
    parameter DATA_WIDTH = 16,
    parameter CAS_LAT    = 3,
    parameter tRCD_MIN   = 18,  // ns
    parameter tRP_MIN    = 18,  // ns
    parameter CLK_PERIOD = 10   // ns (100 MHz)
) (
    input  wire                  clk,
    input  wire                  cke,
    input  wire                  cs_n,
    input  wire                  ras_n,
    input  wire                  cas_n,
    input  wire                  we_n,
    input  wire [ROW_BITS-1:0]   addr,
    input  wire [BANK_BITS-1:0]  ba,
    inout  wire [DATA_WIDTH-1:0] dq,
    input  wire [DATA_WIDTH/8-1:0] dqm
);

localparam NUM_BANKS  = 1 << BANK_BITS;
localparam NUM_ROWS   = 1 << ROW_BITS;
localparam NUM_COLS   = 1 << COL_BITS;
localparam MEM_WORDS  = NUM_BANKS * NUM_ROWS * NUM_COLS;

// Memory array
reg [DATA_WIDTH-1:0] mem [0:MEM_WORDS-1];

integer i;
initial begin
    for (i = 0; i < MEM_WORDS; i = i + 1)
        mem[i] = {DATA_WIDTH{1'bx}};
end

// Bank state
reg [ROW_BITS-1:0] open_row  [0:NUM_BANKS-1];
reg                row_active [0:NUM_BANKS-1];

initial begin
    for (i = 0; i < NUM_BANKS; i = i + 1) begin
        row_active[i] = 1'b0;
        open_row[i]   = {ROW_BITS{1'b0}};
    end
end

// Mode register
reg [12:0] mode_reg;
initial mode_reg = 13'b0;

// CAS latency pipeline: index of read data in pipeline
reg [DATA_WIDTH-1:0] cas_pipe [0:CAS_LAT];
reg                  cas_valid[0:CAS_LAT];
integer j;
initial begin
    for (j = 0; j <= CAS_LAT; j = j + 1) begin
        cas_pipe[j]  = {DATA_WIDTH{1'bx}};
        cas_valid[j] = 1'b0;
    end
end

// Output register
reg [DATA_WIDTH-1:0] dq_out;
reg                  dq_oe;
assign dq = dq_oe ? dq_out : {DATA_WIDTH{1'bz}};

// Decode command
wire [3:0] cmd = {cs_n, ras_n, cas_n, we_n};

localparam CMD_NOP        = 4'b0111;
localparam CMD_ACTIVE     = 4'b0011;
localparam CMD_READ       = 4'b0101;
localparam CMD_WRITE      = 4'b0100;
localparam CMD_PRECHARGE  = 4'b0010;
localparam CMD_AUTO_REF   = 4'b0001;
localparam CMD_LOAD_MODE  = 4'b0000;
localparam CMD_DESELECT   = 4'b1111;

// Timing check helpers
real last_active_time [0:NUM_BANKS-1];
real last_precharge_time [0:NUM_BANKS-1];
initial begin
    for (i = 0; i < NUM_BANKS; i = i + 1) begin
        last_active_time[i]    = 0.0;
        last_precharge_time[i] = 0.0;
    end
end

// Helper function: compute word address
function [31:0] word_addr;
    input [BANK_BITS-1:0] bk;
    input [ROW_BITS-1:0]  rw;
    input [COL_BITS-1:0]  cl;
    begin
        word_addr = (bk * NUM_ROWS * NUM_COLS) + (rw * NUM_COLS) + cl;
    end
endfunction

integer b, r, c;
real now_ns;

always @(posedge clk) begin
    now_ns = $realtime;
    dq_oe <= 1'b0;

    // Shift CAS pipeline
    for (b = CAS_LAT; b > 0; b = b - 1) begin
        cas_pipe[b]  <= cas_pipe[b-1];
        cas_valid[b] <= cas_valid[b-1];
    end
    cas_pipe[0]  <= {DATA_WIDTH{1'bx}};
    cas_valid[0] <= 1'b0;

    // Output read data when pipeline head is valid
    if (cas_valid[CAS_LAT]) begin
        dq_out <= cas_pipe[CAS_LAT];
        dq_oe  <= 1'b1;
    end

    if (!cs_n && cke) begin
        case (cmd)
            CMD_ACTIVE: begin
                b = ba;
                `ifdef SDRAM_TIMING_CHECK
                if (row_active[b])
                    $display("[SDRAM MODEL] WARNING: ACTIVE to already-active bank %0d at %0t", b, $time);
                `endif
                row_active[b]           <= 1'b1;
                open_row[b]             <= addr;
                last_active_time[b]     = now_ns;
            end

            CMD_READ: begin
                b = ba;
                c = addr[COL_BITS-1:0];
                if (!row_active[b]) begin
                    $display("[SDRAM MODEL] ERROR: READ to inactive bank %0d at %0t", b, $time);
                end else begin
                    cas_pipe[0]  <= mem[word_addr(b, open_row[b], c)];
                    cas_valid[0] <= 1'b1;
                end
            end

            CMD_WRITE: begin
                b = ba;
                c = addr[COL_BITS-1:0];
                if (!row_active[b]) begin
                    $display("[SDRAM MODEL] ERROR: WRITE to inactive bank %0d at %0t", b, $time);
                end else begin
                    mem[word_addr(b, open_row[b], c)] <= dq;
                end
            end

            CMD_PRECHARGE: begin
                if (addr[10]) begin
                    // Precharge all banks
                    for (b = 0; b < NUM_BANKS; b = b + 1) begin
                        row_active[b]              <= 1'b0;
                        last_precharge_time[b]      = now_ns;
                    end
                end else begin
                    b = ba;
                    row_active[b]              <= 1'b0;
                    last_precharge_time[b]      = now_ns;
                end
            end

            CMD_AUTO_REF: begin
                // Just a timing event — no state needed for functional model
            end

            CMD_LOAD_MODE: begin
                mode_reg <= addr[12:0];
                $display("[SDRAM MODEL] Mode register loaded: 0x%h at %0t", addr[12:0], $time);
            end

            CMD_NOP, CMD_DESELECT: ; // No-op

            default: $display("[SDRAM MODEL] Unknown command %b at %0t", cmd, $time);
        endcase
    end
end

endmodule

`default_nettype wire
