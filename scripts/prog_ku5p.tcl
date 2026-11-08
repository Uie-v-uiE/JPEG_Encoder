# prog_ku5p.tcl -- JTAG-program the KU5P with the JPEG demo bitstream.
open_hw_manager
connect_hw_server
open_hw_target localhost:3121/xilinx_tcf/Xilinx/0ABC01A
puts "devices: [get_hw_devices]"
set dev [lindex [get_hw_devices] 0]
puts "device: $dev"
set_property PROGRAM.FILE {D:/Xilinx/Harness/Project/new_prj/k5p-jpeg-encoder/build/jpeg_board/jpeg_board.runs/impl_1/jpeg_demo_board.bit} $dev
program_hw_devices $dev
puts "Programming succeeded"
close_hw_target
close_hw_manager
