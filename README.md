# LTC2500-32-Driver

SystemVerilog drivers for the Analog Devices LTC2500-32 32-bit SAR ADC (Port A, digitally filtered output), written for FPGA acquisition of neural signals in the Intelligent Sensory Microsystems Laboratory (University of Toronto). The lab board is a Digilent Genesys 2 (Kintex-7 xc7k325t) with a 100 MHz system clock.

## Two drivers

| File | Purpose |
|---|---|
| `src/rtl/ltc_driver_fsm.sv` | The driver used on the Genesys 2. Reads one 32-bit filtered word every 64 conversions and hands it to the Ethernet IP as four 8-bit bytes. |
| `src/rtl/ltc2500_drv.sv` | A parameterized rewrite of the same interface, with SDI configuration and error flags, for reuse in other setups. |

### `ltc_driver_fsm` (board version)

- **Conversion loop:** drives MCLK high for 3 cycles, waits for BUSY to fall (with a timeout that raises `o_error`), waits the acquisition time, and repeats until `DF` conversions are done (`DF = 64`).
- **Synchronizers:** BUSY and DRL pass through `cdc_sync_edge` (2-flop) before use.
- **Readout:** after DRL falls, holds a quiet period, drives RDLA low, generates SCKA at 25 MHz (`SCK_DIV = 2`) and shifts 32 bits from SDOA, sampling on SCKA falling edges.
- **Ethernet output:** presents the word on `o_read_data` with `o_data_valid`, then sends it MSB-first as four bytes on `o_eth_data` / `o_eth_valid`, one byte every other cycle.
- `o_debug_state` exposes the FSM state for an ILA.

### `ltc2500_drv` (parameterized version)

- **Conversion clock:** free-running MCLK generator with programmable period and high time.
- **Readout:** DRL's falling edge (2-flop synchronized) starts a readout of `NBITS` bits; SDOA is sampled at the end of each SCKA low phase, so it works whether the ADC shifts the next bit on the rising or the falling SCKA edge.
- **Configuration:** a `CFG_W`-bit word (filter type, down-sampling factor) queued with `i_cfg_load` is shifted into SDI, MSB first, during the next readout.
- **Error flags (sticky):** `o_busy_err` if BUSY is still high when the next MCLK is due; `o_overrun` if DRL falls again before the previous word has been read.
- Yosys `synth_xilinx` (7-series): 44 LUTs and 105 flip-flops.

## Verification

```
make test   # Icarus Verilog, 8 cases
make lint   # Verilator -Wall
```

Both testbenches use a behavioural Port-A model of the ADC: BUSY for 660 ns after each MCLK rising edge, DRL low every DF conversions with a new pseudo-random 32-bit word, and SDOA shifted out on SCKA. The edge on which the model shifts SDOA is a parameter (`LAUNCH_FALL`). A scoreboard checks every word read, and for the board version also checks the four Ethernet bytes against the word.

| Case | Driver | Setup | Result |
|---|---|---|---|
| `fsm_fall` | ltc_driver_fsm | DF = 64, ADC shifts on SCKA falling | 6/6 words and all Ethernet bytes match |
| `fsm_rise` | ltc_driver_fsm | DF = 64, ADC shifts on SCKA rising | 0/6 match (word shifted left by one bit); expected, see below |
| `drv_rise` | ltc2500_drv | DF = 4, SCKA 25 MHz, rising | 40/40 words match, config word received once |
| `drv_fall` | ltc2500_drv | DF = 4, SCKA 25 MHz, falling | 40/40 words match, config word received once |
| `drv_df1` | ltc2500_drv | DF = 1, SCKA 50 MHz | 40/40 words match |
| `drv_df16` | ltc2500_drv | DF = 16, SCKA 12.5 MHz | 40/40 words match |
| `drv_busy` | ltc2500_drv | conversion longer than the MCLK period | `o_busy_err` raised |
| `drv_overrun` | ltc2500_drv | DF = 1 with SCKA too slow | `o_overrun` raised |

`ltc2500_drv` passes Verilator `-Wall` with no warnings. `ltc_driver_fsm` is kept exactly as it ran on the board; Verilator reports width and unused-signal warnings on it that do not affect behaviour.

### SCKA edge convention

`ltc_driver_fsm` samples SDOA on SCKA falling edges, which reads the word correctly only if the ADC shifts the next bit on the falling edge. That is the case the board version was validated with. The original smoke test (`src/rtl/tb_ltc2500_driver.sv` with `src/rtl/ltc2500_slave.sv`) uses a model that shifts on the rising edge, so in simulation it reads `DEAD_ABCD` as `BD5B579A`; that testbench is kept for reference, and `src/tests/tb_ltc_driver_fsm.sv` replaces it. `ltc2500_drv` samples mid-way through the low phase and reads correctly under either convention.

## Not included

The Ethernet/UDP IP, the MATLAB post-processing used across in-vivo sessions, and the Genesys 2 pin constraints are not in this repository.
