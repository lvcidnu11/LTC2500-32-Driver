// Self-checking testbench for ltc2500_drv with a behavioural LTC2500-32 Port-A model.
//
// Plusargs / defines:
//   DF          down-sampling factor of the model (one DRL per DF conversions)
//   SCK_HALF    SCK_HALF_CYC of the driver
//   T_CONV_NS   model conversion time (BUSY high)
//   EXPECT      0 = clean run, 1 = expect o_busy_err, 2 = expect o_overrun
`timescale 1ns/1ps
`ifndef DF
  `define DF 4
`endif
`ifndef SCK_HALF
  `define SCK_HALF 2
`endif
`ifndef T_CONV_NS
  `define T_CONV_NS 660
`endif
`ifndef EXPECT
  `define EXPECT 0
`endif
`ifndef LAUNCH_FALL
  `define LAUNCH_FALL 0
`endif
`ifndef NWORDS
  `define NWORDS 40
`endif

module tb_ltc2500_drv;
    localparam int NBITS = 32;
    localparam int CFG_W = 12;

    logic clk = 0, rst = 1, en = 0;
    always #5 clk = ~clk;   // 100 MHz

    logic [CFG_W-1:0] cfg_word;
    logic             cfg_load;
    wire mclk, sync, pre, rdla, scka, sdi;
    logic busy = 0, drl = 1, sdoa = 0;
    wire [NBITS-1:0] data;
    wire valid, busy_err, overrun;

    ltc2500_drv #(.NBITS(NBITS), .CFG_W(CFG_W), .SCK_HALF_CYC(`SCK_HALF)) dut (
        .i_clk(clk), .i_rst(rst), .i_en(en),
        .i_cfg_word(cfg_word), .i_cfg_load(cfg_load),
        .o_mclk(mclk), .o_sync(sync), .o_pre(pre),
        .i_busy(busy), .i_drl(drl),
        .o_rdla(rdla), .o_scka(scka), .o_sdi(sdi), .i_sdoa(sdoa),
        .o_data(data), .o_valid(valid), .o_busy_err(busy_err), .o_overrun(overrun));

    // ---------------- ADC model ----------------
    logic [NBITS-1:0] expected[$];
    logic [NBITS-1:0] out_word;
    logic [31:0]      lfsr = 32'hACE1_2027;
    int               conv_cnt = 0;
    int               bit_idx;
    logic [CFG_W-1:0] sdi_sh;
    int               sdi_n;
    logic [CFG_W-1:0] cfg_seen[$];

    function automatic logic [31:0] next_lfsr(input logic [31:0] x);
        return {x[30:0], x[31] ^ x[21] ^ x[1] ^ x[0]};
    endfunction

    // Conversion: BUSY high for T_CONV after MCLK rises; every DF-th result
    // raises a new filtered word and pulls DRL low until the next MCLK.
    always @(posedge mclk) begin
        drl  <= 1'b1;
        busy <= 1'b1;
        #(`T_CONV_NS) busy <= 1'b0;
        conv_cnt++;
        if (conv_cnt % `DF == 0) begin
            lfsr     = next_lfsr(lfsr);
            out_word = lfsr;
            expected.push_back(lfsr);
            #10 drl <= 1'b0;
        end
    end

    // Readout: MSB once RDLA is low, next bit after each SCKA rising edge
    // (LAUNCH_FALL=0) or falling edge (LAUNCH_FALL=1). SDI is sampled on rising.
    always @(negedge rdla) begin
        bit_idx = NBITS - 1;
        sdoa    <= out_word[bit_idx];
        sdi_sh  = '0;
        sdi_n   = 0;
    end
    always @(posedge scka) begin
        if (!rdla && sdi_n < CFG_W) begin
            sdi_sh = {sdi_sh[CFG_W-2:0], sdi};
            sdi_n++;
        end
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
    always @(posedge rdla) begin
        if (sdi_n == CFG_W) cfg_seen.push_back(sdi_sh);
    end

    // ---------------- Scoreboard ----------------
    int n_ok = 0, n_err = 0, n_rx = 0;
    always @(posedge clk) begin
        if (valid && `EXPECT == 0) begin
            n_rx++;
            if (expected.size() == 0) begin
                n_err++;
                $display("ERROR: unexpected word %h", data);
            end else begin
                logic [NBITS-1:0] exp_w;
                exp_w = expected.pop_front();
                if (data !== exp_w) begin
                    n_err++;
                    $display("ERROR: word %0d got %h expected %h", n_rx, data, exp_w);
                end else n_ok++;
            end
        end
    end

    // Static pins
    always @(posedge clk) begin
        if (sync !== 1'b0 || pre !== 1'b0) begin
            n_err++;
            $display("ERROR: SYNC/PRE not held low");
        end
    end

    initial begin
        logic [CFG_W-1:0] cfg_sent;
        cfg_word = '0;
        cfg_load = 0;
        repeat (5) @(posedge clk);
        rst = 0;
        en  = 1;

        if (`EXPECT == 0) begin
            // Send one configuration word on an early readout.
            cfg_sent = 12'hA5C;
            @(posedge clk);
            cfg_word <= cfg_sent;
            cfg_load <= 1;
            @(posedge clk);
            cfg_load <= 0;
        end

        // Run until enough words were read (or timeout).
        fork
            wait (n_rx >= `NWORDS);
            #(`NWORDS * `DF * 1000 * 2 + 50_000);
        join_any
        repeat (20) @(posedge clk);

        if (`EXPECT == 0) begin
            if (n_rx < `NWORDS) begin n_err++; $display("ERROR: only %0d words read", n_rx); end
            if (busy_err)  begin n_err++; $display("ERROR: unexpected busy_err"); end
            if (overrun)   begin n_err++; $display("ERROR: unexpected overrun"); end
            // Exactly one readout carries the config word; all others shift zeros.
            begin
                int n_cfg, n_bad;
                n_cfg = 0;
                n_bad = 0;
                foreach (cfg_seen[i]) begin
                    if (cfg_seen[i] === cfg_sent) n_cfg++;
                    else if (cfg_seen[i] !== '0) n_bad++;
                end
                if (n_cfg != 1 || n_bad != 0) begin
                    n_err++;
                    $display("ERROR: config word seen %0d times, %0d corrupt SDI words", n_cfg, n_bad);
                end
            end
        end else if (`EXPECT == 1) begin
            if (!busy_err) begin n_err++; $display("ERROR: busy_err not raised"); end
        end else if (`EXPECT == 2) begin
            if (!overrun) begin n_err++; $display("ERROR: overrun not raised"); end
        end

        if (`EXPECT == 0)
            $display("DRIVER=ltc2500_drv LAUNCH=%s DF=%0d SCK_HALF=%0d: %0d/%0d words matched, config 0x%h received, errors=%0d",
                     `LAUNCH_FALL ? "fall" : "rise", `DF, `SCK_HALF, n_ok, n_rx, cfg_sent, n_err);
        else
            $display("DRIVER=ltc2500_drv DF=%0d SCK_HALF=%0d EXPECT=%0d: busy_err=%0b overrun=%0b errors=%0d",
                     `DF, `SCK_HALF, `EXPECT, busy_err, overrun, n_err);
        if (n_err == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end
endmodule
