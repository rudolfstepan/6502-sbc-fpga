/* GoRV32 Plus zero-stage bootloader, no vendor SDK involved.
 *
 * Runs XIP from the QSPI flash window at 0x80000000 (flash offset
 * FLASH_BURN_ADDR = 0x500000 on the 8 MB Tang Console flash). Loads a
 * GRV1 image (OpenSBI to $0, DTB to $3F0000, kernel to $400000 in SDRAM)
 * and jumps to OpenSBI with the DTB address in a1.
 *
 * Image sources, in order:
 *   1. QSPI XIP window at 0x80010000 (flash offset 0x510000).
 *   2. SD card fallback, raw GRV1 image starting at LBA 0 (vendor SD host at
 *      0xF0600000, registers per MUG1532 chapter 16; card brought up in
 *      4-bit mode at 1 MHz (1-bit fallback), single-block CMD17 reads).
 *
 * UART1 register file per MUG1532 chapter 9: 16550-compatible registers
 * at +0x20 with 4-byte stride, 32-bit APB access, 16x oversampling.
 */
#include <stdint.h>

#define UART_BASE 0xF0200000u
#define UART(reg) (*(volatile uint32_t *)(UART_BASE + (reg)))
#define UART_OSCR 0x14u
#define UART_THR  0x20u
#define UART_DLL  0x20u
#define UART_DLM  0x24u
#define UART_FCR  0x28u
#define UART_LCR  0x2Cu
#define UART_LSR  0x34u
#define LSR_THRE  0x20u
#define BAUD_DIVISOR 27u /* 50 MHz / (16 * 115200) */

#define SD_BASE 0xF0600000u
#define SD(reg) (*(volatile uint32_t *)(SD_BASE + (reg)))
#define SD_ARG        0x00u /* write starts the command */
#define SD_CMD        0x04u
#define SD_RESP0      0x08u
#define SD_DATA_TMO   0x18u
#define SD_CTRL       0x1Cu /* bit0: 4-bit bus */
#define SD_CMD_TMO    0x20u
#define SD_CLK_DIV    0x24u /* f_sd = 50 MHz / (2*(div+1)) */
#define SD_RESET      0x28u
#define SD_CMD_EVENT  0x34u /* bit0 done, bit1 any error; write clears */
#define SD_CMD_EVMASK 0x38u
#define SD_DAT_EVENT  0x3Cu
#define SD_BLK_SIZE   0x44u /* bytes - 1 */
#define SD_BLK_COUNT  0x48u /* blocks - 1 */
#define SD_RX         0x50u
#define SD_FIFO_STAT  0x54u /* bit1: read FIFO empty */
#define EV_DONE 0x1u
#define EV_ERR  0x2u
#define DAT_TIMEOUT_ERR (1u << 2)
#define DAT_CRC_ERR     (1u << 3)
#define DAT_WR_EMPTY    (1u << 4)
#define DAT_RD_FULL     (1u << 5)

/* Command register flags */
#define RESP_SHORT (1u << 0)
#define RESP_LONG  (2u << 0)
#define CHK_BUSY   (1u << 2)
#define CHK_CRC    (1u << 3)
#define CHK_IDX    (1u << 4)
#define DATA_READ  (1u << 5)

#define XIP_IMAGE  0x80010000u
#define FDT_ADDR   0x003F0000u
#define SBI_ENTRY  0x00000000u
#define GRV1_MAGIC 0x31565247u /* "GRV1" little-endian */

struct rec { uint32_t src_off, dst, len; };
struct hdr { uint32_t magic, count, sum; struct rec rec[]; };

static uint32_t sd_swap;     /* RX FIFO word order, detected from magic */
static uint32_t sd_is_sdhc;  /* block vs byte addressing */
static uint32_t sd_div;      /* current clock divider */
static uint32_t sd_wide;     /* current bus width */
static uint32_t sd_hdr_buf[128];
static uint32_t sd_last_words;
static uint32_t sd_last_fifo_full;
static uint32_t sd_last_fifo_status;

static void uart_putc(char c)
{
	while (!(UART(UART_LSR) & LSR_THRE))
		;
	UART(UART_THR) = (uint8_t)c;
}

static void uart_puts(const char *s)
{
	for (; *s; s++) {
		if (*s == '\n')
			uart_putc('\r');
		uart_putc(*s);
	}
}

static void uart_puthex(uint32_t v)
{
	for (int i = 28; i >= 0; i -= 4) {
		uint32_t d = (v >> i) & 0xFu;
		uart_putc((char)(d < 10 ? '0' + d : 'A' + d - 10));
	}
}

static void delay(uint32_t n)
{
	while (n--)
		__asm__ volatile("nop");
}

