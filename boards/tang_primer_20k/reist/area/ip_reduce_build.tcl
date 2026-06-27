## Area/Fmax probe -- Gowin Integer Division IP only.
## Run from this directory:  gw_sh ip_reduce_build.tcl
## Then read the resource summary (LUT/Reg/DSP) and "Max Frequency" from impl/.
set_device GW2A-LV18PG256C8/I7 -name GW2A-18C

add_file -type verilog {../src/integer_division/integer_division.v}
add_file -type vhdl    {../../rtl/ip_reduce_top.vhd}
add_file -type cst     {area_probe.cst}
add_file -type sdc     {area_probe.sdc}

set_option -top_module ip_reduce_top
set_option -output_base_name ip_reduce
set_option -vhdl_std vhd1993
set_option -timing_driven 1

run all
