// Small first-word-fall-through asynchronous FIFO for byte streams.
//
// The binary read/write pointers live exclusively in their respective clock
// domains.  Only Gray-coded pointers cross the clock boundary, through two
// explicit synchronizer stages.  ADDR_WIDTH must be at least 2.
module sys16_async_fifo #(
    parameter DATA_WIDTH = 8,
    parameter ADDR_WIDTH = 9
) (
    input  wire                  reset_n,

    input  wire                  wr_clk,
    input  wire                  wr_en,
    input  wire [DATA_WIDTH-1:0] wr_data,
    output reg                   wr_full,
    output wire [ADDR_WIDTH:0]   wr_level,

    input  wire                  rd_clk,
    input  wire                  rd_en,
    // Drop everything visible to the read clock without disturbing a writer
    // which may still be running in the other clock domain.
    input  wire                  rd_flush,
    output wire [DATA_WIDTH-1:0] rd_data,
    output reg                   rd_empty,
    output wire [ADDR_WIDTH:0]   rd_level
);
  localparam PTR_WIDTH = ADDR_WIDTH + 1;

  // The board reset is allowed to assert asynchronously.  Release it through
  // two clocks in each local domain so pointer flops cannot violate reset
  // recovery/removal when 50 MHz and 60 MHz have unrelated phases.
  reg [1:0] wr_reset_pipe;
  reg [1:0] rd_reset_pipe;
  wire wr_reset_n = wr_reset_pipe[1];
  wire rd_reset_n = rd_reset_pipe[1];
  always @(posedge wr_clk or negedge reset_n) begin
    if (!reset_n)
      wr_reset_pipe <= 2'b00;
    else
      wr_reset_pipe <= {wr_reset_pipe[0],1'b1};
  end
  always @(posedge rd_clk or negedge reset_n) begin
    if (!reset_n)
      rd_reset_pipe <= 2'b00;
    else
      rd_reset_pipe <= {rd_reset_pipe[0],1'b1};
  end

  // An asynchronous read is intentional: it gives the consumer a FWFT
  // interface and keeps retry handling outside the CDC FIFO simple.
  reg [DATA_WIDTH-1:0] mem [0:(1 << ADDR_WIDTH)-1];

  reg [PTR_WIDTH-1:0] wr_bin;
  reg [PTR_WIDTH-1:0] wr_gray;
  reg [PTR_WIDTH-1:0] rd_bin;
  reg [PTR_WIDTH-1:0] rd_gray;
  reg rd_flushing;
  reg [PTR_WIDTH-1:0] rd_flush_target;

  (* syn_preserve = 1, syn_keep = 1 *) reg [PTR_WIDTH-1:0] rd_gray_wr_meta;
  (* syn_preserve = 1, syn_keep = 1 *) reg [PTR_WIDTH-1:0] rd_gray_wr_sync;
  (* syn_preserve = 1, syn_keep = 1 *) reg [PTR_WIDTH-1:0] wr_gray_rd_meta;
  (* syn_preserve = 1, syn_keep = 1 *) reg [PTR_WIDTH-1:0] wr_gray_rd_sync;

  function [PTR_WIDTH-1:0] gray_to_bin;
    input [PTR_WIDTH-1:0] gray;
    integer i;
    begin
      gray_to_bin[PTR_WIDTH-1] = gray[PTR_WIDTH-1];
      for (i = PTR_WIDTH-2; i >= 0; i = i - 1)
        gray_to_bin[i] = gray_to_bin[i+1] ^ gray[i];
    end
  endfunction

  wire wr_take = wr_en && wr_reset_n && !wr_full;
  wire rd_take = rd_en && rd_reset_n && !rd_empty && !rd_flushing;
  wire [PTR_WIDTH-1:0] wr_bin_next = wr_bin + wr_take;
  wire [PTR_WIDTH-1:0] rd_bin_next = rd_bin + rd_take;
  wire [PTR_WIDTH-1:0] wr_gray_next =
      (wr_bin_next >> 1) ^ wr_bin_next;
  wire [PTR_WIDTH-1:0] rd_gray_next =
      (rd_bin_next >> 1) ^ rd_bin_next;
  wire [PTR_WIDTH-1:0] rd_flush_step_bin = rd_bin + 1'b1;
  wire [PTR_WIDTH-1:0] rd_flush_step_gray =
      (rd_flush_step_bin >> 1) ^ rd_flush_step_bin;

  // Inverting the two most significant synchronized Gray bits identifies a
  // write pointer exactly one complete FIFO revolution ahead of the reader.
  wire wr_full_next =
      (wr_gray_next == {~rd_gray_wr_sync[PTR_WIDTH-1:PTR_WIDTH-2],
                         rd_gray_wr_sync[PTR_WIDTH-3:0]});
  wire rd_empty_next = (rd_gray_next == wr_gray_rd_sync);

  assign rd_data = mem[rd_bin[ADDR_WIDTH-1:0]];
  assign wr_level = wr_bin - gray_to_bin(rd_gray_wr_sync);
  assign rd_level = rd_flushing ? {PTR_WIDTH{1'b0}} :
                    (gray_to_bin(wr_gray_rd_sync) - rd_bin);

  always @(posedge wr_clk or negedge reset_n) begin
    if (!reset_n) begin
      wr_bin <= {PTR_WIDTH{1'b0}};
      wr_gray <= {PTR_WIDTH{1'b0}};
      wr_full <= 1'b1;
      rd_gray_wr_meta <= {PTR_WIDTH{1'b0}};
      rd_gray_wr_sync <= {PTR_WIDTH{1'b0}};
    end else if (!wr_reset_n) begin
      wr_bin <= {PTR_WIDTH{1'b0}};
      wr_gray <= {PTR_WIDTH{1'b0}};
      // Reject writes until this clock domain completed reset release.
      wr_full <= 1'b1;
      rd_gray_wr_meta <= {PTR_WIDTH{1'b0}};
      rd_gray_wr_sync <= {PTR_WIDTH{1'b0}};
    end else begin
      rd_gray_wr_meta <= rd_gray;
      rd_gray_wr_sync <= rd_gray_wr_meta;
      if (wr_take)
        mem[wr_bin[ADDR_WIDTH-1:0]] <= wr_data;
      wr_bin <= wr_bin_next;
      wr_gray <= wr_gray_next;
      wr_full <= wr_full_next;
    end
  end

  always @(posedge rd_clk or negedge reset_n) begin
    if (!reset_n) begin
      rd_bin <= {PTR_WIDTH{1'b0}};
      rd_gray <= {PTR_WIDTH{1'b0}};
      rd_empty <= 1'b1;
      rd_flushing <= 1'b0;
      rd_flush_target <= {PTR_WIDTH{1'b0}};
      wr_gray_rd_meta <= {PTR_WIDTH{1'b0}};
      wr_gray_rd_sync <= {PTR_WIDTH{1'b0}};
    end else if (!rd_reset_n) begin
      rd_bin <= {PTR_WIDTH{1'b0}};
      rd_gray <= {PTR_WIDTH{1'b0}};
      rd_empty <= 1'b1;
      rd_flushing <= 1'b0;
      rd_flush_target <= {PTR_WIDTH{1'b0}};
      wr_gray_rd_meta <= {PTR_WIDTH{1'b0}};
      wr_gray_rd_sync <= {PTR_WIDTH{1'b0}};
    end else begin
      wr_gray_rd_meta <= wr_gray;
      wr_gray_rd_sync <= wr_gray_rd_meta;
      if (rd_flush) begin
        // Capture the synchronized target but never jump to it: a multi-bit
        // Gray transition could make the remote full detector see a false
        // pointer.  The flush walker below advances exactly one entry/clock.
        rd_flush_target <= gray_to_bin(wr_gray_rd_sync);
        rd_flushing <= (rd_bin != gray_to_bin(wr_gray_rd_sync));
        rd_empty <= 1'b1;
      end else if (rd_flushing) begin
        // Hide all discarded entries from the consumer while the pointer
        // walks.  Every binary +1 changes exactly one Gray bit.
        rd_empty <= 1'b1;
        if (rd_bin == rd_flush_target) begin
          rd_flushing <= 1'b0;
          rd_empty <= (rd_gray == wr_gray_rd_sync);
        end else begin
          rd_bin <= rd_flush_step_bin;
          rd_gray <= rd_flush_step_gray;
          if (rd_flush_step_bin == rd_flush_target) begin
            rd_flushing <= 1'b0;
            // Writes newer than the captured target remain readable.
            rd_empty <= (rd_flush_step_gray == wr_gray_rd_sync);
          end
        end
      end else begin
        rd_bin <= rd_bin_next;
        rd_gray <= rd_gray_next;
        rd_empty <= rd_empty_next;
      end
    end
  end
endmodule
