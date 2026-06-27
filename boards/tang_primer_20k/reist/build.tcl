## ============================================================================
## gw_sh build script for the standalone REIST benchmark engine.
## Run from this directory:  gw_sh build.tcl
## (mirrors the SBC flow; VHDL-93 synthesis, single 27 MHz clock)
## ============================================================================
set_device GW2A-LV18PG256C8/I7 -name GW2A-18C

# generated Gowin Integer Division IP + its VHDL wrapper (work.ip_divider)
add_file -type verilog {src/integer_division/integer_division.v}
add_file -type vhdl {../../../rtl/reist/ip_divider_ip.vhd}

# package first, then leaf datapath, engine, reporter, board top
add_file -type vhdl {../../../rtl/reist/reist_pkg.vhd}
add_file -type vhdl {../../../rtl/reist/reist_core.vhd}
add_file -type vhdl {../../../rtl/reist/reist_bench_engine.vhd}
add_file -type vhdl {../../../rtl/core/peripherals/uart_tx_ser.vhd}
add_file -type vhdl {../../../rtl/reist/bench_report.vhd}
add_file -type vhdl {../rtl/reist_top.vhd}

add_file -type cst {reist_bench.cst}
add_file -type sdc {reist_bench.sdc}

set_option -top_module reist_top
set_option -output_base_name reist_bench
set_option -vhdl_std vhd1993
set_option -timing_driven 1

run all
