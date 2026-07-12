module dvi_tx_tmds_phy(
	
	input				pixel_clock,
	input				ddr_bit_clock,
	input				reset,
	input	[9 : 0]		data,
	output	[1 : 0]		tmds_lane
);
	
	// Keep one reset synchronizer beside each OSER10.  Without preservation
	// Gowin synthesis merges the three identical lane synchronizers into the
	// first lane, then routes that single register across all HDMI serializers.
	// At 5x pixel clock the half-cycle recovery window is only 1.33 ns; the
	// merged fanout violated it and could leave every OSER10 held/reset
	// metastably after an unrelated placement change (for example USB logic).
	(* keep, syn_keep *) reg [2:0] reset_5x_sr /* synthesis syn_preserve = 1 */;
	
	wire dq_tmds;
	
	always@(posedge ddr_bit_clock or posedge reset)begin
		if(reset)begin
			reset_5x_sr <= 3'b111;
		end else begin
			reset_5x_sr <= {reset_5x_sr[1:0], 1'b0};
		end
	end
	
	OSER10 tmds_serdes_inst0 (
		.Q(dq_tmds),
		.D0(data[0]),
		.D1(data[1]),
		.D2(data[2]),
		.D3(data[3]),
		.D4(data[4]),
		.D5(data[5]),
		.D6(data[6]),
		.D7(data[7]),
		.D8(data[8]),
		.D9(data[9]),
		.PCLK(pixel_clock),
		.FCLK(ddr_bit_clock),
		.RESET(reset_5x_sr[2])
	);
	
	ELVDS_OBUF tmds_bufds_isnt0 (
		.I(dq_tmds),
		.O(tmds_lane[1]),
		.OB(tmds_lane[0])
	);
	
endmodule
