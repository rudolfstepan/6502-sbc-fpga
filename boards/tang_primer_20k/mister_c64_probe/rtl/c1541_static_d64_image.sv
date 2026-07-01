// Small read-only D64-style sector image for the Tang MiSTer C64 probe.
//
// This module deliberately exposes a simple logical disk interface:
//   track/sector/offset -> byte
//
// The surrounding GCR module turns these sector bytes into the serial format
// the MiSTer 1541 DOS logic expects. Keeping the image here makes it easier to
// replace the fixed test sectors with UART/SDRAM-backed D64 data later.
module c1541_static_d64_image
(
    input      [7:0] track,
    input      [4:0] sector,
    input      [7:0] offset,
    output reg [7:0] dout
);

localparam [7:0] ID1 = 8'h54; // "T"
localparam [7:0] ID2 = 8'h50; // "P"

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

function automatic [7:0] file_name_char(input [3:0] index);
begin
    case(index)
        4'd0: file_name_char = "H";
        4'd1: file_name_char = "E";
        4'd2: file_name_char = "L";
        4'd3: file_name_char = "L";
        4'd4: file_name_char = "O";
        default: file_name_char = 8'hA0;
    endcase
end
endfunction

function automatic [7:0] hello_prg_byte(input [5:0] index);
begin
    case(index)
        6'd0:  hello_prg_byte = 8'h01; // Load address $0801
        6'd1:  hello_prg_byte = 8'h08;
        6'd2:  hello_prg_byte = 8'h19; // Link to line 20 at $0819
        6'd3:  hello_prg_byte = 8'h08;
        6'd4:  hello_prg_byte = 8'h0A; // 10
        6'd5:  hello_prg_byte = 8'h00;
        6'd6:  hello_prg_byte = 8'h99; // PRINT
        6'd7:  hello_prg_byte = 8'h20;
        6'd8:  hello_prg_byte = 8'h22;
        6'd9:  hello_prg_byte = "H";
        6'd10: hello_prg_byte = "E";
        6'd11: hello_prg_byte = "L";
        6'd12: hello_prg_byte = "L";
        6'd13: hello_prg_byte = "O";
        6'd14: hello_prg_byte = " ";
        6'd15: hello_prg_byte = "F";
        6'd16: hello_prg_byte = "R";
        6'd17: hello_prg_byte = "O";
        6'd18: hello_prg_byte = "M";
        6'd19: hello_prg_byte = " ";
        6'd20: hello_prg_byte = "1";
        6'd21: hello_prg_byte = "5";
        6'd22: hello_prg_byte = "4";
        6'd23: hello_prg_byte = "1";
        6'd24: hello_prg_byte = 8'h22;
        6'd25: hello_prg_byte = 8'h00;
        6'd26: hello_prg_byte = 8'h00; // Last line link
        6'd27: hello_prg_byte = 8'h00;
        6'd28: hello_prg_byte = 8'h14; // 20
        6'd29: hello_prg_byte = 8'h00;
        6'd30: hello_prg_byte = 8'h80; // END
        6'd31: hello_prg_byte = 8'h00;
        default: hello_prg_byte = 8'h00;
    endcase
end
endfunction

always @* begin
    dout = 8'h00;

    if(track == 8'd17 && sector == 5'd0) begin
        // First sector of a two-sector PRG file: HELLO.
        case(offset)
            8'h00: dout = 8'd17;
            8'h01: dout = 8'd1;
            default: begin
                if(offset >= 8'd2 && offset <= 8'd33) begin
                    dout = hello_prg_byte(offset[5:0] - 6'd2);
                end
            end
        endcase
    end else if(track == 8'd17 && sector == 5'd1) begin
        // Final sector. The C64 loads a little padding after the BASIC end
        // marker, which proves the 1541 followed the sector chain.
        case(offset)
            8'h00: dout = 8'd0;
            8'h01: dout = 8'h04;
            default: dout = 8'h00;
        endcase
    end else if(track == 8'd18 && sector == 5'd0) begin
        // Track 18 sector 0: BAM and disk header.
        case(offset)
            8'h00: dout = 8'd18;   // first directory sector track
            8'h01: dout = 8'd1;    // first directory sector sector
            8'h02: dout = 8'h41;   // DOS version "A"
            8'h90: dout = disk_name_char(4'd0);
            8'h91: dout = disk_name_char(4'd1);
            8'h92: dout = disk_name_char(4'd2);
            8'h93: dout = disk_name_char(4'd3);
            8'h94: dout = disk_name_char(4'd4);
            8'h95: dout = disk_name_char(4'd5);
            8'h96: dout = disk_name_char(4'd6);
            8'h97: dout = disk_name_char(4'd7);
            8'h98: dout = disk_name_char(4'd8);
            8'h99,8'h9A,8'h9B,8'h9C,8'h9D,8'h9E,8'h9F: dout = 8'hA0;
            8'hA2: dout = ID1;
            8'hA3: dout = ID2;
            8'hA5: dout = 8'h32;   // "2"
            8'hA6: dout = 8'h41;   // "A"
            default: begin
                // Minimal BAM: mark sectors free everywhere except track 18.
                if(offset >= 8'h04 && offset < 8'h90) begin
                    case((offset - 8'h04) & 8'h03)
                        2'd0: dout = (((offset - 8'h04) >> 2) == 8'd17) ? 8'd17 : 8'd21;
                        2'd1: dout = 8'hFF;
                        2'd2: dout = 8'hFF;
                        2'd3: dout = (((offset - 8'h04) >> 2) >= 8'd17) ? 8'h01 : 8'h1F;
                    endcase
                end
            end
        endcase
    end else if(track == 8'd18 && sector == 5'd1) begin
        // Track 18 sector 1: directory with one closed PRG file.
        case(offset)
            8'h00: dout = 8'd0;
            8'h01: dout = 8'hFF;
            8'h02: dout = 8'h82; // Closed PRG
            8'h03: dout = 8'd17;
            8'h04: dout = 8'd0;
            8'h05: dout = file_name_char(4'd0);
            8'h06: dout = file_name_char(4'd1);
            8'h07: dout = file_name_char(4'd2);
            8'h08: dout = file_name_char(4'd3);
            8'h09: dout = file_name_char(4'd4);
            8'h0A: dout = file_name_char(4'd5);
            8'h0B: dout = file_name_char(4'd6);
            8'h0C: dout = file_name_char(4'd7);
            8'h0D: dout = file_name_char(4'd8);
            8'h0E: dout = file_name_char(4'd9);
            8'h0F: dout = file_name_char(4'd10);
            8'h10: dout = file_name_char(4'd11);
            8'h11: dout = file_name_char(4'd12);
            8'h12: dout = file_name_char(4'd13);
            8'h13: dout = file_name_char(4'd14);
            8'h14: dout = file_name_char(4'd15);
            8'h20: dout = 8'd2;  // File size in blocks, low byte.
            8'h21: dout = 8'd0;
            default: dout = 8'h00;
        endcase
    end else begin
        case(offset)
            8'h00: dout = 8'd0;
            8'h01: dout = 8'hFF;
            default: dout = 8'h00;
        endcase
    end
end

endmodule
