# 烧 ILA bit 并捕获(pending_emit==1 触发),导出 CSV
open_hw_manager
connect_hw_server
set t [lindex [get_hw_targets -of [get_hw_servers]] 0]
open_hw_target $t
set d [lindex [get_hw_devices -of $t] 0]
set_property PROGRAM.FILE {D:/Xilinx/Harness/Project/new_prj/k5p-jpeg-encoder/build/jpeg_dbg/jpeg_dbg.bit} $d
set_property PROBES.FILE {D:/Xilinx/Harness/Project/new_prj/k5p-jpeg-encoder/build/jpeg_dbg/jpeg_dbg_probes.ltx} $d
set_property FULL_PROBES.FILE {} $d
program_hw_devices $d
puts "DBG BIT PROGRAMMED"
refresh_hw_device $d
set ila [lindex [get_hw_ilas -of $d -filter {NAME =~ *ila_1}] 0]
if {$ila == ""} { set ila [lindex [get_hw_ilas -of $d] 0] }
puts "ILA: $ila"
set_property CONTROL.DATA_DEPTH 4096 $ila
set_property CONTROL.TRIGGER_POSITION 2048 $ila
set_property CONTROL.WINDOW_COUNT 1 $ila
set_property TRIGGER_COMPARE_VALUE eq1'b1 [get_hw_probes -of $ila -filter {NAME =~ */cfg_valid}]
run_hw_ila [get_hw_ilas -of $d] 100000
puts "CAPTURE DONE"
write_hw_ila_data -csv_file results/ila_capture.csv [current_hw_ila_data $ila]
puts "CSV EXPORTED"