/* Full controller reinit. The engine state machines live in the divided
 * SD clock domain and have been seen to go silent after some commands;
 * a soft reset before every command gives each transaction a virgin
 * engine while the card keeps its own state. */
static void sd_engine_reset(void)
{
	SD(SD_RESET) = 1;
	delay(20000);
	SD(SD_RESET) = 0;
	delay(20000);
	SD(SD_CLK_DIV) = sd_div;
	SD(SD_CMD_TMO) = 0x8000u;
	SD(SD_DATA_TMO) = 0xFFFFFFu;
	SD(SD_CMD_EVMASK) = 0x1Fu;
	SD(0x40) = 0x3Fu;
	SD(SD_CTRL) = sd_wide;
	delay(20000);
}

/* Command without the preceding engine reset (for data transactions
 * that configure block registers after the reset). */
static uint32_t sd_cmd_raw(uint32_t idx, uint32_t arg, uint32_t flags)
{
	SD(SD_CMD_EVENT) = 0; /* write clears all pending flags */
	SD(SD_CMD) = (idx << 8) | flags;
	delay(5000); /* let the value cross into the SD clock domain */
	SD(SD_ARG) = arg;
	for (uint32_t spin = 0; spin < 50000000u; spin++) {
		uint32_t ev = SD(SD_CMD_EVENT);
		if (ev & EV_ERR)
			return ev;
		if (ev & EV_DONE)
			return 0;
	}
	return 0xFFFFu; /* no completion event at all */
}

/* Issue one SD command from a freshly reset engine. */
static uint32_t sd_cmd(uint32_t idx, uint32_t arg, uint32_t flags)
{
	sd_engine_reset();
	return sd_cmd_raw(idx, arg, flags);
}

static uint32_t bswap(uint32_t v)
{
	return (v << 24) | ((v & 0xFF00u) << 8) | ((v >> 8) & 0xFF00u) | (v >> 24);
}

/* Read one 512-byte block into dst (word aligned). 0 on success. */
static uint32_t sd_read_block(uint32_t lba, uint32_t *dst)
{
	uint32_t arg = sd_is_sdhc ? lba : lba << 9;
	sd_engine_reset();
	sd_last_words = 0;
	sd_last_fifo_full = 0;
	sd_last_fifo_status = 0;
	SD(SD_DAT_EVENT) = 0;
	SD(SD_BLK_SIZE) = 511;
	SD(SD_BLK_COUNT) = 0;
	delay(5000);

	/* CMD17 starts its data phase immediately after the response. Waiting in
	 * sd_cmd_raw() before touching RX lets the small controller FIFO fill,
	 * which reports data_event_status $22 (FIFORdFulErr | AllErr). Start the
	 * command here and service command events and RX data concurrently. */
	SD(SD_CMD_EVENT) = 0;
	SD(SD_CMD) = (17u << 8) | RESP_SHORT | CHK_CRC | CHK_IDX | DATA_READ;
	delay(5000);
	SD(SD_ARG) = arg;

	uint32_t got = 0;
	uint32_t cmd_done = 0;
	for (uint32_t spin = 0; spin < 50000000u; spin++) {
		while (got < 128 && !(SD(SD_FIFO_STAT) & 0x2u)) {
			uint32_t w = SD(SD_RX);
			dst[got++] = sd_swap ? bswap(w) : w;
		}
		sd_last_words = got;
		sd_last_fifo_status = SD(SD_FIFO_STAT);

		uint32_t cmd_ev = SD(SD_CMD_EVENT);
		if (cmd_ev & EV_ERR)
			return cmd_ev;
		if (cmd_ev & EV_DONE)
			cmd_done = 1;

		uint32_t data_ev = SD(SD_DAT_EVENT);
		/* CRC and timeout mean the block is unusable. DAT_WR_EMPTY only
		 * applies to writes, but is fatal if it ever appears on this path. */
		if (data_ev & (DAT_TIMEOUT_ERR | DAT_CRC_ERR | DAT_WR_EMPTY))
			return data_ev | 0x100u;
		if (data_ev & EV_DONE) {
			if (got != 128)
				return 0xFFFFFFFEu;
			return 0;
		}
		if (data_ev & DAT_RD_FULL) {
			/* The FIFO has already been drained above. Clear the latched
			 * full event and keep consuming instead of abandoning the card. */
			sd_last_fifo_full++;
			SD(SD_DAT_EVENT) = 0;
		}
	}
	return cmd_done ? 0xFFFFFFFDu : 0xFFFFu;
}

