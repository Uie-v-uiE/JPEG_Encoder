open_hw_manager
connect_hw_server
set t [lindex [get_hw_targets -of [get_hw_servers]] 0]
open_hw_target $t
set d [lindex [get_hw_devices -of $t] 0]
set_property PROGRAM.FILE {D:/Xilinx/Harness/Project/new_prj/k5p-fft-accelerator/build/fft_board/fft_board.runs/impl_1/fft_demo_board.bit} $d
set_property FULL_PROBES.FILE {} $d
program_hw_devices $d
puts "PROGRAMMED FFT OK"
