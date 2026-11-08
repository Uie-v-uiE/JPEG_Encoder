# JPEG debug 综合:synth + checkpoint(mark_debug 信号保留)
set part xcku5p-ffvb676-2-i
create_project -force jpeg_dbg build/jpeg_dbg -part $part
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
synth_design -top jpeg_demo_board
opt_design
write_checkpoint -force build/jpeg_dbg/synth_dbg.dcp
puts "SYNTH-DBG DONE"
