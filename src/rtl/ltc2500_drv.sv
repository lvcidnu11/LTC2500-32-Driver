// LTC2500-32 acquisition driver (Port A: filtered output).
//
// - Free-running MCLK generator starts one conversion per MCLK_PERIOD_CYC clocks.
// - BUSY and DRL are asynchronous to i_clk and pass through 2-FF synchronizers.
// - When DRL falls (a filtered result is ready), the read engine drives RDLA low
//   and clocks NBITS bits out of SDOA with SCKA, MSB first. A configuration word
//   can be shifted into SDI on the same SCKA edges (filter type / down-sampling).
// - Status: o_busy_err  = BUSY was still high when the next MCLK was due.
//           o_overrun   = DRL fell again before the previous word was read out.
//
// Timing assumptions (check against the LTC2500-32 datasheet for your setup):
// - The ADC presents the MSB on SDOA once RDLA is low, and shifts out the next
//   bit on each SCKA rising edge. The driver samples SDOA at the end of the SCKA
//   low phase, i.e. half an SCKA period after the previous launch edge.
// - SDI is driven while SCKA is low and is sampled by the ADC on SCKA rising.
// - Default parameters assume i_clk = 100 MHz: MCLK high 40 ns (min 20 ns),
//   1 Msps conversion rate, SCKA = 25 MHz.
module ltc2500_drv #(
    parameter int NBITS           = 32,
    parameter int CFG_W           = 12,
    parameter int MCLK_PERIOD_CYC = 100,
    parameter int MCLK_HIGH_CYC   = 4,
    parameter int SCK_HALF_CYC    = 2
) (
    input  logic             i_clk,
    input  logic             i_rst,      // synchronous, active high
    input  logic             i_en,       // run conversions

    // Configuration word, shifted into SDI on the next readout after i_cfg_load
    input  logic [CFG_W-1:0] i_cfg_word,
    input  logic             i_cfg_load,

    // ADC pins
    output logic             o_mclk,
    output logic             o_sync,
    output logic             o_pre,
    input  logic             i_busy,
    input  logic             i_drl,
    output logic             o_rdla,
    output logic             o_scka,
    output logic             o_sdi,
    input  logic             i_sdoa,

    // Data out
    output logic [NBITS-1:0] o_data,
    output logic             o_valid,    // one-cycle pulse with o_data
    output logic             o_busy_err, // sticky until reset
    output logic             o_overrun   // sticky until reset
);

    localparam int PCNT_W = $clog2(MCLK_PERIOD_CYC);
    localparam int HCNT_W = (SCK_HALF_CYC > 1) ? $clog2(SCK_HALF_CYC) : 1;
    localparam int BCNT_W = $clog2(NBITS + 1);

    // Unused control pins held inactive.
    assign o_sync = 1'b0;
    assign o_pre  = 1'b0;

    // ------------------------------------------------------------------
    // Synchronizers for the asynchronous ADC status outputs
    // ------------------------------------------------------------------
    logic [1:0] busy_ff, drl_ff;
    logic       drl_d;
    always_ff @(posedge i_clk) begin
        if (i_rst) begin
            busy_ff <= 2'b00;
            drl_ff  <= 2'b11;
            drl_d   <= 1'b1;
        end else begin
            busy_ff <= {busy_ff[0], i_busy};
            drl_ff  <= {drl_ff[0], i_drl};
            drl_d   <= drl_ff[1];
        end
    end
    wire busy_s    = busy_ff[1];
    wire drl_fall  = drl_d & ~drl_ff[1];

    // ------------------------------------------------------------------
    // MCLK generator
    // ------------------------------------------------------------------
    logic [PCNT_W-1:0] pcnt;
    always_ff @(posedge i_clk) begin
        if (i_rst || !i_en) begin
            pcnt       <= '0;
            o_mclk     <= 1'b0;
        end else begin
            pcnt   <= (pcnt == PCNT_W'(MCLK_PERIOD_CYC - 1)) ? '0 : pcnt + 1'b1;
            o_mclk <= (pcnt < PCNT_W'(MCLK_HIGH_CYC));
        end
    end

    // BUSY should be low by the time the next conversion starts.
    always_ff @(posedge i_clk) begin
        if (i_rst)
            o_busy_err <= 1'b0;
        else if (i_en && pcnt == '0 && busy_s)
            o_busy_err <= 1'b1;
    end

    // ------------------------------------------------------------------
    // Read engine
    // ------------------------------------------------------------------
    typedef enum logic [1:0] {S_IDLE, S_LOW, S_HIGH, S_DONE} state_t;
    state_t state;

    logic [HCNT_W-1:0] hcnt;
    logic [BCNT_W-1:0] bcnt;   // bits captured so far
    logic [NBITS-1:0]  shreg;
    logic [CFG_W-1:0]  cfg_sh;
    logic              cfg_pending;
    logic              cfg_active;

    wire half_done = (hcnt == HCNT_W'(SCK_HALF_CYC - 1));

    always_ff @(posedge i_clk) begin
        if (i_rst) begin
            cfg_pending <= 1'b0;
        end else if (i_cfg_load) begin
            cfg_pending <= 1'b1;
        end else if (state == S_IDLE && drl_fall) begin
            cfg_pending <= 1'b0;   // consumed by this readout
        end
    end

    always_ff @(posedge i_clk) begin
        if (i_rst) begin
            state      <= S_IDLE;
            hcnt       <= '0;
            bcnt       <= '0;
            shreg      <= '0;
            cfg_sh     <= '0;
            cfg_active <= 1'b0;
            o_rdla     <= 1'b1;
            o_scka     <= 1'b0;
            o_sdi      <= 1'b0;
            o_data     <= '0;
            o_valid    <= 1'b0;
            o_overrun  <= 1'b0;
        end else begin
            o_valid <= 1'b0;
            if (state != S_IDLE && drl_fall)
                o_overrun <= 1'b1;

            case (state)
                S_IDLE: begin
                    o_scka <= 1'b0;
                    o_rdla <= 1'b1;
                    o_sdi  <= 1'b0;
                    if (drl_fall) begin
                        o_rdla     <= 1'b0;
                        hcnt       <= '0;
                        bcnt       <= '0;
                        cfg_active <= cfg_pending;
                        cfg_sh     <= i_cfg_word;
                        o_sdi      <= cfg_pending ? i_cfg_word[CFG_W-1] : 1'b0;
                        state      <= S_LOW;
                    end
                end

                // SCKA low: data from the previous launch settles; sample at the end.
                S_LOW: begin
                    hcnt <= hcnt + 1'b1;
                    if (half_done) begin
                        hcnt  <= '0;
                        shreg <= {shreg[NBITS-2:0], i_sdoa};
                        bcnt  <= bcnt + 1'b1;
                        if (bcnt == BCNT_W'(NBITS - 1)) begin
                            state <= S_DONE;
                        end else begin
                            o_scka <= 1'b1;   // ADC launches the next bit
                            state  <= S_HIGH;
                        end
                    end
                end

                S_HIGH: begin
                    hcnt <= hcnt + 1'b1;
                    if (half_done) begin
                        hcnt   <= '0;
                        o_scka <= 1'b0;
                        // Next SDI bit, presented while SCKA is low.
                        cfg_sh <= {cfg_sh[CFG_W-2:0], 1'b0};
                        o_sdi  <= (cfg_active && bcnt < BCNT_W'(CFG_W)) ? cfg_sh[CFG_W-2] : 1'b0;
                        state  <= S_LOW;
                    end
                end

                S_DONE: begin
                    o_rdla  <= 1'b1;
                    o_sdi   <= 1'b0;
                    o_data  <= shreg;
                    o_valid <= 1'b1;
                    state   <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
