// SPDX-License-Identifier: GPL-2.0-only
/* Polling block driver for the Gowin GoRV32 Plus APB SD host.
 *
 * The firmware image occupies physical sectors starting at LBA 0.  This
 * driver deliberately exposes only the root-filesystem window described by
 * gowin,root-lba/root-sectors, so Linux cannot overwrite its own boot image.
 */
#include <linux/blk-mq.h>
#include <linux/blkdev.h>
#include <linux/delay.h>
#include <linux/highmem.h>
#include <linux/io.h>
#include <linux/irqflags.h>
#include <linux/ktime.h>
#include <linux/math64.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/swab.h>

#define DRV_NAME "gorv32-sd"
#define SECTOR_SIZE 512
#define GRV1_MAGIC 0x31565247 /* "GRV1" little endian */

#define SD_ARG          0x00
#define SD_CMD          0x04
#define SD_RESP0        0x08
#define SD_DATA_TMO     0x18
#define SD_CTRL         0x1c
#define SD_CMD_TMO      0x20
#define SD_CLK_DIV      0x24
#define SD_RESET        0x28
#define SD_CMD_EVENT    0x34
#define SD_CMD_EVMASK   0x38
#define SD_DATA_EVENT   0x3c
#define SD_DATA_EVMASK  0x40
#define SD_BLK_SIZE     0x44
#define SD_BLK_COUNT    0x48
#define SD_TX           0x4c
#define SD_RX           0x50
#define SD_FIFO_STATUS  0x54

#define CMD_DONE        BIT(0)
#define CMD_ERROR       BIT(1)
#define DATA_DONE       BIT(0)
#define DATA_TIMEOUT    BIT(2)
#define DATA_CRC_ERROR  BIT(3)
#define DATA_TX_EMPTY   BIT(4)
#define DATA_RX_FULL    BIT(5)
#define FIFO_RX_EMPTY   BIT(1)
#define FIFO_TX_FULL    BIT(2)

#define ENGINE_RESET_DELAY_US 50
#define DATA_SETUP_DELAY_US   20
#define TRANSFER_TIMEOUT_NS   (10ULL * NSEC_PER_MSEC)

#define SD_INPUT_CLOCK_HZ           50000000U
#define CALIBRATION_SAFE_DIV        24U /* 1 MHz, 1-bit reference mode */
#define CALIBRATION_FALLBACK_DIV    32U /* 758 kHz if 1 MHz is marginal */
#define CALIBRATION_MAX_DIV         24U /* Test every divider, 25..1 MHz */
#define CALIBRATION_REFERENCE_SECTORS 16U
#define CALIBRATION_REFERENCE_ATTEMPTS 3U
#define CALIBRATION_SWEEP_SECTORS    8U
#define CALIBRATION_VERIFY_SECTORS  64U
#define CALIBRATION_VERIFY_CANDIDATES 3U
#define CALIBRATION_RESULT_COUNT \
	(2U * (CALIBRATION_MAX_DIV + 1U))

#define RESP_SHORT      BIT(0)
#define RESP_LONG       BIT(1)
#define CHECK_CRC       BIT(3)
#define CHECK_INDEX     BIT(4)
#define DATA_READ       BIT(5)
#define DATA_WRITE      BIT(6)

struct gorv32_sd {
	struct device *dev;
	void __iomem *base;
	u32 root_lba;
	u32 root_sectors;
	u32 rca;
	u32 clock_div;
	u32 data_clock_div;
	u32 wide;
	u32 sdhc;
	u32 swap_words;
	bool read_only;
	bool calibrating;
	u32 blocks_transferred;
	u32 transfer_retries;
	u32 rx_full_events;
	struct blk_mq_tag_set tag_set;
	struct gendisk *disk;
};

struct gorv32_sd_cal_result {
	u32 divider;
	bool wide;
	bool valid;
	bool verified;
	u64 kib_per_sec;
};

static inline u32 sd_readl(struct gorv32_sd *sd, u32 reg)
{
	return readl(sd->base + reg);
}

static inline void sd_writel(struct gorv32_sd *sd, u32 reg, u32 value)
{
	writel(value, sd->base + reg);
}

/* The GoRV32 APB window is strongly ordered.  Avoid the RISC-V readl()/
 * writel() fences only inside the FIFO service loop, where a fence after
 * every word is slow enough to let the tiny FIFO overflow. */
static inline u32 sd_fifo_readl(struct gorv32_sd *sd, u32 reg)
{
	return readl_relaxed(sd->base + reg);
}

