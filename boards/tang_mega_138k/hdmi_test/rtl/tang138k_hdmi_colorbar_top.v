module tang138k_hdmi_colorbar_top (
    input clk_50mhz,
    output dvi_a_psv,
    input dvi_a_hpd,
    inout dvi_ddc_clk,
    inout dvi_ddc_dat,
    output tmds_clk_p,
    output tmds_clk_n,
    output [2:0] tmds_d_p,
    output [2:0] tmds_d_n
);

wire pll_lock;
wire clk_pix;
wire clk_5x;
reg [7:0] reset_sr = 8'h00;
wire reset = ~reset_sr[7];

reg [11:0] x = 12'd0;
reg [10:0] y = 11'd0;
wire active;
wire hsync;
wire vsync;
reg [23:0] pixel_data = 24'h000000;
wire [1:0] tmds_clk_pair;
wire [1:0] tmds_d0_pair;
wire [1:0] tmds_d1_pair;
wire [1:0] tmds_d2_pair;
wire hpd_seen;

localparam H_ACTIVE = 12'd1280;
localparam H_FP     = 12'd110;
localparam H_SYNC   = 12'd40;
localparam H_BP     = 12'd220;
localparam H_TOTAL  = H_ACTIVE + H_FP + H_SYNC + H_BP;

localparam V_ACTIVE = 11'd720;
localparam V_FP     = 11'd5;
localparam V_SYNC   = 11'd5;
localparam V_BP     = 11'd20;
localparam V_TOTAL  = V_ACTIVE + V_FP + V_SYNC + V_BP;

Gowin_HDMI_720P_PLL pll_i (
    .lock(pll_lock),
    .clkout0(clk_pix),
    .clkout1(clk_5x),
    .clkin(clk_50mhz)
);

always @(posedge clk_pix or negedge pll_lock) begin
    if (!pll_lock) begin
        reset_sr <= 8'h00;
    end else begin
        reset_sr <= {reset_sr[6:0], 1'b1};
    end
end

always @(posedge clk_pix) begin
    if (reset) begin
        x <= 12'd0;
        y <= 11'd0;
    end else if (x == H_TOTAL - 1'b1) begin
        x <= 12'd0;
        if (y == V_TOTAL - 1'b1) begin
            y <= 11'd0;
        end else begin
            y <= y + 1'b1;
        end
    end else begin
        x <= x + 1'b1;
    end
end

assign active = (x < H_ACTIVE) && (y < V_ACTIVE);
assign hsync = (x >= H_ACTIVE + H_FP) && (x < H_ACTIVE + H_FP + H_SYNC);
assign vsync = (y >= V_ACTIVE + V_FP) && (y < V_ACTIVE + V_FP + V_SYNC);

always @* begin
    if (!active) begin
        pixel_data = 24'h000000;
    end else if (x < 12'd160) begin
        pixel_data = 24'hFFFFFF;
    end else if (x < 12'd320) begin
        pixel_data = 24'hFFFF00;
    end else if (x < 12'd480) begin
        pixel_data = 24'h00FFFF;
    end else if (x < 12'd640) begin
        pixel_data = 24'h00FF00;
    end else if (x < 12'd800) begin
        pixel_data = 24'hFF00FF;
    end else if (x < 12'd960) begin
        pixel_data = 24'hFF0000;
    end else if (x < 12'd1120) begin
        pixel_data = 24'h0000FF;
    end else begin
        pixel_data = 24'h202020;
    end
end

dvi_tx_top dvi_i (
    .pixel_clock(clk_pix),
    .ddr_bit_clock(clk_5x),
    .reset(reset),
    .den(active),
    .hsync(hsync),
    .vsync(vsync),
    .pixel_data(pixel_data),
    .tmds_clk(tmds_clk_pair),
    .tmds_d0(tmds_d0_pair),
    .tmds_d1(tmds_d1_pair),
    .tmds_d2(tmds_d2_pair)
);

assign tmds_clk_p = tmds_clk_pair[1];
assign tmds_clk_n = tmds_clk_pair[0];
assign tmds_d_p[0] = tmds_d0_pair[1];
assign tmds_d_n[0] = tmds_d0_pair[0];
assign tmds_d_p[1] = tmds_d1_pair[1];
assign tmds_d_n[1] = tmds_d1_pair[0];
assign tmds_d_p[2] = tmds_d2_pair[1];
assign tmds_d_n[2] = tmds_d2_pair[0];

assign dvi_a_psv = 1'b0;
assign dvi_ddc_clk = 1'bz;
assign dvi_ddc_dat = 1'bz;
assign hpd_seen = dvi_a_hpd;

endmodule
