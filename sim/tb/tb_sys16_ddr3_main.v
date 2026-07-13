`timescale 1ns/1ps
module tb_sys16_ddr3_main;
  reg clk=0,resetn=0,calib=0,req=0,we=0; always #5 clk=~clk;
  reg [31:0] addr=0,wdata=0;reg [3:0] be=4'hf;wire [31:0] rdata;wire ready;
  wire [2:0] cmd;wire cmd_en;wire [27:0] app_addr;wire [255:0] app_wdata;
  wire [31:0] app_wmask;wire app_wren,app_wend;reg [255:0] app_rdata=0;
  reg app_rvalid=0;wire active,done,fail;wire [29:0] fail_addr;
  wire [2:0] phase;wire [6:0] progress;reg [255:0] mem[0:3];reg [1:0] wr_idx;
  integer i; integer service_cmds=0; integer service_writes=0;
  integer ready_pulses=0;
  sys16_bus32_to_ddr3 #(.TEST_BEATS(4)) dut(
    .bus_clk(clk),.bus_resetn(resetn),.bus_req(req),.bus_we(we),.bus_addr(addr),
    .bus_be(be),.bus_wdata(wdata),.bus_rdata(rdata),.bus_ready(ready),
    .app_clk(clk),.app_calib(calib),.app_cmd(cmd),.app_cmd_en(cmd_en),
    .app_cmd_ready(1'b1),.app_addr(app_addr),.app_wdata(app_wdata),
    .app_wmask(app_wmask),.app_wren(app_wren),.app_wend(app_wend),
    .app_wready(1'b1),.app_rdata(app_rdata),.app_rvalid(app_rvalid),
    .test_active(active),.test_done(done),.test_fail(fail),
    .test_fail_addr(fail_addr),.test_phase(phase),.test_progress(progress));
  always @(posedge clk) begin
    app_rvalid<=0;
    if(done && cmd_en) service_cmds<=service_cmds+1;
    if(done && app_wren) service_writes<=service_writes+1;
    if(done && ready) ready_pulses<=ready_pulses+1;
    if(cmd_en && cmd==3'b000) wr_idx<=app_addr[4:3];
    if(app_wren) for(i=0;i<32;i=i+1) if(!app_wmask[i]) mem[wr_idx][i*8 +:8]<=app_wdata[i*8 +:8];
    if(cmd_en && cmd==3'b001) begin app_rdata<=mem[app_addr[4:3]];app_rvalid<=1;end
  end
  initial begin
    repeat(4)@(posedge clk);@(negedge clk);resetn=1;
    repeat(2)@(posedge clk);@(negedge clk);calib=1;
    wait(done);if(fail)$fatal(1,"self-test failed at %h",fail_addr);
    @(negedge clk);addr=32'h00000024;wdata=32'h12345678;we=1;req=1;
    wait(ready);repeat(2)@(posedge clk);@(negedge clk);req=0;we=0;
    @(negedge clk);addr=32'h00000024;req=1;wait(ready);
    if(rdata!==32'h12345678)$fatal(1,"CPU readback %h",rdata);
    repeat(2)@(posedge clk);@(negedge clk);req=0;repeat(10)@(posedge clk);
    if(service_cmds!=2)$fatal(1,"duplicate CPU request(s): %0d app commands",service_cmds);
    if(service_writes!=1)$fatal(1,"duplicate CPU write(s): %0d data beats",service_writes);
    if(ready_pulses!=2)$fatal(1,"unexpected ready pulses: %0d",ready_pulses);
    $display("PASS: DDR3 full-test FSM and CPU write/read bridge");$finish;
  end
  initial begin #100000;$fatal(1,"timeout");end
endmodule
