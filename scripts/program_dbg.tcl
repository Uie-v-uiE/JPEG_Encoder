open_hw_manager
connect_hw_server
set t [lindex [get_hw_targets -of [get_hw_servers]] 0]
open_hw_target $t
set d [lindex [get_hw_devices -of $t] 0]
set_property PROGRAM.FILE {D:/Xilinx/Harness/Project/new_prj/k5p-jpeg-encoder/build/jpeg_dbg/jpeg_dbg.bit} $d
set_property PROBES.FILE {D:/Xilinx/Harness/Project/new_prj/k5p-jpeg-encoder/build/jpeg_dbg/jpeg_dbg_probes.ltx} $d
set_property FULL_PROBES.FILE {} $d
program_hw_devices $d
puts "PROGRAMMED JPEG DBG OK"
