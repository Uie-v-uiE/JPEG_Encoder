# synth_ooc.tcl -- out-of-context synthesis + timing closure check for the
# JPEG encoder core on Kintex UltraScale+ (xcku5p-ffvb676-2-i).
# Run from the project root (the $readmemh files live there):
#   vivado -mode batch -source scripts/synth_ooc.tcl
# Target: 100 MHz on clk (10 ns). Reports land in results/.
set part xcku5p-ffvb676-2-i
set period 10.0

create_project -force jpeg_ooc build/ooc -part $part
add_files rtl/jpeg_top.v
add_files rtl/rgb2ycbcr.v
add_files rtl/decim420.v
add_files rtl/mcu_gather.v
add_files rtl/fdct1d_llm.v
add_files rtl/dct2d.v
add_files rtl/quant.v
add_files rtl/huff_enc.v
set_property top jpeg_top [current_fileset]
# OOC: the cfg/gf inputs are constants chosen for a 1080p-wide design
set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} \
    -value {-mode out_of_context} -objects [get_runs synth_1]

synth_design -top jpeg_top -part $part -mode out_of_context
create_clock -name clk -period $period [get_ports clk]
# MAX_W=1920 drives deep line buffers; cfg is a static OOC input. Constrain
# nothing else -- single clock domain.

report_timing_summary -file results/ooc_timing.rpt
report_utilization   -file results/ooc_util.rpt
report_control_sets  -file results/ooc_control.rpt

# fail loudly on WNS
set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
set fh [open results/ooc_status.txt w]
puts $fh "WNS=$wns WHS=$whs period=$period"
if {$wns < 0 || $whs < 0} {
    puts $fh "TIMING_FAIL"
} else {
    puts $fh "TIMING_MET"
}
close $fh
puts "OOC done: WNS=$wns WHS=$whs"
