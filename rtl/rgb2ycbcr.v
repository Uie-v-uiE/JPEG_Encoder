// rgb2ycbcr.v -- RGB888 to JFIF integer YCbCr, full-rate pipeline.
//   Y  = ( 77R + 150G +  29B + 128) >> 8
//   Cb = 128 + ((-43R -  85G + 128B) >> 8)     (arithmetic shifts)
//   Cr = 128 + ((128R - 107G -  21B) >> 8)
// Exactly mirrors golden/jpeg_golden.py rgb2y/rgb2cb/rgb2cr.
// Latency: 3 cycles. Canonical stall-uniform pipeline: all stages advance
// together when the output drain is open; s_ready = drain open.
module rgb2ycbcr (
    input  wire        clk,
    input  wire        rst,
    input  wire        s_valid,
    output wire        s_ready,
    input  wire [23:0] s_rgb,
    input  wire        s_sof,       // first pixel of frame
    input  wire        s_eol,       // last pixel of line
    output reg         m_valid,
    input  wire        m_ready,
    output reg  [7:0]  m_y,
    output reg  [7:0]  m_cb,
    output reg  [7:0]  m_cr,
    output reg         m_sof,
    output reg         m_eol
);
    wire go = !m_valid || m_ready;    // output register drains this cycle
    assign s_ready = go;

    // stage 1: products
    reg [17:0] py, pcb, pcr;
    reg v1, sof1, eol1;
    // stage 2: shifted/offset results
    reg [7:0] y2, cb2, cr2;
    reg v2, sof2, eol2;

    always @(posedge clk) begin
        if (rst) begin
            v1 <= 1'b0; sof1 <= 1'b0; eol1 <= 1'b0;
            v2 <= 1'b0; sof2 <= 1'b0; eol2 <= 1'b0;
            m_valid <= 1'b0; m_sof <= 1'b0; m_eol <= 1'b0;
        end else if (go) begin
            // shift stage2 -> output
            m_valid <= v2;
            m_sof   <= sof2;
            m_eol   <= eol2;
            if (v2) begin
                m_y  <= y2;
                m_cb <= cb2;
                m_cr <= cr2;
            end
            // shift stage1 -> stage2
            v2   <= v1;
            sof2 <= sof1;
            eol2 <= eol1;
            if (v1) begin
                y2  <= py[15:8];
                cb2 <= 8'd128 + pcb[15:8];
                cr2 <= 8'd128 + pcr[15:8];
            end
            // load stage1
            v1   <= s_valid;
            sof1 <= s_valid && s_sof;
            eol1 <= s_valid && s_eol;
            if (s_valid) begin
                // Y carries the +128 round-half-up bias inside the product
                // (golden rgb2y); Cb/Cr stay floor per golden rgb2cb/cr --
                // dropping the bias made Y differ by 1 on half the pixels
                // and the DCT amplified it into a fully wrong stream (I-13)
                py  <= 77 * s_rgb[23:16] + 150 * s_rgb[15:8] + 29 * s_rgb[7:0]
                       + 18'd128;
                pcb <= 128 * s_rgb[7:0] - 43 * s_rgb[23:16] - 85 * s_rgb[15:8];
                pcr <= 128 * s_rgb[23:16] - 107 * s_rgb[15:8] - 21 * s_rgb[7:0];
            end
        end
    end
endmodule
