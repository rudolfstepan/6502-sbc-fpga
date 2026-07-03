#!/usr/bin/tclsh

set project_name "pipistrello_sbc_minimal"
set device "XC6SLX45"
set package "CSG324"
set speed "-3"
set top_module "pipistrello_sbc_minimal_top"

set script_dir [file dirname [file normalize [info script]]]
set board_dir [file normalize [file join $script_dir ..]]
set repo_dir [file normalize [file join $board_dir .. ..]]
set project_dir [file join $board_dir project]

file mkdir $project_dir
cd $project_dir

proc add_file {path} {
  xfile add [file nativename [file normalize $path]]
}

project new $project_name

project set device $device
project set device_package $package
project set device_speed_grade $speed
project set device_family Spartan6
project set device_speedgrade $speed

project set synthesis_tool XST
project set synthesize_xst.hdl_type Mixed
project set synthesize_xst.compiler VHDL_1993
project set implement_tool NgdBuild
project set map_tool MAP
project set place_and_route_tool PAR
project set simulator Modelsim

add_file [file join $board_dir constraints pipistrello_minimal.ucf]

add_file [file join $repo_dir third_party t65 rtl T65_Pack.vhd]
add_file [file join $repo_dir third_party t65 rtl T65_ALU.vhd]
add_file [file join $repo_dir third_party t65 rtl T65_MCode.vhd]
add_file [file join $repo_dir third_party t65 rtl T65.vhd]

add_file [file join $repo_dir rtl core sbc_pkg.vhd]
add_file [file join $repo_dir rtl core bus_decode.vhd]
add_file [file join $repo_dir rtl core mem sync_ram.vhd]
add_file [file join $repo_dir rtl core mem rom.vhd]
add_file [file join $repo_dir rtl core mem char_rom.vhd]
add_file [file join $repo_dir rtl core peripherals via6522.vhd]
add_file [file join $repo_dir rtl core peripherals uart6551.vhd]
add_file [file join $repo_dir rtl core peripherals uart_rx_ser.vhd]
add_file [file join $repo_dir rtl core peripherals uart_tx_ser.vhd]
add_file [file join $repo_dir rtl core peripherals vic_vga.vhd]
add_file [file join $repo_dir rtl core cpu t65_adapter.vhd]
add_file [file join $repo_dir rtl core sbc_minimal_top.vhd]
add_file [file join $board_dir rtl pipistrello_sbc_minimal_top.vhd]

project set top_module_instance_name $top_module
project set top_module $top_module
project save

puts "ISE project created: $project_name"
puts "Device: $device-$package$speed"
puts "Top module: $top_module"
