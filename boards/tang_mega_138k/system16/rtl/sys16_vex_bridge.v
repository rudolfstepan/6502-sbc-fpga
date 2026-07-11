module sys16_vex_bridge (
  input  wire clk,
  input  wire reset,
  input  wire timer_irq,
  input  wire external_irq,
  input  wire software_irq,
  output wire i_valid,
  input  wire i_ready,
  output wire [31:0] i_addr,
  output wire [2:0] i_size,
  input  wire i_rsp_valid,
  input  wire [31:0] i_rsp_data,
  output wire d_valid,
  input  wire d_ready,
  output wire d_write,
  output wire [31:0] d_addr,
  output wire [31:0] d_wdata,
  output wire [3:0] d_mask,
  output wire [2:0] d_size,
  input  wire d_rsp_valid,
  input  wire [31:0] d_rsp_data,
  input  wire d_rsp_last
  ,output reg bridge_alive
  ,output reg fetch_seen
);
  initial begin bridge_alive = 1'b0; fetch_seen = 1'b0; end
  always @(posedge clk or posedge reset) begin
    if(reset) begin bridge_alive <= 1'b0; fetch_seen <= 1'b0; end
    else begin
      bridge_alive <= 1'b1;
      if(i_valid) fetch_seen <= 1'b1;
    end
  end
  VexRiscv cpu (
    // DebugPlugin is a separate reset domain. Leaving debugReset tied low
    // leaves its halt/step registers undefined in FPGA hardware and can park
    // the CPU permanently even though the main pipeline left reset.
    .clk(clk), .reset(reset), .debugReset(reset),
    .timerInterrupt(timer_irq), .externalInterrupt(external_irq),
    .softwareInterrupt(software_irq), .externalInterruptS(1'b0),
    .debug_bus_cmd_valid(1'b0), .debug_bus_cmd_payload_wr(1'b0),
    .debug_bus_cmd_payload_address(8'b0), .debug_bus_cmd_payload_data(32'b0),
    .iBus_cmd_valid(i_valid), .iBus_cmd_ready(i_ready),
    .iBus_cmd_payload_address(i_addr), .iBus_cmd_payload_size(i_size),
    .iBus_rsp_valid(i_rsp_valid), .iBus_rsp_payload_data(i_rsp_data),
    .iBus_rsp_payload_error(1'b0),
    .dBus_cmd_valid(d_valid), .dBus_cmd_ready(d_ready),
    .dBus_cmd_payload_wr(d_write), .dBus_cmd_payload_uncached(),
    .dBus_cmd_payload_address(d_addr), .dBus_cmd_payload_data(d_wdata),
    .dBus_cmd_payload_mask(d_mask), .dBus_cmd_payload_size(d_size),
    .dBus_cmd_payload_last(), .dBus_rsp_valid(d_rsp_valid),
    .dBus_rsp_payload_last(d_rsp_last), .dBus_rsp_payload_data(d_rsp_data),
    .dBus_rsp_payload_error(1'b0), .debug_bus_cmd_ready(),
    .debug_bus_rsp_data(), .debug_resetOut()
  );
endmodule
