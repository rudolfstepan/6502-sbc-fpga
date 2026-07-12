/*
 * Board-local readback check for the Kickstart image copied to SDRAM.
 * The interface is deliberately small so this diagnostic can remain a
 * separate synthesis unit from NanoMig and the SDRAM controller.
 */
module sdram_boot_verify (
    input  wire        clk,
    input  wire        reset_n,
    input  wire        start,
    input  wire [15:0] ram_dout,
    output reg         ram_access,
    output reg  [21:0] ram_addr,
    output reg         done,
    output reg         pass,
    output reg  [7:0]   fail_map, // one bit per sample that read back wrong
    output reg  [127:0] got_flat  // captured readback word per sample
);

localparam [2:0] PHASE_IDLE   = 3'd0;
localparam [2:0] PHASE_SETUP  = 3'd1;
localparam [2:0] PHASE_ACCESS = 3'd2;
localparam [2:0] PHASE_WAIT   = 3'd3;
localparam [2:0] PHASE_CHECK  = 3'd4;
localparam [2:0] PHASE_NEXT   = 3'd5;
localparam [2:0] PHASE_DONE   = 3'd6;

reg [2:0] phase;
reg [2:0] sample_index;
reg [3:0] wait_count;

function [21:0] sample_address;
    input [2:0] index;
    begin
        case(index)
            3'd0: sample_address = 22'h3c0000;
            3'd1: sample_address = 22'h3c0001;
            3'd2: sample_address = 22'h3c0002;
            3'd3: sample_address = 22'h3c0003;
            3'd4: sample_address = 22'h3e0000;
            3'd5: sample_address = 22'h3e0001;
            3'd6: sample_address = 22'h3c00aa;
            default: sample_address = 22'h3fffff;
        endcase
    end
endfunction

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

always @(posedge clk or negedge reset_n) begin
    if(!reset_n) begin
        phase       <= PHASE_IDLE;
        sample_index <= 3'd0;
        wait_count  <= 4'd0;
        ram_access  <= 1'b0;
        ram_addr    <= 22'd0;
        done        <= 1'b0;
        pass        <= 1'b0;
        fail_map    <= 8'd0;
        got_flat    <= 128'd0;
    end else begin
        case(phase)
            PHASE_IDLE: begin
                ram_access <= 1'b0;
                if(start) begin
                    sample_index <= 3'd0;
                    ram_addr     <= sample_address(3'd0);
                    wait_count   <= 4'd0;
                    done         <= 1'b0;
                    pass         <= 1'b1;
                    fail_map     <= 8'd0;
                    phase        <= PHASE_SETUP;
                end
            end

            PHASE_SETUP: begin
                ram_access <= 1'b0;
                if(wait_count == 4'd3) begin
                    wait_count <= 4'd0;
                    phase      <= PHASE_ACCESS;
                end else begin
                    wait_count <= wait_count + 4'd1;
                end
            end

            PHASE_ACCESS: begin
                ram_access <= 1'b1;
                if(wait_count == 4'd9) begin
                    ram_access <= 1'b0;
                    wait_count <= 4'd0;
                    phase      <= PHASE_WAIT;
                end else begin
                    wait_count <= wait_count + 4'd1;
                end
            end

            PHASE_WAIT: begin
                ram_access <= 1'b0;
                if(wait_count == 4'd9) begin
                    wait_count <= 4'd0;
                    phase      <= PHASE_CHECK;
                end else begin
                    wait_count <= wait_count + 4'd1;
                end
            end

            PHASE_CHECK: begin
                got_flat[sample_index*16 +: 16] <= ram_dout;
                if(ram_dout != sample_value(sample_index)) begin
                    pass <= 1'b0;
                    fail_map[sample_index] <= 1'b1;
                end
                phase <= PHASE_NEXT;
            end

            PHASE_NEXT: begin
                if(sample_index == 3'd7) begin
                    done  <= 1'b1;
                    phase <= PHASE_DONE;
                end else begin
                    sample_index <= sample_index + 3'd1;
                    ram_addr     <= sample_address(sample_index + 3'd1);
                    wait_count   <= 4'd0;
                    phase        <= PHASE_SETUP;
                end
            end

            default: begin
                ram_access <= 1'b0;
                done       <= 1'b1;
                phase      <= PHASE_DONE;
            end
        endcase
    end
end

endmodule
