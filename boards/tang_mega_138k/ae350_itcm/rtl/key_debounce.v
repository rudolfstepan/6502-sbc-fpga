// 20-ms input debounce for the 50-MHz board clock.
module key_debounce (
    output reg out,
    input      in,
    input      clk,
    input      rstn
);
    localparam [19:0] STABLE_CYCLES = 20'd1000000;

    reg in_meta;
    reg in_sync;
    reg in_last;
    reg [19:0] stable_count;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            in_meta      <= 1'b0;
            in_sync      <= 1'b0;
            in_last      <= 1'b0;
            stable_count <= 20'd0;
            out          <= 1'b0;
        end else begin
            in_meta <= in;
            in_sync <= in_meta;
            in_last <= in_sync;

            if (in_sync != in_last) begin
                stable_count <= 20'd0;
            end else if (stable_count < STABLE_CYCLES) begin
                stable_count <= stable_count + 1'b1;
            end else begin
                out <= in_sync;
            end
        end
    end
endmodule
