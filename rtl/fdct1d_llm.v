// fdct1d_llm.v -- one 1-D integer FDCT (LL&M / jfdctint algorithm),
// one 8-sample vector per clock, registered output (1 cycle latency).
// first_pass=1: outputs scaled by 2**PASS1_BITS (descale 11 bits after
// CONST_BITS multiplies); first_pass=0: descale 15 bits. Matches
// golden fdct1d() bit-for-bit (CONST_BITS=13, PASS1_BITS=2).
module fdct1d_llm (
    input  wire               clk,
    input  wire               rst,
    input  wire               en,
    input  wire               first_pass,
    input  wire signed [15:0] x0, x1, x2, x3, x4, x5, x6, x7,
    output reg  signed [15:0] y0, y1, y2, y3, y4, y5, y6, y7,
    output reg                yv
);
    // 15-bit signed: C_3_072711026=25172, C_2_562915447=20995 and
    // C_2_053119869=16819 exceed the 14-bit signed range
    localparam signed [15:0] C_1_175875602 = 16'sd9633;
    localparam signed [15:0] C_1_961570560 = 16'sd16069;
    localparam signed [15:0] C_1_501321110 = 16'sd12299;
    localparam signed [15:0] C_2_053119869 = 16'sd16819;
    localparam signed [15:0] C_2_562915447 = 16'sd20995;
    localparam signed [15:0] C_3_072711026 = 16'sd25172;
    localparam signed [15:0] C_0_298631336 = 16'sd2446;
    localparam signed [15:0] C_0_390180644 = 16'sd3196;
    localparam signed [15:0] C_0_541196100 = 16'sd4433;
    localparam signed [15:0] C_0_765366865 = 16'sd6270;
    localparam signed [15:0] C_0_899976223 = 16'sd7373;
    localparam signed [15:0] C_1_847759065 = 16'sd15137;

    reg signed [31:0] tmp0, tmp1, tmp2, tmp3, tmp4, tmp5, tmp6, tmp7;
    reg signed [31:0] tmp10, tmp11, tmp12, tmp13;
    reg signed [31:0] z1, z2, z3, z4, z5;
    reg signed [31:0] m4, m5, m6, m7;
    reg signed [31:0] even0, even4, even2, even6;
    reg signed [31:0] odd7, odd5, odd3, odd1;
    reg fp;

    always @(posedge clk) begin
        if (rst) begin
            yv <= 1'b0;
        end else begin
            yv <= en;
            fp <= first_pass;
            if (en) begin
                tmp0 = x0 + x7;
                tmp7 = x0 - x7;
                tmp1 = x1 + x6;
                tmp6 = x1 - x6;
                tmp2 = x2 + x5;
                tmp5 = x2 - x5;
                tmp3 = x3 + x4;
                tmp4 = x3 - x4;

                tmp10 = tmp0 + tmp3;
                tmp13 = tmp0 - tmp3;
                tmp11 = tmp1 + tmp2;
                tmp12 = tmp1 - tmp2;

                if (first_pass) begin
                    even0 = (tmp10 + tmp11) <<< 2;
                    even4 = (tmp10 - tmp11) <<< 2;
                end else begin
                    even0 = (tmp10 + tmp11 + 2) >>> 2;
                    even4 = (tmp10 - tmp11 + 2) >>> 2;
                end
                z1 = (tmp12 + tmp13) * C_0_541196100;
                if (first_pass) begin
                    even2 = (z1 + tmp13 * C_0_765366865 + 1024) >>> 11;
                    even6 = (z1 - tmp12 * C_1_847759065 + 1024) >>> 11;
                end else begin
                    even2 = (z1 + tmp13 * C_0_765366865 + 16384) >>> 15;
                    even6 = (z1 - tmp12 * C_1_847759065 + 16384) >>> 15;
                end

                z1 = tmp4 + tmp7;
                z2 = tmp5 + tmp6;
                z3 = tmp4 + tmp6;
                z4 = tmp5 + tmp7;
                z5 = (z3 + z4) * C_1_175875602;

                m4 = tmp4 * C_0_298631336;
                m5 = tmp5 * C_2_053119869;
                m6 = tmp6 * C_3_072711026;
                m7 = tmp7 * C_1_501321110;
                z1 = z1 * -C_0_899976223;
                z2 = z2 * -C_2_562915447;
                z3 = z3 * -C_1_961570560;
                z4 = z4 * -C_0_390180644;
                z3 = z3 + z5;
                z4 = z4 + z5;

                if (first_pass) begin
                    odd7 = (m4 + z1 + z3 + 1024) >>> 11;
                    odd5 = (m5 + z2 + z4 + 1024) >>> 11;
                    odd3 = (m6 + z2 + z3 + 1024) >>> 11;
                    odd1 = (m7 + z1 + z4 + 1024) >>> 11;
                end else begin
                    odd7 = (m4 + z1 + z3 + 16384) >>> 15;
                    odd5 = (m5 + z2 + z4 + 16384) >>> 15;
                    odd3 = (m6 + z2 + z3 + 16384) >>> 15;
                    odd1 = (m7 + z1 + z4 + 16384) >>> 15;
                end
                y0 <= even0[15:0];
                y1 <= odd1[15:0];
                y2 <= even2[15:0];
                y3 <= odd3[15:0];
                y4 <= even4[15:0];
                y5 <= odd5[15:0];
                y6 <= even6[15:0];
                y7 <= odd7[15:0];
            end
        end
    end
endmodule
