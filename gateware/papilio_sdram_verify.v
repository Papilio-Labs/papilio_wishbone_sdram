// papilio_sdram_verify.v
// Hardware-accelerated SDRAM memory verification engine
// Runs autonomously at SDRAM clock speed — ESP32 just starts and polls status.
//
// Patterns:
//   0: walking ones  — writes 1<<n at address n (mod DATA_WIDTH), reads back
//   1: address-as-data — writes addr[DATA_WIDTH-1:0] to each word, reads back
//   2: pseudo-random  — LFSR-based pattern (same LFSR sequence for write and verify)
//   3: fill           — writes fixed value (0xA5A5) to all words, reads back
//
// Control signals are driven from the WB clock domain but synchronised here.
// The ctrl_* port connects directly to papilio_sdram_ctrl's vfy_* interface.

`default_nettype none

module papilio_sdram_verify #(
    parameter ADDR_WIDTH = 24,
    parameter DATA_WIDTH = 16
) (
    input  wire                  clk,
    input  wire                  rst,

    // Control (from WB domain — safe after register writes settle)
    input  wire                  start,       // pulse (synchronised in WB module)
    input  wire [1:0]            pattern,
    input  wire [ADDR_WIDTH-1:0] start_addr,
    input  wire [ADDR_WIDTH-1:0] size,        // in words

    // Status (to WB domain — read as level signals)
    output reg                   running,
    output reg                   done,
    output reg                   pass,
    output reg  [ADDR_WIDTH-1:0] fail_addr,

    // Memory controller port
    output reg                   ctrl_req,
    output reg                   ctrl_we,
    output reg  [ADDR_WIDTH-1:0] ctrl_addr,
    output reg  [DATA_WIDTH-1:0] ctrl_wdata,
    input  wire                  ctrl_ack,
    input  wire [DATA_WIDTH-1:0] ctrl_rdata
);

localparam PAT_WALKING = 2'd0;
localparam PAT_ADDR    = 2'd1;
localparam PAT_RANDOM  = 2'd2;
localparam PAT_FILL    = 2'd3;

localparam FILL_VALUE  = 16'hA5A5;

localparam S_IDLE      = 3'd0;
localparam S_WRITE     = 3'd1;
localparam S_WRITE_ACK = 3'd2;
localparam S_READ_PREP = 3'd3;  // rewind to start for verify pass
localparam S_READ      = 3'd4;
localparam S_READ_ACK  = 3'd5;
localparam S_DONE      = 3'd6;

reg [2:0] state;

reg [ADDR_WIDTH-1:0] cur_addr;
reg [ADDR_WIDTH-1:0] words_left;
reg [1:0]            cur_pattern;
reg [ADDR_WIDTH-1:0] cur_start;
reg [ADDR_WIDTH-1:0] cur_size;

// LFSR for pseudo-random pattern (maximal 16-bit LFSR, polynomial x^16+x^14+x^13+x^11+1)
reg [15:0] lfsr_wr;
reg [15:0] lfsr_rd;

function [15:0] lfsr_next;
    input [15:0] l;
    begin
        lfsr_next = {l[14:0], l[15] ^ l[13] ^ l[12] ^ l[10]};
    end
endfunction

// Generate expected data for current address
function [DATA_WIDTH-1:0] gen_data;
    input [ADDR_WIDTH-1:0] addr;
    input [1:0] pat;
    input [15:0] lfsr;
    begin
        case (pat)
            PAT_WALKING: gen_data = (DATA_WIDTH)'(1'b1) << (addr % DATA_WIDTH);
            PAT_ADDR:    gen_data = addr[DATA_WIDTH-1:0];
            PAT_RANDOM:  gen_data = lfsr[DATA_WIDTH-1:0];
            PAT_FILL:    gen_data = FILL_VALUE[DATA_WIDTH-1:0];
            default:     gen_data = {DATA_WIDTH{1'b0}};
        endcase
    end
endfunction

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state      <= S_IDLE;
        running    <= 1'b0;
        done       <= 1'b0;
        pass       <= 1'b0;
        fail_addr  <= {ADDR_WIDTH{1'b0}};
        ctrl_req   <= 1'b0;
        ctrl_we    <= 1'b0;
        ctrl_addr  <= {ADDR_WIDTH{1'b0}};
        ctrl_wdata <= {DATA_WIDTH{1'b0}};
        lfsr_wr    <= 16'hACE1;
        lfsr_rd    <= 16'hACE1;
    end else begin
        ctrl_req <= 1'b0;

        case (state)
            S_IDLE: begin
                if (start) begin
                    cur_pattern <= pattern;
                    cur_start   <= start_addr;
                    cur_addr    <= start_addr;
                    cur_size    <= size;
                    words_left  <= size;
                    lfsr_wr     <= 16'hACE1;  // fixed init seed
                    done        <= 1'b0;
                    pass        <= 1'b0;
                    running     <= 1'b1;
                    state       <= S_WRITE;
                end
            end

            // ---- Write pass ----
            S_WRITE: begin
                if (words_left == 0) begin
                    // All written — start read-back pass
                    cur_addr   <= cur_start;
                    words_left <= cur_size;
                    lfsr_rd    <= 16'hACE1;
                    state      <= S_READ;
                end else begin
                    ctrl_we     <= 1'b1;
                    ctrl_addr   <= cur_addr;
                    ctrl_wdata  <= gen_data(cur_addr, cur_pattern, lfsr_wr);
                    ctrl_req    <= 1'b1;
                    state       <= S_WRITE_ACK;
                end
            end

            S_WRITE_ACK: begin
                if (ctrl_ack) begin
                    if (cur_pattern == PAT_RANDOM)
                        lfsr_wr <= lfsr_next(lfsr_wr);
                    cur_addr   <= cur_addr + 1'b1;
                    words_left <= words_left - 1'b1;
                    state      <= S_WRITE;
                end
            end

            // ---- Read-back and verify pass ----
            S_READ: begin
                if (words_left == 0) begin
                    state <= S_DONE;
                end else begin
                    ctrl_we    <= 1'b0;
                    ctrl_addr  <= cur_addr;
                    ctrl_req   <= 1'b1;
                    state      <= S_READ_ACK;
                end
            end

            S_READ_ACK: begin
                if (ctrl_ack) begin
                    begin : verify_check
                        reg [DATA_WIDTH-1:0] expected;
                        expected = gen_data(cur_addr, cur_pattern, lfsr_rd);
                        if (ctrl_rdata !== expected && pass) begin
                            pass      <= 1'b0;
                            fail_addr <= cur_addr;
                        end
                    end
                    if (cur_pattern == PAT_RANDOM)
                        lfsr_rd <= lfsr_next(lfsr_rd);
                    cur_addr   <= cur_addr + 1'b1;
                    words_left <= words_left - 1'b1;
                    state      <= S_READ;
                end
            end

            S_DONE: begin
                pass    <= (fail_addr == {ADDR_WIDTH{1'b0}}) ? 1'b1 : pass;
                done    <= 1'b1;
                running <= 1'b0;
                state   <= S_IDLE;
            end

            default: state <= S_IDLE;
        endcase
    end
end

`default_nettype wire

endmodule
