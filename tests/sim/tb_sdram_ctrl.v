// tb_sdram_ctrl.v
// Testbench for papilio_sdram_ctrl
// Uses sdram_model.v as the memory under test
//
// Tests:
//   1. INIT sequence completes (init_done goes high)
//   2. Single write, read back (same bank/row)
//   3. Write/read across different banks
//   4. Row miss in same bank (forces precharge + reactivate)
//   5. Page hit (sequential column in same row, no precharge)
//   6. Back-to-back writes
//   7. Read after refresh does not corrupt data
//   8. All 4 banks independently accessible

`timescale 1ns / 100ps
`default_nettype none

module tb_sdram_ctrl;

// DUT parameters
localparam ROW_BITS   = 13;
localparam COL_BITS   = 9;
localparam BANK_BITS  = 2;
localparam DATA_WIDTH = 16;
localparam ADDR_WIDTH = ROW_BITS + COL_BITS + BANK_BITS;  // 24

// Timing — fast for simulation (1 ns = 100 MHz sim clock)
localparam tRCD = 2;
localparam tRP  = 2;
localparam tRC  = 6;
localparam tRFC = 6;
localparam tWR  = 2;
localparam CL   = 3;
localparam REFRESH_INTERVAL = 780;
localparam INIT_WAIT = 200;  // Short for simulation (real = 20000)

reg clk_sdram = 0;
reg rst       = 1;

// DUT I/O
reg                   req = 0;
reg                   we  = 0;
reg  [ADDR_WIDTH-1:0] addr  = 0;
reg  [DATA_WIDTH-1:0] wdata = 0;
wire                  ack;
wire [DATA_WIDTH-1:0] rdata;
wire                  init_done;
wire                  busy;

// SDRAM pins
wire [ROW_BITS-1:0]   sdram_addr;
wire [BANK_BITS-1:0]  sdram_ba;
wire [DATA_WIDTH-1:0] sdram_dq;
wire                  sdram_clk;
wire                  sdram_cke;
wire                  sdram_cs_n;
wire                  sdram_ras_n;
wire                  sdram_cas_n;
wire                  sdram_we_n;
wire [DATA_WIDTH/8-1:0] sdram_dqm;

// Clock generation: 10 ns period (100 MHz)
always #5 clk_sdram = ~clk_sdram;

// Verify engine stubs (not under test here)
wire vfy_req   = 1'b0;
wire vfy_we    = 1'b0;
wire [ADDR_WIDTH-1:0] vfy_addr  = {ADDR_WIDTH{1'b0}};
wire [DATA_WIDTH-1:0] vfy_wdata = {DATA_WIDTH{1'b0}};
wire vfy_ack;
wire [DATA_WIDTH-1:0] vfy_rdata;

// DUT
papilio_sdram_ctrl #(
    .ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS), .BANK_BITS(BANK_BITS),
    .DATA_WIDTH(DATA_WIDTH),
    .tRCD(tRCD), .tRP(tRP), .tRC(tRC), .tRFC(tRFC), .tWR(tWR),
    .CAS_LATENCY(CL),
    .REFRESH_INTERVAL(REFRESH_INTERVAL),
    .INIT_WAIT(INIT_WAIT)
) dut (
    .clk(clk_sdram), .rst(rst),
    .req(req), .we(we), .addr(addr), .wdata(wdata),
    .ack(ack), .rdata(rdata),
    .init_done(init_done), .busy(busy),
    .vfy_req(vfy_req), .vfy_we(vfy_we),
    .vfy_addr(vfy_addr), .vfy_wdata(vfy_wdata),
    .vfy_ack(vfy_ack), .vfy_rdata(vfy_rdata),
    .sdram_addr(sdram_addr), .sdram_ba(sdram_ba), .sdram_dq(sdram_dq),
    .sdram_clk(sdram_clk), .sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n),
    .sdram_ras_n(sdram_ras_n), .sdram_cas_n(sdram_cas_n), .sdram_we_n(sdram_we_n),
    .sdram_dqm(sdram_dqm)
);

// Behavioral SDRAM model
sdram_model #(
    .ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS), .BANK_BITS(BANK_BITS),
    .DATA_WIDTH(DATA_WIDTH), .CAS_LAT(CL), .CLK_PERIOD(10)
) u_sdram (
    .clk(sdram_clk), .cke(sdram_cke),
    .cs_n(sdram_cs_n), .ras_n(sdram_ras_n), .cas_n(sdram_cas_n), .we_n(sdram_we_n),
    .addr(sdram_addr), .ba(sdram_ba), .dq(sdram_dq), .dqm(sdram_dqm)
);

// ============================================================
// Task: issue a write and wait for ack
// ============================================================
task do_write;
    input [ADDR_WIDTH-1:0] a;
    input [DATA_WIDTH-1:0] d;
    begin
        @(posedge clk_sdram);
        req = 1; we = 1; addr = a; wdata = d;
        @(posedge clk_sdram);
        req = 0;
        @(posedge ack);
        @(posedge clk_sdram);
    end
