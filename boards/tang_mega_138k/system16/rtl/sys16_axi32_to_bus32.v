// Single-transaction AXI4 slave converting read/write bursts to the simple
// System16 req/ready bus. Read and write traffic is serialized deliberately;
// the external 16-bit SDRAM controller can service only one word at a time.
module sys16_axi32_to_bus32(
 input wire clk,input wire resetn,
 input wire [31:0] araddr,input wire [1:0] arburst,input wire [7:0] arid,
 input wire [7:0] arlen,input wire [2:0] arsize,input wire arvalid,output wire arready,
 output reg [31:0] rdata,output reg [7:0] rid,output reg rlast,
 output wire [1:0] rresp,output reg rvalid,input wire rready,
 input wire [31:0] awaddr,input wire [1:0] awburst,input wire [7:0] awid,
 input wire [7:0] awlen,input wire [2:0] awsize,input wire awvalid,output wire awready,
 input wire [31:0] wdata,input wire wlast,input wire [3:0] wstrb,input wire wvalid,output wire wready,
 output reg [7:0] bid,output wire [1:0] bresp,output reg bvalid,input wire bready,
 output reg bus_req,output reg bus_we,output reg [31:0] bus_addr,
 output reg [31:0] bus_wdata,output reg [3:0] bus_be,
 input wire [31:0] bus_rdata,input wire bus_ready
);
 localparam IDLE=0,RD_BUS=1,RD_DROP=2,RD_RESP=3,
            WR_DATA=4,WR_BUS=5,WR_DROP=6,WR_RESP=7;
 reg [3:0] state=IDLE;reg [7:0] left;reg [2:0] size_l;
 reg [1:0] burst_l;reg [31:0] addr_l;reg write_last;
 wire [31:0] step=(32'b1 << size_l);
 assign arready=(state==IDLE);
 // Prefer an accepted read if AR and AW are asserted simultaneously.
 assign awready=(state==IDLE && !arvalid);
 assign wready=(state==WR_DATA);
 assign rresp=2'b00;assign bresp=2'b00;
 always @(posedge clk) begin
  if(!resetn)begin state<=IDLE;bus_req<=0;bus_we<=0;rvalid<=0;bvalid<=0;
    rlast<=0;left<=0;addr_l<=0;bus_be<=0;end
  else case(state)
   IDLE:begin
    if(arvalid)begin addr_l<=araddr;bus_addr<=araddr;left<=arlen;
      size_l<=arsize;burst_l<=arburst;rid<=arid;bus_we<=0;bus_be<=4'hf;bus_req<=1;state<=RD_BUS;end
    else if(awvalid)begin addr_l<=awaddr;left<=awlen;size_l<=awsize;
      burst_l<=awburst;bid<=awid;state<=WR_DATA;end
   end
   RD_BUS:if(bus_ready)begin rdata<=bus_rdata;bus_req<=0;state<=RD_DROP;end
   RD_DROP:if(!bus_ready)begin rlast<=(left==0);rvalid<=1;state<=RD_RESP;end
   RD_RESP:if(rvalid && rready)begin rvalid<=0;if(left==0)begin rlast<=0;state<=IDLE;end
     else begin left<=left-1;if(burst_l!=2'b00)begin addr_l<=addr_l+step;bus_addr<=addr_l+step;end
       bus_req<=1;state<=RD_BUS;end end
   WR_DATA:if(wvalid)begin bus_addr<=addr_l;bus_wdata<=wdata;bus_be<=wstrb;
      bus_we<=1;bus_req<=1;write_last<=wlast || (left==0);state<=WR_BUS;end
   WR_BUS:if(bus_ready)begin bus_req<=0;state<=WR_DROP;end
   WR_DROP:if(!bus_ready)begin if(write_last)begin bvalid<=1;state<=WR_RESP;end
      else begin left<=left-1;if(burst_l!=2'b00)addr_l<=addr_l+step;state<=WR_DATA;end end
   WR_RESP:if(bvalid && bready)begin bvalid<=0;state<=IDLE;end
  endcase
 end
endmodule
