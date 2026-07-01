// Tiny read-only GCR source for bring-up.
//
// This is not a real disk backend. It presents enough of a D64-like track to let
// the 1541 DOS read an empty directory, while avoiding the RAM-heavy MiSTer
// track/DDRAM path.
module c1541_static_dir_gcr
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
    output            we
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

function automatic [7:0] disk_name_char(input [3:0] index);
begin
    case(index)
        4'd0: disk_name_char = "T";
        4'd1: disk_name_char = "A";
        4'd2: disk_name_char = "N";
        4'd3: disk_name_char = "G";
        4'd4: disk_name_char = " ";
        4'd5: disk_name_char = "1";
        4'd6: disk_name_char = "5";
        4'd7: disk_name_char = "4";
        4'd8: disk_name_char = "1";
        default: disk_name_char = 8'hA0;
    endcase
end
endfunction

function automatic [7:0] sector_byte(input [4:0] sec, input [7:0] offset);
    reg [7:0] v;
begin
    v = 8'h00;

    if(logical_track != 8'd18) begin
        case(offset)
            8'h00: v = 8'd0;
            8'h01: v = 8'hFF;
            default: v = 8'h00;
        endcase
    end else if(sec == 5'd0) begin
        // Track 18 sector 0: BAM and disk header.
        case(offset)
            8'h00: v = 8'd18;   // first directory sector track
            8'h01: v = 8'd1;    // first directory sector sector
            8'h02: v = 8'h41;   // DOS version "A"
            8'h90: v = disk_name_char(4'd0);
            8'h91: v = disk_name_char(4'd1);
            8'h92: v = disk_name_char(4'd2);
            8'h93: v = disk_name_char(4'd3);
            8'h94: v = disk_name_char(4'd4);
            8'h95: v = disk_name_char(4'd5);
            8'h96: v = disk_name_char(4'd6);
            8'h97: v = disk_name_char(4'd7);
            8'h98: v = disk_name_char(4'd8);
            8'h99,8'h9A,8'h9B,8'h9C,8'h9D,8'h9E,8'h9F: v = 8'hA0;
            8'hA2: v = ID1;
            8'hA3: v = ID2;
            8'hA5: v = 8'h32;   // "2"
            8'hA6: v = 8'h41;   // "A"
            default: begin
                // Minimal BAM: mark sectors free everywhere except track 18.
                if(offset >= 8'h04 && offset < 8'h90) begin
                    case((offset - 8'h04) & 8'h03)
                        2'd0: v = (((offset - 8'h04) >> 2) == 8'd17) ? 8'd17 : 8'd21;
                        2'd1: v = 8'hFF;
                        2'd2: v = 8'hFF;
                        2'd3: v = (((offset - 8'h04) >> 2) >= 8'd17) ? 8'h01 : 8'h1F;
                    endcase
                end
            end
        endcase
    end else if(sec == 5'd1) begin
        // Track 18 sector 1: empty directory sector.
        case(offset)
            8'h00: v = 8'd0;
            8'h01: v = 8'hFF;
            default: v = 8'h00;
        endcase
    end else begin
        case(offset)
            8'h00: v = 8'd0;
            8'h01: v = 8'hFF;
            default: v = 8'h00;
        endcase
    end

    sector_byte = v;
end
endfunction

reg       bit_clk_en;
reg [6:0] old_track;

always @(posedge clk) begin
    reg [5:0] bit_clk_cnt;
    reg       mode_r1;

    bit_clk_en <= 1'b0;

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
        end else begin
            bit_clk_cnt <= bit_clk_cnt + 1'b1;
            if(byte_in && bit_clk_cnt[5:4] == 1) byte_n <= 1'b0;

            if (&bit_clk_cnt) begin
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
                    buff_do <= sector_byte(sector, byte_cnt[7:0]);
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

reg [4:0] sector;
reg [7:0] buff_di;

endmodule
