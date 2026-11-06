# Simulation (Icarus) and lint (Verilator) for both LTC2500-32 drivers.
#   ltc_driver_fsm : version used on the Genesys 2 board, with 8-bit Ethernet output
#   ltc2500_drv    : parameterized driver with SDI configuration and error flags
FSM_RTL = src/rtl/cdc_sync_edge.sv src/rtl/ltc_driver_fsm.sv
FSM_TB  = src/tests/tb_ltc_driver_fsm.sv
DRV_RTL = src/rtl/ltc2500_drv.sv
DRV_TB  = src/tests/tb_ltc2500_drv.sv

.PHONY: test lint
test:
	@mkdir -p build
	@fail=0; \
	for c in fsm_fall fsm_rise drv_rise drv_fall drv_df1 drv_df16 drv_busy drv_overrun; do \
	  case $$c in \
	    fsm_fall)    f="$(FSM_RTL) $(FSM_TB)"; d="-DLAUNCH_FALL=1 -DEXPECT_PASS=1";; \
	    fsm_rise)    f="$(FSM_RTL) $(FSM_TB)"; d="-DLAUNCH_FALL=0 -DEXPECT_PASS=0";; \
	    drv_rise)    f="$(DRV_RTL) $(DRV_TB)"; d="-DLAUNCH_FALL=0 -DDF=4 -DSCK_HALF=2";; \
	    drv_fall)    f="$(DRV_RTL) $(DRV_TB)"; d="-DLAUNCH_FALL=1 -DDF=4 -DSCK_HALF=2";; \
	    drv_df1)     f="$(DRV_RTL) $(DRV_TB)"; d="-DDF=1 -DSCK_HALF=1";; \
	    drv_df16)    f="$(DRV_RTL) $(DRV_TB)"; d="-DDF=16 -DSCK_HALF=4";; \
	    drv_busy)    f="$(DRV_RTL) $(DRV_TB)"; d="-DDF=4 -DT_CONV_NS=1200 -DEXPECT=1 -DNWORDS=3";; \
	    drv_overrun) f="$(DRV_RTL) $(DRV_TB)"; d="-DDF=1 -DSCK_HALF=2 -DEXPECT=2 -DNWORDS=5";; \
	  esac; \
	  iverilog -g2012 $$d -o build/$$c.vvp $$f 2>build/$$c.log || { cat build/$$c.log; exit 1; }; \
	  out=$$(vvp -n build/$$c.vvp); \
	  if echo "$$out" | grep -q '^PASS$$'; then r=PASS; else r=FAIL; fail=1; echo "$$out"; fi; \
	  echo "[$$r] $$c: $$(echo "$$out" | grep '^DRIVER=')"; \
	done; exit $$fail

lint:
	verilator --lint-only -Wall $(DRV_RTL)
	-verilator --lint-only -Wall --top-module ltc_driver_fsm $(FSM_RTL)
