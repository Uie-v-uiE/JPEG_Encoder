// huff_enc.v -- Baseline JPEG entropy encoder (serial, 1 coefficient/clock).
// Input: quantized blocks in NATURAL order (8/clock bursts) from quant.v.
// Blocks buffer 2-deep; the engine drains one block at a time in zigzag
// order (ZZ ROM). Run-length symbols use an iterative scheme (>=16 zero
// runs emit one ZRL per cycle and re-process the coefficient). Codes come
// from Annex K ROMs (huff_dc{0,1}.mem / huff_ac{0,1}.mem from
// golden/gen_vectors.py, entries {code[15:0], len[4:0]}). Code + amplitude
// bits combine into ONE accumulator update per cycle; the accumulator
// emits <=1 byte/cycle with 0xFF stuffing into a 16-deep byte FIFO.
// Advance gate: accumulator backlog <= 16 bits (worst case 4 cycles per
// coefficient, typically 1). Real-time ceiling: clk/64 blocks/s = 720p60 /
// 1080p30 at 100 MHz, 1080p60 at >= 140 MHz. DC predictors reset only by
// rst (one frame per reset; see DESIGN.md).
module huff_enc (
    input  wire        clk,
    input  wire        rst,
    input  wire        q_valid,
    output wire        q_ready,
    input  wire [11:0] q_0,
    input  wire [11:0] q_1,
    input  wire [11:0] q_2,
    input  wire [11:0] q_3,
    input  wire [11:0] q_4,
    input  wire [11:0] q_5,
    input  wire [11:0] q_6,
    input  wire [11:0] q_7,
    input  wire [2:0]  q_comp,     // [1:0] component, [2] = last block of frame
    input  wire        q_first,
    input  wire        q_last,
    output wire        out_valid,
    input  wire        out_ready,
    output wire [7:0]  out_data,
    output wire        out_last
);
    // ------------------------------------------------------------- tables
    (* rom_style = "block" *)
    reg [5:0] zz [0:63];
    (* rom_style = "block" *)
    reg [20:0] dc0 [0:15];
    (* rom_style = "block" *)
    reg [20:0] dc1 [0:15];
    (* rom_style = "block" *)
    reg [20:0] ac0 [0:255];
    (* rom_style = "block" *)
    reg [20:0] ac1 [0:255];
    initial $readmemh("zigzag.mem", zz);
    initial $readmemh("huff_dc0.mem", dc0);
    initial $readmemh("huff_dc1.mem", dc1);
    initial $readmemh("huff_ac0.mem", ac0);
    initial $readmemh("huff_ac1.mem", ac1);


    // ------------------------------------------------------- block buffers
    reg [11:0] bram [0:1][0:63];
    reg        slot_v [0:1];
    reg [1:0]  slot_comp [0:1];
    reg        slot_eof [0:1];
    reg [6:0]  widx;
    reg [1:0]  wslot;
    wire take = q_valid && q_ready;
    wire fill_done = take && q_last;
    // the writer's target slot (wslot) must hold no unconsumed block --
    // !(sv0&&sv1) allowed the writer to overwrite an unread block when the
    // engine lagged, dropping 2 Y blocks per MCU (I-06)
    assign q_ready = !slot_v[wslot];

    always @(posedge clk) begin
        if (rst) begin
            widx <= 7'd0;
            wslot <= 2'd0;
        end else if (take) begin
            bram[wslot][widx[5:0]]      <= q_0;
            bram[wslot][widx[5:0]+7'd1] <= q_1;
            bram[wslot][widx[5:0]+7'd2] <= q_2;
            bram[wslot][widx[5:0]+7'd3] <= q_3;
            bram[wslot][widx[5:0]+7'd4] <= q_4;
            bram[wslot][widx[5:0]+7'd5] <= q_5;
            bram[wslot][widx[5:0]+7'd6] <= q_6;
            bram[wslot][widx[5:0]+7'd7] <= q_7;
            if (q_last) begin
                slot_v[wslot] <= 1'b1;
                slot_comp[wslot] <= q_comp[1:0];
                slot_eof[wslot] <= q_comp[2];
                // toggle (NOT +1): wslot indexes a 2-entry array; +1 walked
                // it to 2/3, slot_v[wslot] read X, q_ready went X and the
                // engine starved after 2 blocks (I-08)
                wslot <= wslot ^ 2'd1;
            end
            widx <= q_last ? 7'd0 : widx + 7'd8;
        end
    end

    // ------------------------------------------------------------- engine
    reg        eng_run;
    reg [1:0]  eng_slot;
    reg [1:0]  eng_comp;
    reg        eng_eof;
    reg [6:0]  k;
    reg [5:0]  zz_q;
    reg signed [11:0] pred_y, pred_cb, pred_cr;
    reg [5:0]  run;
    reg        eob_pending;
    reg [1:0]  fstate;      // 0=idle/run, 1=pad, 2=drain-final, 3=done
    reg [3:0]  pad_n;

    wire signed [11:0] din = bram[eng_slot][zz_q];
    wire is_dc = (k == 7'd0);
    wire signed [11:0] pred_now = (eng_comp == 2'd0) ? pred_y :
                                  (eng_comp == 2'd1) ? pred_cb : pred_cr;
    wire signed [11:0] dc_diff = din - pred_now;

    // magnitude category, fixed 12-step structure (synthesizable)
    function [3:0] cat12(input signed [11:0] v);
        reg [11:0] a;
        begin
            a = (v < 0) ? (~v + 1'b1) : v;
            case (1'b1)
                a[11]: cat12 = 4'd12;
                a[10]: cat12 = 4'd11;
                a[9]:  cat12 = 4'd10;
                a[8]:  cat12 = 4'd9;
                a[7]:  cat12 = 4'd8;
                a[6]:  cat12 = 4'd7;
                a[5]:  cat12 = 4'd6;
                a[4]:  cat12 = 4'd5;
                a[3]:  cat12 = 4'd4;
                a[2]:  cat12 = 4'd3;
                a[1]:  cat12 = 4'd2;
                a[0]:  cat12 = 4'd1;
                default: cat12 = 4'd0;
            endcase
        end
    endfunction

    function [11:0] amp12(input signed [11:0] v, input [3:0] s);
        begin
            if (v >= 0)
                amp12 = v;
            else
                amp12 = v + ((12'b1 << s) - 1);
        end
    endfunction

    wire [3:0] dc_cat = cat12(dc_diff);
    wire [3:0] ac_cat = cat12(din);
    wire [20:0] dc_code = (eng_comp == 2'd0) ? dc0[dc_cat] : dc1[dc_cat];
    wire [20:0] ac_code = (eng_comp == 2'd0) ?
        ac0[{run[3:0], ac_cat}] : ac1[{run[3:0], ac_cat}];
    wire [20:0] zrl_code = (eng_comp == 2'd0) ? ac0[8'hF0] : ac1[8'hF0];
    wire [20:0] eob_code = (eng_comp == 2'd0) ? ac0[8'h00] : ac1[8'h00];
    wire [11:0] dc_amp = amp12(dc_diff, dc_cat);
    wire [11:0] ac_amp = amp12(din, ac_cat);

    // cycle-specific put (code+amp combined into one accumulator update)
    reg [31:0] put_word;    // bits to append (aligned: code then amp)
    reg [5:0]  put_len;
    reg        put_v;

    always @* begin
        put_v = 1'b0;
        put_word = 32'b0;
        put_len = 6'd0;
        if (eng_run && (fstate == 2'd0)) begin
            if (is_dc) begin
                put_v = 1'b1;
                put_len = dc_code[4:0] + {1'b0, dc_cat};
                put_word = (dc_code[20:5] << dc_cat) | dc_amp;
            end else if (eob_pending) begin
                put_v = 1'b1;
                put_len = eob_code[4:0];
                put_word = eob_code[20:5];
            end else if (din != 12'sd0 && run >= 6'd16) begin
                // ZRL only when a NONZERO coefficient follows the 16-zero
                // run; a trailing all-zero tail needs just the EOB (the
                // eager ZRL here inflated flat-block output 4x, I-05)
                put_v = 1'b1;
                put_len = zrl_code[4:0];
                put_word = zrl_code[20:5];
            end else if (din != 12'sd0) begin
                put_v = 1'b1;
                put_len = ac_code[4:0] + {1'b0, ac_cat};
                put_word = (ac_code[20:5] << ac_cat) | ac_amp;
            end
        end
    end

    // ---------------------------------------------------------- bit packer
    reg [47:0] acc;
    reg [5:0]  nbits;
    // byte FIFO (16 deep), push 1..2 entries per cycle (stuffing)
    reg [7:0]  f_d [0:15];
    reg        f_l [0:15];
    reg [3:0]  f_wr, f_rd;
    reg [5:0]  f_cnt;
    wire f_full = (f_cnt >= 6'd14);
    wire f_pop = out_valid && out_ready;
    assign out_valid = (f_cnt != 0);
    assign out_data = f_d[f_rd];
    assign out_last = f_l[f_rd];

    wire drain = (nbits >= 6'd8) && (f_cnt <= 6'd13);
    // engine advance: accumulator room for a 28-bit put after the drain
    wire advance_ok = ((drain ? (nbits - 6'd8) : nbits) <= 6'd16) &&
                      (f_cnt <= 6'd11);
    // byte being drained: the TOP 8 valid bits of the right-aligned acc
    wire [7:0] dbyte = acc[nbits - 6'd1 -: 8];
    // frame-final byte: everything still in the accumulator once the eof
    // block is done (fstate 1/2). fstate 1 matters when the stream ends
    // exactly byte-aligned -- the last byte then drains BEFORE the pad
    // step moves the FSM to fstate 2 and would leave out_last unset
    wire final_byte = (fstate == 2'd1 || fstate == 2'd2) && (nbits == 6'd8);
    // next accumulator state (drain then put; the put applies only when the
    // engine actually advanced this cycle -- put_v alone is combinational
    // and must not stack bits while the engine is gated)
    // drain: clear the emitted byte's bits in place (the remaining bits stay
    // right-aligned); put: shift left and insert at the bottom
    // after draining a byte, keep only the low (nbits-8) valid bits: the
    // bits above the valid field must be ZERO, or the next put's left-shift
    // drags old garbage into the stream (I-07: byte 2 = f4 vs 28)
    wire [47:0] acc_drain = acc & ((48'h1 << (nbits - 6'd8)) - 1);
    wire [47:0] acc_shift = drain ? acc_drain : acc;
    wire [5:0]  nbits_shift = drain ? (nbits - 6'd8) : nbits;
    wire        put_apply = put_v && advance_ok;
    wire [47:0] acc_next = put_apply ?
        ((acc_shift << put_len) | put_word) : acc_shift;
    wire [5:0]  nbits_next = put_apply ? (nbits_shift + put_len) : nbits_shift;

    always @(posedge clk) begin
        if (rst) begin
            eng_run <= 0; k <= 0; zz_q <= 0;
            pred_y <= 0; pred_cb <= 0; pred_cr <= 0;
            run <= 0; eob_pending <= 0;
            fstate <= 2'd0; pad_n <= 0;
            acc <= 0; nbits <= 0;
            f_wr <= 0; f_rd <= 0; f_cnt <= 0;
            slot_v[0] <= 0; slot_v[1] <= 0;
            slot_comp[0] <= 0; slot_comp[1] <= 0;
            slot_eof[0] <= 0; slot_eof[1] <= 0;
        end else begin
            // ---------------- output FIFO drain ----------------
            if (f_pop) begin
                f_rd <= f_rd + 1'b1;
            end

            // ---------------- accumulator: drain + put ----------------
            acc <= acc_next;
            nbits <= nbits_next;
            // single f_cnt write point (push entries, pop one)
            f_cnt <= f_cnt + (drain ? ((dbyte == 8'hFF) ? 5'd2 : 5'd1) : 5'd0)
                     - (f_pop ? 5'd1 : 5'd0);
            if (drain) begin
                f_d[f_wr] <= dbyte;
                f_l[f_wr] <= final_byte;
                if (dbyte == 8'hFF) begin
                    f_d[f_wr + 4'd1] <= 8'h00;
                    f_l[f_wr + 4'd1] <= final_byte;
                    f_wr <= f_wr + 4'd2;
                end else begin
                    f_wr <= f_wr + 4'd1;
                end
            end

            // ---------------- engine ----------------
            if (fstate == 2'd0) begin
                if (!eng_run) begin
                    if ((slot_v[0] || slot_v[1]) && !f_full && (nbits <= 6'd16)) begin
                        eng_run <= 1'b1;
                        // when both slots hold completed blocks, the OLDEST
                        // is the writer's current target slot (wslot): the
                        // writer filled wslot^1 last and stalled before
                        // re-filling wslot
                        eng_slot <= (slot_v[0] && slot_v[1]) ? wslot :
                                    (slot_v[0] ? 2'd0 : 2'd1);
                        eng_comp <= (slot_v[0] && slot_v[1]) ?
                            slot_comp[wslot] :
                            (slot_v[0] ? slot_comp[0] : slot_comp[1]);
                        eng_eof <= (slot_v[0] && slot_v[1]) ?
                            slot_eof[wslot] :
                            (slot_v[0] ? slot_eof[0] : slot_eof[1]);
                        k <= 7'd0;
                        zz_q <= zz[0];
                        run <= 6'd0;
                        eob_pending <= 1'b0;
                    end
                end else if (advance_ok && put_v) begin
                    // per-coefficient state updates
                    if (is_dc) begin
                        if (eng_comp == 2'd0) pred_y <= din;
                        else if (eng_comp == 2'd1) pred_cb <= din;
                        else pred_cr <= din;
                        k <= 7'd1;
                        zz_q <= zz[1];
                    end else if (eob_pending) begin
                        // final EOB: block done
                        eng_run <= 1'b0;
                        slot_v[eng_slot] <= 1'b0;
                        if (eng_eof) begin
                            fstate <= 2'd1;
                            pad_n <= (4'd8 - {1'b0, nbits_next[2:0]}) & 4'd7;
                        end
                    end else if (din != 12'sd0 && run >= 6'd16) begin
                        run <= run - 6'd16;   // ZRL: re-process coefficient
                    end else if (din != 12'sd0) begin
                        run <= 6'd0;
                        if (k == 7'd63) begin
                            // last AC coefficient was nonzero: block done
                            eng_run <= 1'b0;
                            slot_v[eng_slot] <= 1'b0;
                            if (eng_eof) begin
                                fstate <= 2'd1;
                                pad_n <= (4'd8 - {1'b0, nbits_next[2:0]}) & 4'd7;
                            end
                        end else begin
                            k <= k + 1'b1;
                            zz_q <= zz[k[5:0] + 6'd1];
                        end
                    end else begin
                        // zero coefficient: count the run
                        if (k == 7'd63)
                            eob_pending <= 1'b1;  // trailing zeros -> EOB
                        else begin
                            run <= run + 1'b1;
                            k <= k + 1'b1;
                            zz_q <= zz[k[5:0] + 6'd1];
                        end
                    end
                end else if (advance_ok && !put_v) begin
                    // zero coefficient (or trailing state): no bits
                    if (eob_pending) begin
                        // (unreachable: eob_pending puts EOB via put_v)
                    end else if (k == 7'd63) begin
                        eob_pending <= 1'b1;   // trailing zeros -> EOB
                    end else begin
                        run <= run + 1'b1;
                        k <= k + 1'b1;
                        zz_q <= zz[k[5:0] + 6'd1];
                    end
                end
            end else if (fstate == 2'd1) begin
                // pad to byte boundary with 1s (single cycle). The pad must
                // apply to the POST-DRAIN accumulator: a drain may fire on
                // this very edge (nbits>=8 left over from the last put), and
                // the plain assignment at the top of the block would
                // otherwise be overridden here with an un-drained acc,
                // duplicating the already-pushed byte on frames whose tail
                // lands in [9..43] bits (I-23). pad_n is a mod-8 quantity,
                // so draining 8 bits does not change it.
                if (pad_n != 4'd0) begin
                    acc   <= ((drain ? acc_drain : acc) << pad_n)
                             | ((48'h1 << pad_n) - 1);
                    nbits <= (drain ? (nbits - 6'd8) : nbits)
                             + {2'b0, pad_n};
                    pad_n <= 4'd0;
                    fstate <= 2'd2;
                end else begin
                    acc   <= acc_shift;
                    nbits <= nbits_shift;
                    fstate <= 2'd2;
                end
            end else if (fstate == 2'd2) begin
                // draining the final byte(s); done when acc is empty
                if (nbits == 6'd0 && f_cnt == 5'd0) begin
                    fstate <= 2'd3;
                end
            end
        end
    end
endmodule