static inline void sd_fifo_writel(struct gorv32_sd *sd, u32 reg, u32 value)
{
	writel_relaxed(value, sd->base + reg);
}

static void sd_engine_reset(struct gorv32_sd *sd)
{
	sd_writel(sd, SD_RESET, 1);
	udelay(ENGINE_RESET_DELAY_US);
	sd_writel(sd, SD_RESET, 0);
	udelay(ENGINE_RESET_DELAY_US);
	sd_writel(sd, SD_CLK_DIV, sd->clock_div);
	sd_writel(sd, SD_CMD_TMO, 0x8000);
	sd_writel(sd, SD_DATA_TMO, 0xffffff);
	sd_writel(sd, SD_CMD_EVMASK, 0x1f);
	sd_writel(sd, SD_DATA_EVMASK, 0x3f);
	sd_writel(sd, SD_CTRL, sd->wide);
	udelay(ENGINE_RESET_DELAY_US);
}

static int sd_command_raw(struct gorv32_sd *sd, u32 index, u32 arg,
			  u32 flags)
{
	u32 event;
	unsigned int spin;

	sd_writel(sd, SD_CMD_EVENT, 0);
	sd_writel(sd, SD_CMD, (index << 8) | flags);
	udelay(100);
	sd_writel(sd, SD_ARG, arg);
	for (spin = 0; spin < 2000000; spin++) {
		event = sd_readl(sd, SD_CMD_EVENT);
		if (event & CMD_ERROR)
			return -EIO;
		if (event & CMD_DONE)
			return 0;
		cpu_relax();
	}
	return -ETIMEDOUT;
}

static int sd_command(struct gorv32_sd *sd, u32 index, u32 arg, u32 flags)
{
	sd_engine_reset(sd);
	return sd_command_raw(sd, index, arg, flags);
}

static int sd_wait_transfer_state(struct gorv32_sd *sd, u32 rca)
{
	u32 status;
	unsigned int i;

	/* CMD7 may complete before the card has left its internal busy state.
	 * Poll CMD13 until READY_FOR_DATA is set and CURRENT_STATE is TRAN (4),
	 * rather than relying on a fixed delay that happens to work after the
	 * ZSBL has already initialized the card. */
	for (i = 0; i < 200; i++) {
		if (!sd_command(sd, 13, rca, RESP_SHORT | CHECK_CRC)) {
			status = sd_readl(sd, SD_RESP0);
			if ((status & BIT(8)) && ((status >> 9) & 0xf) == 4)
				return 0;
		}
		mdelay(1);
	}
	return -ETIMEDOUT;
}

static int sd_card_init(struct gorv32_sd *sd)
{
	u32 ocr;
	unsigned int i;
	bool v2 = false;

	sd->clock_div = 124; /* 200 kHz identification clock */
	sd->wide = 0;
	sd->rca = 0;
	sd_engine_reset(sd);
	mdelay(20);
	for (i = 0; i < 3 && !v2; i++) {
		sd_command(sd, 0, 0, 0);
		udelay(2000);
		v2 = !sd_command(sd, 8, 0x1aa, RESP_SHORT | CHECK_CRC) &&
			(sd_readl(sd, SD_RESP0) & 0xff) == 0xaa;
	}
	for (i = 0; i < 4000; i++) {
		if (sd_command(sd, 55, 0, RESP_SHORT | CHECK_CRC))
			return -EIO;
		if (sd_command(sd, 41, v2 ? 0x40ff8000 : 0x00ff8000,
			       RESP_SHORT))
			return -EIO;
		ocr = sd_readl(sd, SD_RESP0);
		if (ocr & BIT(31))
			break;
	}
	if (i == 4000)
		return -ETIMEDOUT;
	sd->sdhc = !!(ocr & BIT(30));
	if (sd_command(sd, 2, 0, RESP_LONG))
		return -EIO;
	if (sd_command(sd, 3, 0, RESP_SHORT | CHECK_CRC))
		return -EIO;
	sd->rca = sd_readl(sd, SD_RESP0) & 0xffff0000;
	if (sd_command(sd, 7, sd->rca, RESP_SHORT | CHECK_CRC))
		return -EIO;
	if (sd_wait_transfer_state(sd, sd->rca))
		return -ETIMEDOUT;
	for (i = 0; i < 3; i++) {
		mdelay(4);
		if (!sd_command(sd, 55, sd->rca, RESP_SHORT | CHECK_CRC) &&
		    !sd_command(sd, 6, 2, RESP_SHORT | CHECK_CRC)) {
			sd->wide = 1;
			break;
		}
	}
	sd->clock_div = sd->data_clock_div;
	return 0;
}

