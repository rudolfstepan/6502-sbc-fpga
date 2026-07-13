// Minimal CDC ACM class-request handler for endpoint zero.
// The Gowin device controller itself handles standard USB requests.
module usb_cdc_acm_control (
    input  wire        clk,
    input  wire        reset,
    input  wire        setup,
    input  wire [3:0]  endpoint,
    input  wire        rx_active,
    input  wire        rx_valid,
    input  wire [7:0]  rx_data,
    input  wire        tx_active,
    input  wire        tx_pop,
    output wire [7:0]  tx_data,
    output wire        tx_valid,
    output wire [11:0] tx_length,
    output wire [31:0] line_baud,
    output wire [7:0]  line_stop_bits,
    output wire [7:0]  line_parity,
    output wire [7:0]  line_data_bits,
    output wire [15:0] control_lines
);
  localparam [7:0] SET_LINE_CODING        = 8'h20;
  localparam [7:0] GET_LINE_CODING        = 8'h21;
  localparam [7:0] SET_CONTROL_LINE_STATE = 8'h22;

  reg [3:0] setup_index;
  reg [7:0] request_type;
  reg [7:0] request;
  reg [15:0] value;
  reg [15:0] interface_number;
  reg [15:0] request_length;

  reg [31:0] baud;
  reg [7:0] stop_bits;
  reg [7:0] parity;
  reg [7:0] data_bits;
  reg [15:0] modem_lines;

  reg set_line_active;
  reg get_line_active;
  reg [3:0] data_index;
  reg [7:0] ep0_data;
  reg ep0_valid;

  assign tx_data = ep0_data;
  assign tx_valid = ep0_valid;
  assign tx_length = 12'd7;
  assign line_baud = baud;
  assign line_stop_bits = stop_bits;
  assign line_parity = parity;
  assign line_data_bits = data_bits;
  assign control_lines = modem_lines;

  always @(posedge clk or posedge reset) begin
    if (reset) begin
      setup_index <= 0;
      request_type <= 0;
      request <= 0;
      value <= 0;
      interface_number <= 0;
      request_length <= 0;
      baud <= 32'd115200;
      stop_bits <= 0;
      parity <= 0;
      data_bits <= 8;
      modem_lines <= 0;
      set_line_active <= 1'b0;
      get_line_active <= 1'b0;
      data_index <= 0;
      ep0_data <= 0;
      ep0_valid <= 1'b0;
    end else begin
      if (setup) begin
        // setup can stay asserted while rx_valid has bubbles. Preserve the
        // byte index across those cycles, exactly as the controller's
        // reference handshake requires.
        if (rx_valid) begin
          case (setup_index)
          0: begin
            request_type <= rx_data;
            setup_index <= 1;
            data_index <= 0;
            ep0_valid <= 1'b0;
            set_line_active <= 1'b0;
            get_line_active <= 1'b0;
          end
          1: begin request <= rx_data; setup_index <= 2; end
          2: begin value[7:0] <= rx_data; setup_index <= 3; end
          3: begin value[15:8] <= rx_data; setup_index <= 4; end
          4: begin interface_number[7:0] <= rx_data; setup_index <= 5; end
          5: begin interface_number[15:8] <= rx_data; setup_index <= 6; end
          6: begin request_length[7:0] <= rx_data; setup_index <= 7; end
          7: begin
            request_length[15:8] <= rx_data;
            setup_index <= 8;
            if ((request_type == 8'hA1) &&
                (request == GET_LINE_CODING) &&
                (interface_number == 0)) begin
              get_line_active <= 1'b1;
              ep0_data <= baud[7:0];
              ep0_valid <= 1'b1;
            end else if ((request_type == 8'h21) &&
                         (request == SET_LINE_CODING) &&
                         (interface_number == 0)) begin
              set_line_active <= 1'b1;
            end else if ((request_type == 8'h21) &&
                         (request == SET_CONTROL_LINE_STATE) &&
                         (interface_number == 0)) begin
              modem_lines <= value;
            end
          end
            default: setup_index <= setup_index;
          endcase
        end
      end else begin
        setup_index <= 0;

        if (set_line_active && rx_active && rx_valid && (endpoint == 0)) begin
          case (data_index)
            0: baud[7:0] <= rx_data;
            1: baud[15:8] <= rx_data;
            2: baud[23:16] <= rx_data;
            3: baud[31:24] <= rx_data;
            4: stop_bits <= rx_data;
            5: parity <= rx_data;
            6: begin
              data_bits <= rx_data;
              set_line_active <= 1'b0;
            end
            default: set_line_active <= 1'b0;
          endcase
          data_index <= data_index + 1'b1;
        end

        if (get_line_active && tx_active && tx_pop && (endpoint == 0)) begin
          case (data_index)
            0: ep0_data <= baud[15:8];
            1: ep0_data <= baud[23:16];
            2: ep0_data <= baud[31:24];
            3: ep0_data <= stop_bits;
            4: ep0_data <= parity;
            5: ep0_data <= data_bits;
            default: begin
              ep0_data <= 0;
              ep0_valid <= 1'b0;
              get_line_active <= 1'b0;
            end
          endcase
          data_index <= data_index + 1'b1;
        end
      end
    end
  end
endmodule
