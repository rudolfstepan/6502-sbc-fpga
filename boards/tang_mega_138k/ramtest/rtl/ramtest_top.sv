// SDRAM phase sweep tester for the Tang Console 138K with the external
// GPIO SDRAM module. Runs NanoMig's sdram.sv at 85 MHz and steps the SDRAM
// clock pin phase through all 80 positions (4.5 deg each) using the PLL's
// dynamic phase adjustment. Per phase it writes and reads back 8192 words
// (pattern and inverted pattern) with periodic refresh and counts errors.
//
// Output: one line per sweep on the UART (115200 8N1, pin U15 like the
// System16 monitor). 80 characters, one per phase position starting at
// 0 deg from power-on: '.' = no errors, '1'..'9'/'A'..'F' = error count,
// '#' = 16 or more errors. A clean NanoMig phase is any '.' region; pick
// its middle, phase index = character position (0-based), then set
// CLKOUT2_PE_COARSE = index/8 and CLKOUT2_PE_FINE = index%8 in NanoMig's
// pll_142m_mod.v.
//
// If the whole map shows the same value on every position, the dynamic
// phase select is not hitting CLKOUT2 - adjust PS_SEL below.

module ramtest_top(
    input  wire        clk,          // 50 MHz board oscillator
    output wire        uart_tx,      // 115200 8N1, U15

    output wire        O_sdram_clk,
    output wire        O_sdram_cs_n,
    output wire        O_sdram_cas_n,
    output wire        O_sdram_ras_n,
    output wire        O_sdram_wen_n,
    inout  wire [15:0] IO_sdram_dq,
    output wire [12:0] O_sdram_addr,
    output wire [1:0]  O_sdram_ba,
    output wire [1:0]  O_sdram_dqm
);

localparam [2:0] PS_SEL = 3'b010;   // PLL dynamic phase select: CLKOUT2

// ------------------------------ clocks -------------------------------

wire clk_85;
wire clk_sdram_pin;
wire pll_lock;
reg  [2:0] psel;
reg        pdir;
reg        ppulse;

pll_ramtest pll (
    .clkin    ( clk          ),
    .init_clk ( clk          ),
    .psel     ( psel         ),
    .pdir     ( pdir         ),
    .ppulse   ( ppulse       ),
    .clkout1  ( clk_85       ),
    .clkout2  ( clk_sdram_pin),
    .lock     ( pll_lock     )
);

assign O_sdram_clk = clk_sdram_pin;

// ----------------------------- SDRAM ---------------------------------

reg         req_cs, req_we, req_ref, req_sync;
reg  [21:0] req_addr;
reg  [15:0] req_din;
wire [15:0] sdram_dout;
wire        sdram_ready;

