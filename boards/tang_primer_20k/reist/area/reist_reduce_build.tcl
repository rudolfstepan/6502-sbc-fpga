## Area/Fmax probe -- REIST reduction unit only.
## Run from this directory:  gw_sh reist_reduce_build.tcl
## Then read the resource summary and "Max Frequency" from impl/.
set_device GW2A-LV18PG256C8/I7 -name GW2A-18C

add_file -type vhdl {../../../../rtl/reist/reist_core.vhd}
add_file -type vhdl {../../rtl/reist_reduce_top.vhd}
add_file -type cst  {area_probe.cst}
add_file -type sdc  {area_probe.sdc}

set_option -top_module reist_reduce_top
set_option -output_base_name reist_reduce
set_option -vhdl_std vhd1993
set_option -timing_driven 1

run all
