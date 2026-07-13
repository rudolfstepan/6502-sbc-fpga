// Standalone full-speed USB CDC ACM enumeration and bulk-loopback test for
// the Tang Mega 138K / Tang Console dedicated USB-C circuit.
module tang138k_usb_cdc_loopback_top (
    input  wire       clk,
    inout  wire       usb_dp_io,
    inout  wire       usb_dn_io,
    input  wire       usb_rxdp_p,
    input  wire       usb_rxdp_n,
    input  wire       usb_rxdn_p,
    input  wire       usb_rxdn_n,
    inout  wire       usb_term_dp_io,
    inout  wire       usb_term_dn_io,
    inout  wire       usb_pullup_en_io,
    output wire [3:0] led
);
  reg [19:0] power_on_count = 0;
  wire power_on_ready = &power_on_count;
  always @(posedge clk)
    if (!power_on_ready)
      power_on_count <= power_on_count + 1'b1;

  wire usb_clk60;
  wire pll_lock;
  usb_fs_pll phy_pll_i (
      .lock(pll_lock), .clk60(usb_clk60), .clkin(clk));

  // Asynchronous assertion, synchronous release in the 60-MHz USB domain.
  wire usb_async_reset = !power_on_ready || !pll_lock;
  reg [2:0] usb_reset_pipe = 3'b111;
  always @(posedge usb_clk60 or posedge usb_async_reset) begin
    if (usb_async_reset)
      usb_reset_pipe <= 3'b111;
    else
      usb_reset_pipe <= {usb_reset_pipe[1:0], 1'b0};
  end
  wire controller_reset = usb_reset_pipe[2];

  wire usb_bus_reset;
  wire usb_high_speed_unused;
  wire usb_suspend;
  wire usb_online;
  wire datapath_reset = controller_reset || usb_bus_reset;
  wire softphy_reset = controller_reset;

  // R129 is a direct 1.5-kOhm connection from M17 to D+. During reset or
  // detach M17 must be high impedance, never low. Once the 60-MHz domain is
  // out of reset, drive it high to announce a full-speed device. A host bus
  // reset must not detach the pull-up or reset the SoftPHY.
  wire attach_enable = !controller_reset;
  wire pullup_sense;
  IOBUF pullup_enable_iobuf (
      .O(pullup_sense), .IO(usb_pullup_en_io),
      .I(1'b1), .OEN(!attach_enable));

  // The USB-2-only termination paths remain electrically quiet in this
  // full-speed design. Reading them, and the unused differential receivers,
  // into LED3 prevents synthesis from dropping the explicitly neutral pads.
  wire term_dp_sense;
  wire term_dn_sense;
  IOBUF term_dp_disable_iobuf (
      .O(term_dp_sense), .IO(usb_term_dp_io),
      .I(1'b0), .OEN(1'b1));
  IOBUF term_dn_disable_iobuf (
      .O(term_dn_sense), .IO(usb_term_dn_io),
      .I(1'b0), .OEN(1'b1));
  wire neutral_pad_sense = usb_rxdp_p ^ usb_rxdp_n ^
                           usb_rxdn_p ^ usb_rxdn_n ^
                           term_dp_sense ^ term_dn_sense ^ pullup_sense;

  wire [7:0] phy_data_out;
  wire phy_tx_valid;
  wire phy_tx_ready;
  wire [7:0] phy_data_in;
  wire phy_rx_active;
  wire phy_rx_valid;
  wire phy_rx_error;
  wire [1:0] phy_line_state;
  wire [1:0] phy_op_mode;
  wire [1:0] phy_xcvr_select;
  wire phy_term_select;

  wire [7:0] usb_rx_data;
  wire usb_rx_valid;
  wire usb_rx_active;
  wire usb_rx_packet_valid;
  wire usb_rx_ready;
  wire [3:0] usb_endpoint;
  wire usb_setup;
  wire usb_sof;
  wire usb_tx_pop;
  wire usb_tx_active;
  wire usb_tx_packet_finished;

  wire [7:0] ep0_tx_data;
  wire ep0_tx_valid;
  wire [11:0] ep0_tx_length;
  wire [31:0] line_baud;
  wire [7:0] line_stop_bits;
  wire [7:0] line_parity;
  wire [7:0] line_data_bits;
  wire [15:0] control_lines;

  usb_cdc_acm_control control_i (
      .clk(usb_clk60), .reset(datapath_reset),
      .setup(usb_setup), .endpoint(usb_endpoint),
      .rx_active(usb_rx_active), .rx_valid(usb_rx_valid),
      .rx_data(usb_rx_data), .tx_active(usb_tx_active),
      .tx_pop(usb_tx_pop), .tx_data(ep0_tx_data),
      .tx_valid(ep0_tx_valid), .tx_length(ep0_tx_length),
      .line_baud(line_baud), .line_stop_bits(line_stop_bits),
      .line_parity(line_parity), .line_data_bits(line_data_bits),
      .control_lines(control_lines));

  wire [7:0] echo_tx_data;
  wire [11:0] echo_tx_length;
  wire echo_tx_cork;
  wire echo_rx_ready;
  wire activity_toggle;
  usb_packet_echo_fifo echo_i (
      .clk(usb_clk60), .reset(datapath_reset), .endpoint(usb_endpoint),
      .rx_active(usb_rx_active), .rx_valid(usb_rx_valid),
      .rx_packet_valid(usb_rx_packet_valid), .rx_data(usb_rx_data),
      .rx_ready(echo_rx_ready), .tx_active(usb_tx_active),
      .tx_pop(usb_tx_pop), .tx_packet_finished(usb_tx_packet_finished),
      .tx_cork(echo_tx_cork), .tx_data(echo_tx_data),
      .tx_length(echo_tx_length), .activity_toggle(activity_toggle));

  wire [7:0] controller_tx_data =
      (usb_endpoint == 0) ? ep0_tx_data : echo_tx_data;
  wire [11:0] controller_tx_length =
      (usb_endpoint == 0) ? ep0_tx_length :
      (usb_endpoint == 2) ? echo_tx_length : 12'd0;
  wire controller_tx_cork =
      (usb_endpoint == 0) ? 1'b0 :
      (usb_endpoint == 2) ? echo_tx_cork : 1'b1;
  assign usb_rx_ready = (usb_endpoint == 0) ? 1'b1 : echo_rx_ready;

  wire [15:0] desc_read_address;
  wire [7:0] desc_index;
  wire [7:0] desc_type;
  wire [7:0] desc_read_data;
  wire [15:0] desc_device_address, desc_device_length;
  wire [15:0] desc_qualifier_address, desc_qualifier_length;
  wire [15:0] desc_fs_address, desc_fs_length;
  wire [15:0] desc_hs_address, desc_hs_length;
  wire [15:0] desc_other_address;
  wire [15:0] desc_lang_address;
  wire [15:0] desc_vendor_address, desc_vendor_length;
  wire [15:0] desc_product_address, desc_product_length;
  wire [15:0] desc_serial_address, desc_serial_length;
  wire desc_have_strings;

  usb_cdc_descriptor descriptor_i (
      .read_address(desc_read_address), .read_data(desc_read_data),
      .device_address(desc_device_address),
      .device_length(desc_device_length),
      .qualifier_address(desc_qualifier_address),
      .qualifier_length(desc_qualifier_length),
      .fs_config_address(desc_fs_address),
      .fs_config_length(desc_fs_length),
      .hs_config_address(desc_hs_address),
      .hs_config_length(desc_hs_length),
      .other_speed_address(desc_other_address),
      .string_lang_address(desc_lang_address),
      .string_vendor_address(desc_vendor_address),
      .string_vendor_length(desc_vendor_length),
      .string_product_address(desc_product_address),
      .string_product_length(desc_product_length),
      .string_serial_address(desc_serial_address),
      .string_serial_length(desc_serial_length),
      .have_strings(desc_have_strings));

  wire [7:0] interface_alternate_out;
  wire [7:0] interface_select;
  wire interface_set;
  reg [7:0] interface0_alternate;
  reg [7:0] interface1_alternate;
  wire [7:0] interface_alternate_in =
      (interface_select == 0) ? interface0_alternate :
      (interface_select == 1) ? interface1_alternate : 8'd0;
  always @(posedge usb_clk60 or posedge datapath_reset) begin
    if (datapath_reset) begin
      interface0_alternate <= 0;
      interface1_alternate <= 0;
    end else if (interface_set) begin
      if (interface_select == 0)
        interface0_alternate <= interface_alternate_out;
      else if (interface_select == 1)
        interface1_alternate <= interface_alternate_out;
    end
  end

  USB_Device_Controller_Top controller_i (
      .clk_i(usb_clk60), .reset_i(controller_reset),
      .usbrst_o(usb_bus_reset), .highspeed_o(usb_high_speed_unused),
      .suspend_o(usb_suspend), .online_o(usb_online),
      .txdat_i(controller_tx_data),
      .txval_i(ep0_tx_valid && (usb_endpoint == 0)),
      .txdat_len_i(controller_tx_length), .txiso_pid_i(4'b0011),
      .txcork_i(controller_tx_cork), .txpop_o(usb_tx_pop),
      .txact_o(usb_tx_active), .txpktfin_o(usb_tx_packet_finished),
      .rxdat_o(usb_rx_data), .rxval_o(usb_rx_valid),
      .rxrdy_i(usb_rx_ready), .rxact_o(usb_rx_active),
      .rxpktval_o(usb_rx_packet_valid), .setup_o(usb_setup),
      .endpt_o(usb_endpoint), .sof_o(usb_sof),
      .inf_alter_i(interface_alternate_in),
      .inf_alter_o(interface_alternate_out),
      .inf_sel_o(interface_select), .inf_set_o(interface_set),
      .descrom_raddr_o(desc_read_address), .desc_index_o(desc_index),
      .desc_type_o(desc_type), .descrom_rdata_i(desc_read_data),
      .desc_dev_addr_i(desc_device_address),
      .desc_dev_len_i(desc_device_length),
      .desc_qual_addr_i(desc_qualifier_address),
      .desc_qual_len_i(desc_qualifier_length),
      .desc_fscfg_addr_i(desc_fs_address),
      .desc_fscfg_len_i(desc_fs_length),
      .desc_hscfg_addr_i(desc_hs_address),
      .desc_hscfg_len_i(desc_hs_length),
      .desc_oscfg_addr_i(desc_other_address),
      .desc_hidrpt_addr_i(16'd0), .desc_hidrpt_len_i(16'd0),
      .desc_bos_addr_i(16'd0), .desc_bos_len_i(16'd0),
      .desc_strlang_addr_i(desc_lang_address),
      .desc_strvendor_addr_i(desc_vendor_address),
      .desc_strvendor_len_i(desc_vendor_length),
      .desc_strproduct_addr_i(desc_product_address),
      .desc_strproduct_len_i(desc_product_length),
      .desc_strserial_addr_i(desc_serial_address),
      .desc_strserial_len_i(desc_serial_length),
      .desc_have_strings_i(desc_have_strings),
      .utmi_dataout_o(phy_data_out), .utmi_txvalid_o(phy_tx_valid),
      .utmi_txready_i(phy_tx_ready), .utmi_datain_i(phy_data_in),
      .utmi_rxactive_i(phy_rx_active), .utmi_rxvalid_i(phy_rx_valid),
      .utmi_rxerror_i(phy_rx_error), .utmi_linestate_i(phy_line_state),
      .utmi_opmode_o(phy_op_mode), .utmi_xcvrselect_o(phy_xcvr_select),
      .utmi_termselect_o(phy_term_select), .utmi_reset_o());

  USB_SoftPHY_Top softphy_i (
      .clk_i(usb_clk60), .rst_i(softphy_reset),
      .utmi_data_out_i(phy_data_out), .utmi_txvalid_i(phy_tx_valid),
      .utmi_op_mode_i(phy_op_mode), .utmi_xcvrselect_i(phy_xcvr_select),
      .utmi_termselect_i(phy_term_select), .utmi_data_in_o(phy_data_in),
      .utmi_txready_o(phy_tx_ready), .utmi_rxvalid_o(phy_rx_valid),
      .utmi_rxactive_o(phy_rx_active), .utmi_rxerror_o(phy_rx_error),
      .utmi_linestate_o(phy_line_state),
      .usb_dp_io(usb_dp_io), .usb_dn_io(usb_dn_io));

  assign led[0] = pll_lock;
  assign led[1] = usb_online;
  assign led[2] = activity_toggle;
  assign led[3] = usb_bus_reset ^ neutral_pad_sense;

  // Diagnostic class state remains readable in synthesis/debug views.
  wire unused_ok = &{1'b0, usb_high_speed_unused, usb_suspend, usb_sof,
                     desc_index[0], desc_type[0], line_baud[0],
                     line_stop_bits[0], line_parity[0], line_data_bits[0],
                     control_lines[0]};
endmodule
