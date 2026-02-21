`timescale 1ns/1ps
// =============================================================================
// tb_sdram_wb.v — Testbench for papilio_sdram_wb Wishbone wrapper
// Tests CDC, register decode, paged window, and verify trigger via WB protocol
// =============================================================================

module tb_sdram_wb;

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------
localparam DATA_WIDTH  = 16;
localparam ROW_BITS    = 13;
localparam COL_BITS    = 9;
localparam INIT_WAIT   = 200;  // Fast for simulation
localparam BASE_ADDR   = 16'h8000;

// ---------------------------------------------------------------------------
// Clock generation: 27 MHz WB clock, 100 MHz SDRAM clock
// ---------------------------------------------------------------------------
reg clk_wb   = 0;
reg clk_sdram = 0;
always #18.5 clk_wb    = ~clk_wb;    // ~27 MHz
always #5    clk_sdram = ~clk_sdram; // 100 MHz

reg rst = 1;
initial begin
    #50 rst = 0;
end

// ---------------------------------------------------------------------------
// Wishbone signals
// ---------------------------------------------------------------------------
reg  [15:0] wb_adr;
reg  [31:0] wb_dat_i;
wire [31:0] wb_dat_o;
reg         wb_we;
reg         wb_cyc;
reg         wb_stb;
wire        wb_ack;

// ---------------------------------------------------------------------------
// SDRAM physical interface
// ---------------------------------------------------------------------------
wire [ROW_BITS-1:0] sdram_addr;
wire [1:0]          sdram_ba;
wire [DATA_WIDTH-1:0] sdram_dq;
wire                sdram_clk;
wire                sdram_cke;
wire                sdram_cs_n;
wire                sdram_ras_n;
wire                sdram_cas_n;
wire                sdram_we_n;
wire [1:0]          sdram_dqm;

// ---------------------------------------------------------------------------
// DUT
// ---------------------------------------------------------------------------
papilio_sdram_wb #(
    .BASE_ADDR (BASE_ADDR),
    .INIT_WAIT (INIT_WAIT)
) dut (
    .clk       (clk_wb),
    .clk_sdram (clk_sdram),
    .rst       (rst),

    .wb_adr_i  (wb_adr),
    .wb_dat_i  (wb_dat_i),
    .wb_dat_o  (wb_dat_o),
    .wb_we_i   (wb_we),
    .wb_cyc_i  (wb_cyc),
    .wb_stb_i  (wb_stb),
    .wb_ack_o  (wb_ack),

    .sdram_addr  (sdram_addr),
    .sdram_ba    (sdram_ba),
    .sdram_dq    (sdram_dq),
    .sdram_clk   (sdram_clk),
    .sdram_cke   (sdram_cke),
    .sdram_cs_n  (sdram_cs_n),
    .sdram_ras_n (sdram_ras_n),
    .sdram_cas_n (sdram_cas_n),
    .sdram_we_n  (sdram_we_n),
    .sdram_dqm   (sdram_dqm)
);

// ---------------------------------------------------------------------------
// SDRAM behavioral model
// ---------------------------------------------------------------------------
sdram_model #(
    .DATA_WIDTH (DATA_WIDTH),
    .ROW_BITS   (ROW_BITS),
    .COL_BITS   (COL_BITS)
) sdram (
    .clk     (sdram_clk),
    .cke     (sdram_cke),
    .cs_n    (sdram_cs_n),
    .ras_n   (sdram_ras_n),
    .cas_n   (sdram_cas_n),
    .we_n    (sdram_we_n),
    .addr    (sdram_addr),
    .ba      (sdram_ba),
    .dq      (sdram_dq),
    .dqm     (sdram_dqm)
);

// ---------------------------------------------------------------------------
// WB task helpers
// ---------------------------------------------------------------------------
integer pass_count = 0;
integer fail_count = 0;

task wb_write;
    input [15:0] addr;
    input [31:0] data;
    begin
        @(negedge clk_wb);
        wb_adr   = addr;
        wb_dat_i = data;
        wb_we    = 1;
        wb_cyc   = 1;
        wb_stb   = 1;
        @(posedge clk_wb);
        while (!wb_ack) @(posedge clk_wb);
        wb_stb = 0;
        wb_cyc = 0;
        wb_we  = 0;
        @(negedge clk_wb);
    end
endtask

task wb_read;
    input  [15:0] addr;
    output [31:0] data;
    begin
        @(negedge clk_wb);
        wb_adr   = addr;
        wb_we    = 0;
        wb_cyc   = 1;
        wb_stb   = 1;
        @(posedge clk_wb);
        while (!wb_ack) @(posedge clk_wb);
        data   = wb_dat_o;
        wb_stb = 0;
        wb_cyc = 0;
        @(negedge clk_wb);
    end
endtask

task check;
    input [31:0] got;
    input [31:0] expected;
    input [127:0] msg;
    begin
        if (got === expected) begin
            $display("  PASS: %0s (got 0x%08X)", msg, got);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: %0s — got 0x%08X, expected 0x%08X", msg, got, expected);
            fail_count = fail_count + 1;
        end
    end
endtask

// ---------------------------------------------------------------------------
// Test stimulus
// ---------------------------------------------------------------------------
reg [31:0] rdata;

initial begin
    wb_adr   = 0;
    wb_dat_i = 0;
    wb_we    = 0;
    wb_cyc   = 0;
    wb_stb   = 0;

    // Wait for reset and SDRAM init
    @(negedge rst);
    repeat(INIT_WAIT + 500) @(posedge clk_sdram);
    repeat(10) @(posedge clk_wb);

    // -----------------------------------------------------------------------
    $display("TEST 1: CSR register — init_done should be 1");
    wb_read(BASE_ADDR + 16'h0000, rdata);
    check(rdata & 32'h1, 32'h1, "CSR.init_done");

    // -----------------------------------------------------------------------
    $display("TEST 2: PAGE_REG default value = 0");
    wb_read(BASE_ADDR + 16'h0004, rdata);
    check(rdata[12:0], 13'h0, "PAGE_REG default");

    // -----------------------------------------------------------------------
    $display("TEST 3: Write and read back PAGE_REG");
    wb_write(BASE_ADDR + 16'h0004, 32'h0000_00AB);
    wb_read (BASE_ADDR + 16'h0004, rdata);
    check(rdata[12:0], 13'h0AB, "PAGE_REG write-back");

    // -----------------------------------------------------------------------
    $display("TEST 4: DIR_ADDR/DIR_DATA direct write");
    wb_write(BASE_ADDR + 16'h0008, 32'h0000_0010);  // DIR_ADDR = 0x10
    wb_write(BASE_ADDR + 16'h000C, 32'h0000_CAFE);  // DIR_DATA write

    // allow CDC round-trip
    repeat(40) @(posedge clk_wb);

    $display("TEST 5: DIR_ADDR/DIR_DATA direct read");
    wb_write(BASE_ADDR + 16'h0008, 32'h0000_0010);  // DIR_ADDR = 0x10
    wb_read (BASE_ADDR + 16'h000C, rdata);           // DIR_DATA read
    repeat(40) @(posedge clk_wb);
    check(rdata[15:0], 16'hCAFE, "DIR_DATA read-back");

    // -----------------------------------------------------------------------
    $display("TEST 6: Paged window write");
    wb_write(BASE_ADDR + 16'h0004, 32'h0);          // PAGE = 0
    wb_write(BASE_ADDR + 16'h0100, 32'h0000_1234);  // window[0] = 0x1234
    repeat(30) @(posedge clk_wb);

    $display("TEST 7: Paged window read");
    wb_write(BASE_ADDR + 16'h0004, 32'h0);          // PAGE = 0
    wb_read (BASE_ADDR + 16'h0100, rdata);
    repeat(30) @(posedge clk_wb);
    check(rdata[15:0], 16'h1234, "PAGE window read-back");

    // -----------------------------------------------------------------------
    $display("TEST 8: VFY registers — write start/size, check ctrl");
    wb_write(BASE_ADDR + 16'h0014, 32'h00_0000);    // VFY_START = 0
    wb_write(BASE_ADDR + 16'h0018, 32'h00_0100);    // VFY_SIZE = 256
    wb_write(BASE_ADDR + 16'h0010, 32'h0000_0080);  // VFY_CTRL: start=1

    // Wait for verify to complete
    begin : vfy_wait
        integer timeout;
        timeout = 0;
        rdata   = 0;
        while (!(rdata & 32'h100) && timeout < 100000) begin
            wb_read(BASE_ADDR + 16'h0010, rdata);
            timeout = timeout + 1;
            repeat(10) @(posedge clk_wb);
        end
        if (timeout >= 100000)
            $display("  FAIL: Verify timed out");
        else begin
            // One extra read to let pass settle through any CDC race at done-edge
            repeat(4) @(posedge clk_wb);
            wb_read(BASE_ADDR + 16'h0010, rdata);
            check(rdata[9], 1'b1, "VFY_CTRL.pass after small region verify");
        end
    end

    // -----------------------------------------------------------------------
    $display("\n=== RESULTS: %0d passed, %0d failed ===", pass_count, fail_count);
    if (fail_count == 0)
        $display("ALL TESTS PASSED");
    else
        $display("SOME TESTS FAILED");
    $finish;
end

// Timeout watchdog
initial begin
    #2_000_000;
    $display("TIMEOUT: simulation exceeded 2 ms");
    $finish;
end

endmodule
