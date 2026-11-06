# synth_ooc.tcl -- out-of-context synthesis + timing closure check for the
# JPEG encoder core on Kintex UltraScale+ (xcku5p-ffvb676-2-i).
# Run from the project root ( Vivado resolves the $readmemh files against
# the project directory in project mode):
#   vivado -mode batch -source scripts/synth_ooc.tcl
# Target: 100 MHz on clk (10 ns). Reports land in results/.
#
# PROJECT mode + mem files in the fileset on purpose:
#  - non-project mode resolves $readmemh against a different CWD and the
#    ROMs came up empty, X-cascading into bogus multi-driven nets that
#    constant-folded the whole design (I-32);
#  - a crashed project run also reused a stale netlist once (I-29), so this
#    script recreates the project from scratch on every invocation.
set part xcku5p-ffvb676-2-i
set period 10.0

# self-locate the project root (the .tcl lives in <root>/scripts): the
# Vivado process CWD does not necessarily follow the shell's, and every
# relative path here -- add_files AND the $readmemh resolution -- depends
# on it (I-32)
cd [file normalize [file join [file dirname [info script]] ..]]
puts "OOC CWD: [pwd]"

create_project -force jpeg_ooc build/ooc -part $part
add_files rtl/jpeg_top.v
add_files rtl/rgb2ycbcr.v
add_files rtl/decim420.v
add_files rtl/mcu_gather.v
add_files rtl/fdct1d_llm.v
add_files rtl/dct2d.v
add_files rtl/quant.v
add_files rtl/huff_enc.v
foreach f {zigzag.mem huff_dc0.mem huff_dc1.mem huff_ac0.mem huff_ac1.mem
           quant_luma_q.mem quant_luma_m.mem quant_luma_s.mem
           quant_chroma_q.mem quant_chroma_m.mem quant_chroma_s.mem} {
    add_files -norecurse $f
    set_property file_type {Memory File} [get_files $f]
}
set_property top jpeg_top [current_fileset]
set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} \
    -value {-mode out_of_context} -objects [get_runs synth_1]

synth_design -top jpeg_top -part $part -mode out_of_context
create_clock -name clk -period $period [get_ports clk]

report_utilization -hierarchical -hierarchical_depth 3 \
    -file results/ooc_hier.rpt
report_timing_summary -file results/ooc_timing.rpt
report_utilization   -file results/ooc_util.rpt
write_checkpoint -force build/ooc/jpeg_top_synth.dcp

set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
set nbram [llength [get_cells -hier -filter "PRIMITIVE_TYPE =~ BMEM.*"]]
set nmd [llength [get_drc_violations -quiet -filter {Severity == Critical}]]
set fh [open results/ooc_status.txt w]
puts $fh "WNS=$wns WHS=$whs period=$period BRAM_cells=$nbram critDRC=$nmd"
if {$wns < 0 || $whs < 0} {
    puts $fh "TIMING_FAIL"
} else {
    puts $fh "TIMING_MET"
}
close $fh
puts "OOC done: WNS=$wns WHS=$whs BRAM=$nbram critDRC=$nmd"
