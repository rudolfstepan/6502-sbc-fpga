`timescale 1ns/1ps
module tb_vexriscv_boot;
  reg clk=0, reset=1; always #10 clk=~clk;
  wire iv, dv; wire [31:0] ia, da, dd; wire [3:0] dm;
  reg irsp=0, drsp=0; integer seen=0;
  VexRiscv dut(
    .clk(clk),.reset(reset),.debugReset(1'b0),
    .timerInterrupt(1'b0),.externalInterrupt(1'b0),.softwareInterrupt(1'b0),.externalInterruptS(1'b0),
    .debug_bus_cmd_valid(1'b0),.debug_bus_cmd_payload_wr(1'b0),
    .debug_bus_cmd_payload_address(8'b0),.debug_bus_cmd_payload_data(32'b0),
    .iBus_cmd_valid(iv),.iBus_cmd_ready(1'b1),.iBus_cmd_payload_address(ia),
    .iBus_rsp_valid(irsp),.iBus_rsp_payload_data(32'h00000013),.iBus_rsp_payload_error(1'b0),
    .dBus_cmd_valid(dv),.dBus_cmd_ready(1'b1),.dBus_cmd_payload_address(da),
    .dBus_cmd_payload_data(dd),.dBus_cmd_payload_mask(dm),.dBus_rsp_valid(drsp),
    .dBus_rsp_payload_last(1'b1),.dBus_rsp_payload_data(32'b0),.dBus_rsp_payload_error(1'b0)
  );
  always @(posedge clk) begin
    irsp <= iv;
    drsp <= dv;
    if(iv) begin
      seen <= 1;
      $display("iBus fetch %08x",ia);
    end
  end
  initial begin
    repeat(10) @(posedge clk); reset<=0;
    repeat(200) @(posedge clk);
    if(!seen) $fatal(1,"VexRiscv produced no instruction request");
    $display("tb_vexriscv_boot PASS"); $finish;
  end
endmodule
