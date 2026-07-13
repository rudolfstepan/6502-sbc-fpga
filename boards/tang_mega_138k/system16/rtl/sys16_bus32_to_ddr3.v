// System16 32-bit bus to Gowin 256-bit DDR3 app-port bridge.
// Before serving the CPU it destructively tests every 32-byte beat of the
// complete 1 GiB device (two 512 MiB x16 chips) with a per-address pattern
// and its inverse. The 32-bit DDR app address counts 32-bit words.
module sys16_bus32_to_ddr3 #(
  parameter integer TEST_BEATS = 33554432      // 1 GiB / 32 bytes
)(
  input wire bus_clk,input wire bus_resetn,input wire bus_req,input wire bus_we,
  input wire [31:0] bus_addr,input wire [3:0] bus_be,input wire [31:0] bus_wdata,
  output reg [31:0] bus_rdata,output reg bus_ready,
  input wire app_clk,input wire app_calib,
  output reg [2:0] app_cmd,output reg app_cmd_en,input wire app_cmd_ready,
  output reg [27:0] app_addr,output reg [255:0] app_wdata,
  output reg [31:0] app_wmask,output reg app_wren,output reg app_wend,
  input wire app_wready,input wire [255:0] app_rdata,input wire app_rvalid,
  output reg test_active,output reg test_done,output reg test_fail,
  output reg [29:0] test_fail_addr,output reg [2:0] test_phase,
  output wire [6:0] test_progress
);
  function [255:0] test_pattern;
    input [24:0] beat; input invert;
    integer i; reg [31:0] v;
    begin
      for(i=0;i<8;i=i+1) begin
        v = 32'hA5A50000 ^ {7'b0,beat} ^ (i * 32'h11111111);
        test_pattern[i*32 +: 32] = invert ? ~v : v;
      end
    end
  endfunction

  // One-request toggle CDC. The AXI adapter holds its payload until ready.
  reg req_toggle=0,busy=0,wait_req_low=0,lat_we=0;
  reg [29:0] lat_addr=0; reg [3:0] lat_be=0;
  reg [31:0] lat_wdata=0,return_data=0; reg [2:0] ack_sync=0;
  reg ack_toggle=0;
  always @(posedge bus_clk) begin
    bus_ready<=0; ack_sync<={ack_sync[1:0],ack_toggle};
    if(!bus_resetn) begin
      req_toggle<=0;busy<=0;wait_req_low<=0;ack_sync<=0;bus_rdata<=0;
    end else if(wait_req_low) begin
      // bus_req is a level held through the ready pulse.  Do not interpret
      // that same level as a second request on the following clock.
      if(!bus_req) wait_req_low<=0;
    end else if(!busy && bus_req) begin
      lat_we<=bus_we;lat_addr<=bus_addr[29:0];lat_be<=bus_be;
      lat_wdata<=bus_wdata;req_toggle<=~req_toggle;busy<=1;
    end else if(busy && ack_sync[2]!=ack_sync[1]) begin
      bus_rdata<=return_data;bus_ready<=1;busy<=0;wait_req_low<=1;
    end
  end

  localparam WAIT_CAL=0,T_WCMD=1,T_WDATA=2,T_RCMD=3,T_RWAIT=4,
             SERVE=5,R_CMD=6,R_WAIT=7,W_CMD=8,W_DATA=9;
  reg [3:0] state=WAIT_CAL; reg [2:0] req_sync=0;
  reg [24:0] test_beat=0; reg test_invert=0;
  assign test_progress={test_phase,test_beat[24:21]};
  reg [23:0] watchdog=0; integer lane;
  wire [255:0] expected=test_pattern(test_beat,test_invert);
  always @(posedge app_clk) begin
    req_sync<={req_sync[1:0],req_toggle};
    app_cmd_en<=0;app_wren<=0;app_wend<=0;
    if(!bus_resetn) begin
      state<=WAIT_CAL;req_sync<=0;ack_toggle<=0;app_cmd<=3'b001;
      app_addr<=0;app_wdata<=0;app_wmask<=32'hffffffff;return_data<=0;
      test_active<=0;test_done<=0;test_fail<=0;test_fail_addr<=0;
      test_phase<=0;test_beat<=0;test_invert<=0;watchdog<=0;
    end else begin
      if(state==WAIT_CAL || state==SERVE) watchdog<=0;
      else watchdog<=watchdog+1'b1;
      case(state)
        WAIT_CAL: if(app_calib) begin
          test_active<=1;test_phase<=1;test_beat<=0;test_invert<=0;state<=T_WCMD;
        end
        // Command and write-data handshakes are deliberately separate. This is
        // the protocol used by the proven framebuffer DDR3 engine.
        T_WCMD: if(app_cmd_ready) begin
          app_addr<={test_beat,3'b0};app_cmd<=3'b000;app_cmd_en<=1;state<=T_WDATA;
        end
        T_WDATA: if(app_wready) begin
          app_wdata<=expected;app_wmask<=0;app_wren<=1;app_wend<=1;
          watchdog<=0;
          if(test_beat==TEST_BEATS-1) begin
            test_beat<=0;
            if(test_invert) test_phase<=4; else test_phase<=2;
            state<=T_RCMD;
          end
          else begin test_beat<=test_beat+1'b1;state<=T_WCMD; end
        end
        T_RCMD: if(app_cmd_ready) begin
          app_addr<={test_beat,3'b0};app_cmd<=3'b001;app_cmd_en<=1;state<=T_RWAIT;
        end
        T_RWAIT: if(app_rvalid) begin
          watchdog<=0;
          if(app_rdata!=expected) begin
            test_fail<=1;test_done<=1;test_active<=0;
            test_fail_addr<={test_beat,5'b0};state<=SERVE;
          end else if(test_beat==TEST_BEATS-1) begin
            if(!test_invert) begin
              test_invert<=1;test_beat<=0;test_phase<=3;state<=T_WCMD;
            end else begin
              test_done<=1;test_active<=0;test_phase<=0;state<=SERVE;
            end
          end else begin test_beat<=test_beat+1'b1;state<=T_RCMD; end
        end
        SERVE: if(test_done && !test_fail && req_sync[2]!=req_sync[1]) begin
          app_addr<={lat_addr[29:5],3'b0};lane=lat_addr[4:2];
          if(lat_we) begin
            app_cmd<=3'b000;app_wdata<=0;app_wmask<=32'hffffffff;
            app_wdata[lane*32 +: 32]<=lat_wdata;
            app_wmask[lane*4 +: 4]<=~lat_be;state<=W_CMD;
          end else begin app_cmd<=3'b001;state<=R_CMD; end
        end
        R_CMD: if(app_cmd_ready) begin app_cmd_en<=1;state<=R_WAIT; end
        R_WAIT: if(app_rvalid) begin
          lane=lat_addr[4:2];return_data<=app_rdata[lane*32 +: 32];
          ack_toggle<=~ack_toggle;state<=SERVE;
        end
        W_CMD: if(app_cmd_ready) begin app_cmd_en<=1;state<=W_DATA; end
        W_DATA: if(app_wready) begin
          app_wren<=1;app_wend<=1;ack_toggle<=~ack_toggle;state<=SERVE;
        end
        default:state<=WAIT_CAL;
      endcase
      // A missing app-port handshake is a hard test failure, not a silent hang.
      if(watchdog==24'hffffff && state!=SERVE && state!=WAIT_CAL) begin
        test_fail<=1;test_done<=1;test_active<=0;
        test_fail_addr<={test_beat,5'b0};state<=SERVE;
      end
    end
  end
endmodule