static int sd_set_bus_width(struct gorv32_sd *sd, bool wide)
{
	int error;

	/* ACMD6 itself is a command-line transaction.  Keep the old host-side
	 * width until the card has acknowledged its new width, then update CTRL. */
	error = sd_command(sd, 55, sd->rca, RESP_SHORT | CHECK_CRC);
	if (error)
		return error;
	error = sd_command(sd, 6, wide ? 2 : 0, RESP_SHORT | CHECK_CRC);
	if (error)
		return error;
	sd->wide = wide;
	sd_engine_reset(sd);
	return 0;
}

static int sd_prepare_mode(struct gorv32_sd *sd, bool wide, u32 divider)
{
	int error;

	/* A failed data command can leave the card outside TRAN.  A full card
	 * initialization makes every calibration candidate independent. */
	error = sd_card_init(sd);
	if (error)
		return error;
	sd->clock_div = CALIBRATION_SAFE_DIV;
	sd_engine_reset(sd);
	error = sd_set_bus_width(sd, wide);
	if (error)
		return error;
	sd->clock_div = divider;
	sd_engine_reset(sd);
	return 0;
}

static int sd_transfer_block_once(struct gorv32_sd *sd, u32 lba,
				  void *buffer, bool write)
{
	u32 *words = buffer;
	u32 arg = sd->sdhc ? lba : lba << 9;
	u32 event, value;
	u64 start_ns;
	unsigned int done = 0, spin;
	bool data_done = false;

	sd_engine_reset(sd);
	sd_writel(sd, SD_DATA_EVENT, 0);
	sd_writel(sd, SD_BLK_SIZE, SECTOR_SIZE - 1);
	sd_writel(sd, SD_BLK_COUNT, 0);
	udelay(DATA_SETUP_DELAY_US);
	/* CMD24 starts consuming the write FIFO as soon as its data phase
	 * begins.  Preload the FIFO before starting the command; otherwise the
	 * controller can raise WrFIFOEmpErr (data event 0x12) before the CPU
	 * gets its first chance to service it. */
	if (write) {
		while (done < 128 &&
		       !(sd_fifo_readl(sd, SD_FIFO_STATUS) & FIFO_TX_FULL)) {
			value = sd->swap_words ? swab32(words[done]) : words[done];
			sd_fifo_writel(sd, SD_TX, value);
			done++;
		}
	}
	sd_writel(sd, SD_CMD_EVENT, 0);
	sd_writel(sd, SD_CMD, ((write ? 24 : 17) << 8) | RESP_SHORT |
		  CHECK_CRC | CHECK_INDEX | (write ? DATA_WRITE : DATA_READ));
	udelay(DATA_SETUP_DELAY_US);
	sd_writel(sd, SD_ARG, arg);
	start_ns = ktime_get_ns();

	for (spin = 0; spin < 4000000; spin++) {
		if (write) {
			while (done < 128 &&
			       !(sd_fifo_readl(sd, SD_FIFO_STATUS) & FIFO_TX_FULL)) {
				value = sd->swap_words ? swab32(words[done]) : words[done];
				sd_fifo_writel(sd, SD_TX, value);
				done++;
			}
		} else {
			while (done < 128 &&
			       !(sd_fifo_readl(sd, SD_FIFO_STATUS) & FIFO_RX_EMPTY)) {
				value = sd_fifo_readl(sd, SD_RX);
				words[done++] = sd->swap_words ? swab32(value) : value;
			}
		}
		event = sd_readl(sd, SD_CMD_EVENT);
		if (event & CMD_ERROR)
			return -EIO;
		event = sd_readl(sd, SD_DATA_EVENT);
		if (event & (DATA_TIMEOUT | DATA_CRC_ERROR | DATA_TX_EMPTY))
			return -EIO;
		if (event & DATA_RX_FULL) {
			sd->rx_full_events++;
			sd_writel(sd, SD_DATA_EVENT, 0);
		}
		if (event & DATA_DONE)
			data_done = true;
		/* DATA_DONE describes the card-side transfer.  A few words may
		 * still be crossing into the APB RX FIFO, so finish draining them
		 * and sample the final FIFO event before completing the request. */
		if (data_done && done == 128)
			return 0;
		if (!(spin & 0xff) &&
		    ktime_get_ns() - start_ns > TRANSFER_TIMEOUT_NS)
			return -ETIMEDOUT;
		cpu_relax();
	}
	return -ETIMEDOUT;
}

