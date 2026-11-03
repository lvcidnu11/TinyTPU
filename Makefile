IVERILOG ?= iverilog
VVP ?= vvp
VERILATOR ?= verilator
YOSYS ?= yosys

RTL := src/verilog/tpu_pkg.sv \
       src/verilog/mac_cell.sv \
       src/verilog/systolic_data_setup.sv \
       src/verilog/unified_buffer.sv \
       src/verilog/tpu_fsm.sv \
       src/verilog/tpu.sv

.PHONY: test wave lint synth check clean

test: build/tb_tpu.vvp
	$(VVP) $<

wave: build/tb_tpu.vvp
	$(VVP) $< +vcd

build/tb_tpu.vvp: $(RTL) tests/tb_tpu.sv
	mkdir -p build
	$(IVERILOG) -g2012 -Wall -s tb_tpu -o $@ $^

lint:
	$(VERILATOR) --lint-only --Wall -Wno-IMPORTSTAR --top-module tpu $(RTL)

synth:
	mkdir -p build
	$(YOSYS) -Q -T -l build/synthesis.log -s scripts/synth.ys

check: test lint synth

clean:
	rm -rf build
