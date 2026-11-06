# JPEG 板级演示一键构建:synth + impl + bit(xcku5p-ffvb676-2-i,200 MHz)
set part xcku5p-ffvb676-2-i
set out results
file mkdir $out
create_project -force jpeg_board build/jpeg_board -part $part
add_files rtl/rgb2ycbcr.v
add_files rtl/decim420.v
add_files rtl/mcu_gather.v
add_files rtl/dct2d.v
add_files rtl/fdct1d_llm.v
add_files rtl/quant.v
add_files rtl/huff_enc.v
add_files rtl/jpeg_top.v
add_files rtl/uart_tx.v
add_files rtl/jpeg_demo_board.v
add_files vectors/jpeg_demo_rgb.mem
set_property file_type {Memory File} [get_files vectors/jpeg_demo_rgb.mem]
add_files -fileset constrs_1 constr/jpeg_demo_board.xdc
set_property top jpeg_demo_board [current_fileset]
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} { puts "SYNTH FAIL"; exit 1 }
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
set bit [glob -nocomplain build/jpeg_board/jpeg_board.runs/impl_1/*.bit]
if {[llength $bit] == 0} { puts "IMPL FAIL"; exit 1 }
open_run impl_1
report_timing_summary -file $out/jpeg_board_timing.rpt
report_utilization -file $out/jpeg_board_util.rpt
puts "JPEG-BOARD BIT: [lindex $bit 0]"
puts "JPEG-BOARD DONE"