static u32 sd_clock_hz(u32 divider)
{
	return SD_INPUT_CLOCK_HZ / (2U * (divider + 1U));
}

static u32 sd_next_slower_divider(u32 divider)
{
	/* new_div = 2 * old_div + 1 halves the SD clock exactly. */
	return min(2U * divider + 1U, 124U);
}

static int sd_transfer_block(struct gorv32_sd *sd, u32 lba, void *buffer,
			     bool write)
{
	unsigned long irq_flags;
	u32 last_cmd = 0, last_data = 0, last_fifo = 0;
	u32 initial_divider = sd->clock_div;
	u32 rx_full_before = sd->rx_full_events;
	int attempt, error = -EIO;

	/* The GoRV32 SD host has only a small programmed-I/O FIFO.  A timer or
	 * UART interrupt between FIFO reads can overrun it, especially after the
	 * normal Linux interrupt handlers have been enabled.  Keep interrupts
	 * disabled only for one 512-byte transaction; they are enabled again
	 * between sectors in a multi-sector block request. */
	local_irq_save(irq_flags);
	for (attempt = 0; attempt < 3; attempt++) {
		error = sd_transfer_block_once(sd, lba, buffer, write);
		if (!error)
			break;
		last_cmd = sd_readl(sd, SD_CMD_EVENT);
		last_data = sd_readl(sd, SD_DATA_EVENT);
		last_fifo = sd_readl(sd, SD_FIFO_STATUS);
		if (!sd->calibrating && attempt < 2 && sd->clock_div < 124) {
			sd->clock_div = sd_next_slower_divider(sd->clock_div);
			sd->data_clock_div = sd->clock_div;
		}
	}
	local_irq_restore(irq_flags);
	/* A handled FIFO-full event means the data survived, but the mode has no
	 * service margin.  Slow the following block before it becomes an error. */
	if (!sd->calibrating && !error &&
	    sd->rx_full_events != rx_full_before &&
	    sd->clock_div == initial_divider && sd->clock_div < 124) {
		sd->clock_div = sd_next_slower_divider(sd->clock_div);
		sd->data_clock_div = sd->clock_div;
	}
	sd->blocks_transferred++;
	sd->transfer_retries += min(attempt, 2);
	if (!sd->calibrating && sd->clock_div != initial_divider)
		dev_warn_ratelimited(sd->dev,
			"adaptive SD downshift: divider %u -> %u (%u Hz)\n",
			initial_divider, sd->clock_div,
			sd_clock_hz(sd->clock_div));
	if (error && !sd->calibrating)
		dev_err_ratelimited(sd->dev,
			"%s LBA %u failed after %d attempts: cmd=%08x data=%08x fifo=%08x\n",
			write ? "write" : "read", lba, attempt,
			last_cmd, last_data, last_fifo);
	else if (attempt && !sd->calibrating)
		dev_warn_ratelimited(sd->dev,
			"%s LBA %u recovered after %d retries: cmd=%08x data=%08x fifo=%08x\n",
			write ? "write" : "read", lba, attempt,
			last_cmd, last_data, last_fifo);

	return error;
}

static int sd_read_calibration_reference(struct gorv32_sd *sd, u8 *reference,
					 u8 *scratch, u32 sectors)
{
	u32 retries_before = sd->transfer_retries;
	u32 rx_full_before = sd->rx_full_events;
	u32 i;
	int error;

	/* Two identical, zero-retry reads establish a trustworthy reference.
	 * Comparing later candidates against only one possibly-corrupt read
	 * could otherwise bless silent FIFO corruption. */
	for (i = 0; i < sectors; i++) {
		error = sd_transfer_block(sd, i,
					  reference + i * SECTOR_SIZE, false);
		if (error)
			return error;
		if (sd->transfer_retries != retries_before ||
		    sd->rx_full_events != rx_full_before)
			return -EAGAIN;
	}
	for (i = 0; i < sectors; i++) {
		error = sd_transfer_block(sd, i, scratch, false);
		if (error)
			return error;
		if (sd->transfer_retries != retries_before ||
		    sd->rx_full_events != rx_full_before)
			return -EAGAIN;
		if (memcmp(scratch, reference + i * SECTOR_SIZE,
			   SECTOR_SIZE))
			return -EILSEQ;
	}
	return 0;
}

