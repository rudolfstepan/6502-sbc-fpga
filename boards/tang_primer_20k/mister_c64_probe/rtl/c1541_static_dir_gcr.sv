// Tiny GCR source for the sector-fetch D64 backends.
//
// Read side: presents a D64-like track from on-demand sector fetches (img_*
// bus), avoiding the RAM-heavy MiSTer track/DDRAM path.
//
// Write side: when the 1541 DOS switches the head to write (mode=0) it emits
// 5 sync bytes (0xFF) followed by the GCR-encoded data block ($07 marker,
// 256 data bytes, checksum).  Both bit counters reset on the mode edge and
// din bytes are latched on our own byte boundary (the DOS feeds them through
// the byte_n handshake), so the 5-bit GCR groups stay aligned by
// construction (40 sync bits = 8 whole groups).  Each decoded data byte is
// pulsed out on we/wr_data/wr_offset; after the following checksum byte
// matches, wr_commit fires so the backend can flush the sector.  wr_stall
// freezes the bit engine while the parent wrapper also holds the 1541 CPU
// clock during the backend flush.
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

    // Decoded write-byte stream (mode=0).  we pulses once per data byte;
    // wr_commit pulses after byte 255 plus a matching checksum byte so the
    // backend can flush the sector the head is on (img_track/img_sector).
    // wr_stall freezes the engine in write mode while the backend is busy.
    output reg        we,
    output reg  [7:0] wr_data,
    output reg  [7:0] wr_offset,
    output reg        wr_commit,
    input             wr_stall,

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
        5'b11010: gcr_decode = 4'h1;
        5'b01001: gcr_decode = 4'h2;
        5'b11001: gcr_decode = 4'h3;
        5'b01110: gcr_decode = 4'h4;
        5'b11110: gcr_decode = 4'h5;
        5'b01101: gcr_decode = 4'h6;
        5'b11101: gcr_decode = 4'h7;
        5'b10010: gcr_decode = 4'h8;
        5'b10011: gcr_decode = 4'h9;
        5'b01011: gcr_decode = 4'hA;
        5'b11011: gcr_decode = 4'hB;
        5'b10110: gcr_decode = 4'hC;
        5'b10111: gcr_decode = 4'hD;
        5'b01111: gcr_decode = 4'hE;
        5'b10101: gcr_decode = 4'hF;
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
        end else if (mode ? !img_valid : wr_stall) begin
            // Freeze the engine while the backend is busy: in read mode while
            // a sector is being (re)fetched, in write mode while a written
            // sector is being flushed.  The wrapper also holds the 1541 CPU
            // during write flushes; byte_n/SO is an event input, not RDY.
            // (Write mode must NOT freeze on !img_valid: the target sector is
            // usually not the buffered one, and the fetch is suppressed while
            // a write burst is active -- freezing here would deadlock.)
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
reg  [7:0] buff_di;
reg  [8:0] wr_cnt;
reg        wr_committed;
reg        wr_capture;
reg        wr_seen_sync;
reg  [5:0] wr_sync_run;
reg  [3:0] wr_post_sync_bits;
reg  [9:0] wr_marker_shift;
reg  [4:0] wr_gcr_shift;
reg  [2:0] wr_gcr_cnt;
reg        wr_half;
reg  [3:0] wr_high;
reg  [7:0] wr_cks;
wire [3:0] nibble_out = gcr_decode(gcr_nibble_out);
wire [7:0] decoded_byte = {buff_di[7:4], nibble_out};

