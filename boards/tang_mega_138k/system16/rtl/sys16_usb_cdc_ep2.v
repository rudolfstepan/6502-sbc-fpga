// USB CDC ACM endpoint-2 data bridge.
//
// OUT packets first land in a 64-byte USB-clock staging buffer.  They become
// visible to the CPU only after rx_packet_valid confirms a good CRC.  IN data
// is staged in packets of at most 63 bytes; the local read position is not
// committed until tx_packet_finished, so a NAK/retry replays identical bytes.
// Two Gray-pointer FIFOs provide the actual 50-MHz/60-MHz clock crossing.
module sys16_usb_cdc_ep2 #(
    parameter FIFO_ADDR_WIDTH = 9
) (
    input  wire                         reset_n,
    input  wire                         cpu_clk,
    input  wire                         usb_clk,
    input  wire                         usb_datapath_reset,

    input  wire [3:0]                   endpoint,
    input  wire                         rx_active,
    input  wire                         rx_valid,
    input  wire                         rx_packet_valid,
    input  wire [7:0]                   rx_data,
    output wire                         ep2_rx_ready,
    input  wire                         tx_active,
    input  wire                         tx_pop,
    input  wire                         tx_packet_finished,
    output wire                         ep2_tx_cork,
    output wire [7:0]                   ep2_tx_data,
    output wire [11:0]                  ep2_tx_length,

    input  wire                         cpu_rx_pop,
    output wire [7:0]                   cpu_rx_data,
    output wire                         cpu_rx_empty,
    output wire [FIFO_ADDR_WIDTH:0]     cpu_rx_level,
    input  wire                         cpu_tx_push,
    input  wire [7:0]                   cpu_tx_data,
    output wire                         cpu_tx_full,
    output wire [FIFO_ADDR_WIDTH:0]     cpu_tx_level,
    input  wire                         cpu_flush_rx,
    input  wire                         cpu_flush_tx,
    output reg                          rx_overflow_toggle
);
  localparam [FIFO_ADDR_WIDTH:0] FIFO_DEPTH_VALUE =
      {1'b1,{FIFO_ADDR_WIDTH{1'b0}}};

  // Local release guard for the USB-side packet logic.  usb_datapath_reset
  // is synchronous to usb_clk in the integration, while reset_n may assert
  // asynchronously from the board POR.
  reg [1:0] usb_ready_pipe;
  wire usb_operational = usb_ready_pipe[1];
  always @(posedge usb_clk or negedge reset_n) begin
    if (!reset_n)
      usb_ready_pipe <= 2'b00;
    else if (usb_datapath_reset)
      usb_ready_pipe <= 2'b00;
    else
      usb_ready_pipe <= {usb_ready_pipe[0],1'b1};
  end

  // -----------------------------------------------------------------------
  // Host OUT -> CPU RX FIFO: reserve space for a complete USB packet, then
  // commit the staging buffer only after the controller validates its CRC.
  // -----------------------------------------------------------------------
  reg [7:0] rx_stage [0:63];
  reg [6:0] rx_stage_count;
  reg [6:0] rx_drain_index;
  reg [6:0] rx_drain_count;
  reg rx_draining;
  reg rx_waiting_valid;
  reg [2:0] rx_validation_count;
  reg rx_packet_overflow;
  reg rx_active_d;
  reg rx_armed;
  reg rx_packet_ready;

  wire [FIFO_ADDR_WIDTH:0] rx_wr_level;
  wire rx_fifo_full;
  wire ep2_rx_active = (endpoint == 4'd2) && rx_active;
  wire rx_start = usb_operational && rx_armed && !rx_waiting_valid &&
                  !rx_draining && ep2_rx_active && !rx_active_d;
  wire rx_has_packet_room =
      !rx_draining && !rx_waiting_valid &&
      (rx_wr_level <= (FIFO_DEPTH_VALUE - 10'd64));
  wire rx_accept = ep2_rx_active && rx_valid && ep2_rx_ready;
  wire [6:0] rx_count_next = rx_stage_count + (rx_accept ? 1'b1 : 1'b0);
  wire rx_drain_write = usb_operational &&
                        rx_draining && !rx_fifo_full;
  wire rx_overflow_now = rx_accept && (rx_stage_count >= 7'd64);

  assign ep2_rx_ready = usb_operational &&
      (endpoint == 4'd2) &&
      (!ep2_rx_active ? (rx_armed && rx_has_packet_room) :
       (rx_start ? rx_has_packet_room :
        ((rx_active_d && !rx_waiting_valid && !rx_draining) ?
         rx_packet_ready : 1'b0)));

  sys16_async_fifo #(
      .DATA_WIDTH(8), .ADDR_WIDTH(FIFO_ADDR_WIDTH)
  ) rx_fifo_i (
      .reset_n(reset_n),
      .wr_clk(usb_clk), .wr_en(rx_drain_write),
      .wr_data(rx_stage[rx_drain_index[5:0]]),
      .wr_full(rx_fifo_full), .wr_level(rx_wr_level),
      .rd_clk(cpu_clk), .rd_en(cpu_rx_pop), .rd_flush(cpu_flush_rx),
      .rd_data(cpu_rx_data), .rd_empty(cpu_rx_empty),
      .rd_level(cpu_rx_level));

  // -----------------------------------------------------------------------
  // CPU TX FIFO -> host IN: a 64-entry ring holds one retryable packet.
  // Capping the offer at 63 bytes guarantees a short packet for Windows
  // usbser and avoids the exact-64-byte stream latency seen in hardware.
  // -----------------------------------------------------------------------
  reg [7:0] tx_stage [0:63];
  reg [5:0] tx_head;
  reg [6:0] tx_stage_count;
  reg [6:0] tx_send_index;
  reg tx_active_d;
  reg tx_finished_seen;
  reg tx_packet_locked;
  reg [6:0] tx_locked_length;
  reg [11:0] tx_prepared_length;
  reg tx_prepared_cork;

  wire [7:0] tx_fifo_data;
  wire tx_fifo_empty;
  wire [FIFO_ADDR_WIDTH:0] tx_rd_level;
  wire tx_flush_apply;
  wire tx_load = usb_operational && !tx_active && !tx_packet_locked &&
                 !tx_flush_apply &&
                 (tx_stage_count < 7'd63) && !tx_fifo_empty;
  wire [6:0] tx_count_with_load = tx_stage_count + (tx_load ? 1'b1 : 1'b0);
  wire [6:0] tx_send_limit =
      tx_packet_locked ? tx_locked_length : tx_stage_count;
  wire [6:0] tx_send_next = tx_send_index +
      (((endpoint == 4'd2) && tx_active && tx_pop &&
        (tx_send_index < tx_send_limit)) ? 1'b1 : 1'b0);

  // FLUSH_TX is generated in the CPU domain.  Crossing it as a toggle makes
  // a one-clock write pulse unmissable in the unrelated USB clock domain.
  reg tx_flush_toggle_cpu;
  (* syn_preserve = 1, syn_keep = 1 *) reg tx_flush_usb_meta;
  (* syn_preserve = 1, syn_keep = 1 *) reg tx_flush_usb_sync;
  reg tx_flush_usb_seen;
  reg tx_flush_pending;
  wire tx_flush_request = tx_flush_usb_sync != tx_flush_usb_seen;
  assign tx_flush_apply = usb_operational && !tx_active &&
                          !tx_packet_locked &&
                          (tx_flush_pending || tx_flush_request);

  sys16_async_fifo #(
      .DATA_WIDTH(8), .ADDR_WIDTH(FIFO_ADDR_WIDTH)
  ) tx_fifo_i (
      .reset_n(reset_n),
      .wr_clk(cpu_clk), .wr_en(cpu_tx_push), .wr_data(cpu_tx_data),
      .wr_full(cpu_tx_full), .wr_level(cpu_tx_level),
      .rd_clk(usb_clk), .rd_en(tx_load), .rd_flush(tx_flush_apply),
      .rd_data(tx_fifo_data), .rd_empty(tx_fifo_empty),
      .rd_level(tx_rd_level));

  assign ep2_tx_data = tx_stage[(tx_head + tx_send_index[5:0]) & 6'h3f];
  assign ep2_tx_length = tx_packet_locked ?
      {5'd0,tx_locked_length} : tx_prepared_length;
  assign ep2_tx_cork = tx_packet_locked ?
      (tx_locked_length == 0) : tx_prepared_cork;

  always @(posedge cpu_clk or negedge reset_n) begin
    if (!reset_n)
      tx_flush_toggle_cpu <= 1'b0;
    else if (cpu_flush_tx)
      tx_flush_toggle_cpu <= ~tx_flush_toggle_cpu;
  end

  always @(posedge usb_clk or negedge reset_n) begin
    if (!reset_n) begin
      tx_flush_usb_meta <= 1'b0;
      tx_flush_usb_sync <= 1'b0;
      tx_flush_usb_seen <= 1'b0;
    end else begin
      tx_flush_usb_meta <= tx_flush_toggle_cpu;
      tx_flush_usb_sync <= tx_flush_usb_meta;
      if (tx_flush_request)
        tx_flush_usb_seen <= tx_flush_usb_sync;
    end
  end

  always @(posedge usb_clk or negedge reset_n) begin
    if (!reset_n) begin
      rx_stage_count <= 7'd0;
      rx_drain_index <= 7'd0;
      rx_drain_count <= 7'd0;
      rx_draining <= 1'b0;
      rx_waiting_valid <= 1'b0;
      rx_validation_count <= 3'd0;
      rx_packet_overflow <= 1'b0;
      rx_active_d <= 1'b0;
      rx_armed <= 1'b0;
      rx_packet_ready <= 1'b0;
      rx_overflow_toggle <= 1'b0;
      tx_head <= 6'd0;
      tx_stage_count <= 7'd0;
      tx_send_index <= 7'd0;
      tx_active_d <= 1'b0;
      tx_finished_seen <= 1'b0;
      tx_packet_locked <= 1'b0;
      tx_locked_length <= 7'd0;
      tx_flush_pending <= 1'b0;
      tx_prepared_length <= 12'd0;
      tx_prepared_cork <= 1'b1;
    end else begin
      rx_active_d <= ep2_rx_active;
      tx_active_d <= (endpoint == 4'd2) && tx_active;
      if (tx_flush_request)
        tx_flush_pending <= 1'b1;

      if (usb_datapath_reset) begin
        // A USB bus reset invalidates only packet-local speculative state.
        // The CDC FIFOs and a fully validated packet which is already being
        // drained retain queued software data.  Likewise, bytes already
        // removed from the TX FIFO stay in tx_stage and are retransmitted
        // after re-enumeration instead of being silently lost.
        if (!rx_draining)
          rx_stage_count <= 7'd0;
        rx_waiting_valid <= 1'b0;
        rx_validation_count <= 3'd0;
        rx_packet_overflow <= 1'b0;
        rx_active_d <= 1'b0;
        rx_armed <= 1'b0;
        rx_packet_ready <= 1'b0;
        tx_send_index <= 7'd0;
        tx_active_d <= 1'b0;
        tx_finished_seen <= 1'b0;
        tx_packet_locked <= 1'b0;
        tx_locked_length <= 7'd0;
        tx_prepared_length <= 12'd0;
        tx_prepared_cork <= 1'b1;
      end else begin
        if (!usb_operational)
          rx_armed <= 1'b0;
        else if (!ep2_rx_active)
          // A low phase must be observed after reset before any OUT packet can
          // be accepted.  This prevents ready rising in the middle of rxact.
          rx_armed <= 1'b1;

        if (rx_start) begin
          rx_armed <= 1'b0;
          rx_packet_ready <= rx_has_packet_room;
          rx_stage_count <= 7'd0;
          rx_waiting_valid <= 1'b0;
          rx_validation_count <= 3'd0;
          rx_packet_overflow <= 1'b0;
        end

        if (rx_accept) begin
          if (rx_stage_count < 7'd64) begin
            rx_stage[rx_stage_count[5:0]] <= rx_data;
            rx_stage_count <= rx_count_next;
          end else begin
            // A conforming full-speed packet never exceeds 64 bytes.  Drop a
            // malformed overlength packet and report the condition once.
            if (!rx_packet_overflow)
              rx_overflow_toggle <= ~rx_overflow_toggle;
            rx_packet_overflow <= 1'b1;
          end
        end

        if (rx_packet_valid && rx_packet_ready &&
            ((endpoint == 4'd2) || rx_waiting_valid || rx_active_d)) begin
          // rx_count_next includes a final byte coincident with rxpktval.
          rx_packet_ready <= 1'b0;
          rx_waiting_valid <= 1'b0;
          rx_validation_count <= 3'd0;
          if ((rx_count_next != 0) && !rx_packet_overflow &&
              !rx_overflow_now && (rx_count_next <= 7'd64)) begin
            rx_drain_index <= 7'd0;
            rx_drain_count <= rx_count_next;
            rx_draining <= 1'b1;
          end else begin
            rx_stage_count <= 7'd0;
            rx_packet_overflow <= 1'b0;
          end
        end else begin
          if (!ep2_rx_active && rx_active_d && !rx_draining) begin
            // Gowin controller revisions may pulse rxpktval a few clocks
            // after rxact falls.  Hold the complete speculative packet for a
            // four-clock validation window instead of dropping it at once.
            if (rx_packet_ready && (rx_stage_count != 0)) begin
              rx_waiting_valid <= 1'b1;
              rx_validation_count <= 3'd0;
            end else begin
              rx_stage_count <= 7'd0;
              rx_waiting_valid <= 1'b0;
              rx_packet_overflow <= 1'b0;
              rx_packet_ready <= 1'b0;
            end
          end else if (rx_waiting_valid) begin
            if (rx_validation_count == 3'd3) begin
              // No CRC-valid indication arrived within the safe window.
              rx_stage_count <= 7'd0;
              rx_waiting_valid <= 1'b0;
              rx_validation_count <= 3'd0;
              rx_packet_overflow <= 1'b0;
              rx_packet_ready <= 1'b0;
            end else begin
              rx_validation_count <= rx_validation_count + 1'b1;
            end
          end
        end

        if (rx_drain_write) begin
          if (rx_drain_index + 1'b1 >= rx_drain_count) begin
            rx_drain_index <= 7'd0;
            rx_drain_count <= 7'd0;
            rx_stage_count <= 7'd0;
            rx_draining <= 1'b0;
            rx_packet_overflow <= 1'b0;
            rx_packet_ready <= 1'b0;
          end else begin
            rx_drain_index <= rx_drain_index + 1'b1;
          end
        end

        if (tx_flush_apply) begin
          tx_head <= 6'd0;
          tx_stage_count <= 7'd0;
          tx_send_index <= 7'd0;
          tx_finished_seen <= 1'b0;
          tx_packet_locked <= 1'b0;
          tx_locked_length <= 7'd0;
          tx_flush_pending <= 1'b0;
          tx_prepared_length <= 12'd0;
          tx_prepared_cork <= 1'b1;
        end else begin
          if (tx_load) begin
            tx_stage[(tx_head + tx_stage_count[5:0]) & 6'h3f]
                <= tx_fifo_data;
            tx_stage_count <= tx_count_with_load;
          end

          // Length/cork are registered as one pair and held for an entire IN
          // transaction, matching the proven standalone controller handshake.
          if (!tx_active && !tx_packet_locked) begin
            tx_prepared_length <= {5'd0, tx_count_with_load};
            tx_prepared_cork <= (tx_count_with_load == 0);
          end

          if ((endpoint == 4'd2) && tx_active && !tx_active_d) begin
            // Some controller revisions assert txpop together with the first
            // txact cycle.  The byte on tx_data is index zero in that cycle,
            // so account for that pop instead of discarding it here.
            tx_send_index <= tx_send_next;
            tx_finished_seen <= 1'b0;
            if (!tx_packet_locked) begin
              tx_packet_locked <= 1'b1;
              tx_locked_length <= tx_prepared_length[6:0];
            end
          end else if ((endpoint == 4'd2) && tx_active && tx_pop &&
                       (tx_send_index < tx_stage_count)) begin
            tx_send_index <= tx_send_next;
          end

          if ((endpoint == 4'd2) && tx_packet_finished) begin
            // Include a final tx_pop which coincides with txpktfin.  The ring
            // head advances only here; an aborted transaction never consumes
            // software bytes and therefore retries from the identical byte.
            tx_head <= tx_head + tx_send_next[5:0];
            tx_stage_count <= tx_stage_count - tx_send_next;
            tx_send_index <= 7'd0;
            tx_finished_seen <= 1'b1;
            tx_packet_locked <= 1'b0;
            tx_locked_length <= 7'd0;
          end

          if (!((endpoint == 4'd2) && tx_active) && tx_active_d) begin
            if (!tx_finished_seen && !tx_packet_finished)
              tx_send_index <= 7'd0;
            tx_finished_seen <= 1'b0;
          end
        end
      end
    end
  end

  // Keep the USB-domain read level observable during synthesis/debug.
  wire unused_tx_level = ^tx_rd_level;
endmodule
