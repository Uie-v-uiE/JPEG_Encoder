# ILA 插入(v2:全显式,单网逐位连接,修正 get_nets 多位置参数错误)
open_checkpoint build/jpeg_dbg/synth_dbg.dcp
create_debug_core u_ila_jpeg ila
set_property C_DATA_DEPTH 4096 [get_debug_cores u_ila_jpeg]
set_property C_TRIGIN_EN false [get_debug_cores u_ila_jpeg]
set_property C_TRIGOUT_EN false [get_debug_cores u_ila_jpeg]
set_property C_ADV_TRIGGER false [get_debug_cores u_ila_jpeg]
set_property C_INPUT_PIPE_STAGES 0 [get_debug_cores u_ila_jpeg]
set_property ALL_PROBE_SAME_MU true [get_debug_cores u_ila_jpeg]
set_property ALL_PROBE_SAME_MU_CNT 1 [get_debug_cores u_ila_jpeg]
for {set i 0} {$i < 17} {incr i} { create_debug_port u_ila_jpeg probe }

set_property port_width 1 [get_debug_ports u_ila_jpeg/clk]
connect_debug_port u_ila_jpeg/clk [get_nets {clk}]

set sig1 {cfg_valid s_valid s_ready y_valid y_ready c_valid cfg_seen hold_input accept_y pending_emit m_valid m_last tx_we done}
set pi 0
foreach sig $sig1 {
    set p u_ila_jpeg/probe$pi
    set_property port_width 1 [get_debug_ports $p]
    set nl [get_nets -quiet -hierarchical $sig]
    if {[llength $nl] == 0} { puts "SKIP $sig"; incr pi; continue }
    if {[llength $nl] > 1} {
        set pick ""
        foreach nn $nl { if {[string first "u_jpeg/" $nn] == 0} { set pick $nn } }
        if {$pick != ""} { set nl [list $pick] }
    }
    connect_debug_port $p [lindex $nl 0]
    puts "PROBE$pi <- $sig"
    incr pi
}

set p u_ila_jpeg/probe14
set_property port_width 11 [get_debug_ports $p]
set w15 {}
foreach b {10 9 8 7 6 5 4 3 2 1 0} {
    lappend w15 [get_nets "u_jpeg/u_decim/W\[$b\]"]
}
connect_debug_port $p $w15
puts "PROBE14 <- W[10:0]"
incr pi

set p u_ila_jpeg/probe15
set_property port_width 11 [get_debug_ports $p]
set w16 {}
foreach b {10 9 8 7 6 5 4 3 2 1 0} {
    lappend w16 [get_nets "u_jpeg/u_decim/xcnt\[$b\]"]
}
connect_debug_port $p $w16
puts "PROBE15 <- xcnt[11:0]"
incr pi

set p u_ila_jpeg/probe16
set_property port_width 1 [get_debug_ports $p]
connect_debug_port $p [get_nets -hierarchical *odd_row]
puts "PROBE16 <- odd_row"
incr pi

set p u_ila_jpeg/probe17
set_property port_width 12 [get_debug_ports $p]
set w17 {}
foreach b {11 10 9 8 7 6 5 4 3 2 1 0} {
    lappend w17 [get_nets "ridx\[$b\]"]
}
connect_debug_port $p $w17
puts "PROBE17 <- ridx[11:0]"

implement_debug_core
opt_design
place_design
route_design
report_timing_summary -file results/jpeg_dbg_timing.rpt
write_checkpoint -force build/jpeg_dbg/jpeg_dbg_routed.dcp
write_bitstream -force build/jpeg_dbg/jpeg_dbg.bit
write_debug_probes -force build/jpeg_dbg/jpeg_dbg_probes.ltx
puts "ILA-BIT DONE"