always @(posedge clk) begin
    reg       mode_r2;
    reg       autorise_write;
    reg       autorise_count;
    reg [5:0] sync_cnt;
    reg [7:0] gcr_byte;
    reg [2:0] bit_cnt;
    reg [3:0] gcr_bit_cnt;
    reg       write_bit;
    reg [9:0] wr_marker_next;
    reg [4:0] wr_gcr_next;
    reg [3:0] wr_nibble;

    hdr_cks <= logical_track ^ {3'b000, sector} ^ ID1 ^ ID2;

    // One-clock pulses towards the backend (bit_clk_en ticks are many clocks
    // apart, so these must be cleared every clock, not per bit tick).
    we <= 1'b0;
    wr_commit <= 1'b0;

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
        we <= 1'b0;
        wr_data <= 8'd0;
        wr_offset <= 8'd0;
        wr_commit <= 1'b0;
        wr_cnt <= 9'd0;
        wr_committed <= 1'b1;
        wr_capture <= 1'b0;
        wr_seen_sync <= 1'b0;
        wr_sync_run <= 6'd0;
        wr_post_sync_bits <= 4'd0;
        wr_marker_shift <= 10'd0;
        wr_gcr_shift <= 5'd0;
        wr_gcr_cnt <= 3'd0;
        wr_half <= 1'b0;
        wr_high <= 4'd0;
        wr_cks <= 8'd0;
    end else if (sector > sector_max) begin
        sector <= 5'd0;
    end else begin
        if (bit_clk_en) begin
        mode_r2 <= mode;
        if (mode) begin
            autorise_write <= 1'b0;
            wr_capture <= 1'b0;
            wr_seen_sync <= 1'b0;
            wr_sync_run <= 6'd0;
            wr_post_sync_bits <= 4'd0;
        end

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
                wr_cnt <= 9'd0;
                wr_committed <= 1'b0;
                wr_capture <= 1'b0;
                wr_seen_sync <= 1'b0;
                wr_sync_run <= 6'd0;
                wr_post_sync_bits <= 4'd0;
                wr_marker_shift <= 10'd0;
                wr_gcr_shift <= 5'd0;
                wr_gcr_cnt <= 3'd0;
                wr_half <= 1'b0;
                wr_cks <= 8'd0;
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

            // Wire order = standard GCR (the DOS packs its table MSB-first
            // into $1C01).  The marker register keeps wire order; the group
            // register shifts in from the LEFT so a finished group reads
            // bit-reversed, matching gcr_decode's bit-reversed table.
            write_bit = gcr_byte_out[~bit_cnt];
            wr_marker_next = {wr_marker_shift[8:0], write_bit};
            wr_gcr_next = {write_bit, wr_gcr_shift[4:1]};
            wr_nibble = gcr_decode(wr_gcr_next);

            gcr_nibble_out <= {gcr_nibble_out[3:0], gcr_byte_out[~bit_cnt]};
            if (~mode) begin
                wr_marker_shift <= wr_marker_next;
                if (write_bit) begin
                    if (wr_sync_run != 6'h3F) wr_sync_run <= wr_sync_run + 6'd1;
                end else begin
                    if (wr_sync_run >= 6'd32) begin
                        wr_seen_sync <= 1'b1;
                        wr_post_sync_bits <= 4'd1;
                    end
                    wr_sync_run <= 6'd0;
                end

                if (!wr_capture) begin
                    // Data block marker $07 in wire order: 0 -> 01010 and
                    // 7 -> 10111 (standard GCR read MSB-first).
                    // Only accept it shortly after a SYNC run.  The byte-wide
                    // VIA handoff can shift the complete marker a few bit
                    // times past the first non-sync zero, but header/data
                    // blocks later in the stream can contain the same 10-bit
                    // pattern by chance; starting capture there writes
                    // garbage.
                    if (wr_seen_sync && wr_marker_next == 10'b0101010111) begin
                        wr_capture <= 1'b1;
                        wr_seen_sync <= 1'b0;
                        wr_post_sync_bits <= 4'd0;
                        wr_gcr_shift <= 5'd0;
                        wr_gcr_cnt <= 3'd0;
                        wr_half <= 1'b0;
                        wr_cnt <= 9'd0;
                        wr_committed <= 1'b0;
                        wr_cks <= 8'd0;
                    end else if (wr_seen_sync) begin
                        if (wr_post_sync_bits == 4'd15) begin
                            wr_seen_sync <= 1'b0;
                            wr_post_sync_bits <= 4'd0;
                        end else begin
                            wr_post_sync_bits <= wr_post_sync_bits + 4'd1;
                        end
                    end
                end else begin
                    wr_gcr_shift <= wr_gcr_next;
                    if (wr_gcr_cnt == 3'd4) begin
                        wr_gcr_cnt <= 3'd0;
                        if (!wr_half) begin
                            wr_high <= wr_nibble;
                            wr_half <= 1'b1;
                        end else begin
                            if (!wr_cnt[8]) begin
                                we <= 1'b1;
                                wr_data <= {wr_high, wr_nibble};
                                wr_offset <= wr_cnt[7:0];
                                wr_cks <= (wr_cnt == 9'd0) ? {wr_high, wr_nibble}
                                                           : (wr_cks ^ {wr_high, wr_nibble});
                                wr_cnt <= wr_cnt + 9'd1;
                            end else begin
                                // The byte after the 256 data bytes is the
                                // sector XOR checksum.  Only a matching block
                                // is allowed to touch the SD card.
                                if (!wr_committed && wr_cks == {wr_high, wr_nibble}) begin
                                    wr_commit <= 1'b1;
                                    wr_committed <= 1'b1;
                                end
                                wr_capture <= 1'b0;
                                wr_seen_sync <= 1'b0;
                                wr_post_sync_bits <= 4'd0;
                            end
                            wr_half <= 1'b0;
                        end
                    end else begin
                        wr_gcr_cnt <= wr_gcr_cnt + 3'd1;
                    end
                end
            end
            if (!gcr_bit_cnt) begin
                if (nibble) buff_di[7:4] <= nibble_out;
                else begin
                    buff_di[3:0] <= nibble_out;
                end
            end
        end
        end
    end
end

endmodule
