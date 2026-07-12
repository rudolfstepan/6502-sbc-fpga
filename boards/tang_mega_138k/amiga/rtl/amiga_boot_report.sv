/*
 * Plain-text failure report for the SDRAM boot verification, 115200 8N1.
 * While `active` is high it repeats every two seconds:
 *
 *   MAP 3C
 *   0 1111 1111
 *   1 4EF9 4EF9
 *   2 00FC 00E4
 *   ...
 *
 * MAP is the fail bitmap (bit per sample), each sample line shows the
 * expected word and what the SDRAM actually returned. The expected values
 * mirror the sample table in sdram_boot_verify.sv.
 */
module amiga_boot_report (
    input  wire         clk,       // 85 MHz SDRAM clock
    input  wire         reset_n,
    input  wire         active,
    input  wire [7:0]   fail_map,
    input  wire [127:0] got_flat,
    output wire         uart_tx
);

localparam [9:0] BAUD_DIV = 10'd738;        // 85 MHz / 115200
localparam [27:0] PAUSE   = 28'd170000000;  // two seconds between reports

function [15:0] sample_value;
    input [2:0] index;
    begin
        case(index)
            3'd0: sample_value = 16'h1111;
            3'd1: sample_value = 16'h4ef9;
            3'd2: sample_value = 16'h00fc;
            3'd3: sample_value = 16'h00d2;
            3'd4: sample_value = 16'h1111;
            3'd5: sample_value = 16'h4ef9;
            3'd6: sample_value = 16'h6078;
            default: sample_value = 16'h001f;
        endcase
    end
endfunction

function [7:0] hex_char;
    input [3:0] n;
    begin
        hex_char = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h37 + {4'd0, n});
    end
endfunction

// ------------------------------ UART TX ------------------------------

reg [9:0] tx_shift;
reg [3:0] tx_bits;
reg [9:0] tx_div;
reg       tx_start;
reg [7:0] tx_data;

wire tx_busy = (tx_bits != 4'd0);
assign uart_tx = tx_shift[0];

always @(posedge clk or negedge reset_n) begin
    if(!reset_n) begin
        tx_shift <= 10'h3ff;
        tx_bits  <= 4'd0;
        tx_div   <= 10'd0;
    end else if(tx_start && !tx_busy) begin
        tx_shift <= {1'b1, tx_data, 1'b0};
        tx_bits  <= 4'd10;
        tx_div   <= 10'd0;
    end else if(tx_bits != 4'd0) begin
        if(tx_div == BAUD_DIV - 10'd1) begin
            tx_div   <= 10'd0;
            tx_shift <= {1'b1, tx_shift[9:1]};
            tx_bits  <= tx_bits - 4'd1;
        end else
            tx_div <= tx_div + 10'd1;
    end
end

// --------------------------- message engine ---------------------------

// line 0:    "MAP " hex hex CR LF                 (8 columns)
// lines 1-8: digit ' ' eeee ' ' gggg CR LF        (13 columns)
// line 9:    pause, then repeat

reg [3:0]  line;
reg [3:0]  col;
reg [27:0] pause_cnt;

wire [2:0]  smp = line[2:0] - 3'd1;
wire [15:0] exp = sample_value(smp);
wire [15:0] got = got_flat[smp*16 +: 16];

reg [7:0] ch;
always @* begin
    if(line == 4'd0) begin
        case(col)
            4'd0: ch = 8'h4D;                     // 'M'
            4'd1: ch = 8'h41;                     // 'A'
            4'd2: ch = 8'h50;                     // 'P'
            4'd3: ch = 8'h20;                     // ' '
            4'd4: ch = hex_char(fail_map[7:4]);
            4'd5: ch = hex_char(fail_map[3:0]);
            4'd6: ch = 8'h0D;
            default: ch = 8'h0A;
        endcase
    end else begin
        case(col)
            4'd0:  ch = 8'h30 + {5'd0, smp};      // sample index
            4'd1:  ch = 8'h20;
            4'd2:  ch = hex_char(exp[15:12]);
            4'd3:  ch = hex_char(exp[11:8]);
            4'd4:  ch = hex_char(exp[7:4]);
            4'd5:  ch = hex_char(exp[3:0]);
            4'd6:  ch = 8'h20;
            4'd7:  ch = hex_char(got[15:12]);
            4'd8:  ch = hex_char(got[11:8]);
            4'd9:  ch = hex_char(got[7:4]);
            4'd10: ch = hex_char(got[3:0]);
            4'd11: ch = 8'h0D;
            default: ch = 8'h0A;
        endcase
    end
end

wire [3:0] last_col = (line == 4'd0) ? 4'd7 : 4'd12;

always @(posedge clk or negedge reset_n) begin
    if(!reset_n) begin
        line      <= 4'd0;
        col       <= 4'd0;
        pause_cnt <= 28'd0;
        tx_start  <= 1'b0;
        tx_data   <= 8'h00;
    end else begin
        tx_start <= 1'b0;

        if(!active) begin
            line      <= 4'd0;
            col       <= 4'd0;
            pause_cnt <= 28'd0;
        end else if(line == 4'd9) begin
            if(pause_cnt == PAUSE) begin
                pause_cnt <= 28'd0;
                line      <= 4'd0;
                col       <= 4'd0;
            end else
                pause_cnt <= pause_cnt + 28'd1;
        end else if(!tx_busy && !tx_start) begin
            tx_data  <= ch;
            tx_start <= 1'b1;
            if(col == last_col) begin
                col  <= 4'd0;
                line <= line + 4'd1;
            end else
                col <= col + 4'd1;
        end
    end
end

endmodule
