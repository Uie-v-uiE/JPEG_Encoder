open_hw_manager
connect_hw_server
set t [lindex [get_hw_targets -of [get_hw_servers]] 0]
open_hw_target $t
set d [lindex [get_hw_devices -of $t] 0]
set_property PROBES.FILE {D:/Xilinx/Harness/Project/new_prj/k5p-jpeg-encoder/build/jpeg_dbg/jpeg_dbg_probes.ltx} $d
refresh_hw_device $d
set ila [lindex [get_hw_ilas -of $d] 0]
puts "CORE: [get_property STATUS.CORE_STATUS $ila] samples=[get_property STATUS.SAMPLE_COUNT $ila]"
current_hw_ila_data
set dobj [lindex [get_hw_ila_data -of_objects [get_hw_ilas -of $d]] 0]
write_hw_ila_data -force -file D:/Xilinx/Harness/Project/new_prj/k5p-jpeg-encoder/results/ila_capture_txwe.csv -hw_ila_data $dobj
puts "CSV EXPORTED"
