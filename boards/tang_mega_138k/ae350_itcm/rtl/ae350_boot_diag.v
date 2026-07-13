// Independent 50 MHz UART diagnostic for the AE350 ITCM bring-up image.
// This message is emitted before the AE350 is released from reset, allowing
// the board UART path to be distinguished from CPU/ITCM startup failures.
module ae350_boot_diag #(
    parameter integer CLK_HZ  = 50000000,
    parameter integer BAUD    = 38400,
    parameter integer WAIT_MS = 50
) (
    input  wire clk,
    input  wire reset_n,
    input  wire pll_lock,
    output wire tx,
    output reg  done
);
    localparam integer BAUD_DIV       = CLK_HZ / BAUD;
    localparam integer STARTUP_CYCLES = (CLK_HZ / 1000) * WAIT_MS;
    localparam [4:0]   LAST_CHAR      = 5'd22;

    reg [21:0] startup_counter;
    reg        started;
    reg        pll_lock_meta;
    reg        pll_lock_sync;
    reg        sampled_lock;
    reg [4:0]  char_index;
    reg [9:0]  tx_shift;
    reg [10:0] baud_counter;
    reg [3:0]  bit_index;
    reg        sending;

    assign tx = sending ? tx_shift[0] : 1'b1;

    function [7:0] message_byte;
        input [4:0] index;
        begin
            case (index)
                5'd0:  message_byte = "F";
                5'd1:  message_byte = "P";
                5'd2:  message_byte = "G";
                5'd3:  message_byte = "A";
                5'd4:  message_byte = " ";
                5'd5:  message_byte = "A";
                5'd6:  message_byte = "E";
                5'd7:  message_byte = "3";
                5'd8:  message_byte = "5";
                5'd9:  message_byte = "0";
                5'd10: message_byte = " ";
                5'd11: message_byte = "I";
                5'd12: message_byte = "T";
                5'd13: message_byte = "C";
                5'd14: message_byte = "M";
                5'd15: message_byte = " ";
                5'd16: message_byte = "P";
                5'd17: message_byte = "L";
                5'd18: message_byte = "L";
                5'd19: message_byte = "=";
                5'd21: message_byte = 8'h0d;
                5'd22: message_byte = 8'h0a;
                default: message_byte = "?";
            endcase
        end
    endfunction

    function [7:0] selected_byte;
        input [4:0] index;
        input       lock_value;
        begin
            if (index == 5'd20)
                selected_byte = lock_value ? "1" : "0";
            else
                selected_byte = message_byte(index);
        end
    endfunction

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            startup_counter <= 22'd0;
            started         <= 1'b0;
            pll_lock_meta   <= 1'b0;
            pll_lock_sync   <= 1'b0;
            sampled_lock    <= 1'b0;
            char_index      <= 5'd0;
            tx_shift        <= 10'h3ff;
            baud_counter    <= 11'd0;
            bit_index       <= 4'd0;
            sending         <= 1'b0;
            done            <= 1'b0;
        end else begin
            pll_lock_meta <= pll_lock;
            pll_lock_sync <= pll_lock_meta;

            if (!started) begin
                if (startup_counter == STARTUP_CYCLES - 1) begin
                    startup_counter <= startup_counter;
                    started         <= 1'b1;
                    sampled_lock    <= pll_lock_sync;
                    char_index      <= 5'd0;
                    tx_shift        <= {1'b1, selected_byte(5'd0, pll_lock_sync), 1'b0};
                    baud_counter    <= 11'd0;
                    bit_index       <= 4'd0;
                    sending         <= 1'b1;
                end else begin
                    startup_counter <= startup_counter + 1'b1;
                end
            end else if (sending) begin
                if (baud_counter == BAUD_DIV - 1) begin
                    baud_counter <= 11'd0;
                    if (bit_index == 4'd9) begin
                        bit_index <= 4'd0;
                        sending   <= 1'b0;
                        if (char_index == LAST_CHAR)
                            done <= 1'b1;
                        else
                            char_index <= char_index + 1'b1;
                    end else begin
                        bit_index <= bit_index + 1'b1;
                        tx_shift  <= {1'b1, tx_shift[9:1]};
                    end
                end else begin
                    baud_counter <= baud_counter + 1'b1;
                end
            end else if (!done) begin
                tx_shift     <= {1'b1, selected_byte(char_index, sampled_lock), 1'b0};
                baud_counter <= 11'd0;
                bit_index    <= 4'd0;
                sending      <= 1'b1;
            end
        end
    end
endmodule