sdram #(
    .RASCAS_DELAY     ( 2 ),  // >= 15 ns tRCD for the W9825G6KH-6 at 85 MHz
    .READ_LATCH_DELAY ( 1 )   // capture one clock later, like the NanoMig build
) sdram (
    .sd_data ( IO_sdram_dq   ),
    .sd_addr ( O_sdram_addr  ),
    .sd_dqm  ( O_sdram_dqm   ),
    .sd_ba   ( O_sdram_ba    ),
    .sd_cs   ( O_sdram_cs_n  ),
    .sd_we   ( O_sdram_wen_n ),
    .sd_ras  ( O_sdram_ras_n ),
    .sd_cas  ( O_sdram_cas_n ),

    .clk     ( clk_85        ),
    .reset_n ( pll_lock      ),
    .ready   ( sdram_ready   ),
    .sync    ( req_sync      ),
    .refresh ( req_ref       ),
    .din     ( req_din       ),
    .dout    ( sdram_dout    ),
    .addr    ( req_addr      ),
    .ds      ( 2'b00         ),
    .cs      ( req_cs        ),
    .we      ( req_we        ),

    .p2_din  ( 16'h0000      ),
    .p2_dout (               ),
    .p2_addr ( 22'd0         ),
    .p2_ds   ( 2'b00         ),
    .p2_cs   ( 1'b0          ),
    .p2_we   ( 1'b0          ),
    .p2_ack  (               )
);

// --------------------------- UART TX ---------------------------------

localparam [9:0] BAUD_DIV = 10'd738;  // 85 MHz / 115200

reg [9:0] tx_shift;
reg [3:0] tx_bits;
reg [9:0] tx_div;
reg       tx_start;
reg [7:0] tx_data;

wire tx_busy = (tx_bits != 4'd0);
assign uart_tx = tx_shift[0];

always @(posedge clk_85 or negedge pll_lock) begin
    if(!pll_lock) begin
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

// ----------------------- phase step, 50 MHz side ----------------------

reg        step_req;      // toggle, clk_85 domain
wire       step_ack;      // toggle, back from the 50 MHz side
reg  [1:0] req_s50;
reg        ack50;
reg  [4:0] ps_cnt;
reg        ps_active;

assign step_ack = ack50;

always @(posedge clk or negedge pll_lock) begin
    if(!pll_lock) begin
        req_s50   <= 2'b00;
        ack50     <= 1'b0;
        ps_cnt    <= 5'd0;
        ps_active <= 1'b0;
        psel      <= PS_SEL;
        pdir      <= 1'b0;
        ppulse    <= 1'b0;
    end else begin
        req_s50 <= {req_s50[0], step_req};
        psel    <= PS_SEL;
        pdir    <= 1'b0;

        if(!ps_active) begin
            ppulse <= 1'b0;
            if(req_s50[1] != ack50) begin
                ps_active <= 1'b1;
                ps_cnt    <= 5'd0;
            end
        end else begin
            ps_cnt <= ps_cnt + 5'd1;
            // one wide pulse, then settling time
            ppulse <= (ps_cnt < 5'd4);
            if(ps_cnt == 5'd31) begin
                ps_active <= 1'b0;
                ack50     <= req_s50[1];
            end
        end
    end
end

// ------------------------- test engine, 85 MHz ------------------------

localparam [21:0] BASE  = 22'h3C0000;   // same segment NanoMig uses for Kickstart
localparam [12:0] WORDS = 13'd8191;     // last index, 8192 words

localparam ST_WAIT_READY = 3'd0;
localparam ST_RUN        = 3'd1;
localparam ST_TX_CHAR    = 3'd2;
localparam ST_TX_CR      = 3'd3;
localparam ST_TX_LF      = 3'd4;
localparam ST_STEP       = 3'd5;
localparam ST_ACK        = 3'd6;

reg [2:0]  st;
reg [6:0]  phase_idx;     // 0..79
reg [1:0]  pass_idx;      // 0 write, 1 read, 2 write inverted, 3 read inverted
reg [12:0] widx;
reg [3:0]  slot;
reg [2:0]  ref_gap;
reg        refresh_slot;
reg [15:0] err_cnt;
reg        sweep_clean;
reg        window_found;
reg        hb;
reg [1:0]  ack_s85;

wire [15:0] pat_base = {widx[7:0], widx[12:5]} ^ 16'hA53C;
wire [15:0] pat      = (pass_idx[1]) ? ~pat_base : pat_base;

wire [7:0] map_char = (err_cnt == 16'd0)  ? 8'h2E :                       // '.'
                      (err_cnt < 16'd10)  ? (8'h30 + err_cnt[7:0]) :      // '1'..'9'
                      (err_cnt < 16'd16)  ? (8'h41 + err_cnt[7:0] - 8'd10) : // 'A'..'F'
                                            8'h23;                        // '#'

always @(posedge clk_85 or negedge pll_lock) begin
    if(!pll_lock) begin
        st           <= ST_WAIT_READY;
        phase_idx    <= 7'd0;
        pass_idx     <= 2'd0;
        widx         <= 13'd0;
        slot         <= 4'd0;
        ref_gap      <= 3'd0;
        refresh_slot <= 1'b0;
        err_cnt      <= 16'd0;
        sweep_clean  <= 1'b0;
        window_found <= 1'b0;
        hb           <= 1'b0;
        step_req     <= 1'b0;
        ack_s85      <= 2'b00;
        tx_start     <= 1'b0;
        tx_data      <= 8'h00;
        req_cs       <= 1'b0;
        req_we       <= 1'b0;
        req_ref      <= 1'b0;
        req_sync     <= 1'b0;
        req_addr     <= 22'd0;
        req_din      <= 16'd0;
    end else begin
        ack_s85  <= {ack_s85[0], step_ack};
        tx_start <= 1'b0;

        case(st)
            ST_WAIT_READY: begin
                if(sdram_ready) begin
                    st   <= ST_RUN;
                    slot <= 4'd0;
                end
            end

            ST_RUN: begin
                slot <= slot + 4'd1;
                case(slot)
                    4'd0: begin
                        req_sync <= 1'b1;
                        req_cs   <= 1'b1;
                        if(refresh_slot) begin
                            req_ref <= 1'b1;
                            req_we  <= 1'b0;
                        end else begin
                            req_ref  <= 1'b0;
                            req_we   <= !pass_idx[0];        // passes 0 and 2 write
                            req_addr <= BASE + {9'd0, widx};
                            req_din  <= pat;
                        end
                    end
                    4'd4: req_sync <= 1'b0;
                    4'd12: begin
                        if(!refresh_slot && pass_idx[0]) begin // passes 1 and 3 read
                            if(sdram_dout != pat && err_cnt != 16'hffff)
                                err_cnt <= err_cnt + 16'd1;
                        end
                    end
                    4'd15: begin
                        req_cs  <= 1'b0;
                        req_ref <= 1'b0;
                        if(refresh_slot)
                            refresh_slot <= 1'b0;
                        else begin
                            ref_gap <= ref_gap + 3'd1;
                            if(ref_gap == 3'd7)
                                refresh_slot <= 1'b1;
                            if(widx == WORDS) begin
                                widx <= 13'd0;
                                if(pass_idx == 2'd3) begin
                                    pass_idx <= 2'd0;
                                    st       <= ST_TX_CHAR;
                                end else
                                    pass_idx <= pass_idx + 2'd1;
                            end else
                                widx <= widx + 13'd1;
                        end
                    end
                    default: ;
                endcase
            end

            ST_TX_CHAR: begin
                if(err_cnt == 16'd0)
                    sweep_clean <= 1'b1;
                if(!tx_busy && !tx_start) begin
                    tx_data  <= map_char;
                    tx_start <= 1'b1;
                    st       <= (phase_idx == 7'd79) ? ST_TX_CR : ST_STEP;
                end
            end

            ST_TX_CR: begin
                if(!tx_busy && !tx_start) begin
                    tx_data  <= 8'h0D;
                    tx_start <= 1'b1;
                    st       <= ST_TX_LF;
                end
            end

            ST_TX_LF: begin
                if(!tx_busy && !tx_start) begin
                    tx_data      <= 8'h0A;
                    tx_start     <= 1'b1;
                    window_found <= sweep_clean;
                    sweep_clean  <= 1'b0;
                    hb           <= ~hb;
                    st           <= ST_STEP;
                end
            end

            ST_STEP: begin
                step_req <= ~step_req;
                st       <= ST_ACK;
            end

            ST_ACK: begin
                if(ack_s85[1] == step_req) begin
                    phase_idx    <= (phase_idx == 7'd79) ? 7'd0 : phase_idx + 7'd1;
                    err_cnt      <= 16'd0;
                    widx         <= 13'd0;
                    pass_idx     <= 2'd0;
                    slot         <= 4'd0;
                    ref_gap      <= 3'd0;
                    refresh_slot <= 1'b0;
                    st           <= ST_RUN;
                end
            end

            default: st <= ST_WAIT_READY;
        endcase
    end
end

endmodule
