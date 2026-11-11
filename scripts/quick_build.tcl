cd D:/Xilinx/Harness/Project/new_prj/k5p-jpeg-encoder
set part xcku5p-ffvb676-2-i

read_verilog rtl/rgb2ycbcr.v
read_verilog rtl/decim420.v
read_verilog rtl/mcu_gather.v
read_verilog rtl/fdct1d_llm.v
read_verilog rtl/dct2d.v
read_verilog rtl/quant.v
read_verilog rtl/huff_enc.v
read_verilog rtl/jpeg_top.v
read_verilog rtl/uart_tx.v
read_verilog rtl/jpeg_demo_board.v

synth_design -top jpeg_demo_board -part $part
read_xdc constr/jpeg_demo_board.xdc
opt_design
place_design
route_design
write_bitstream -force build/jpeg_board_quick.bit
puts "QUICK-BUILD DONE"
