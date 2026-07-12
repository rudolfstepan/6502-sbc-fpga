// Behavioral single-chip SDR SDRAM model (W9825G6KH class, 16 bit) for the
// boot-copy testbench. Commands are sampled on the negative clock edge, which
// stands in for the phase-shifted chip clock of the real board: controller
// outputs are registered on the posedge and therefore stable at the negedge.
// Reads honour CL2 with a one-word burst; unwritten memory returns x so the
// testbench can tell unwritten locations from wrongly written ones.
module sdram_chip_model (
    input  wire        clk,
    input  wire        cs_n,
    input  wire        ras_n,
    input  wire        cas_n,
    input  wire        we_n,
    input  wire [1:0]  ba,
    input  wire [12:0] addr,
    input  wire [1:0]  dqm,
    inout  wire [15:0] dq
);

// 8192 rows x 512 cols. The MiSTer address profile of sdram.sv (RAS 13,
// CAS 9) always drives bank 00, so the bank bits are checked but not stored.
reg [15:0] mem [0:4194303];
reg [12:0] open_row [0:3];
reg        row_open [0:3];

reg [1:0]  drive_cnt;              // read data window, two clock periods
reg [15:0] drive_data;

wire drive = (drive_cnt != 2'd0);
assign dq = drive ? drive_data : 16'hzzzz;

integer refresh_count = 0;
integer write_count = 0;
integer read_count = 0;
time    last_refresh = 0;
time    max_refresh_gap = 0;

wire [2:0] cmd = {ras_n, cas_n, we_n};
localparam CMD_ACTIVE    = 3'b011;
localparam CMD_READ      = 3'b101;
localparam CMD_WRITE     = 3'b100;
localparam CMD_PRECHARGE = 3'b010;
localparam CMD_REFRESH   = 3'b001;
localparam CMD_LOADMODE  = 3'b000;

reg [21:0] rd_index;
reg [1:0]  rd_wait;
reg        rd_pending;

initial begin
    row_open[0] = 0; row_open[1] = 0; row_open[2] = 0; row_open[3] = 0;
    drive_cnt = 0;
    rd_pending = 0;
end

always @(negedge clk) begin
    if(drive_cnt != 0)
        drive_cnt <= drive_cnt - 2'd1;

    // finish a pending read: CL2 -> drive data two clocks after the command
    if(rd_pending) begin
        if(rd_wait == 0) begin
            drive_cnt  <= 2'd2;
            drive_data <= mem[rd_index];
            rd_pending <= 1'b0;
        end else
            rd_wait <= rd_wait - 1'b1;
    end

    if(!cs_n) begin
        case(cmd)
            CMD_ACTIVE: begin
                open_row[ba] <= addr;
                row_open[ba] <= 1'b1;
            end

            CMD_WRITE: begin
                if(!row_open[ba])
                    $display("MODEL: WRITE to closed row, bank %0d at %0t", ba, $time);
                else begin
                    if(ba != 2'b00)
                        $display("MODEL: WRITE to unexpected bank %0d at %0t", ba, $time);
                    if(!dqm[0]) mem[{open_row[ba], addr[8:0]}][7:0]  <= dq[7:0];
                    if(!dqm[1]) mem[{open_row[ba], addr[8:0]}][15:8] <= dq[15:8];
                    write_count = write_count + 1;
                    if(addr[10]) row_open[ba] <= 1'b0;   // auto precharge
                end
            end

            CMD_READ: begin
                if(!row_open[ba])
                    $display("MODEL: READ from closed row, bank %0d at %0t", ba, $time);
                else begin
                    if(ba != 2'b00)
                        $display("MODEL: READ from unexpected bank %0d at %0t", ba, $time);
                    rd_index   <= {open_row[ba], addr[8:0]};
                    rd_wait    <= 2'd1;    // data appears CL2 after the command
                    rd_pending <= 1'b1;
                    read_count = read_count + 1;
                    if(addr[10]) row_open[ba] <= 1'b0;   // auto precharge
                end
            end

            CMD_PRECHARGE: begin
                if(addr[10]) begin
                    row_open[0] <= 0; row_open[1] <= 0;
                    row_open[2] <= 0; row_open[3] <= 0;
                end else
                    row_open[ba] <= 0;
            end

            CMD_REFRESH: begin
                refresh_count = refresh_count + 1;
                if(last_refresh != 0 && ($time - last_refresh) > max_refresh_gap)
                    max_refresh_gap = $time - last_refresh;
                last_refresh = $time;
            end

            CMD_LOADMODE:
                $display("MODEL: LOAD MODE %b at %0t", addr, $time);

            default: ;
        endcase
    end
end

endmodule