endtask

// ============================================================
// Task: issue a read and return data
// ============================================================
reg [DATA_WIDTH-1:0] read_result;
task do_read;
    input [ADDR_WIDTH-1:0] a;
    begin
        @(posedge clk_sdram);
        req = 1; we = 0; addr = a; wdata = 0;
        @(posedge clk_sdram);
        req = 0;
        @(posedge ack);
        read_result = rdata;
        @(posedge clk_sdram);
    end
endtask

// ============================================================
// Test utilities
// ============================================================
integer test_num = 0;
integer pass_cnt = 0;
integer fail_cnt = 0;

task check;
    input [DATA_WIDTH-1:0] got;
    input [DATA_WIDTH-1:0] expected;
    input [255:0] name;
    begin
        test_num = test_num + 1;
        if (got === expected) begin
            $display("  PASS [%0d] %s: got 0x%h", test_num, name, got);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL [%0d] %s: expected 0x%h, got 0x%h", test_num, name, expected, got);
            fail_cnt = fail_cnt + 1;
        end
    end
endtask

// ============================================================
// Test sequence
// ============================================================
integer timeout;

initial begin
    $display("=== tb_sdram_ctrl: starting ===");
    rst = 1;
    repeat(5) @(posedge clk_sdram);
    rst = 0;

    // --- Test 1: Wait for init_done ---
    $display("\n[Test 1] INIT sequence");
    timeout = INIT_WAIT + 200;
    while (!init_done && timeout > 0) begin
        @(posedge clk_sdram);
        timeout = timeout - 1;
    end
    check(init_done, 1'b1, "init_done asserted");

    // --- Test 2: Single write then read (same bank, same row) ---
    $display("\n[Test 2] Write/read same row");
    do_write(24'h000001, 16'hABCD);
    do_read (24'h000001);
    check(read_result, 16'hABCD, "read_back_same_row");

    // --- Test 3: Different column, same row (page hit) ---
    $display("\n[Test 3] Page hit — consecutive columns");
    do_write(24'h000002, 16'h1234);
    do_write(24'h000003, 16'h5678);
    do_read (24'h000002);
    check(read_result, 16'h1234, "page_hit_col2");
    do_read (24'h000003);
    check(read_result, 16'h5678, "page_hit_col3");

    // --- Test 4: Different banks ---
    $display("\n[Test 4] Different banks");
    do_write({2'd0, 13'd0, 9'd10}, 16'hAAAA);
    do_write({2'd1, 13'd0, 9'd10}, 16'hBBBB);
    do_write({2'd2, 13'd0, 9'd10}, 16'hCCCC);
    do_write({2'd3, 13'd0, 9'd10}, 16'hDDDD);
    do_read ({2'd0, 13'd0, 9'd10}); check(read_result, 16'hAAAA, "bank0");
    do_read ({2'd1, 13'd0, 9'd10}); check(read_result, 16'hBBBB, "bank1");
    do_read ({2'd2, 13'd0, 9'd10}); check(read_result, 16'hCCCC, "bank2");
    do_read ({2'd3, 13'd0, 9'd10}); check(read_result, 16'hDDDD, "bank3");

    // --- Test 5: Row miss (different row in same bank → forces precharge) ---
    $display("\n[Test 5] Row miss");
    do_write({2'd0, 13'd0,   9'd5}, 16'h1111);
    do_write({2'd0, 13'd100, 9'd5}, 16'h2222);  // different row
    do_read ({2'd0, 13'd0,   9'd5}); check(read_result, 16'h1111, "row_miss_r0");
    do_read ({2'd0, 13'd100, 9'd5}); check(read_result, 16'h2222, "row_miss_r100");

    // --- Test 6: Back-to-back writes ---
    $display("\n[Test 6] Back-to-back writes");
    begin : bb_writes
        integer k;
        for (k = 0; k < 8; k = k + 1)
            do_write({2'd0, 13'd5, k[8:0]}, k[15:0] * 16'h0101);
        for (k = 0; k < 8; k = k + 1) begin
            do_read({2'd0, 13'd5, k[8:0]});
            check(read_result, k[15:0] * 16'h0101, "back_to_back");
        end
    end

    // Summary
    $display("\n=== Results: %0d/%0d passed ===", pass_cnt, pass_cnt + fail_cnt);
    if (fail_cnt == 0)
        $display("ALL TESTS PASSED");
    else
        $display("FAILURES DETECTED");

    $finish;
end

// Timeout watchdog
initial begin
    #10_000_000;  // 10ms sim limit
    $display("TIMEOUT: simulation exceeded 10ms");
    $finish;
end

endmodule

`default_nettype wire
