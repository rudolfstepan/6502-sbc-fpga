// Testbench for the NanoMig Console 138K boot path: block-ROM to SDRAM copy,
// refresh slots and readback verification, using the real sdram.sv,
// sdram_boot_verify.sv and kickstart_bram.sv against a behavioral SDRAM chip.
// The copier logic and the SDRAM muxes are copied verbatim from
// third_party/NanoMig/src/tang/console138k/top.sv - keep them in sync.
//
// A fake Kickstart image (fake_kick13.hex, see make_fake_kick.py) provides
// the signature words, the patch word at 0xAA and address-derived filler so
// any misplaced word identifies its origin.
//
// Two independent checks:
//   1. the verifier's own pass/fail_map/got results
//   2. a full compare of the chip model's memory against the expected image

`timescale 1ns/1ps

module tb_boot_copy;

// ------------------------------ clocks --------------------------------

reg clk85 = 1'b0;
always #5.88 clk85 = ~clk85;

reg [1:0] c3 = 2'd0;
always @(posedge clk85) c3 <= (c3 == 2'd2) ? 2'd0 : c3 + 2'd1;
wire clk28 = (c3 == 2'd0);

reg pll_lock = 1'b0;
initial #200 pll_lock = 1'b1;

wire boot_hold = 1'b0;

// --------------------------- reference image --------------------------

reg [15:0] ref_img [0:131071];
initial $readmemh("fake_kick13.hex", ref_img);

// ----------------------- start_rom_copy (from top.sv) ------------------

wire sdram_ready;
wire mem_ready = sdram_ready && pll_lock;

reg  start_rom_copy;
reg  mem_ready_D;

always @(posedge clk28 or negedge pll_lock) begin
 if(!pll_lock || boot_hold) begin
      start_rom_copy <= 1'b0;
      mem_ready_D <= 1'b0;

   end else begin
      mem_ready_D <= mem_ready;
      start_rom_copy <= 1'b0;

      if(mem_ready && !mem_ready_D)
          start_rom_copy <= 1'b1;
   end
end

// ------------------------- copier (from top.sv) ------------------------

reg [22:0]  flash_addr;
wire [15:0] flash_dout;
reg [15:0]  flash_doutD;
reg [31:0]  word_count;
reg [4:0]   state;

reg         rom_copy_done;
reg         rom_signature_ok;
wire        rom_verify_done;
wire        rom_verify_pass;
wire [7:0]  rom_verify_fail_map;
wire [127:0] rom_verify_got;
wire        verify_ram_access;
wire [21:0] verify_ram_addr;

wire        rom_done = rom_verify_done && rom_verify_pass;

reg [21:0]  flash_ram_addr;
reg         flash_ram_write;
reg [5:0]   flash_cnt;
reg [3:0]   boot_ref_gap;
reg         boot_ref_slot;
reg         boot_ref;

kickstart_bram #(
    .INIT_FILE ( "fake_kick13.hex" )
) kickstart_rom (
    .clk  ( clk85              ),
    .addr ( flash_addr[16:0]   ),
    .data ( flash_dout         )
);

always @(posedge clk85 or negedge mem_ready) begin
  if(!mem_ready || boot_hold) begin
       flash_addr <= 23'h300000;          // logical word address used by ROM patch checks
       flash_ram_addr <= { 4'hf, 18'h0 }; // write into 512k sdram segment used for kick rom
       word_count <= 22'h40001;
       rom_copy_done <= 1'b0;
       rom_signature_ok <= 1'b1;

       state <= 5'h0;
       flash_ram_write <= 1'b0;
       flash_cnt <= 6'd0;
       boot_ref_gap <= 4'd0;
       boot_ref_slot <= 1'b0;
       boot_ref <= 1'b0;
    end else begin
        rom_copy_done <= (word_count == 0);

        if(state == 22) begin
            boot_ref_slot <= (boot_ref_gap == 4'd15);
            boot_ref_gap  <= boot_ref_gap + 4'd1;
        end
        if(state == 24 && boot_ref_slot) boot_ref <= 1'b1;
        if(state == 28) boot_ref <= 1'b0;
        if(state == 31) boot_ref_slot <= 1'b0;

        if((start_rom_copy ||
            (state == 23 && !boot_ref_slot) ||
            (state == 31 &&  boot_ref_slot)) && (word_count != 0)) begin
            flash_cnt <= 6'd3;
        end else begin
            if(flash_cnt != 0) flash_cnt <= flash_cnt - 6'd1;

            if(flash_cnt == 6'd1) begin
               state <= 1;
               flash_addr <= flash_addr + 23'd1;
               word_count <= word_count - 22'd1;

               if((flash_addr == 23'h300000 || flash_addr == 23'h320000) && flash_dout != 16'h1111)
                 rom_signature_ok <= 1'b0;
               if((flash_addr == 23'h300001 || flash_addr == 23'h320001) && flash_dout != 16'h4ef9)
                 rom_signature_ok <= 1'b0;
               if((flash_addr == 23'h300002 || flash_addr == 23'h320002) && flash_dout != 16'h00fc)
                 rom_signature_ok <= 1'b0;
               if((flash_addr == 23'h300003 || flash_addr == 23'h320003) && flash_dout != 16'h00d2)
                 rom_signature_ok <= 1'b0;

               if ((flash_addr == 23'h3000aa || flash_addr == 23'h3200aa) && flash_dout == 16'h6678)
                 flash_doutD <= flash_dout & 16'hf0ff;
               else
                 flash_doutD <= flash_dout;
            end
        end

        if(state != 0 && flash_cnt != 6'd1)
          state <= state + 5'd1;
        if(state == 3)  flash_ram_write <= 1'b1;
        if(state == 18) flash_ram_write <= 1'b0;
        if(state == 21) flash_ram_addr <= flash_ram_addr + 22'd1;
    end
end

wire [15:0] sdram_dout;

sdram_boot_verify boot_verify (
    .clk        ( clk85                             ),
    .reset_n    ( mem_ready && !boot_hold           ),
    .start      ( rom_copy_done && (state == 5'd0)  ),
    .ram_dout   ( sdram_dout                        ),
    .ram_access ( verify_ram_access                 ),
    .ram_addr   ( verify_ram_addr                   ),
    .done       ( rom_verify_done                   ),
    .pass       ( rom_verify_pass                   ),
    .fail_map   ( rom_verify_fail_map               ),
    .got_flat   ( rom_verify_got                    )
);

// ------------------------ SDRAM muxes (from top.sv) --------------------

// no Minimig in this bench: the runtime side stays inactive
wire        ram_oe_n = 1'b1;
wire        ram_we_n = 1'b1;
wire        ram_refresh = 1'b0;
wire [21:0] ram_a22 = 22'd0;
wire [15:0] ram_dout_cpu = 16'd0;
wire [1:0]  ram_be = 2'b00;
wire [1:0]  cyc = 2'd3;   // !cyc stays 0 after rom_done

wire        sdram_access  = (!ram_oe_n || !ram_we_n);
wire        sdram_rw      = !ram_we_n;
wire        boot_ram_access = rom_copy_done ? verify_ram_access : flash_ram_write;
wire [21:0] boot_ram_addr   = rom_copy_done ? verify_ram_addr   : flash_ram_addr;

wire        sdram_cs      = rom_done?sdram_access:(boot_ram_access || boot_ref);

wire        sdram_sync    = rom_done?!cyc:(boot_ram_access || boot_ref);

wire        sdram_refresh = rom_done?ram_refresh:boot_ref;

wire [21:0] sdram_addr    = rom_done?ram_a22:boot_ram_addr;
wire [15:0] sdram_din     = rom_done?ram_dout_cpu:flash_doutD;
wire [1:0]  sdram_be      = rom_done?ram_be:2'b00;
wire        sdram_we      = rom_done?sdram_rw:(!rom_copy_done && flash_ram_write);

// ------------------------------ DUT ------------------------------------

wire [15:0] IO_sdram_dq;
wire [12:0] O_sdram_addr;
wire [1:0]  O_sdram_ba;
wire [1:0]  O_sdram_dqm;
wire        O_sdram_cs_n, O_sdram_wen_n, O_sdram_ras_n, O_sdram_cas_n;

sdram #(
	.RASCAS_DELAY     ( 2 ),
	.SYNC_DELAY       ( 1 ),
	.READ_LATCH_DELAY ( 1 )
) sdram (
	.sd_data    ( IO_sdram_dq   ),
	.sd_addr    ( O_sdram_addr  ),
	.sd_dqm     ( O_sdram_dqm   ),
	.sd_ba      ( O_sdram_ba    ),
	.sd_cs      ( O_sdram_cs_n  ),
	.sd_we      ( O_sdram_wen_n ),
	.sd_ras     ( O_sdram_ras_n ),
	.sd_cas     ( O_sdram_cas_n ),

	.clk        ( clk85         ),
	.reset_n    ( pll_lock      ),

	.ready      ( sdram_ready   ),
	.sync       ( sdram_sync    ),
	.refresh    ( sdram_refresh ),
	.din        ( sdram_din     ),
	.dout       ( sdram_dout    ),
	.addr       ( sdram_addr    ),
	.ds         ( sdram_be      ),
	.cs         ( sdram_cs      ),
	.we         ( sdram_we      ),

	.p2_din     ( 16'h0000      ),
	.p2_dout    (               ),
	.p2_addr    ( 22'd0         ),
	.p2_ds      ( 2'b00         ),
	.p2_cs      ( 1'b0          ),
	.p2_we      ( 1'b0          ),
	.p2_ack     (               )
);

sdram_chip_model chip (
    .clk   ( clk85         ),
    .cs_n  ( O_sdram_cs_n  ),
    .ras_n ( O_sdram_ras_n ),
    .cas_n ( O_sdram_cas_n ),
    .we_n  ( O_sdram_wen_n ),
    .ba    ( O_sdram_ba    ),
    .addr  ( O_sdram_addr  ),
    .dqm   ( O_sdram_dqm   ),
    .dq    ( IO_sdram_dq   )
);

// ---------------------------- supervision ------------------------------

integer cycles = 0;
always @(posedge clk85) begin
    cycles = cycles + 1;
    if(cycles % 1000000 == 0)
        $display("... %0d cycles, words left %0d", cycles, word_count);
    if(cycles == 12000000) begin
        $display("TIMEOUT: verify never finished");
        $finish;
    end
end

always @(negedge rom_signature_ok)
    $display("SIGNATURE went bad at %0t, flash_addr %06x", $time, flash_addr);

function [15:0] expected_word;
    input [17:0] w;
    reg [16:0] idx;
    begin
        idx = w[16:0];
        expected_word = ref_img[idx];
        if((w == 18'h000AA || w == 18'h200AA) && ref_img[idx] == 16'h6678)
            expected_word = 16'h6078;
    end
endfunction

integer i, wrong, unwritten;
reg [21:0] a;
reg [15:0] exp, got;

initial begin
    wait(rom_verify_done);
    repeat(20) @(posedge clk85);

    $display("");
    $display("copy done at %0t", $time);
    $display("signature_ok = %b", rom_signature_ok);
    $display("verify pass  = %b, fail_map = %02x", rom_verify_pass, rom_verify_fail_map);
    for(i = 0; i < 8; i = i + 1)
        $display("  sample %0d got %04x", i, rom_verify_got[i*16 +: 16]);
    $display("model: %0d writes, %0d reads, %0d refreshes, max refresh gap %0t",
             chip.write_count, chip.read_count, chip.refresh_count, chip.max_refresh_gap);

    // independent full compare of the chip contents
    wrong = 0; unwritten = 0;
    for(i = 0; i < 262144; i = i + 1) begin
        a   = 22'h3C0000 + i[21:0];
        exp = expected_word(i[17:0]);
        got = chip.mem[a];
        if(got !== exp) begin
            if(got === 16'hxxxx) begin
                unwritten = unwritten + 1;
                if(unwritten <= 10)
                    $display("UNWRITTEN word %05x (addr %06x), expected %04x", i, a, exp);
            end else begin
                wrong = wrong + 1;
                if(wrong <= 10)
                    $display("WRONG word %05x (addr %06x): expected %04x, stored %04x", i, a, exp, got);
            end
        end
    end
    $display("full compare: %0d wrong, %0d unwritten of 262144 words", wrong, unwritten);
    $finish;
end

endmodule