/* Bring up the card: 0 on success, else (step << 16) | event bits. */
static uint32_t sd_init(void)
{
	uint32_t ev;
	sd_div = 124; /* 50 MHz / (2*(124+1)) = 200 kHz identification */
	sd_wide = 0;  /* 1-bit during identification */
	sd_engine_reset();
	delay(800000); /* >74 card clocks at 200 kHz */

	uint32_t v2 = 0;
	for (uint32_t attempt = 0; attempt < 3 && !v2; attempt++) {
		sd_cmd(0, 0, 0); /* CMD0: idle, no response */
		delay(100000);
		/* CMD8: voltage check; old SDv1 cards time out here. */
		v2 = ((ev = sd_cmd(8, 0x1AA, RESP_SHORT | CHK_CRC)) == 0) &&
		     ((SD(SD_RESP0) & 0xFFu) == 0xAAu);
	}
	uart_puts(v2 ? "SD v2 card\n" : "SD: no CMD8 reply, trying v1\n");
	uint32_t acmd_arg = v2 ? 0x40FF8000u : 0x00FF8000u;
	uint32_t ready = 0;
	for (uint32_t i = 0; i < 4000 && !ready; i++) {
		if ((ev = sd_cmd(55, 0, RESP_SHORT | CHK_CRC)))
			return (1u << 16) | ev;
		if ((ev = sd_cmd(41, acmd_arg, RESP_SHORT))) /* R3: no CRC */
			return (2u << 16) | ev;
		ready = SD(SD_RESP0) >> 31;
	}
	if (!ready)
		return 3u << 16;
	sd_is_sdhc = (SD(SD_RESP0) >> 30) & 1u;
	if ((ev = sd_cmd(2, 0, RESP_LONG))) /* CID, contents unused */
		return (4u << 16) | ev;
	if ((ev = sd_cmd(3, 0, RESP_SHORT | CHK_CRC))) /* R6: RCA */
		return (5u << 16) | ev;
	uint32_t rca = SD(SD_RESP0) & 0xFFFF0000u;
	uart_puts("RCA $");
	uart_puthex(rca);
	/* Probe A: addressed CMD13 in standby, before the select. */
	ev = sd_cmd(13, rca, RESP_SHORT | CHK_CRC);
	uart_puts(" stby-probe $");
	uart_puthex(ev ? ev : SD(SD_RESP0));
	uart_puts("\n");
	/* Select; print the R1 card status of the select itself. */
	if ((ev = sd_cmd(7, rca, RESP_SHORT | CHK_CRC)))
		return (6u << 16) | ev;
	uart_puts("CMD7 R1 $");
	uart_puthex(SD(SD_RESP0));
	delay(400000);
	/* Probe B: the same CMD13 after the select. */
	ev = sd_cmd(13, rca, RESP_SHORT | CHK_CRC);
	uart_puts(" tran-probe $");
	uart_puthex(ev ? ev : SD(SD_RESP0));
	uart_puts("\n");
	/* Some cards stay busy for a moment after the select and ignore
	 * addressed commands meanwhile; retry the 4-bit switch and fall
	 * back to 1-bit operation if it never succeeds. */
	uint32_t wide = 0;
	for (uint32_t attempt = 0; attempt < 3 && !wide; attempt++) {
		delay(200000);
		if (sd_cmd(55, rca, RESP_SHORT | CHK_CRC))
			continue;
		if (sd_cmd(6, 2, RESP_SHORT | CHK_CRC)) /* ACMD6 */
			continue;
		wide = 1;
	}
	sd_wide = wide ? 1 : 0;
	if (!wide)
		uart_puts("SD: staying in 1-bit mode\n");
	/* Keep ample FIFO service margin while the ZSBL executes from QSPI XIP.
	 * 50 MHz / (2*(24+1)) = 1 MHz. Raise this only after sustained SD boots. */
	sd_div = 24;
	return 0;
}

static void hang(void)
{
	for (;;)
		__asm__ volatile("wfi");
}

static void boot(uint32_t fdt)
{
	uart_puts("checksum ok, jump to OpenSBI\n");
	__asm__ volatile("fence rw, rw; fence.i");
	register uint32_t a0 __asm__("a0") = 0;
	register uint32_t a1 __asm__("a1") = fdt;
	__asm__ volatile("jr %0" : : "r"(SBI_ENTRY), "r"(a0), "r"(a1));
}

/* Checksum from the copied destination, which also proves SDRAM readback. */
static uint32_t sum_records(const struct hdr *h)
{
	uint32_t sum = 0;
	for (uint32_t i = 0; i < h->count; i++) {
		const uint32_t *d = (const uint32_t *)h->rec[i].dst;
		uint32_t words = (h->rec[i].len + 3u) >> 2;
		for (uint32_t w = 0; w < words; w++)
			sum += d[w];
	}
	return sum;
}

