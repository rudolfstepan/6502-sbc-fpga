// Packet-aware endpoint-2 echo buffer. OUT data is not exposed to the IN
// side until the controller reports a valid packet. IN reads are committed
// only after tx_packet_finished, so a retried USB transaction sees the same
// bytes again.
module usb_packet_echo_fifo #(
    parameter ADDR_WIDTH = 11
) (
    input  wire        clk,
    input  wire        reset,
    input  wire [3:0]  endpoint,
    input  wire        rx_active,
    input  wire        rx_valid,
    input  wire        rx_packet_valid,
    input  wire [7:0]  rx_data,
    output wire        rx_ready,
    input  wire        tx_active,
    input  wire        tx_pop,
    input  wire        tx_packet_finished,
    output wire        tx_cork,
    output wire [7:0]  tx_data,
    output wire [11:0] tx_length,
    output reg         activity_toggle
);
  localparam PTR_WIDTH = ADDR_WIDTH + 1;
  localparam [PTR_WIDTH-1:0] DEPTH = (1 << ADDR_WIDTH);

  reg [7:0] rx_mem [0:(1 << ADDR_WIDTH)-1];
  reg [7:0] tx_mem [0:(1 << ADDR_WIDTH)-1];

  reg [PTR_WIDTH-1:0] rx_write;
  reg [PTR_WIDTH-1:0] rx_committed;
  reg [PTR_WIDTH-1:0] rx_read;
  reg [PTR_WIDTH-1:0] tx_write;
  reg [PTR_WIDTH-1:0] tx_read;
  reg [PTR_WIDTH-1:0] tx_committed;
  reg rx_active_d;
  reg tx_active_d;
  reg tx_finished_seen;
  reg rx_packet_ready;
  reg [11:0] prepared_len;
  reg prepared_cork;

  wire ep2_rx = (endpoint == 4'd2) && rx_active;
  wire ep2_tx = (endpoint == 4'd2) && tx_active;
  wire rx_start = ep2_rx && !rx_active_d;
  wire [PTR_WIDTH-1:0] rx_write_base =
      rx_start ? rx_committed : rx_write;
  wire [PTR_WIDTH-1:0] rx_committed_used = rx_committed - rx_read;
  wire [PTR_WIDTH-1:0] tx_used = tx_write - tx_committed;
  wire can_accept_packet =
      rx_committed_used <= (DEPTH - 12'd64);
  // Keep every bulk-IN transaction shorter than the advertised 64-byte
  // MaxPacketSize. Windows usbser otherwise keeps an exact 64*N-byte read
  // pending until a later short packet or ZLP arrives. Capping at 63 gives
  // deterministic stream latency without adding retry-sensitive ZLP state.
  wire [11:0] tx_offer_length =
      (tx_used >= 12'd63) ? 12'd63 : tx_used;
  wire rx_accept = ep2_rx && rx_valid && rx_ready;
  wire [PTR_WIDTH-1:0] rx_write_next =
      rx_write_base + (rx_accept ? 1'b1 : 1'b0);
  wire tx_consume = ep2_tx && tx_pop && (tx_read != tx_write);
  wire [PTR_WIDTH-1:0] tx_read_next =
      tx_read + (tx_consume ? 1'b1 : 1'b0);

  // Reserve one complete full-speed bulk packet before accepting its first
  // byte, then keep that decision stable for the complete OUT transaction.
  // On rx_start the freshly computed value is used directly because the
  // register is only updated at that same clock edge.
  assign rx_ready = (endpoint == 0) ? 1'b1 :
                    (endpoint == 2) ?
                      (rx_start ? can_accept_packet :
                       (ep2_rx ? rx_packet_ready : can_accept_packet)) :
                    1'b0;
  assign tx_cork = prepared_cork;
  assign tx_data = tx_mem[tx_read[ADDR_WIDTH-1:0]];
  assign tx_length = prepared_len;

  always @(posedge clk or posedge reset) begin
    if (reset) begin
      rx_write <= 0;
      rx_committed <= 0;
      rx_read <= 0;
      tx_write <= 0;
      tx_read <= 0;
      tx_committed <= 0;
      rx_active_d <= 1'b0;
      tx_active_d <= 1'b0;
      tx_finished_seen <= 1'b0;
      rx_packet_ready <= 1'b0;
      prepared_len <= 12'd0;
      prepared_cork <= 1'b1;
      activity_toggle <= 1'b0;
    end else begin
      rx_active_d <= ep2_rx;
      tx_active_d <= ep2_tx;

      if (rx_start)
        rx_packet_ready <= can_accept_packet;

      // Present length and cork as one registered pair. The Gowin controller
      // may sample both when an IN transaction begins, so neither may change
      // while tx_active is asserted. A newly queued first byte can therefore
      // cause one harmless additional NAK cycle before the pair is prepared.
      if (!tx_active) begin
        prepared_len <= tx_offer_length;
        prepared_cork <= (tx_used == 0);
      end

      if (ep2_tx && !tx_active_d) begin
        tx_finished_seen <= 1'b0;
      end

      // Start every OUT transaction at the last committed position. If the
      // first byte arrives with rx_active's rising edge, write it at that
      // rollback position rather than at a stale speculative pointer.
      if (rx_start || rx_accept)
        rx_write <= rx_write_next;
      if (rx_accept) begin
        rx_mem[rx_write_base[ADDR_WIDTH-1:0]] <= rx_data;
      end
      if ((endpoint == 2) && rx_packet_valid) begin
        // Include a final byte if rx_valid and rx_packet_valid coincide.
        rx_committed <= rx_write_next;
        activity_toggle <= ~activity_toggle;
      end
      if (!ep2_rx && rx_active_d) begin
        // Drop a CRC-failed speculative packet as soon as the OUT transaction
        // ends. A valid packet ending in this cycle keeps rx_write_next.
        rx_write <= ((endpoint == 2) && rx_packet_valid) ?
                    rx_write_next : rx_committed;
      end

      // Move committed OUT bytes into the retransmission-safe IN queue.
      if (!ep2_tx && (rx_read != rx_committed) &&
          ((tx_write - tx_committed) != DEPTH)) begin
        tx_mem[tx_write[ADDR_WIDTH-1:0]] <= rx_mem[rx_read[ADDR_WIDTH-1:0]];
        rx_read <= rx_read + 1'b1;
        tx_write <= tx_write + 1'b1;
      end

      if (tx_consume)
        tx_read <= tx_read_next;

      if ((endpoint == 2) && tx_packet_finished) begin
        // Include a final consumed byte if tx_pop and txpktfin coincide.
        tx_committed <= tx_read_next;
        tx_finished_seen <= 1'b1;
        activity_toggle <= ~activity_toggle;
      end
      if (!ep2_tx && tx_active_d) begin
        if (!tx_finished_seen && !tx_packet_finished)
          // No successful packet indication: rewind speculative reads.
          tx_read <= tx_committed;
        tx_finished_seen <= 1'b0;
      end
    end
  end
endmodule
