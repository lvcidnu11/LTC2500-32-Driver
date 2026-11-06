// Self-checking testbench for ltc_driver_fsm (the Genesys 2 / Ethernet version).
//
// The ADC model raises a new pseudo-random filtered word every DF conversions.
// Every o_read_data word and every 4-byte Ethernet burst is checked against it.
//
// Defines:
//   LAUNCH_FALL  1 = model shifts the next SDOA bit on SCKA falling edges,
//                0 = on SCKA rising edges
//   EXPECT_PASS  1 = all words must match, 0 = expect mismatches (used to show
//                which SCKA edge convention the driver is written for)
`timescale 1ns/1ps
`ifndef LAUNCH_FALL
  `define LAUNCH_FALL 1
`endif
`ifndef EXPECT_PASS
  `define EXPECT_PASS 1
`endif
`ifndef NWORDS
  `define NWORDS 6
`endif

module tb_ltc_driver_fsm;
    localparam int DF = 64;

    logic clk = 0, rst_n = 0, start = 0;
    always #5 clk = ~clk;   // 100 MHz

    wire mclk, sync, pre, sdi, scka, rdla;
    logic busy = 0, drl = 1, sdoa = 0;
    wire [31:0] read_data;
    wire [7:0]  eth_data;
    wire        data_valid, eth_valid, error;
    wire [3:0]  dbg_state;

    ltc_driver_fsm #(.DATA_WIDTH(32), .DF(DF)) dut (
        .i_clk(clk), .i_rst_n(rst_n), .i_start(start),
        .o_mclk(mclk), .o_sync(sync), .o_pre(pre),
        .i_busy(busy), .i_drl(drl),
        .o_sdi(sdi), .o_scka(scka), .o_rdla(rdla), .i_sdoa(sdoa),
        .o_debug_state(dbg_state),
        .o_read_data(read_data), .o_eth_data(eth_data),
        .o_eth_valid(eth_valid), .o_data_valid(data_valid), .o_error(error));

    // ---------------- ADC model ----------------
    logic [31:0] lfsr = 32'hDEAD_ABCD;
    logic [31:0] out_word = 32'hDEAD_ABCD;
    logic [31:0] expected[$];
    int conv_cnt = 0;
    int bit_idx;

    function automatic logic [31:0] next_lfsr(input logic [31:0] x);
        return {x[30:0], x[31] ^ x[21] ^ x[1] ^ x[0]};
    endfunction

    always @(posedge mclk) begin
        drl  <= 1'b1;
        busy <= 1'b1;
        #660 busy <= 1'b0;
        conv_cnt++;
        if (conv_cnt % DF == 0) begin
            lfsr     = next_lfsr(lfsr);
            out_word = lfsr;
            expected.push_back(lfsr);
            #10 drl <= 1'b0;
        end
    end

    always @(negedge rdla) begin
        bit_idx = 31;
        sdoa    <= out_word[31];
    end
    generate
        if (`LAUNCH_FALL) begin : g_fall
            always @(negedge scka) if (!rdla) begin
                bit_idx--;
                #3 sdoa <= (bit_idx >= 0) ? out_word[bit_idx] : 1'b0;
            end
        end else begin : g_rise
            always @(posedge scka) if (!rdla) begin
                bit_idx--;
                #3 sdoa <= (bit_idx >= 0) ? out_word[bit_idx] : 1'b0;
            end
        end
    endgenerate

    // ---------------- Scoreboard ----------------
    int n_rx = 0, n_ok = 0, n_bad = 0, n_eth_bad = 0;
    logic [31:0] cur_exp;
    logic [7:0]  eth_bytes[$];

    always @(posedge clk) begin
        if (data_valid) begin
            cur_exp = (expected.size() > 0) ? expected.pop_front() : 'x;
            n_rx++;
            if (read_data === cur_exp) n_ok++;
            else begin
                n_bad++;
                if (`EXPECT_PASS)
                    $display("ERROR: word %0d got %h expected %h", n_rx, read_data, cur_exp);
            end
            eth_bytes.delete();
        end
        if (eth_valid) begin
            eth_bytes.push_back(eth_data);
            if (eth_bytes.size() == 4) begin
                if ({eth_bytes[0], eth_bytes[1], eth_bytes[2], eth_bytes[3]} !== read_data) begin
                    n_eth_bad++;
                    $display("ERROR: Ethernet bytes %h %h %h %h do not match word %h",
                             eth_bytes[0], eth_bytes[1], eth_bytes[2], eth_bytes[3], read_data);
                end
            end
        end
    end

    initial begin
        int n_err;
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);
        start = 1;
        fork
            wait (n_rx >= `NWORDS);
            #(`NWORDS * DF * 1200 + 100_000);
        join_any
        repeat (50) @(posedge clk);

        n_err = n_eth_bad + (error ? 1 : 0) + (n_rx < `NWORDS ? 1 : 0);
        if (`EXPECT_PASS) n_err += n_bad;
        else if (n_bad == 0) n_err++;   // a mismatch was expected

        $display("DRIVER=ltc_driver_fsm LAUNCH=%s: %0d/%0d words matched, Ethernet byte errors=%0d, o_error=%0b",
                 `LAUNCH_FALL ? "fall" : "rise", n_ok, n_rx, n_eth_bad, error);
        if (n_err == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end
endmodule
