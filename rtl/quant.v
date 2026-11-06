// quant.v -- coefficient quantization, 8 per clock (natural order).
//   q = sign(v) * (((|v| + 4Q) >> 3) * M') >> S'
// Per-coefficient (M', S') ROMs proven exact over the legal range in golden
// build_recip (round-half-away, matching libjpeg). Q tables are the Annex K
// tables in NATURAL order (the stream is natural order here; zigzag
// reordering happens in huff_enc before entropy coding).
// Uniform-stall 3-stage pipeline (same template as rgb2ycbcr): all stages
// advance together when the output drains, so backpressure never corrupts.
// Tables from golden/gen_vectors.py: quant_{luma,chroma}_{q,m,s}.mem.
module quant (
    input  wire        clk,
    input  wire        rst,
    input  wire        coef_valid,
    output wire        coef_ready,
    input  wire [14:0] coef_0,
    input  wire [14:0] coef_1,
    input  wire [14:0] coef_2,
    input  wire [14:0] coef_3,
    input  wire [14:0] coef_4,
    input  wire [14:0] coef_5,
    input  wire [14:0] coef_6,
    input  wire [14:0] coef_7,
    input  wire [2:0]  coef_comp,
    input  wire        coef_first,
    input  wire        coef_last,
    output reg         q_valid,
    input  wire        q_ready,
    output reg  [11:0] q_0,
    output reg  [11:0] q_1,
    output reg  [11:0] q_2,
    output reg  [11:0] q_3,
    output reg  [11:0] q_4,
    output reg  [11:0] q_5,
    output reg  [11:0] q_6,
    output reg  [11:0] q_7,
    output reg  [2:0]  q_comp,
    output reg         q_first,
    output reg         q_last
);
    (* rom_style = "block" *)
    reg [7:0]  qtab_l [0:63];
    (* rom_style = "block" *)
    reg [7:0]  qtab_c [0:63];
    (* rom_style = "block" *)
    reg [23:0] mtab_l [0:63];
    (* rom_style = "block" *)
    reg [23:0] mtab_c [0:63];
    (* rom_style = "block" *)
    reg [4:0]  stab_l [0:63];
    (* rom_style = "block" *)
    reg [4:0]  stab_c [0:63];
    initial $readmemh("quant_luma_q.mem", qtab_l);
    initial $readmemh("quant_luma_m.mem", mtab_l);
    initial $readmemh("quant_luma_s.mem", stab_l);
    initial $readmemh("quant_chroma_q.mem", qtab_c);
    initial $readmemh("quant_chroma_m.mem", mtab_c);
    initial $readmemh("quant_chroma_s.mem", stab_c);

    function [7:0] qs(input is_l, input [5:0] i);
        begin
            qs = is_l ? qtab_l[i] : qtab_c[i];
        end
    endfunction
    function [23:0] ms(input is_l, input [5:0] i);
        begin
            ms = is_l ? mtab_l[i] : mtab_c[i];
        end
    endfunction
    function [4:0] ss(input is_l, input [5:0] i);
        begin
            ss = is_l ? stab_l[i] : stab_c[i];
        end
    endfunction

    wire adv = !q_valid || q_ready;    // output register drains
    assign coef_ready = adv;
    wire take = coef_valid && adv;

    // stage 1: t = (|v| + 4Q) >> 3 (magnitude), plus M/S/sign sidebands
    reg [10:0] t0, t1, t2, t3, t4, t5, t6, t7;
    reg [23:0] mm0, mm1, mm2, mm3, mm4, mm5, mm6, mm7;
    reg [4:0]  ss0, ss1, ss2, ss3, ss4, ss5, ss6, ss7;
    reg        sgn0, sgn1, sgn2, sgn3, sgn4, sgn5, sgn6, sgn7;
    reg        v1, v1f, v1l;
    reg [2:0]  c1;   // [2]=frame-end eof bit (2-bit decl dropped it)
    reg [2:0]  gidx; // group within the block: the ROM index is the NATURAL
                     // position {gidx, lane} -- lane-only indexing served
                     // table entries 0-7 to every group (I-20)
    // stage 2: products
    // full-precision products: t(11b, <= VQ_MAX+1) x M(24b) needs 35 bits.
    // A 27-bit product WRAPPED for luma positions 58-61 (M~176603) once
    // |v| >= ~5700 -- reachable by high-frequency content (I-24/P0-2).
    reg [34:0] pr0, pr1, pr2, pr3, pr4, pr5, pr6, pr7;
    reg        v2, v2f, v2l;
    reg [2:0]  c2;   // [2]=frame-end eof bit
    reg [4:0]  sh0, sh1, sh2, sh3, sh4, sh5, sh6, sh7;
    reg        sg0, sg1, sg2, sg3, sg4, sg5, sg6, sg7;

    always @(posedge clk) begin
        if (rst) begin
            q_valid <= 0; v1 <= 0; v2 <= 0;
            q_comp <= 0; q_first <= 0; q_last <= 0;
            v1f <= 0; v1l <= 0; v2f <= 0; v2l <= 0;
            c1 <= 0; c2 <= 0; gidx <= 0;
        end else if (adv) begin
            // stage 2 -> output (magnitude shift + sign restore)
            q_valid <= v2;
            q_comp  <= c2;
            q_first <= v2f;
            q_last  <= v2l;
            q_0 <= sg0 ? -(pr0 >> sh0) : (pr0 >> sh0);
            q_1 <= sg1 ? -(pr1 >> sh1) : (pr1 >> sh1);
            q_2 <= sg2 ? -(pr2 >> sh2) : (pr2 >> sh2);
            q_3 <= sg3 ? -(pr3 >> sh3) : (pr3 >> sh3);
            q_4 <= sg4 ? -(pr4 >> sh4) : (pr4 >> sh4);
            q_5 <= sg5 ? -(pr5 >> sh5) : (pr5 >> sh5);
            q_6 <= sg6 ? -(pr6 >> sh6) : (pr6 >> sh6);
            q_7 <= sg7 ? -(pr7 >> sh7) : (pr7 >> sh7);
            // stage 1 -> stage 2
            v2 <= v1; v2f <= v1f; v2l <= v1l; c2 <= c1;
            pr0 <= t0 * mm0; pr1 <= t1 * mm1;
            pr2 <= t2 * mm2; pr3 <= t3 * mm3;
            pr4 <= t4 * mm4; pr5 <= t5 * mm5;
            pr6 <= t6 * mm6; pr7 <= t7 * mm7;
            sh0 <= ss0; sh1 <= ss1; sh2 <= ss2; sh3 <= ss3;
            sh4 <= ss4; sh5 <= ss5; sh6 <= ss6; sh7 <= ss7;
            sg0 <= sgn0; sg1 <= sgn1; sg2 <= sgn2; sg3 <= sgn3;
            sg4 <= sgn4; sg5 <= sgn5; sg6 <= sgn6; sg7 <= sgn7;
            // input -> stage 1
            v1  <= take;
            v1f <= take && coef_first;
            v1l <= take && coef_last;
            c1  <= coef_comp;
            t0 <= ((coef_0[14] ? (~coef_0[13:0] + 1'b1) : coef_0[13:0])
                   + {3'b0, qs(coef_comp == 2'd0, {gidx, 3'd0}), 2'b00}) >> 3;
            t1 <= ((coef_1[14] ? (~coef_1[13:0] + 1'b1) : coef_1[13:0])
                   + {3'b0, qs(coef_comp == 2'd0, {gidx, 3'd1}), 2'b00}) >> 3;
            t2 <= ((coef_2[14] ? (~coef_2[13:0] + 1'b1) : coef_2[13:0])
                   + {3'b0, qs(coef_comp == 2'd0, {gidx, 3'd2}), 2'b00}) >> 3;
            t3 <= ((coef_3[14] ? (~coef_3[13:0] + 1'b1) : coef_3[13:0])
                   + {3'b0, qs(coef_comp == 2'd0, {gidx, 3'd3}), 2'b00}) >> 3;
            t4 <= ((coef_4[14] ? (~coef_4[13:0] + 1'b1) : coef_4[13:0])
                   + {3'b0, qs(coef_comp == 2'd0, {gidx, 3'd4}), 2'b00}) >> 3;
            t5 <= ((coef_5[14] ? (~coef_5[13:0] + 1'b1) : coef_5[13:0])
                   + {3'b0, qs(coef_comp == 2'd0, {gidx, 3'd5}), 2'b00}) >> 3;
            t6 <= ((coef_6[14] ? (~coef_6[13:0] + 1'b1) : coef_6[13:0])
                   + {3'b0, qs(coef_comp == 2'd0, {gidx, 3'd6}), 2'b00}) >> 3;
            t7 <= ((coef_7[14] ? (~coef_7[13:0] + 1'b1) : coef_7[13:0])
                   + {3'b0, qs(coef_comp == 2'd0, {gidx, 3'd7}), 2'b00}) >> 3;
            mm0 <= ms(coef_comp == 2'd0, {gidx, 3'd0}); mm1 <= ms(coef_comp == 2'd0, {gidx, 3'd1});
            mm2 <= ms(coef_comp == 2'd0, {gidx, 3'd2}); mm3 <= ms(coef_comp == 2'd0, {gidx, 3'd3});
            mm4 <= ms(coef_comp == 2'd0, {gidx, 3'd4}); mm5 <= ms(coef_comp == 2'd0, {gidx, 3'd5});
            mm6 <= ms(coef_comp == 2'd0, {gidx, 3'd6}); mm7 <= ms(coef_comp == 2'd0, {gidx, 3'd7});
            ss0 <= ss(coef_comp == 2'd0, {gidx, 3'd0}); ss1 <= ss(coef_comp == 2'd0, {gidx, 3'd1});
            ss2 <= ss(coef_comp == 2'd0, {gidx, 3'd2}); ss3 <= ss(coef_comp == 2'd0, {gidx, 3'd3});
            ss4 <= ss(coef_comp == 2'd0, {gidx, 3'd4}); ss5 <= ss(coef_comp == 2'd0, {gidx, 3'd5});
            ss6 <= ss(coef_comp == 2'd0, {gidx, 3'd6}); ss7 <= ss(coef_comp == 2'd0, {gidx, 3'd7});
            sgn0 <= coef_0[14]; sgn1 <= coef_1[14];
            sgn2 <= coef_2[14]; sgn3 <= coef_3[14];
            sgn4 <= coef_4[14]; sgn5 <= coef_5[14];
            sgn6 <= coef_6[14]; sgn7 <= coef_7[14];
            if (take)
                gidx <= coef_last ? 3'd0 : gidx + 1'b1;
        end
    end
endmodule
