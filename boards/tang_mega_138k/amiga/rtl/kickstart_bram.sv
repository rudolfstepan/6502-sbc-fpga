module kickstart_bram #(
    parameter INIT_FILE = "kickstart13_words.hex"
) (
    input  wire        clk,
    input  wire [16:0] addr,
    output reg  [15:0] data
);

    // 256 KiB Kickstart image. The board top mirrors these 128K words to
    // provide the 512 KiB ROM window expected by NanoMig.
    reg [15:0] rom [0:131071] /* synthesis syn_romstyle = "block_rom" */;

    initial
        $readmemh(INIT_FILE, rom);

    // Three-stage read pipeline for the 85 MHz SDRAM clock domain. The
    // registered address decouples the board-top ROM/copier address mux from
    // the block-RAM address fanout, and the extra output register decouples
    // the wide BSRAM read mux from the downstream signature compares; both
    // paths violated setup at 85 MHz when they shared one cycle. The boot
    // copier and runtime ROM reads keep the address stable for far more than
    // three cycles before the data is consumed.
    reg [16:0] addr_r;
    reg [15:0] read_r;

    always @(posedge clk) begin
        addr_r <= addr;
        read_r <= rom[addr_r];
        data   <= read_r;
    end

endmodule