static int sd_make_calibration_reference(struct gorv32_sd *sd, u8 *reference,
					 u8 *scratch, u32 sectors,
					 u32 divider)
{
	unsigned int attempt;
	int error = -EIO;

	for (attempt = 0; attempt < CALIBRATION_REFERENCE_ATTEMPTS; attempt++) {
		error = sd_prepare_mode(sd, false, divider);
		if (!error)
			error = sd_read_calibration_reference(sd, reference, scratch,
							      sectors);
		if (!error)
			return 0;
	}
	return error;
}

static int sd_test_calibration_mode(struct gorv32_sd *sd,
				    const u8 *reference, u8 *scratch,
				    u32 reference_sectors, u32 sectors,
				    bool wide, u32 divider,
				    u64 *kib_per_sec)
{
	u32 retries_before;
	u32 rx_full_before;
	u64 start_ns, elapsed_us;
	u32 i, reference_sector;
	int error;

	error = sd_prepare_mode(sd, wide, divider);
	if (error)
		return error;
	retries_before = sd->transfer_retries;
	rx_full_before = sd->rx_full_events;
	start_ns = ktime_get_ns();
	for (i = 0; i < sectors; i++) {
		reference_sector = i % reference_sectors;
		error = sd_transfer_block(sd, reference_sector, scratch, false);
		if (error)
			return error;
		if (sd->transfer_retries != retries_before ||
		    sd->rx_full_events != rx_full_before)
			return -EAGAIN;
		if (memcmp(scratch,
			   reference + reference_sector * SECTOR_SIZE,
			   SECTOR_SIZE))
			return -EILSEQ;
	}
	elapsed_us = max_t(u64,
			   div_u64(ktime_get_ns() - start_ns, NSEC_PER_USEC), 1);
	/* One 512-byte sector is exactly 0.5 KiB. */
	*kib_per_sec = div64_u64((u64)sectors * 500000ULL, elapsed_us);
	return 0;
}

static int sd_best_calibration_result(struct gorv32_sd_cal_result *results)
{
	u64 best_rate = 0, best_wire_rate = 0, wire_rate;
	int best = -1;
	unsigned int i;

	for (i = 0; i < CALIBRATION_RESULT_COUNT; i++) {
		if (!results[i].valid)
			continue;
		wire_rate = (u64)sd_clock_hz(results[i].divider) *
			(results[i].wide ? 4U : 1U);
		if (best < 0 || results[i].kib_per_sec > best_rate ||
		    (results[i].kib_per_sec == best_rate &&
		     wire_rate < best_wire_rate)) {
			best = i;
			best_rate = results[i].kib_per_sec;
			best_wire_rate = wire_rate;
		}
	}
	return best;
}

