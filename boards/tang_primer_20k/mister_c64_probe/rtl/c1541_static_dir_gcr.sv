// Tiny read-only GCR source for bring-up.
//
// This is not a real disk backend. It presents enough of a D64-like track to let
// the 1541 DOS read a synthetic directory and PRG, while avoiding the RAM-heavy
// MiSTer track/DDRAM path.
module c1541_static_dir_gcr
#(
    parameter integer GCR_TURBO = 1
)
(
    input             clk,
    input             ce,
    input             reset,

    output reg  [7:0] dout,
    input       [7:0] din,
    input             mode,
    input             mtr,
    input       [1:0] freq,
    output            sync_n,
    output reg        byte_n,

    input       [6:0] track,
    output            we,

    // Logical disk image bus.  The parent (mister_c1541_iec) instantiates the
    // chosen backend - built-in test image, SDRAM D64 or virtual-1541 UART -
    // and wires it here.  img_valid low stalls the read engine while a sector
    // is being (re)fetched.
    output      [7:0] img_track,
    output      [4:0] img_sector,
    output      [7:0] img_offset,
    input       [7:0] img_dout,
    input             img_valid
);

assign we = 1'b0;
assign sync_n = ~mtr | sync_in_n;

localparam [7:0] ID1 = 8'h54; // "T"
localparam [7:0] ID2 = 8'h50; // "P"

