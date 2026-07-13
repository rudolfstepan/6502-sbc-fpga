// Full-speed USB CDC ACM descriptor set.
// Endpoint 1 IN is the CDC notification endpoint. Endpoint 2 IN/OUT carries
// the byte stream. 0x33aa:0x0121 avoids the locally installed WinUSB driver
// for Gowin's 0x0120 reference PID and is suitable only for this internal
// board-level development test.
module usb_cdc_descriptor (
    input  wire [15:0] read_address,
    output wire [7:0]  read_data,
    output wire [15:0] device_address,
    output wire [15:0] device_length,
    output wire [15:0] qualifier_address,
    output wire [15:0] qualifier_length,
    output wire [15:0] fs_config_address,
    output wire [15:0] fs_config_length,
    output wire [15:0] hs_config_address,
    output wire [15:0] hs_config_length,
    output wire [15:0] other_speed_address,
    output wire [15:0] string_lang_address,
    output wire [15:0] string_vendor_address,
    output wire [15:0] string_vendor_length,
    output wire [15:0] string_product_address,
    output wire [15:0] string_product_length,
    output wire [15:0] string_serial_address,
    output wire [15:0] string_serial_length,
    output wire        have_strings
);
  localparam [15:0] DEV_ADDR = 0;
  localparam [15:0] DEV_LEN = 18;
  localparam [15:0] QUAL_ADDR = 0;
  localparam [15:0] QUAL_LEN = 0;
  localparam [15:0] FS_ADDR = 20;
  localparam [15:0] CFG_LEN = 75;
  localparam [15:0] HS_ADDR = 0;
  localparam [15:0] HS_LEN = 0;
  localparam [15:0] OTHER_ADDR = 0;
  localparam [15:0] LANG_ADDR = FS_ADDR + CFG_LEN;
  localparam [15:0] VENDOR_ADDR = LANG_ADDR + 4;
  localparam [15:0] VENDOR_LEN = 18;  // "System16"
  localparam [15:0] PRODUCT_ADDR = VENDOR_ADDR + VENDOR_LEN;
  localparam [15:0] PRODUCT_LEN = 26; // "CDC Loopback"
  localparam [15:0] SERIAL_ADDR = PRODUCT_ADDR + PRODUCT_LEN;
  localparam [15:0] SERIAL_LEN = 22;  // "CDC138K002"

  assign device_address = DEV_ADDR;
  assign device_length = DEV_LEN;
  assign qualifier_address = QUAL_ADDR;
  assign qualifier_length = QUAL_LEN;
  assign fs_config_address = FS_ADDR;
  assign fs_config_length = CFG_LEN;
  assign hs_config_address = HS_ADDR;
  assign hs_config_length = HS_LEN;
  assign other_speed_address = OTHER_ADDR;
  assign string_lang_address = LANG_ADDR;
  assign string_vendor_address = VENDOR_ADDR;
  assign string_vendor_length = VENDOR_LEN;
  assign string_product_address = PRODUCT_ADDR;
  assign string_product_length = PRODUCT_LEN;
  assign string_serial_address = SERIAL_ADDR;
  assign string_serial_length = SERIAL_LEN;
  assign have_strings = 1'b1;

  function automatic [7:0] config_byte;
    input [6:0] offset;
    begin
      case (offset)
        // Configuration descriptor
        0: config_byte=8'h09;  1: config_byte=8'h02;
        2: config_byte=8'h4b;  3: config_byte=8'h00;
        4: config_byte=8'h02;  5: config_byte=8'h01;
        6: config_byte=8'h00;  7: config_byte=8'h80;
        8: config_byte=8'h32;
        // Interface association descriptor
        9: config_byte=8'h08; 10: config_byte=8'h0b;
       11: config_byte=8'h00; 12: config_byte=8'h02;
       13: config_byte=8'h02; 14: config_byte=8'h02;
       15: config_byte=8'h01; 16: config_byte=8'h00;
        // CDC communications interface 0
       17: config_byte=8'h09; 18: config_byte=8'h04;
       19: config_byte=8'h00; 20: config_byte=8'h00;
       21: config_byte=8'h01; 22: config_byte=8'h02;
       23: config_byte=8'h02; 24: config_byte=8'h01;
       25: config_byte=8'h00;
        // Header, call management, ACM and union functional descriptors
       26: config_byte=8'h05; 27: config_byte=8'h24;
       28: config_byte=8'h00; 29: config_byte=8'h10;
       30: config_byte=8'h01;
       31: config_byte=8'h05; 32: config_byte=8'h24;
       33: config_byte=8'h01; 34: config_byte=8'h00;
       35: config_byte=8'h01;
       36: config_byte=8'h04; 37: config_byte=8'h24;
       38: config_byte=8'h02; 39: config_byte=8'h02;
       40: config_byte=8'h05; 41: config_byte=8'h24;
       42: config_byte=8'h06; 43: config_byte=8'h00;
       44: config_byte=8'h01;
        // Endpoint 1 IN: CDC serial-state notification
       45: config_byte=8'h07; 46: config_byte=8'h05;
       47: config_byte=8'h81; 48: config_byte=8'h03;
       49: config_byte=8'h08; 50: config_byte=8'h00;
       51: config_byte=8'h10;
        // CDC data interface 1
       52: config_byte=8'h09; 53: config_byte=8'h04;
       54: config_byte=8'h01; 55: config_byte=8'h00;
       56: config_byte=8'h02; 57: config_byte=8'h0a;
       58: config_byte=8'h00; 59: config_byte=8'h00;
       60: config_byte=8'h00;
        // Endpoint 2 OUT: bulk data
       61: config_byte=8'h07; 62: config_byte=8'h05;
       63: config_byte=8'h02; 64: config_byte=8'h02;
       65: config_byte=8'h40;
       66: config_byte=8'h00;
       67: config_byte=8'h00;
        // Endpoint 2 IN: bulk data
       68: config_byte=8'h07; 69: config_byte=8'h05;
       70: config_byte=8'h82; 71: config_byte=8'h02;
       72: config_byte=8'h40;
       73: config_byte=8'h00;
       74: config_byte=8'h00;
       default: config_byte=8'h00;
      endcase
    end
  endfunction

  function automatic [7:0] vendor_char;
    input [3:0] index;
    begin
      case (index)
        0:vendor_char="S"; 1:vendor_char="y"; 2:vendor_char="s";
        3:vendor_char="t"; 4:vendor_char="e"; 5:vendor_char="m";
        6:vendor_char="1"; 7:vendor_char="6";
        default:vendor_char=0;
      endcase
    end
  endfunction

  function automatic [7:0] product_char;
    input [3:0] index;
    begin
      case (index)
        0:product_char="C"; 1:product_char="D"; 2:product_char="C";
        3:product_char=" "; 4:product_char="L"; 5:product_char="o";
        6:product_char="o"; 7:product_char="p"; 8:product_char="b";
        9:product_char="a"; 10:product_char="c"; 11:product_char="k";
        default:product_char=0;
      endcase
    end
  endfunction

  function automatic [7:0] serial_char;
    input [3:0] index;
    begin
      case (index)
        0:serial_char="C"; 1:serial_char="D"; 2:serial_char="C";
        3:serial_char="1"; 4:serial_char="3"; 5:serial_char="8";
        6:serial_char="K"; 7:serial_char="0"; 8:serial_char="0";
        9:serial_char="2";
        default:serial_char=0;
      endcase
    end
  endfunction

  reg [7:0] data_mux;
  reg [15:0] relative;
  always @* begin
    data_mux = 0;
    relative = 0;
    if (read_address < DEV_LEN) begin
      case (read_address)
        0:data_mux=8'h12; 1:data_mux=8'h01; 2:data_mux=8'h00;
        3:data_mux=8'h02; 4:data_mux=8'hef; 5:data_mux=8'h02;
        6:data_mux=8'h01; 7:data_mux=8'h40; 8:data_mux=8'haa;
        9:data_mux=8'h33; 10:data_mux=8'h21; 11:data_mux=8'h01;
        12:data_mux=8'h00; 13:data_mux=8'h01; 14:data_mux=8'h01;
        15:data_mux=8'h02; 16:data_mux=8'h03; 17:data_mux=8'h01;
        default:data_mux=0;
      endcase
    end else if ((read_address >= FS_ADDR) &&
                 (read_address < FS_ADDR + CFG_LEN)) begin
      data_mux = config_byte(read_address - FS_ADDR);
    end else if (read_address == LANG_ADDR) begin
      data_mux = 8'h04;
    end else if (read_address == LANG_ADDR + 1) begin
      data_mux = 8'h03;
    end else if (read_address == LANG_ADDR + 2) begin
      data_mux = 8'h09;
    end else if (read_address == LANG_ADDR + 3) begin
      data_mux = 8'h04;
    end else if ((read_address >= VENDOR_ADDR) &&
                 (read_address < VENDOR_ADDR + VENDOR_LEN)) begin
      relative = read_address - VENDOR_ADDR;
      if (relative == 0) data_mux = VENDOR_LEN[7:0];
      else if (relative == 1) data_mux = 8'h03;
      else if (relative[0]) data_mux = 0;
      else data_mux = vendor_char((relative - 2) >> 1);
    end else if ((read_address >= PRODUCT_ADDR) &&
                 (read_address < PRODUCT_ADDR + PRODUCT_LEN)) begin
      relative = read_address - PRODUCT_ADDR;
      if (relative == 0) data_mux = PRODUCT_LEN[7:0];
      else if (relative == 1) data_mux = 8'h03;
      else if (relative[0]) data_mux = 0;
      else data_mux = product_char((relative - 2) >> 1);
    end else if ((read_address >= SERIAL_ADDR) &&
                 (read_address < SERIAL_ADDR + SERIAL_LEN)) begin
      relative = read_address - SERIAL_ADDR;
      if (relative == 0) data_mux = SERIAL_LEN[7:0];
      else if (relative == 1) data_mux = 8'h03;
      else if (relative[0]) data_mux = 0;
      else data_mux = serial_char((relative - 2) >> 1);
    end
  end
  assign read_data = data_mux;
endmodule