static int sd_auto_calibrate(struct gorv32_sd *sd)
{
	struct gorv32_sd_cal_result results[CALIBRATION_RESULT_COUNT] = { };
	u8 *reference = NULL, *scratch = NULL;
	u32 reference_divider = CALIBRATION_SAFE_DIV;
	u32 sweep_modes = 0, verified_modes = 0, divider;
	u64 verified_rate = 0;
	unsigned int index = 0, width, i;
	int best, error, result = -EIO;

	reference = kmalloc_array(CALIBRATION_REFERENCE_SECTORS,
				  SECTOR_SIZE, GFP_KERNEL);
	scratch = kmalloc(SECTOR_SIZE, GFP_KERNEL);
	if (!reference || !scratch) {
		result = -ENOMEM;
		goto out;
	}

	sd->calibrating = true;
	dev_info(sd->dev,
		 "auto calibration: testing 1-bit and 4-bit dividers from 25 to 1 MHz\n");
	error = sd_make_calibration_reference(sd, reference, scratch,
					      CALIBRATION_REFERENCE_SECTORS,
					      reference_divider);
	if (error) {
		reference_divider = CALIBRATION_FALLBACK_DIV;
		error = sd_make_calibration_reference(sd, reference, scratch,
						      CALIBRATION_REFERENCE_SECTORS,
						      reference_divider);
	}
	if (error) {
		dev_err(sd->dev,
			"auto calibration: no repeatable reference read (%d)\n",
			error);
		result = error;
		goto out;
	}

	for (width = 0; width < 2; width++) {
		for (divider = 0; divider <= CALIBRATION_MAX_DIV; divider++) {
			results[index].wide = !!width;
			results[index].divider = divider;
			error = sd_test_calibration_mode(sd, reference, scratch,
					CALIBRATION_REFERENCE_SECTORS,
					CALIBRATION_SWEEP_SECTORS,
					!!width, divider,
					&results[index].kib_per_sec);
			if (!error) {
				results[index].valid = true;
				sweep_modes++;
			} else {
				dev_dbg(sd->dev,
					"calibration rejected %u-bit divider %u: %d\n",
					width ? 4U : 1U, divider, error);
			}
			index++;
		}
	}

	/* Validate the three fastest short-sweep results.  Ranking the final
	 * choice by their longer measurements avoids optimizing for one lucky
	 * eight-sector timing sample. */
	while (verified_modes < CALIBRATION_VERIFY_CANDIDATES) {
		best = sd_best_calibration_result(results);
		if (best < 0)
			break;
		results[best].valid = false;
		error = sd_test_calibration_mode(sd, reference, scratch,
				CALIBRATION_REFERENCE_SECTORS,
				CALIBRATION_VERIFY_SECTORS,
				results[best].wide, results[best].divider,
				&verified_rate);
		if (!error) {
			results[best].verified = true;
			results[best].kib_per_sec = verified_rate;
			verified_modes++;
		}
	}

	/* Select by the long-run rates, then reapply and recheck the winner so
	 * card and host are guaranteed to leave calibration in that mode. */
	for (i = 0; i < CALIBRATION_RESULT_COUNT; i++)
		results[i].valid = results[i].verified;
	for (;;) {
		best = sd_best_calibration_result(results);
		if (best < 0)
			break;
		error = sd_test_calibration_mode(sd, reference, scratch,
				CALIBRATION_REFERENCE_SECTORS,
				CALIBRATION_REFERENCE_SECTORS,
				results[best].wide, results[best].divider,
				&verified_rate);
		if (!error) {
			sd->data_clock_div = results[best].divider;
			dev_info(sd->dev,
				 "auto calibration selected %u-bit divider %u "
				 "(%u Hz, %llu KiB/s); %u/%u sweep modes, "
				 "%u long-run modes passed\n",
				 results[best].wide ? 4U : 1U,
				 results[best].divider,
				 sd_clock_hz(results[best].divider),
				 (unsigned long long)verified_rate,
				 sweep_modes, CALIBRATION_RESULT_COUNT,
				 verified_modes);
			result = 0;
			goto out;
		}
		results[best].valid = false;
		verified_modes--;
	}

	/* The reference mode was already proven with two clean reads. */
	error = sd_prepare_mode(sd, false, reference_divider);
	if (error) {
		result = error;
		goto out;
	}
	sd->data_clock_div = reference_divider;
	dev_warn(sd->dev,
		 "auto calibration found no faster stable mode; using 1-bit %u Hz\n",
		 sd_clock_hz(reference_divider));
	result = 0;
out:
	sd->calibrating = false;
	kfree(scratch);
	kfree(reference);
	return result;
}

static void sd_read_selftest(struct gorv32_sd *sd, u32 sectors)
{
	u32 buffer[128];
	u32 retries_before = sd->transfer_retries;
	u32 rx_full_before = sd->rx_full_events;
	u64 start_ns, elapsed_ms, kib_per_sec;
	u32 i;

	if (!sectors)
		return;
	sectors = min(sectors, 1024U);
	start_ns = ktime_get_ns();
	for (i = 0; i < sectors; i++) {
		if (sd_transfer_block(sd, sd->root_lba + i, buffer, false)) {
			dev_err(sd->dev, "read benchmark stopped at sector %u/%u\n",
				i, sectors);
			return;
		}
	}
	elapsed_ms = max_t(u64, div_u64(ktime_get_ns() - start_ns, 1000000), 1);
	kib_per_sec = div64_u64((u64)sectors * 500, elapsed_ms);
	dev_info(sd->dev,
		 "read benchmark: %u sectors in %llu ms (%llu KiB/s), "
		 "%u retries, %u FIFO-full events\n",
		 sectors, (unsigned long long)elapsed_ms,
		 (unsigned long long)kib_per_sec,
		 sd->transfer_retries - retries_before,
		 sd->rx_full_events - rx_full_before);
}