static void report_rec(const struct rec *r)
{
	uart_puts("copy $");
	uart_puthex(r->dst);
	uart_puts(" len $");
	uart_puthex(r->len);
	uart_puts("\n");
}

static uint32_t try_sd(void)
{
	uint32_t err = sd_init();
	if (err) {
		/* High half: step. Low half: event bits of the failing
		 * command (bit2 timeout, bit3 CRC, bit4 index; $FFFF =
		 * no completion event at all). */
		uart_puts("SD init failed, step.event $");
		uart_puthex(err);
		uart_puts("\n");
		return 1;
	}
	err = sd_read_block(0, sd_hdr_buf);
	if (err) {
		/* <$100: command-phase event bits of CMD17 (bit2 timeout =
		 * command ignored). $1xx: data-phase events (bit2 timeout,
		 * bit3 CRC, bit5 RX FIFO full). $FFFFFFFE: data completed
		 * before 128 words; $FFFFFFFD: no data-complete event. */
		uart_puts("SD header read failed $");
		uart_puthex(err);
		uart_puts(" words $");
		uart_puthex(sd_last_words);
		uart_puts(" full $");
		uart_puthex(sd_last_fifo_full);
		uart_puts(" fifo $");
		uart_puthex(sd_last_fifo_status);
		uart_puts("\n");
		return 1;
	}
	/* Detect the RX FIFO byte order from the magic itself. */
	if (sd_hdr_buf[0] == bswap(GRV1_MAGIC)) {
		sd_swap = 1;
		for (uint32_t i = 0; i < 128; i++)
			sd_hdr_buf[i] = bswap(sd_hdr_buf[i]);
	}
	const struct hdr *h = (const struct hdr *)sd_hdr_buf;
	if (h->magic != GRV1_MAGIC) {
		uart_puts("no GRV1 image on SD\n");
		return 1;
	}
	if (h->count > 8) {
		uart_puts("bad SD header\n");
		return 1;
	}
	uart_puts("boot from SD\n");
	for (uint32_t i = 0; i < h->count; i++) {
		const struct rec *r = &h->rec[i];
		report_rec(r);
		uint32_t blocks = (r->len + 511u) >> 9;
		for (uint32_t b = 0; b < blocks; b++) {
			uint32_t e = sd_read_block((r->src_off >> 9) + b,
			                           (uint32_t *)(r->dst + (b << 9)));
			if (e) {
				uart_puts("SD read error $");
				uart_puthex(e);
				uart_puts("\n");
				return 1;
			}
		}
	}
	uint32_t sum = sum_records(h);
	if (sum != h->sum) {
		uart_puts("SD checksum mismatch $");
		uart_puthex(sum);
		uart_puts("\n");
		return 1;
	}
	boot(FDT_ADDR);
	return 1;
}

static uint32_t try_flash(void)
{
	const struct hdr *h = (const struct hdr *)XIP_IMAGE;
	if (h->magic != GRV1_MAGIC) {
		uart_puts("no GRV1 image 64K above the ZSBL\n");
		return 1;
	}
	uart_puts("boot from flash\n");
	for (uint32_t i = 0; i < h->count; i++) {
		const struct rec *r = &h->rec[i];
		const uint32_t *src = (const uint32_t *)(XIP_IMAGE + r->src_off);
		uint32_t *dst = (uint32_t *)r->dst;
		uint32_t words = (r->len + 3u) >> 2;
		report_rec(r);
		for (uint32_t w = 0; w < words; w++)
			dst[w] = src[w];
	}
	uint32_t sum = sum_records(h);
	if (sum != h->sum) {
		uart_puts("flash checksum mismatch $");
		uart_puthex(sum);
		uart_puts("\n");
		return 1;
	}
	boot(FDT_ADDR);
	return 0;
}

void main(void)
{
	UART(UART_LCR) = 0x80;
	UART(UART_DLL) = BAUD_DIVISOR & 0xFFu;
	UART(UART_DLM) = BAUD_DIVISOR >> 8;
	UART(UART_LCR) = 0x03; /* 8N1 */
	UART(UART_OSCR) = 0x10;
	UART(UART_FCR) = 0x07;
	/* The board shell muxes the probe's "FPGA BOOT OK" onto the pin
	 * right after reset; wait until it is done or the banner gets
	 * chopped up (~1.2 ms at 115200 for 14 characters). */
	delay(2000000);
	uart_puts("\nSystem16 GoRV32 ZSBL v11 flash-first\n");
	try_flash();
	try_sd();
	hang();
}
