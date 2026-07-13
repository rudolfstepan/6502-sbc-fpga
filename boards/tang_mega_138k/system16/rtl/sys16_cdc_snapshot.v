// Coherent req/ack mailbox for a slowly changing multi-bit status value.
//
// The source snapshot is held unchanged until the destination acknowledges
// it.  Changes arriving while a transfer is busy are coalesced into one
// latest-value pending slot, so two quick updates can never toggle twice and
// disappear before the destination samples them.
module sys16_cdc_snapshot #(
    parameter WIDTH = 32
) (
    input  wire             reset_n,
    input  wire             src_clk,
    input  wire [WIDTH-1:0] src_data,
    input  wire             dst_clk,
    output reg  [WIDTH-1:0] dst_data,
    output reg              dst_update
);
  reg [1:0] src_reset_pipe;
  reg [1:0] dst_reset_pipe;
  wire src_reset_n = src_reset_pipe[1];
  wire dst_reset_n = dst_reset_pipe[1];

  always @(posedge src_clk or negedge reset_n) begin
    if (!reset_n)
      src_reset_pipe <= 2'b00;
    else
      src_reset_pipe <= {src_reset_pipe[0],1'b1};
  end
  always @(posedge dst_clk or negedge reset_n) begin
    if (!reset_n)
      dst_reset_pipe <= 2'b00;
    else
      dst_reset_pipe <= {dst_reset_pipe[0],1'b1};
  end

  reg [WIDTH-1:0] src_last;
  reg [WIDTH-1:0] src_snapshot;
  reg [WIDTH-1:0] src_pending_data;
  reg src_pending_valid;
  reg src_request_toggle;

  reg dst_ack_toggle;
  (* syn_preserve = 1, syn_keep = 1 *) reg src_ack_meta;
  (* syn_preserve = 1, syn_keep = 1 *) reg src_ack_sync;
  (* syn_preserve = 1, syn_keep = 1 *) reg dst_request_meta;
  (* syn_preserve = 1, syn_keep = 1 *) reg dst_request_sync;
  reg dst_request_seen;

  wire src_busy = src_request_toggle != src_ack_sync;
  wire src_changed = src_data != src_last;

  always @(posedge src_clk or negedge reset_n) begin
    if (!reset_n) begin
      src_last <= {WIDTH{1'b0}};
      src_snapshot <= {WIDTH{1'b0}};
      src_pending_data <= {WIDTH{1'b0}};
      src_pending_valid <= 1'b0;
      src_request_toggle <= 1'b0;
      src_ack_meta <= 1'b0;
      src_ack_sync <= 1'b0;
    end else if (!src_reset_n) begin
      src_last <= {WIDTH{1'b0}};
      src_snapshot <= {WIDTH{1'b0}};
      src_pending_data <= {WIDTH{1'b0}};
      src_pending_valid <= 1'b0;
      src_request_toggle <= 1'b0;
      src_ack_meta <= 1'b0;
      src_ack_sync <= 1'b0;
    end else begin
      src_ack_meta <= dst_ack_toggle;
      src_ack_sync <= src_ack_meta;

      if (src_changed) begin
        src_last <= src_data;
        if (!src_busy) begin
          // A newly observed value supersedes any older pending snapshot.
          src_snapshot <= src_data;
          src_request_toggle <= ~src_request_toggle;
          src_pending_valid <= 1'b0;
        end else begin
          src_pending_data <= src_data;
          src_pending_valid <= 1'b1;
        end
      end else if (!src_busy && src_pending_valid) begin
        src_snapshot <= src_pending_data;
        src_request_toggle <= ~src_request_toggle;
        src_pending_valid <= 1'b0;
      end
    end
  end

  always @(posedge dst_clk or negedge reset_n) begin
    if (!reset_n) begin
      dst_request_meta <= 1'b0;
      dst_request_sync <= 1'b0;
      dst_request_seen <= 1'b0;
      dst_ack_toggle <= 1'b0;
      dst_data <= {WIDTH{1'b0}};
      dst_update <= 1'b0;
    end else if (!dst_reset_n) begin
      dst_request_meta <= 1'b0;
      dst_request_sync <= 1'b0;
      dst_request_seen <= 1'b0;
      dst_ack_toggle <= 1'b0;
      dst_data <= {WIDTH{1'b0}};
      dst_update <= 1'b0;
    end else begin
      dst_request_meta <= src_request_toggle;
      dst_request_sync <= dst_request_meta;
      dst_update <= 1'b0;
      if (dst_request_sync != dst_request_seen) begin
        // src_snapshot has been stable throughout the two request
        // synchronizer clocks and remains held until this ACK returns.
        dst_data <= src_snapshot;
        dst_request_seen <= dst_request_sync;
        dst_ack_toggle <= dst_request_sync;
        dst_update <= 1'b1;
      end
    end
  end
endmodule