static int sd_detect_word_order(struct gorv32_sd *sd, struct device *dev)
{
	u32 sector[128];
	u8 *bytes = (u8 *)sector;
	int error;

	/* Use the boot-container magic, exactly like the hardware-proven ZSBL.
	 * Unlike the root filesystem, LBA 0 is guaranteed to exist whenever this
	 * kernel has reached probe, because the ZSBL loaded the kernel from it. */
	error = sd_transfer_block(sd, 0, sector, false);
	if (error && sd->clock_div < 24) {
		dev_warn(dev,
			 "CMD17 failed with divider %u; retrying at 1 MHz\n",
			 sd->clock_div);
		sd->clock_div = 24;
		error = sd_transfer_block(sd, 0, sector, false);
	}
	if (error)
		return -EIO;
	if (sector[0] == GRV1_MAGIC) {
		sd->swap_words = 0;
	} else if (swab32(sector[0]) == GRV1_MAGIC) {
		sd->swap_words = 1;
	} else {
		dev_err(dev, "LBA 0 has no GRV1 magic (raw word %08x)\n",
			sector[0]);
		return -EINVAL;
	}

	/* This is a diagnostic, not a probe condition. A block driver must not
	 * refuse to register merely because a particular filesystem is absent.
	 * The ext2 driver will perform the authoritative mount-time validation. */
	if (sd_transfer_block(sd, sd->root_lba + 2, sector, false)) {
		dev_warn(dev, "cannot read root superblock sector at physical LBA %u\n",
			 sd->root_lba + 2);
		return 0;
	}
	if (bytes[56] != 0x53 || bytes[57] != 0xef)
		dev_warn(dev,
			 "no ext magic at physical LBA %u byte 56: got %02x %02x "
			 "(first word %08x)\n",
			 sd->root_lba + 2, bytes[56], bytes[57], sector[0]);
	else
		dev_info(dev, "ext superblock found at physical LBA %u\n",
			 sd->root_lba + 2);
	return 0;
}

static blk_status_t gorv32_sd_queue_rq(struct blk_mq_hw_ctx *hctx,
				       const struct blk_mq_queue_data *bd)
{
	struct request *rq = bd->rq;
	struct gorv32_sd *sd = rq->q->queuedata;
	struct req_iterator iter;
	struct bio_vec bvec;
	sector_t sector = blk_rq_pos(rq);
	bool write = op_is_write(req_op(rq));
	int error = 0;

	blk_mq_start_request(rq);
	if (req_op(rq) == REQ_OP_FLUSH)
		goto complete;
	if (req_op(rq) != REQ_OP_READ && req_op(rq) != REQ_OP_WRITE) {
		error = -EOPNOTSUPP;
		goto complete;
	}
	if (sector + blk_rq_sectors(rq) > sd->root_sectors) {
		error = -EIO;
		goto complete;
	}
	rq_for_each_segment(bvec, rq, iter) {
		u8 *buffer = kmap_local_page(bvec.bv_page) + bvec.bv_offset;
		unsigned int offset;

		if (bvec.bv_len & (SECTOR_SIZE - 1)) {
			error = -EIO;
			kunmap_local(buffer);
			break;
		}
		for (offset = 0; offset < bvec.bv_len; offset += SECTOR_SIZE) {
			error = sd_transfer_block(sd, sd->root_lba + sector,
						  buffer + offset, write);
			if (error)
				break;
			sector++;
		}
		kunmap_local(buffer);
		if (error)
			break;
	}
complete:
	blk_mq_end_request(rq, error ? BLK_STS_IOERR : BLK_STS_OK);
	return BLK_STS_OK;
}

static const struct blk_mq_ops gorv32_sd_mq_ops = {
	.queue_rq = gorv32_sd_queue_rq,
};

static const struct block_device_operations gorv32_sd_fops = {
	.owner = THIS_MODULE,
};

