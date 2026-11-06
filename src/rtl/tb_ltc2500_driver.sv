`timescale 1ns / 1ps

module tb_ltc2500_driver;

    logic clk;
    logic rst_n;
    logic start;
    
    wire mclk;
    wire sync;
    wire pre;
    wire busy;
    wire drl;
    wire sdi;
    wire scka;
    wire rdla;
    wire sdoa;
    
    wire [31:0] read_data;
    wire [7:0] eth_data;
    wire        data_valid;
    wire eth_valid;
    wire        error;
    wire [3:0] state;


    initial begin
        clk = 0;
        forever #5 clk = ~clk; 
    end


    ltc_driver_fsm #(
        .DATA_WIDTH(32),
        .CLK_FREQ(100_000_000)
    ) ltc_driver_fsm_inst (
        .i_clk(clk),
        .i_rst_n(rst_n),
        .i_start(start),
        .o_mclk(mclk),
        .o_sync(sync),
        .o_pre(pre),
        .i_busy(busy),
        .i_drl(drl),
        .o_sdi(sdi),
        .o_scka(scka),
        .o_rdla(rdla),
        .i_sdoa(sdoa),
        .o_read_data(read_data),
        .o_eth_data(eth_data),
        .o_data_valid(data_valid),
        .o_eth_valid(eth_valid),
        .o_error(error),
        .o_debug_state(state)
    );

    ltc2500_slave adc_inst (
        .mclk(mclk),
        .busy(busy),
        .drl(drl),
        .rdla(rdla),
        .scka(scka),
        .sdoa(sdoa)
    );

    initial begin
        rst_n = 0;
        start = 0;
        
        #100;
        rst_n = 1;
        $display("[%0t] System Reset Released.", $time);
        
        #50;
        
        @(posedge clk);
        start = 1;
        $display("[%0t] First Conversion Started...", $time);
        
        @(posedge data_valid);
        $display("[%0t] First Data Read: 32'h%h", $time, read_data);
        
        #200000;
        $display("[%0t] Simulation Finished Successfully!", $time);
        $finish;
    end

    initial begin
        $dumpfile("ltc2500_sim.vcd");
        $dumpvars(0, tb_ltc2500_driver);
    end

endmodule