wire [7:0] logical_track = {2'b00, track[6:1]} + 8'd1;
wire [4:0] sector_max = (logical_track < 8'd18) ? 5'd20 :
                         (logical_track < 8'd25) ? 5'd18 :
                         (logical_track < 8'd31) ? 5'd17 :
                                                   5'd16;
reg  [4:0] sector;

wire [7:0] data_header = (byte_cnt == 0) ? 8'h08 :
                         (byte_cnt == 1) ? hdr_cks :
                         (byte_cnt == 2) ? sector :
                         (byte_cnt == 3) ? logical_track :
                         (byte_cnt == 4) ? ID2 :
                         (byte_cnt == 5) ? ID1 :
                                           8'h0F;

wire [7:0] data_body = (byte_cnt == 0)   ? 8'h07 :
                       (byte_cnt == 257) ? data_cks :
                       (byte_cnt == 258) ? 8'h00 :
                       (byte_cnt == 259) ? 8'h00 :
                       (byte_cnt >= 260) ? 8'h0F :
                                           buff_do;

wire [7:0] data = state ? data_body : data_header;
wire [4:0] gcr_nibble = gcr_encode(nibble ? data[3:0] : data[7:4]);

// Drive the image bus; the backend returns img_dout / img_valid.
assign img_track  = logical_track;
assign img_sector = sector;
assign img_offset = byte_cnt[7:0];

function automatic [4:0] gcr_encode(input [3:0] value);
begin
    case(value)
        4'h0: gcr_encode = 5'b01010;
        4'h1: gcr_encode = 5'b11010;
        4'h2: gcr_encode = 5'b01001;
        4'h3: gcr_encode = 5'b11001;
        4'h4: gcr_encode = 5'b01110;
        4'h5: gcr_encode = 5'b11110;
        4'h6: gcr_encode = 5'b01101;
        4'h7: gcr_encode = 5'b11101;
        4'h8: gcr_encode = 5'b10010;
        4'h9: gcr_encode = 5'b10011;
        4'hA: gcr_encode = 5'b01011;
        4'hB: gcr_encode = 5'b11011;
        4'hC: gcr_encode = 5'b10110;
        4'hD: gcr_encode = 5'b10111;
        4'hE: gcr_encode = 5'b01111;
        default: gcr_encode = 5'b10101;
    endcase
end
endfunction

function automatic [3:0] gcr_decode(input [4:0] value);
begin
    case(value)
        5'b01010: gcr_decode = 4'h0;
        5'b01011: gcr_decode = 4'h1;
        5'b10010: gcr_decode = 4'h2;
        5'b10011: gcr_decode = 4'h3;
        5'b01110: gcr_decode = 4'h4;
        5'b01111: gcr_decode = 4'h5;
        5'b10110: gcr_decode = 4'h6;
        5'b10111: gcr_decode = 4'h7;
        5'b01001: gcr_decode = 4'h8;
        5'b11001: gcr_decode = 4'h9;
        5'b11010: gcr_decode = 4'hA;
        5'b11011: gcr_decode = 4'hB;
        5'b01101: gcr_decode = 4'hC;
        5'b11101: gcr_decode = 4'hD;
        5'b11110: gcr_decode = 4'hE;
        default:  gcr_decode = 4'hF;
    endcase
end
endfunction

reg       bit_clk_en;
reg [6:0] old_track;

always @(posedge clk) begin
    reg [5:0] bit_clk_cnt;
    reg       mode_r1;
    reg [5:0] bit_clk_step;

    bit_clk_en <= 1'b0;
    bit_clk_step = (GCR_TURBO < 1) ? 6'd1 :
                   (GCR_TURBO > 8) ? 6'd8 :
                                     GCR_TURBO;

    if(reset) begin
        old_track <= 7'd34;
        mode_r1 <= 1'b1;
        byte_n <= 1'b1;
        bit_clk_cnt <= 6'd0;
    end else if(ce) begin
        old_track <= track;
        mode_r1 <= mode;
        byte_n <= 1'b1;

        if ((old_track != track) | (mode_r1 ^ mode) | ~mtr) begin
            bit_clk_cnt <= {freq,2'b00};
        end else if (!img_valid) begin
            // Freeze the read engine while the backend (re)fetches a sector.
            // bit_clk_cnt holds and byte_n stays high, so the 1541 DOS simply
            // sees the inter-sector gap stretch until the sector is ready.
        end else begin
            bit_clk_cnt <= bit_clk_cnt + bit_clk_step;
            if(byte_in && bit_clk_cnt[5:4] == 1) byte_n <= 1'b0;

            if (bit_clk_cnt >= (6'd63 - bit_clk_step + 6'd1)) begin
                bit_clk_en <= 1'b1;
                bit_clk_cnt <= {freq,2'b00};
            end
        end
    end
end

reg        sync_in_n;
reg        byte_in;
reg  [8:0] byte_cnt;
reg        nibble;
reg        state;
reg  [7:0] data_cks;
reg  [7:0] buff_do;
reg  [7:0] gcr_byte_out;
reg  [4:0] gcr_nibble_out;
reg  [7:0] hdr_cks;
wire [3:0] nibble_out = gcr_decode(gcr_nibble_out);

always @(posedge clk) begin
    reg       mode_r2;
    reg       autorise_write;
    reg       autorise_count;
    reg [5:0] sync_cnt;
    reg [7:0] gcr_byte;
    reg [2:0] bit_cnt;
    reg [3:0] gcr_bit_cnt;

    hdr_cks <= logical_track ^ {3'b000, sector} ^ ID1 ^ ID2;

    if(reset) begin
        sector <= 5'd0;
        sync_in_n <= 1'b0;
        byte_in <= 1'b0;
        byte_cnt <= 9'd0;
        nibble <= 1'b0;
        state <= 1'b0;
        data_cks <= 8'd0;
        buff_do <= 8'd0;
        dout <= 8'hFF;
        gcr_byte_out <= 8'd0;
        gcr_nibble_out <= 5'd0;
        hdr_cks <= 8'd0;
        mode_r2 <= 1'b1;
        autorise_write <= 1'b0;
        autorise_count <= 1'b0;
        sync_cnt <= 6'd0;
        gcr_byte <= 8'd0;
        bit_cnt <= 3'd0;
        gcr_bit_cnt <= 4'd0;
    end else if (sector > sector_max) begin
        sector <= 5'd0;
    end else if (bit_clk_en) begin
        mode_r2 <= mode;
        if (mode) autorise_write <= 1'b0;

        if (mode ^ mode_r2) begin
            if (mode) begin
                sync_in_n <= 1'b0;
                sync_cnt <= 6'd0;
                state <= 1'b0;
            end else begin
                byte_cnt <= 9'd0;
                nibble <= 1'b0;
                gcr_bit_cnt <= 4'd0;
                bit_cnt <= 3'd0;
                gcr_byte <= 8'd0;
                data_cks <= 8'd0;
            end
        end

        byte_in <= 1'b0;

        if (~sync_in_n & mode) begin
            byte_cnt <= 9'd0;
            nibble <= 1'b0;
            gcr_bit_cnt <= 4'd0;
            bit_cnt <= 3'd0;
            dout <= 8'hFF;
            gcr_byte <= 8'd0;
            data_cks <= 8'd0;
            sync_cnt <= sync_cnt + 1'd1;
            if (sync_cnt == 6'd39) begin
                sync_cnt <= 6'd0;
                sync_in_n <= 1'b1;
            end
        end else begin
            gcr_bit_cnt <= gcr_bit_cnt + 1'b1;
            if (gcr_bit_cnt == 4'd4) begin
                gcr_bit_cnt <= 4'd0;
                if (nibble) begin
                    nibble <= 1'b0;
                    buff_do <= img_dout;
                    if (!byte_cnt) data_cks <= 8'd0;
                    else data_cks <= data_cks ^ data;

                    if (mode | autorise_count) byte_cnt <= byte_cnt + 1'b1;
                end else begin
                    nibble <= 1'b1;
                    if (~mode && buff_di == 8'h07) begin
                        autorise_write <= 1'b1;
                        autorise_count <= 1'b1;
                    end
                    if (byte_cnt[8]) begin
                        autorise_write <= 1'b0;
                        autorise_count <= 1'b0;
                    end
                end
            end

            bit_cnt <= bit_cnt + 1'b1;
            if (bit_cnt == 3'd7) begin
                byte_in <= 1'b1;
                gcr_byte_out <= din;
            end

            if (~state) begin
                if (byte_cnt == 9'd16) begin
                    sync_in_n <= 1'b0;
                    state <= 1'b1;
                end
            end else if (byte_cnt == 9'd273) begin
                sync_in_n <= 1'b0;
                state <= 1'b0;
                if (sector == sector_max) sector <= 5'd0;
                else sector <= sector + 1'b1;
            end

            gcr_byte <= {gcr_byte[6:0], gcr_nibble[gcr_bit_cnt]};
            if (bit_cnt == 3'd7) dout <= {gcr_byte[6:0], gcr_nibble[gcr_bit_cnt]};

            gcr_nibble_out <= {gcr_nibble_out[3:0], gcr_byte_out[~bit_cnt]};
            if (!gcr_bit_cnt) begin
                if (nibble) buff_di[7:4] <= nibble_out;
                else buff_di[3:0] <= nibble_out;
            end
        end
    end
end

reg [7:0] buff_di;

endmodule