static int gorv32_sd_probe(struct platform_device *pdev)
{
	struct gorv32_sd *sd;
	struct queue_limits limits = {
		.logical_block_size = SECTOR_SIZE,
		.physical_block_size = SECTOR_SIZE,
		.max_hw_sectors = 8,
	};
	u32 selftest_sectors = 0;
	bool auto_calibrate;
	int error;

	sd = devm_kzalloc(&pdev->dev, sizeof(*sd), GFP_KERNEL);
	if (!sd)
		return -ENOMEM;
	sd->dev = &pdev->dev;
	sd->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(sd->base))
		return PTR_ERR(sd->base);
	if (of_property_read_u32(pdev->dev.of_node, "gowin,root-lba",
				 &sd->root_lba) ||
	    of_property_read_u32(pdev->dev.of_node, "gowin,root-sectors",
				 &sd->root_sectors))
		return dev_err_probe(&pdev->dev, -EINVAL,
				     "missing root filesystem window\n");
	if (!sd->root_sectors ||
	    sd->root_lba > U32_MAX - (sd->root_sectors - 1U))
		return dev_err_probe(&pdev->dev, -EINVAL,
				     "invalid root filesystem window\n");
	sd->data_clock_div = 24; /* safe default: 1 MHz from the 50 MHz APB clock */
	of_property_read_u32(pdev->dev.of_node, "gowin,data-clock-div",
			     &sd->data_clock_div);
	if (sd->data_clock_div > 124)
		return dev_err_probe(&pdev->dev, -EINVAL,
				     "invalid SD data clock divider %u\n",
				     sd->data_clock_div);
	sd->read_only = of_property_read_bool(pdev->dev.of_node,
					      "gowin,read-only");
	auto_calibrate = of_property_read_bool(pdev->dev.of_node,
					       "gowin,auto-calibrate");
	of_property_read_u32(pdev->dev.of_node, "gowin,self-test-sectors",
			     &selftest_sectors);

	error = sd_card_init(sd);
	if (error)
		return dev_err_probe(&pdev->dev, error, "card initialization failed\n");
	if (auto_calibrate) {
		error = sd_prepare_mode(sd, false, CALIBRATION_SAFE_DIV);
		if (error)
			return dev_err_probe(&pdev->dev, error,
					     "cannot enter calibration reference mode\n");
	}
	error = sd_detect_word_order(sd, &pdev->dev);
	if (error)
		return dev_err_probe(&pdev->dev, error,
				     "cannot determine SD FIFO word order\n");
	if (auto_calibrate) {
		error = sd_auto_calibrate(sd);
		if (error)
			return dev_err_probe(&pdev->dev, error,
					     "auto calibration failed; refusing unverified media\n");
	}
	sd_read_selftest(sd, selftest_sectors);

	sd->tag_set.ops = &gorv32_sd_mq_ops;
	sd->tag_set.nr_hw_queues = 1;
	sd->tag_set.queue_depth = 1;
	sd->tag_set.numa_node = NUMA_NO_NODE;
	sd->tag_set.flags = BLK_MQ_F_NO_SCHED_BY_DEFAULT;
	sd->tag_set.driver_data = sd;
	error = blk_mq_alloc_tag_set(&sd->tag_set);
	if (error)
		return error;
	sd->disk = blk_mq_alloc_disk(&sd->tag_set, &limits, sd);
	if (IS_ERR(sd->disk)) {
		error = PTR_ERR(sd->disk);
		goto free_tags;
	}
	sd->disk->fops = &gorv32_sd_fops;
	sd->disk->flags |= GENHD_FL_NO_PART;
	set_disk_ro(sd->disk, sd->read_only);
	strscpy(sd->disk->disk_name, "gorv32sd", DISK_NAME_LEN);
	set_capacity(sd->disk, sd->root_sectors);
	platform_set_drvdata(pdev, sd);
	error = add_disk(sd->disk);
	if (error)
		goto put_disk;
	dev_info(&pdev->dev, "%u sectors at physical LBA %u, %s, %s word order\n",
		 sd->root_sectors, sd->root_lba, sd->wide ? "4-bit" : "1-bit",
		 sd->swap_words ? "swapped" : "native");
	return 0;

put_disk:
	put_disk(sd->disk);
free_tags:
	blk_mq_free_tag_set(&sd->tag_set);
	return error;
}

static void gorv32_sd_remove(struct platform_device *pdev)
{
	struct gorv32_sd *sd = platform_get_drvdata(pdev);

	del_gendisk(sd->disk);
	put_disk(sd->disk);
	blk_mq_free_tag_set(&sd->tag_set);
}

static const struct of_device_id gorv32_sd_of_match[] = {
	{ .compatible = "gowin,gorv32-sdhost" },
	{ }
};
MODULE_DEVICE_TABLE(of, gorv32_sd_of_match);

static struct platform_driver gorv32_sd_driver = {
	.probe = gorv32_sd_probe,
	.remove = gorv32_sd_remove,
	.driver = {
		.name = DRV_NAME,
		.of_match_table = gorv32_sd_of_match,
	},
};
module_platform_driver(gorv32_sd_driver);

MODULE_DESCRIPTION("Gowin GoRV32 Plus polling SD block driver");
MODULE_LICENSE("GPL");
